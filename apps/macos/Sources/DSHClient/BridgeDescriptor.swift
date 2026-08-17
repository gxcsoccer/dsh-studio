import Foundation

/// `$DSH_HOME` 解析。
public enum DSHHome {
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let explicit = environment["DSH_HOME"], !explicit.isEmpty {
            return URL(fileURLWithPath: explicit, isDirectory: true)
        }
        let home = environment["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".dsh", isDirectory: true)
    }

    /// `$DSH_HOME/studio/bridge.json`（bridge-contract.md §2.1）。
    public static func bridgeDescriptorURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        resolve(environment: environment)
            .appendingPathComponent("studio", isDirectory: true)
            .appendingPathComponent("bridge.json", isDirectory: false)
    }
}

/// 数据通道的接入信息（`$DSH_HOME/studio/bridge.json`）。
///
/// bridge-contract.md §2.1：启动时生成一次性 token 写入该文件（`0600`），
/// 宿主读文件取 token，每个请求带 `Authorization: Bearer`。
///
/// ⚠️ 契约缺口：文档规定了「文件里有 token」，但没给这个文件的字段表。
/// 这里定义为 `{ host, port, token, protocol?, webUrl? }`，并对缺省做保守
/// 处理（host 缺省 = 127.0.0.1，port 缺省 = 43180）。
public struct BridgeDescriptor: Hashable, Sendable, Codable {
    public static let defaultPort = 43180
    public static let loopbackHost = "127.0.0.1"

    public var host: String
    public var port: Int
    public var token: String
    public var protocolVersion: Int?
    /// 官方 UI 壳的地址（原样透传，本 target 自己不使用它 —— 谁渲染 UI
    /// 不是数据通道该知道的事，见 ADR-0002）。
    public var shellURL: URL?

    public init(
        host: String = BridgeDescriptor.loopbackHost,
        port: Int = BridgeDescriptor.defaultPort,
        token: String,
        protocolVersion: Int? = nil,
        shellURL: URL? = nil
    ) {
        self.host = host
        self.port = port
        self.token = token
        self.protocolVersion = protocolVersion
        self.shellURL = shellURL
    }

    private enum CodingKeys: String, CodingKey {
        case host, port, token
        case protocolVersion = "protocol"
        case shellURL = "webUrl"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? BridgeDescriptor.loopbackHost
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? BridgeDescriptor.defaultPort
        token = try container.decodeIfPresent(String.self, forKey: .token) ?? ""
        protocolVersion = try container.decodeIfPresent(Int.self, forKey: .protocolVersion)
        shellURL = try container.decodeIfPresent(String.self, forKey: .shellURL).flatMap(URL.init(string:))
    }

    public var baseURL: URL {
        URL(string: "http://\(host):\(port)")!
    }

    /// 每个请求都带 Bearer —— loopback 也要认证（bridge-contract.md §2.1）：
    /// 同机其他进程不该能驱动用户的 agent。
    public var authorizationHeaders: [String: String] {
        ["Authorization": "Bearer \(token)"]
    }
}

/// 读取/校验 `bridge.json` 的失败原因。全部是拒绝，没有「凑合连一下」。
public enum BridgeDescriptorError: Error, Hashable, Sendable, CustomStringConvertible {
    case notFound(path: String)
    case unreadable(path: String, detail: String)
    case malformed(detail: String)
    case missingToken(path: String)
    /// 只绑 `127.0.0.1`，代码里硬断言，不给配置项（bridge-contract.md §5）。
    case nonLoopbackHost(String)
    case portOutOfRange(Int)
    /// token 文件必须 `0600`；组/其他可读就等于同机任何进程能驱动 agent。
    case insecurePermissions(path: String, mode: UInt16)

    public var description: String {
        switch self {
        case .notFound(let path):
            "bridge descriptor not found at \(path) — is `dsh --profile studio` running?"
        case .unreadable(let path, let detail):
            "bridge descriptor at \(path) is unreadable: \(detail)"
        case .malformed(let detail):
            "bridge descriptor is malformed: \(detail)"
        case .missingToken(let path):
            "bridge descriptor at \(path) carries no token — refusing to talk unauthenticated"
        case .nonLoopbackHost(let host):
            "bridge descriptor points at `\(host)`; only \(BridgeDescriptor.loopbackHost) is allowed"
        case .portOutOfRange(let port):
            "bridge port \(port) is out of range"
        case .insecurePermissions(let path, let mode):
            "bridge descriptor \(path) has mode \(String(mode, radix: 8)); 0600 required"
        }
    }
}

/// 从磁盘读取并校验 descriptor。
///
/// `@unchecked Sendable`：只持有一个 `FileManager`（Foundation 尚未标注它
/// 为 `Sendable`），而我们只用它做 `fileExists` / `attributesOfItem` 这两个
/// 线程安全的只读调用。
public struct BridgeDescriptorLoader: @unchecked Sendable {
    private let url: URL
    private let fileManager: FileManager
    private let enforcePermissions: Bool

    public init(
        url: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        enforcePermissions: Bool = true
    ) {
        self.url = url ?? DSHHome.bridgeDescriptorURL(environment: environment)
        self.fileManager = fileManager
        self.enforcePermissions = enforcePermissions
    }

    public func load() throws -> BridgeDescriptor {
        let path = url.path
        guard fileManager.fileExists(atPath: path) else {
            throw BridgeDescriptorError.notFound(path: path)
        }
        if enforcePermissions {
            let attributes = try? fileManager.attributesOfItem(atPath: path)
            if let raw = attributes?[.posixPermissions] as? NSNumber {
                let mode = raw.uint16Value
                guard mode & 0o177 == 0 else {
                    throw BridgeDescriptorError.insecurePermissions(path: path, mode: mode)
                }
            }
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw BridgeDescriptorError.unreadable(path: path, detail: String(describing: error))
        }
        let descriptor: BridgeDescriptor
        do {
            descriptor = try JSONDecoder().decode(BridgeDescriptor.self, from: data)
        } catch {
            throw BridgeDescriptorError.malformed(detail: String(describing: error))
        }
        guard !descriptor.token.isEmpty else {
            throw BridgeDescriptorError.missingToken(path: path)
        }
        // 硬断言：永不 `0.0.0.0`。
        guard descriptor.host == BridgeDescriptor.loopbackHost || descriptor.host == "localhost" else {
            throw BridgeDescriptorError.nonLoopbackHost(descriptor.host)
        }
        guard (1...65535).contains(descriptor.port) else {
            throw BridgeDescriptorError.portOutOfRange(descriptor.port)
        }
        return descriptor
    }
}
