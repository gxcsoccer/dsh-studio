import Foundation
import DSHKit
import os

/// 宿主遥测缝。
///
/// ARCHITECTURE.md §2.2：把 `onEntryError` 接到宿主遥测，「崩溃即上报 + 记账，
/// 不吞掉」。migration-playbook.md §⑥ 的三个 soak 信号（崩溃退位、契约漂移、
/// 交互回归）全部从这里出。
public protocol SurfaceTelemetry: AnyObject, Sendable {
    /// 我们的条目崩了。`abdicated == true` → 官方实现已自动接管这一格。
    func slotFailed(_ report: SlotErrorReport)
    /// 装配被拒（含 ADR-0003 违规）。
    func assemblyRejected(_ error: SurfaceError)
    /// 不可信输入被拒。
    func inputRejected(_ fault: BridgeFault, raw: String)
    /// 运行时插槽表与编译期快照不符（ARCHITECTURE.md §7）。
    func contractDrift(_ drift: SlotContractDrift)
    /// 降级为纯官方 Web UI。
    func degraded(_ reason: DegradationReason)
    /// 编排事件被安全丢弃（props 早到 / unmount 后到 / 重复 mount）。
    func orchestrationDropped(_ note: String)
    /// **ADR-0002 的告警口**：控制通道上出现了白名单外的字段（= 领域数据）。
    func domainDataRejected(slot: String, keys: [String])
}

/// 默认实现：写 `os.Logger`。诊断模式外不落 payload（bridge-contract.md §5）。
public final class LoggingSurfaceTelemetry: SurfaceTelemetry {
    private let logger = Logger(subsystem: "com.dsh.studio", category: "surface")

    public init() {}

    public func slotFailed(_ report: SlotErrorReport) {
        if report.abdicated {
            // 记账的回落：官方接管了，但这是 soak 阶段的红线信号。
            logger.error("slot `\(report.slot, privacy: .public)` abdicated to the official entry: \(report.error, privacy: .public)")
        } else {
            logger.warning("slot `\(report.slot, privacy: .public)` reported an error: \(report.error, privacy: .public)")
        }
    }

    public func assemblyRejected(_ error: SurfaceError) {
        logger.error("surface assembly rejected: \(error.description, privacy: .public)")
    }

    public func inputRejected(_ fault: BridgeFault, raw: String) {
        // 原始 payload 不落盘（诊断模式才落，且需脱敏）。
        logger.error("rejected untrusted control input: \(fault.description, privacy: .public)")
    }

    public func contractDrift(_ drift: SlotContractDrift) {
        logger.error("slot contract drift: \(drift.description, privacy: .public)")
    }

    public func degraded(_ reason: DegradationReason) {
        logger.error("degrading to official web UI: \(reason.description, privacy: .public)")
    }

    public func orchestrationDropped(_ note: String) {
        logger.debug("dropped orchestration event: \(note, privacy: .public)")
    }

    public func domainDataRejected(slot: String, keys: [String]) {
        // 这条必须是 error 级：它意味着有人开始往控制通道上塞领域数据，
        // 而那是终局重写的第一步（ADR-0002 的硬性 review 项）。
        logger.error("ADR-0002 violation: slot `\(slot, privacy: .public)` sent non-orchestration props \(keys.joined(separator: ","), privacy: .public)")
    }
}

/// 为什么降级到纯官方 Web UI（ADR-0004 是它的底气）。
public enum DegradationReason: Hashable, Sendable, CustomStringConvertible {
    /// 15s 未收到 `surface/ready` → 判定 client 半未加载（bridge-contract.md §1.1）。
    case handshakeTimeout(Duration)
    /// 协议版本不一致 → 不猜、不适配（§4）。
    case protocolMismatch(peer: Int)
    /// `surface/configure` 失败或超时。
    case configureFailed(String)
    /// 上游插槽表漂移到我们不认识的程度。
    case contractDrift(SlotContractDrift)

    public var description: String {
        switch self {
        case .handshakeTimeout(let duration):
            "no surface/ready within \(duration) — client half never loaded"
        case .protocolMismatch(let peer):
            "peer protocol v\(peer) != host v\(BridgeProtocol.current)"
        case .configureFailed(let detail):
            "surface/configure failed: \(detail)"
        case .contractDrift(let drift):
            drift.description
        }
    }
}
