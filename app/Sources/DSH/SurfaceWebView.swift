import DSHSurface
import SwiftUI
import WebKit

/// Hosts the composed client roster.
///
/// This is not a wrapper around the official product: the profile this loads
/// has no `dsh-web-app` in it. The rows rendering here are the ones our own
/// bundle listed, and replacing any one of them with a native slot is a change
/// to that list — which is the whole point of route C. Until the last row is
/// replaced, they render here.
///
/// The bridge is how chrome on this side of the view talks to the studio
/// client plugin on the other. It is our own channel, not a Harness seam.
struct SurfaceWebView: NSViewRepresentable {
    let url: URL
    let bridge: SurfaceBridge

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // The surface is a local, first-party app shell; the browser chrome
        // affordances that would normally guard a remote page are noise here.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(context.coordinator, name: SurfaceFrame.handlerName)
        // Hide the official sidebar column before the client plugin applies.
        // That column must stay mounted (settings is position:fixed inside it)
        // but it must not occupy a track — and this must not depend on a
        // class on <html>, which theme boot is free to replace.
        configuration.userContentController.addUserScript(Self.hideOfficialRailScript)

        let view = SurfaceWKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        view.allowsBackForwardNavigationGestures = false
        context.coordinator.attach(view)
        bridge.attach(context.coordinator)
        ChromeLog.line("webview makeNSView load \(url.absoluteString)")
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        view.load(request)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let loaded = view.url
        if loaded == nil {
            ChromeLog.line("webview updateNSView loaded=nil skip")
            return
        }
        let same = SurfacePageURL.same(loaded, as: url)
        ChromeLog.line(
            "webview updateNSView loaded=\(loaded?.absoluteString ?? "nil") wanted=\(url.absoluteString) same=\(same)"
        )
        guard !same else { return }
        ChromeLog.line("webview RELOAD \(url.absoluteString)")
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        view.load(request)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.titleObservation?.invalidate()
        coordinator.bridge.detach()
        view.configuration.userContentController.removeScriptMessageHandler(forName: SurfaceFrame.handlerName)
    }

    func makeCoordinator() -> Coordinator { Coordinator(bridge: bridge) }

    /// Keep in lockstep with `packages/bundle/src/hide-official-rail.js` `RAIL_CSS`.
    private static let hideOfficialRailScript = WKUserScript(
        source: """
        (function () {
          var css = '[class*="_frame"][data-details-collapsed]{grid-template-columns:0px minmax(0,1fr) 0px !important}[class*="_frame"]:not([data-details-collapsed]){grid-template-columns:0px minmax(0,1fr) minmax(300px,520px) !important}[class*="_sidebarCol"]{width:0 !important;max-width:0 !important;min-width:0 !important;padding:0 !important;border:none !important;overflow:hidden !important}';
          function ensure() {
            if (!document.documentElement) return;
            if (document.getElementById('dsh-studio-hide-rail')) return;
            var tag = document.createElement('style');
            tag.id = 'dsh-studio-hide-rail';
            tag.textContent = css;
            (document.head || document.documentElement).appendChild(tag);
          }
          ensure();
          document.addEventListener('DOMContentLoaded', ensure);
          new MutationObserver(ensure).observe(document.documentElement, { childList: true, subtree: true });
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true
    )

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, SurfaceTransport {
        let bridge: SurfaceBridge
        weak var webView: WKWebView?
        var titleObservation: NSKeyValueObservation?

        init(bridge: SurfaceBridge) { self.bridge = bridge }

        func attach(_ view: WKWebView) {
            webView = view
            titleObservation = view.observe(\.title, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async {
                    ChromeLog.line("webview.title=\(self?.webView?.title ?? "")")
                    self?.applyWindowTitle()
                }
            }
            applyWindowTitle()
        }

        func applyWindowTitle() {
            StudioChrome.apply(StudioChrome.windowTitle, window: webView?.window)
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == SurfaceFrame.handlerName else { return }
            let body = message.body
            Task { @MainActor in
                self.bridge.receive(body)
            }
        }

        func evaluate(_ javascript: String) async throws {
            guard let webView else { throw SurfaceError.detached }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                webView.evaluateJavaScript(javascript) { _, error in
                    if let error, !SurfaceEvaluate.isUnsupportedResult(error) {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            ChromeLog.line("webview didStart \(webView.url?.absoluteString ?? "nil")")
            bridge.notePageReset()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ChromeLog.line("webview didFinish \(webView.url?.absoluteString ?? "nil") pageTitle=\(webView.title ?? "")")
            applyWindowTitle()
        }

        /// Anything that is not our own surface belongs in the user's browser.
        /// A docs link should not replace the app with a web page and strand
        /// the user with no back button.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard let target = action.request.url else { return decisionHandler(.allow) }
            let isSurface = target.host == "127.0.0.1" || target.host == "localhost"
            if isSurface {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
                NSWorkspace.shared.open(target)
            }
        }
    }
}

/// Command keys belong to the app menu. A focused WKWebView otherwise
/// swallows ⌘N (WebKit's "new window") before SwiftUI sees the shortcut.
final class SurfaceWKWebView: WKWebView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command), NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
