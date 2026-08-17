import Foundation
import WebKit
import DSHKit

/// `WKWebView` 侧的接线。
///
/// 这是整个包里唯一 import WebKit 的地方之一（另一处是 DSHApp 的
/// `WebContainer`）。`ControlChannel` 本身不认识 WebKit，所以协议逻辑可以
/// 无头测试；这里只做「把 WKWebView 的两个 API 接到通道上」。
@MainActor
public final class WebViewControlBridge: NSObject, WKScriptMessageHandler, SurfaceScriptEvaluator {
    private let channel: ControlChannel
    private weak var webView: WKWebView?

    public init(channel: ControlChannel) {
        self.channel = channel
        super.init()
    }

    /// 把通道装到一个 `WKWebView` 上。
    public func install(on webView: WKWebView) {
        self.webView = webView
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: ControlChannel.messageHandlerName)
        controller.add(self, name: ControlChannel.messageHandlerName)
        channel.attach(evaluator: self)
    }

    public func uninstall() {
        webView?.configuration.userContentController
            .removeScriptMessageHandler(forName: ControlChannel.messageHandlerName)
        webView = nil
        channel.detachEvaluator()
    }

    /// Web → Native。`message.body` 是不可信输入，原样交给通道去校验。
    public nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // WKScriptMessage 只能在主线程读；body 取出后立刻转成 Sendable 的文本。
        MainActor.assumeIsolated {
            guard message.name == ControlChannel.messageHandlerName else { return }
            channel.receive(rawBody: message.body)
        }
    }

    /// Native → Web。
    public func evaluate(_ javaScript: String) async throws {
        guard let webView else { throw ControlChannelError.webViewUnavailable }
        _ = try await webView.evaluateJavaScript(javaScript)
    }
}
