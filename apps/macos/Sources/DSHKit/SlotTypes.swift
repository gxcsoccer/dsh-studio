import Foundation

/// 插槽的数据上下文（ARCHITECTURE.md §2.1）。
///
/// 封闭枚举：`scope` 决定原生视图能拿到什么上下文，是行为关键字段。
/// 未知 scope 来自不可信输入 → 按 `bad_payload` 拒绝，不兜底。
public enum SlotScope: String, Sendable, Hashable, Codable, CaseIterable {
    case root
    case session
    case sessionMaybe = "session-maybe"
}

/// 插槽基数（slot-map.md §1）。
///
/// 这里**带** `unknown` 兜底：`kind` 只用于漂移检测与诊断展示，上游新增
/// 一种基数不该让宿主拒绝启动。
public enum SlotKind: Sendable, Hashable {
    case single
    case list
    case keyed
    case chain
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "single": self = .single
        case "list": self = .list
        case "keyed": self = .keyed
        case "chain": self = .chain
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .single: "single"
        case .list: "list"
        case .keyed: "keyed"
        case .chain: "chain"
        case .unknown(let raw): raw
        }
    }
}

extension SlotKind: Codable {
    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// 落位方式（ARCHITECTURE.md §4）。`evacuated` 是默认且优先。
public enum Placement: String, Sendable, Hashable, Codable, CaseIterable {
    case evacuated
    case overlay
}

/// 插槽状态机（ARCHITECTURE.md §5 / surface-manifest.md §2）。
///
/// 刻意**没有**第五态：manifest 只能表达「谁来渲染」，不能表达
/// 「谁都不渲染」（surface-manifest.md §7）。
public enum SlotMode: String, Sendable, Hashable, Codable, CaseIterable {
    case web
    case mirrored
    case native
    case retired

    /// 原生侧**被渲染时**是否要装配视图。
    ///
    /// `mirrored` 也装配 —— 但渲染到离屏对照层。
    ///
    /// **`retired` 是 `true`，这是刻意的**（known-gaps.md G-5 的结论）：
    /// ARCHITECTURE.md §5 的状态表里 `retired` 那一行「谁渲染」写的是「我们」
    /// —— `retired` 与 `native` 的区别只是**意图**（官方实现对本产品不再有
    /// 意义），不是渲染行为。surface-manifest.md §3 的例子也把已完成的 W1
    /// 插槽记成 `mode: retired`；若这里返回 `false`，那一行的 `slot/mount`
    /// 会被 `NativeSlotHost` 当成「未声明为原生」拒掉，等于把迁移完成的插槽
    /// 变成一块空白。
    ///
    /// G-5 真正的病灶不在这个布尔值，而在**启动自检**把「被渲染时要装配视图」
    /// 当成了「一定会被渲染」：规则 7 逼出来的子槽行（暗槽）永不渲染，却被要求
    /// 有原生实现。修在 `SurfaceManifest.isDarkHole` / `slotsRequiringNativeView`。
    public var mountsNativeView: Bool {
        switch self {
        case .web: false
        case .mirrored, .native, .retired: true
        }
    }

    /// 原生视图是否赢得渲染权。
    public var ownsRendering: Bool {
        switch self {
        case .web, .mirrored: false
        case .native, .retired: true
        }
    }
}

/// `slot/rect` 的几何（仅 overlay 落位需要）。
public struct SlotRect: Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    /// 不可信输入的合理性检查：非有限值、负尺寸、荒谬坐标一律拒绝。
    public var isSane: Bool {
        [x, y, w, h].allSatisfy(\.isFinite)
            && w >= 0 && h >= 0
            && abs(x) <= 1_000_000 && abs(y) <= 1_000_000
            && w <= 1_000_000 && h <= 1_000_000
    }
}

/// 控制通道方法名（bridge-contract.md §1.3）。
///
/// 只列契约里有的方法。新增方法要先改契约文档，不许在代码里偷偷加
/// —— 尤其不许加任何用来搬运领域数据的方法（ADR-0002）。
public enum ControlMethod {
    // Native → Web（req）
    public static let surfaceConfigure = "surface/configure"
    public static let surfaceReconfigure = "surface/reconfigure"
    public static let slotInvoke = "slot/invoke"
    public static let slotProbe = "slot/probe"
    /// 运行期心跳（known-gaps.md G-3）。10s 一拍，连续 2 拍无 pong → 判定
    /// client 半失联并撤下所有原生插槽视图。
    public static let surfacePing = "surface/ping"

    // Web → Native（evt / res）
    public static let surfaceReady = "surface/ready"
    /// 心跳回答。主格式是 `surface/ping` 的普通回执（`t:"res"`）；本方法名同时
    /// 被接受为单向事件形态，两者都算活体证据（见 `SurfaceHeartbeat`）。
    public static let surfacePong = "surface/pong"
    public static let slotMount = "slot/mount"
    public static let slotProps = "slot/props"
    public static let slotRect = "slot/rect"
    public static let slotUnmount = "slot/unmount"
    public static let slotError = "slot/error"

    /// `req` 默认超时 5s；`surface/configure` 15s（bridge-contract.md §1.5）。
    public static func timeout(for method: String) -> Duration {
        method == surfaceConfigure ? .seconds(15) : .seconds(5)
    }
}

/// W1 的目标插槽（slot-map.md §3）。
public enum W1 {
    public static let workspacesSlot = "sidebar.workspaces"
    /// 官方 `sidebar.workspaces` 占位者声明的子槽（目录选择流程）。
    ///
    /// W1 并不为它准备原生视图 —— 它是规则 7 逼出来的**声明**：父槽被接管后
    /// 这个 hole 永不被渲染（`SurfaceManifest.isDarkHole`）。
    public static let workspacesDirectoryFlowSlot = "sidebar.workspaces.directoryFlow"
}
