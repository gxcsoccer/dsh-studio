import Foundation
import os
import DSHKit
import DSHClient

/// 从 runtime 读**权威** surface manifest（known-gaps.md G-4 的解法 1）。
///
/// WHY THIS FILE EXISTS
/// --------------------
/// surface-manifest.md §1 规定 manifest 只住在 `studio-surface` 那一行的
/// `config` 里，因为热回滚（改一行 YAML，不发版）、对照运行和用户自决都建立在
/// 「它是插件配置」这一点上。实现时却出现了第二份：编译进 Swift 的
/// `SurfaceManifest.w1Default`。两份一旦不一致，症状是 client 半把整行拒掉、
/// 用户回落官方 UI —— 而日志里只有一句 `bad_payload`，最难诊断。
///
/// 所以宿主握手后来这里取一次：拿到 = 采纳（`w1Default` 退化为兜底），
/// 拿不到 = 用兜底继续跑。两条路都不 crash。
///
/// 为什么这段 HTTP 住在 `DSHApp` 而不是 `DSHClient` / `DSHSurface`：
/// - `DSHClient` 是领域数据通道，`ArchitectureGuardTests` 明令它的源码里不许
///   出现 `slot` / `manifest` 这类字眼（ADR-0002）；
/// - `DSHSurface` 是编排通道，同一守卫禁止它出现 `URLSession`；
/// - `DSHApp` 本来就是「唯一同时认识两条通道的地方」，而 manifest 恰恰是
///   「走数据通道来、被控制通道消费」的那一份东西。
///
/// 认证与 `bridge.json` 复用数据通道那一套（bridge-contract.md §2.1）：
/// loopback 也要 Bearer —— 同机其他进程不该能改变用户 UI 的接管范围。
public struct RuntimeManifestSource: Sendable {
    /// HTTP 缝。生产实现是 `URLSession`；换掉它就能离线测试。
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// `/studio/surface` 的超时。**故意很短**：它挡在 `surface/configure`
    /// 前面，而握手窗口只有 15s（bridge-contract.md §1.1）。宁可用兜底
    /// manifest 也不要把握手拖过窗口。
    public static let timeout: TimeInterval = 3

    private let loader: BridgeDescriptorLoader
    private let transport: Transport
    private let logger = Logger(subsystem: "com.dsh.studio", category: "manifest")

    public init(
        loader: BridgeDescriptorLoader = BridgeDescriptorLoader(),
        transport: Transport? = nil
    ) {
        self.loader = loader
        self.transport = transport ?? RuntimeManifestSource.defaultTransport()
    }

    private static func defaultTransport() -> Transport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        return { request in try await session.data(for: request) }
    }

    /// 取一次权威 manifest。
    /// - Returns: runtime 那份；拿不到时 `nil`（调用方用编译期兜底）。
    public func load() async -> SurfaceManifest? {
        do {
            let info = try await fetch()
            logger.notice("adopted runtime manifest: \(info.manifest.slots.count, privacy: .public) row(s), census \(String(describing: info.census), privacy: .public)")
            return info.manifest
        } catch {
            // 拿不到不是错误路径的终点，是「用兜底」的开始 —— 但必须留痕。
            logger.error("no runtime manifest (falling back to the compiled default): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// 取并解析 `GET /studio/surface`。
    public func fetch() async throws -> RemoteSurfaceInfo {
        let descriptor = try loader.load()
        var request = URLRequest(url: descriptor.baseURL.appendingPathComponent("/studio/surface"))
        request.httpMethod = "GET"
        request.timeoutInterval = RuntimeManifestSource.timeout
        for (key, value) in descriptor.authorizationHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await transport(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw RuntimeManifestSourceError.httpStatus(status)
        }
        return try RemoteSurfaceInfo.decode(data)
    }
}

public enum RuntimeManifestSourceError: Error, Hashable, Sendable, CustomStringConvertible {
    case httpStatus(Int)

    public var description: String {
        switch self {
        case .httpStatus(let status): "GET /studio/surface answered HTTP \(status)"
        }
    }
}
