import SwiftUI
import WebKit
import DSHSurface

/// 承载官方 Web UI 的容器。
///
/// 混合期的一半屏幕归它。W7 之后它不再渲染任何 UI，W8 整个删掉
/// （ARCHITECTURE.md §8）—— 那时候删的只是这个文件和 DSHSurface，
/// 不动任何数据路径。
public struct WebContainer: NSViewRepresentable {
    private let bridge: WebViewControlBridge
    private let url: URL?

    public init(bridge: WebViewControlBridge, url: URL?) {
        self.bridge = bridge
        self.url = url
    }

    public func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // 官方壳自己会解析 `window.__DSH_BOOT__` 并 fetch client 插件 bundle：
        // 我们不注入 <script>、不改官方页面（ARCHITECTURE.md §2.3）。
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = false
        bridge.install(on: webView)
        if let url {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    public func updateNSView(_ webView: WKWebView, context: Context) {
        guard let url, webView.url == nil else { return }
        webView.load(URLRequest(url: url))
    }
}
