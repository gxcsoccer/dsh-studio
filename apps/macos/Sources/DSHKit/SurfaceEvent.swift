import Foundation

/// Web→Native 的 `evt`（bridge-contract.md §1.3）。
///
/// **只有插槽编排**：挂载、props、几何、卸载、崩溃退位。任何领域实体出现
/// 在这里都是 ADR-0002 违规 —— 见 `SlotProps` 的白名单说明。
public enum SurfaceEvent: Sendable, Hashable {
    case mount(SlotMount)
    case props(instanceID: String, patch: [String: JSONValue])
    case rect(instanceID: String, rect: SlotRect, scrollable: Bool)
    case unmount(instanceID: String)
    case error(SlotErrorReport)

    public var instanceID: String? {
        switch self {
        case .mount(let mount): mount.instanceID
        case .props(let id, _), .rect(let id, _, _), .unmount(let id): id
        case .error(let report): report.instanceID
        }
    }
}

/// `slot/mount` 的载荷。
public struct SlotMount: Sendable, Hashable {
    public let slot: String
    public let instanceID: String
    /// `keyed` 插槽的 key（slot-map.md §1）。
    public let key: String?
    public let scope: SlotScope
    /// 编排 props（**不含领域数据**）。
    public let props: [String: JSONValue]
    /// 该实例暴露的注入面动作名列表（reference/native-slot-proxy.md §2）。
    /// 注意是**名字**，不是函数：原生据此决定显示哪些可交互控件。
    public let actions: [String]

    public init(
        slot: String,
        instanceID: String,
        key: String? = nil,
        scope: SlotScope,
        props: [String: JSONValue] = [:],
        actions: [String] = []
    ) {
        self.slot = slot
        self.instanceID = instanceID
        self.key = key
        self.scope = scope
        self.props = props
        self.actions = actions
    }
}

/// `slot/error`：来自官方 `ctx.slots.onEntryError` 的崩溃退位遥测。
///
/// `abdicated == true` → 官方 Web 实现已自动接管这一格（ADR-0004）。
/// 我们不做补救，但必须记账 + 告警。
public struct SlotErrorReport: Sendable, Hashable {
    public let slot: String
    public let instanceID: String?
    public let error: String
    public let abdicated: Bool

    public init(slot: String, instanceID: String?, error: String, abdicated: Bool) {
        self.slot = slot
        self.instanceID = instanceID
        self.error = error
        self.abdicated = abdicated
    }
}

/// `surface/ready` 的载荷（bridge-contract.md §1.1）。
///
/// `slots` 是 client 半**实测到的**官方插槽清单，宿主拿它和编译期快照比对
/// —— 运行时漂移检测（ARCHITECTURE.md §7）。
public struct SurfaceReady: Sendable, Hashable {
    public let protocolVersion: Int
    public let slots: [DeclaredSlot]

    public init(protocolVersion: Int, slots: [DeclaredSlot]) {
        self.protocolVersion = protocolVersion
        self.slots = slots
    }
}

/// 实测到的一个插槽。
public struct DeclaredSlot: Sendable, Hashable, Codable {
    public let name: String
    public let kind: SlotKind
    public let scope: SlotScope
    /// 当前占有者（诊断用，可缺）。
    public let owner: String?
    /// 当前占有者的 priority（诊断用，可缺）。
    public let priority: Int?

    public init(name: String, kind: SlotKind, scope: SlotScope, owner: String? = nil, priority: Int? = nil) {
        self.name = name
        self.kind = kind
        self.scope = scope
        self.owner = owner
        self.priority = priority
    }
}

// MARK: - 解码：控制通道的不可信输入边界

/// WebView 输入的硬上限。
///
/// bridge-contract.md §5：「来自 WebView 的消息一律当不可信输入校验
/// （WebView 里跑着第三方插件代码）」。这些数字就是那句话的可执行形式。
public enum SurfaceInputLimits {
    public static let maxMessageBytes = 256 * 1024
    public static let maxSlotNameLength = 128
    public static let maxInstanceIDLength = 64
    public static let maxPropKeys = 64
    public static let maxPropDepth = 6
    public static let maxActions = 32
    public static let maxDeclaredSlots = 512
    public static let maxErrorTextLength = 4096
}

public enum SurfaceEventDecoder {
    /// 从 `(m, p)` 解出 `SurfaceEvent`。
    ///
    /// 失败一律抛 `BridgeFault`（带封闭错误码），因为这就是我们要回给
    /// Web 侧的东西；同时它天然可上报。
    public static func decode(method: String, payload: JSONValue) throws -> SurfaceEvent {
        switch method {
        case ControlMethod.slotMount:
            return .mount(try decodeMount(payload))
        case ControlMethod.slotProps:
            let id = try instanceID(payload)
            let patch = try props(payload["props"] ?? .object([:]))
            return .props(instanceID: id, patch: patch)
        case ControlMethod.slotRect:
            let id = try instanceID(payload)
            guard let rectValue = payload["rect"], let rect = try? rectValue.decoded(as: SlotRect.self) else {
                throw fault(.badPayload, "slot/rect requires rect{x,y,w,h}")
            }
            guard rect.isSane else {
                throw fault(.badPayload, "slot/rect geometry is not sane: \(rect)")
            }
            guard let scrollable = payload["scrollable"]?.boolValue else {
                // `scrollable` 是 ADR-0003 的判据，缺了不许默认为 false ——
                // 默认 false 会把「不知道」静默当成「安全」。
                throw fault(.badPayload, "slot/rect requires boolean `scrollable`")
            }
            return .rect(instanceID: id, rect: rect, scrollable: scrollable)
        case ControlMethod.slotUnmount:
            return .unmount(instanceID: try instanceID(payload))
        case ControlMethod.slotError:
            return .error(try decodeError(payload))
        default:
            throw fault(.unknownMethod, "unknown control method `\(method)`")
        }
    }

    /// 解 `surface/ready`。
    public static func decodeReady(_ payload: JSONValue) throws -> SurfaceReady {
        guard let version = payload["protocol"]?.intValue else {
            throw fault(.badPayload, "surface/ready requires integer `protocol`")
        }
        let rawSlots = payload["slots"]?.arrayValue ?? []
        guard rawSlots.count <= SurfaceInputLimits.maxDeclaredSlots else {
            throw fault(.badPayload, "surface/ready declares too many slots (\(rawSlots.count))")
        }
        var slots: [DeclaredSlot] = []
        slots.reserveCapacity(rawSlots.count)
        for raw in rawSlots {
            guard let name = raw["name"]?.stringValue, isValidSlotName(name) else {
                throw fault(.badPayload, "surface/ready has a slot without a valid `name`")
            }
            guard let rawScope = raw["scope"]?.stringValue, let scope = SlotScope(rawValue: rawScope) else {
                throw fault(.badPayload, "slot `\(name)` has unknown scope")
            }
            let kind = SlotKind(rawValue: raw["kind"]?.stringValue ?? "")
            slots.append(DeclaredSlot(
                name: name,
                kind: kind,
                scope: scope,
                owner: raw["owner"]?.stringValue.map { String($0.prefix(256)) },
                priority: raw["priority"]?.intValue
            ))
        }
        return SurfaceReady(protocolVersion: version, slots: slots)
    }

    // MARK: 校验原语

    private static func decodeMount(_ payload: JSONValue) throws -> SlotMount {
        guard let slot = payload["slot"]?.stringValue, isValidSlotName(slot) else {
            throw fault(.badPayload, "slot/mount requires a valid `slot`")
        }
        let id = try instanceID(payload)
        guard let rawScope = payload["scope"]?.stringValue, let scope = SlotScope(rawValue: rawScope) else {
            throw fault(.badPayload, "slot/mount requires a known `scope`")
        }
        let key: String?
        if let keyValue = payload["key"], !keyValue.isNull {
            guard let text = keyValue.stringValue, !text.isEmpty, text.count <= SurfaceInputLimits.maxSlotNameLength else {
                throw fault(.badPayload, "slot/mount `key` must be a short string")
            }
            key = text
        } else {
            key = nil
        }
        let rawActions = payload["actions"]?.arrayValue ?? []
        guard rawActions.count <= SurfaceInputLimits.maxActions else {
            throw fault(.badPayload, "slot/mount declares too many actions")
        }
        var actions: [String] = []
        for raw in rawActions {
            guard let name = raw.stringValue, isValidActionName(name) else {
                throw fault(.badPayload, "slot/mount action names must be identifiers")
            }
            actions.append(name)
        }
        return SlotMount(
            slot: slot,
            instanceID: id,
            key: key,
            scope: scope,
            props: try props(payload["props"] ?? .object([:])),
            actions: actions
        )
    }

    private static func decodeError(_ payload: JSONValue) throws -> SlotErrorReport {
        guard let slot = payload["slot"]?.stringValue, isValidSlotName(slot) else {
            throw fault(.badPayload, "slot/error requires a valid `slot`")
        }
        guard let abdicated = payload["abdicated"]?.boolValue else {
            throw fault(.badPayload, "slot/error requires boolean `abdicated`")
        }
        let instance = payload["instanceId"]?.stringValue.flatMap { isValidInstanceID($0) ? $0 : nil }
        let text = payload["error"]?.stringValue ?? payload["error"].map(String.init(describing:)) ?? "<no detail>"
        return SlotErrorReport(
            slot: slot,
            instanceID: instance,
            error: String(text.prefix(SurfaceInputLimits.maxErrorTextLength)),
            abdicated: abdicated
        )
    }

    private static func instanceID(_ payload: JSONValue) throws -> String {
        guard let id = payload["instanceId"]?.stringValue, isValidInstanceID(id) else {
            throw fault(.badPayload, "payload requires a valid `instanceId`")
        }
        return id
    }

    private static func props(_ value: JSONValue) throws -> [String: JSONValue] {
        guard let fields = value.objectValue else {
            throw fault(.badPayload, "`props` must be an object")
        }
        guard fields.count <= SurfaceInputLimits.maxPropKeys else {
            throw fault(.badPayload, "`props` has too many keys (\(fields.count))")
        }
        guard value.depth <= SurfaceInputLimits.maxPropDepth else {
            throw fault(.badPayload, "`props` nests too deep (\(value.depth))")
        }
        for key in fields.keys where !isValidActionName(key) {
            throw fault(.badPayload, "`props` key `\(key)` is not an identifier")
        }
        return fields
    }

    public static func isValidSlotName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= SurfaceInputLimits.maxSlotNameLength else { return false }
        guard let first = name.first, first.isLetter else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
    }

    public static func isValidInstanceID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= SurfaceInputLimits.maxInstanceIDLength else { return false }
        return id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    public static func isValidActionName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64 else { return false }
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private static func fault(_ code: BridgeErrorCode, _ message: String) -> BridgeFault {
        BridgeFault(code: code, message: message, retryable: false)
    }
}
