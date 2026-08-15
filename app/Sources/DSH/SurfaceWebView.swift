import SwiftUI
import WebKit

/// Hosts the composed client roster.
///
/// This is not a wrapper around the official product: the profile this loads
/// has no `dsh-web-app` in it. The rows rendering here are the ones our own
/// bundle listed, and replacing any one of them with a native slot is a change
/// to that list — which is the whole point of route C. Until the last row is
/// replaced, they render here.
struct SurfaceWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // The surface is a local, first-party app shell; the browser chrome
        // affordances that would normally guard a remote page are noise here.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        view.allowsBackForwardNavigationGestures = false
        view.load(URLRequest(url: url))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard view.url != url else { return }
        view.load(URLRequest(url: url))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
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
