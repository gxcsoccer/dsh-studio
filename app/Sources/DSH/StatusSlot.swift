import SwiftUI

struct StatusSlot: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.tokens) private var tokens
    @Environment(\.density) private var density
    @Environment(\.typeScale) private var typeScale

    var body: some View {
        HStack(spacing: tokens.space("3", density: density)) {
            StatusDot(kind: kind)
            Text(model.statusText.isEmpty ? label(for: model.phase) : model.statusText)
                .font(.system(size: tokens.typeSize("xs", scale: typeScale)))
                .foregroundStyle(TokenPaint.color(tokens.text.secondary))
            Spacer()
            Text(model.webHealthy ? "3080" : "—")
                .font(.system(size: tokens.typeSize("xs", scale: typeScale), design: .monospaced))
                .foregroundStyle(TokenPaint.color(tokens.text.tertiary))
            Text(model.bridgeHealthy ? "43180" : "—")
                .font(.system(size: tokens.typeSize("xs", scale: typeScale), design: .monospaced))
                .foregroundStyle(TokenPaint.color(tokens.text.tertiary))
        }
        .padding(.horizontal, tokens.space("4", density: density))
        .padding(.vertical, tokens.space("2", density: density))
        .background(TokenPaint.color(tokens.surface))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.t("状态", "Status") + ": " + (model.statusText.isEmpty ? label(for: model.phase) : model.statusText))
    }

    private var kind: StatusDot.Kind {
        switch model.phase {
        case .ready: return .ready
        case .failed: return .danger
        case .missingPrereqs: return .warning
        default: return .idle
        }
    }

    private func label(for phase: RuntimePhase) -> String {
        switch phase {
        case .idle: return L10n.t("空闲", "Idle")
        case .checking: return L10n.t("检查中", "Checking")
        case .missingPrereqs: return L10n.t("缺少依赖", "Missing prerequisites")
        case .installingProfile: return L10n.t("安装 profile", "Installing profile")
        case .starting: return L10n.t("启动中", "Starting")
        case .waitingHealth: return L10n.t("等待就绪", "Waiting")
        case .ready: return L10n.t("已就绪", "Ready")
        case .stopping: return L10n.t("停止中", "Stopping")
        case .failed: return L10n.t("失败", "Failed")
        }
    }
}
