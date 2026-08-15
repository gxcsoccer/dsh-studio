import SwiftUI

struct InspectorSlot: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.tokens) private var tokens
    @Environment(\.density) private var density
    @Environment(\.typeScale) private var typeScale

    var body: some View {
        VStack(alignment: .leading, spacing: tokens.space("4", density: density)) {
            Text(L10n.t("检查器", "Inspector"))
                .font(.system(size: tokens.typeSize("xs", scale: typeScale), weight: .semibold))
                .foregroundStyle(TokenPaint.color(tokens.text.tertiary))
                .textCase(.uppercase)

            row(L10n.t("阶段", "Phase"), label(for: model.phase))
            row("Web", model.webURL.absoluteString)
            row(L10n.t("桥", "Bridge"), model.bridgeHealthy ? "43180" : L10n.t("未就绪", "Down"))
            row("Profile", "studio")
            row(L10n.t("主题", "Theme"), theme.themeId)
            row(L10n.t("密钥", "Key"), KeychainStore.hasAPIKey ? L10n.t("钥匙串", "Keychain") : L10n.t("未设置", "Missing"))

            if !KeychainStore.hasAPIKey {
                MissingKeyView()
            }

            Spacer(minLength: 0)
        }
        .padding(tokens.space("4", density: density))
        .frame(maxHeight: .infinity, alignment: .top)
        .background(TokenPaint.color(tokens.surface))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("检查器", "Inspector"))
    }

    private func row(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(key)
                .font(.system(size: tokens.typeSize("xs", scale: typeScale)))
                .foregroundStyle(TokenPaint.color(tokens.text.tertiary))
            Text(value)
                .font(.system(size: tokens.typeSize("sm", scale: typeScale)))
                .foregroundStyle(TokenPaint.color(tokens.text.primary))
                .textSelection(.enabled)
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
