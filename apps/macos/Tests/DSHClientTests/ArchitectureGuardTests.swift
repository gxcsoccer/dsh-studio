import Testing
import Foundation

/// **ADR-0002 的可执行形式。**
///
/// 「领域数据永不经过官方 UI 壳」这条不变量靠人肉 review 是守不住的：一次
/// 「就这一个字段先过控制通道吧」的妥协就能把它掏空。所以这里用源码扫描把
/// 它变成一个会失败的测试 —— 谁在 DSHClient 里 import 浏览器框架、谁在
/// DSHSurface 里搬运会话，CI 就红。
@Suite("架构不变量：两条通道硬隔离（ADR-0002）")
struct ArchitectureGuardTests {
    /// 从测试文件位置回溯到包根：Tests/DSHClientTests/<this file>
    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func swiftFiles(in target: String) throws -> [(name: String, text: String)] {
        let directory = ArchitectureGuardTests.packageRoot
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent(target, isDirectory: true)
        let urls = FileManager.default
            .enumerator(at: directory, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        return try urls.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    @Test("数据通道 target 里不存在官方 UI 壳这个概念")
    func dataChannelKnowsNothingAboutTheShell() throws {
        let files = try swiftFiles(in: "DSHClient")
        #expect(!files.isEmpty, "源码扫描没找到文件，守卫失效了")
        // 这些词一个都不许出现：出现即意味着数据通道开始认识渲染宿主。
        let forbidden = [
            "WebKit", "WebView", "webView", "WKWebView", "postMessage",
            "evaluateJavaScript", "javaScript", "userContentController",
            "slot", "Slot", "manifest", "Manifest",
        ]
        for file in files {
            for token in forbidden {
                #expect(
                    !file.text.contains(token),
                    "DSHClient/\(file.name) 出现了 `\(token)` —— 数据通道不该认识渲染宿主（ADR-0002）"
                )
            }
        }
    }

    @Test("控制通道 target 不认识领域实体，也不依赖数据通道")
    func controlChannelCarriesNoDomainData() throws {
        let files = try swiftFiles(in: "DSHSurface")
        #expect(!files.isEmpty)
        let forbidden = [
            "import DSHClient", "SessionSummary", "WorkspaceView", "SessionEventRecord",
            "SessionProjections", "URLSession", "\"/rpc\"", "\"/events\"",
        ]
        for file in files {
            for token in forbidden {
                #expect(
                    !file.text.contains(token),
                    "DSHSurface/\(file.name) 出现了 `\(token)` —— 编排通道不许搬运领域数据（ADR-0002）"
                )
            }
        }
    }

    @Test("契约层零框架依赖：DSHKit 不 import WebKit / SwiftUI")
    func contractLayerStaysFrameworkFree() throws {
        for file in try swiftFiles(in: "DSHKit") {
            #expect(!file.text.contains("import WebKit"), "DSHKit/\(file.name)")
            #expect(!file.text.contains("import SwiftUI"), "DSHKit/\(file.name)")
        }
    }

    @Test("WebKit 只出现在两个可删除的文件里（W8 拆壳时删的就是它们）")
    func webKitIsQuarantined() throws {
        let surfaceUsers = try swiftFiles(in: "DSHSurface")
            .filter { $0.text.contains("import WebKit") }
            .map(\.name)
        let appUsers = try swiftFiles(in: "DSHApp")
            .filter { $0.text.contains("import WebKit") }
            .map(\.name)
        #expect(surfaceUsers == ["WebViewControlBridge.swift"])
        #expect(appUsers == ["WebContainer.swift"])
    }

    /// G-6 的源码守卫。
    ///
    /// 时钟缝（`sleeper`）的默认值写成默认参数里的 async 闭包字面量，会让**只走
    /// 默认参数的生产路径**在跨任务释放时 `abort()`，而注入假时钟的单测全绿 ——
    /// 一个只在真机上炸、在 CI 上永远看不见的形态。所以把它钉成源码规则：
    /// 默认值必须是 `SystemSleep.duration` 这类命名常量
    /// （见 `DSHKit/InjectableClock.swift`）。
    @Test("时钟缝不许写成默认参数里的 async 闭包字面量（known-gaps.md G-6）")
    func clockSeamsUseNamedDefaults() throws {
        // 形如：`sleeper: @escaping @Sendable (Duration) async throws -> Void = {`
        let offender = try NSRegularExpression(pattern: #"async[^\n]*->[^\n=]*=\s*\{"#)
        for target in ["DSHKit", "DSHClient", "DSHSurface", "DSHApp"] {
            for file in try swiftFiles(in: target) {
                let lines = file.text.split(separator: "\n", omittingEmptySubsequences: false)
                for (index, line) in lines.enumerated() {
                    let text = String(line)
                    // 注释行不算（`InjectableClock.swift` 的说明里就抄了这个反例）。
                    let trimmed = text.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("///") else { continue }
                    let range = NSRange(text.startIndex..<text.endIndex, in: text)
                    #expect(
                        offender.firstMatch(in: text, range: range) == nil,
                        "\(target)/\(file.name):\(index + 1) 把 async 闭包写成了默认参数值 —— 改成 SystemSleep.duration 这类命名常量（G-6）"
                    )
                }
            }
        }
    }
}
