import SwiftUI
import WebKit

struct WebContainer: NSViewRepresentable {
    let url: URL
    let stylesheet: String

    func makeCoordinator() -> Coordinator {
        Coordinator(fallback: Self.fallbackURL(from: url), stylesheet: stylesheet)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        let script = WKUserScript(
            source: Self.injectionSource(stylesheet),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(script)
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        view.setValue(false, forKey: "drawsBackground")
        view.load(URLRequest(url: url))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.stylesheet = stylesheet
        if view.url?.host != url.host || view.url?.port != url.port {
            view.load(URLRequest(url: url))
        } else {
            view.evaluateJavaScript(Self.applySource(stylesheet), completionHandler: nil)
        }
    }

    static func fallbackURL(from url: URL) -> URL {
        RuntimeSupervisor.swapLoopback(url)
    }

    static func injectionSource(_ stylesheet: String) -> String {
        let escaped = stylesheet
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
        return """
        (function() {
          const css = `\(escaped)`;
          const apply = () => {
            let el = document.getElementById('dsh-studio-theme');
            if (!el) {
              el = document.createElement('style');
              el.id = 'dsh-studio-theme';
              (document.documentElement || document.head || document.body).appendChild(el);
            }
            el.textContent = css;
          };
          apply();
          document.addEventListener('DOMContentLoaded', apply);
        })();
        """
    }

    static func applySource(_ stylesheet: String) -> String {
        let escaped = stylesheet
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
        return """
        (function() {
          const css = `\(escaped)`;
          let el = document.getElementById('dsh-studio-theme');
          if (!el) {
            el = document.createElement('style');
            el.id = 'dsh-studio-theme';
            (document.documentElement || document.head || document.body).appendChild(el);
          }
          el.textContent = css;
        })();
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let fallback: URL
        var stylesheet: String
        private var didTryFallback = false

        init(fallback: URL, stylesheet: String) {
            self.fallback = fallback
            self.stylesheet = stylesheet
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            tryFallback(webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            tryFallback(webView)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            if let http = navigationResponse.response as? HTTPURLResponse, http.statusCode == 403, !didTryFallback {
                didTryFallback = true
                decisionHandler(.cancel)
                webView.load(URLRequest(url: fallback))
                return
            }
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }

        private func tryFallback(_ webView: WKWebView) {
            guard !didTryFallback else { return }
            didTryFallback = true
            webView.load(URLRequest(url: fallback))
        }
    }
}
