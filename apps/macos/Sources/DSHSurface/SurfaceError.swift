import Foundation
import DSHKit

/// 原生侧的装配失败。
///
/// 这些都是**大声失败**：混合期最怕的不是崩溃，而是「看起来渲染出来了，
/// 但其实错位/空白/没接线」。崩溃有回落（官方条目还在 priority 0 排队，
/// ADR-0004），静默漂移没有。
public enum SurfaceError: Error, Hashable, Sendable, CustomStringConvertible {
    /// manifest 说要原生，但宿主没有实现（reference/native-slot-proxy.md §4）。
    case noNativeImplementation(slot: String)
    /// **ADR-0003 的执行点**：滚动容器内不许 overlay。
    case overlayInsideScrollContainer(slot: String, instanceID: String)
    /// evacuated 落位却上报了几何 —— Web 侧代理不该这么做（不可信输入）。
    case geometryForEvacuatedPlacement(slot: String, instanceID: String)
    /// 收到未在 manifest 里声明为 native/mirrored 的插槽的挂载请求。
    /// 安全边界（bridge-contract.md §5）：WebView 不能自己决定接管哪一格。
    case slotNotConfigured(slot: String)
    case slotNotMounted(instanceID: String)
    /// `slot/invoke` 只能触达 manifest 里声明为 native 的插槽的注入面。
    case actionNotDeclared(slot: String, action: String)
    case invokeOnNonNativeSlot(slot: String, action: String)

    public var description: String {
        switch self {
        case .noNativeImplementation(let slot):
            "manifest wants a native view for `\(slot)` but this host registered none"
        case .overlayInsideScrollContainer(let slot, let instanceID):
            "ADR-0003: refusing overlay for `\(slot)` (instance \(instanceID)) inside a scroll container"
        case .geometryForEvacuatedPlacement(let slot, let instanceID):
            "`\(slot)` (instance \(instanceID)) is evacuated; geometry reports are a protocol violation"
        case .slotNotConfigured(let slot):
            "`\(slot)` is not declared native/mirrored in the manifest — refusing to mount"
        case .slotNotMounted(let instanceID):
            "no live slot instance `\(instanceID)`"
        case .actionNotDeclared(let slot, let action):
            "`\(slot)` did not declare action `\(action)` at mount time"
        case .invokeOnNonNativeSlot(let slot, let action):
            "refusing slot/invoke `\(action)`: `\(slot)` is not native in the manifest"
        }
    }

    /// 回给 Web 侧的封闭错误码（bridge-contract.md §1.5）。
    public var bridgeCode: BridgeErrorCode {
        switch self {
        case .noNativeImplementation: .internalError
        case .overlayInsideScrollContainer, .geometryForEvacuatedPlacement: .badPayload
        case .slotNotConfigured: .slotNotDeclared
        case .slotNotMounted: .slotNotMounted
        case .actionNotDeclared: .unknownMethod
        case .invokeOnNonNativeSlot: .slotNotDeclared
        }
    }

    public var fault: BridgeFault {
        BridgeFault(code: bridgeCode, message: description, retryable: false)
    }
}

/// 控制通道自身的失败。
public enum ControlChannelError: Error, Hashable, Sendable, CustomStringConvertible {
    /// `req` 超时。**不重试** —— 重试编排会造成重复挂载（§1.5）。
    case timedOut(method: String, after: Duration)
    /// WebView 没了 / JS 世界被清空。
    case webViewUnavailable
    case evaluationFailed(String)
    /// 对端说了我们不认识的协议版本。
    case protocolMismatch(Int)

    public var description: String {
        switch self {
        case .timedOut(let method, let duration):
            "`\(method)` timed out after \(duration) (not retried: replaying orchestration double-mounts)"
        case .webViewUnavailable:
            "no web view attached to the control channel"
        case .evaluationFailed(let detail):
            "evaluateJavaScript failed: \(detail)"
        case .protocolMismatch(let version):
            "peer speaks protocol v\(version), host speaks v\(BridgeProtocol.current)"
        }
    }
}
