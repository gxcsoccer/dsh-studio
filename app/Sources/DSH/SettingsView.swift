import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.tokens) private var tokens
    @State private var apiKey: String = ""
    @State private var saved = false

    var body: some View {
        Form {
            Section(L10n.t("外观", "Appearance")) {
                Picker(L10n.t("主题包", "Theme pack"), selection: Binding(
                    get: { theme.themeId },
                    set: { theme.select(themeId: $0) }
                )) {
                    ForEach(theme.packs) { pack in
                        Text(pack.displayName).tag(pack.id)
                    }
                }
                HStack {
                    Text(L10n.t("强调色", "Accent"))
                    TextField("#D4A574", text: $theme.accentOverride)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: theme.accentOverride) { _, _ in
                            theme.persist()
                            Task { await theme.pushToBridge() }
                        }
                }
                Picker(L10n.t("密度", "Density"), selection: $theme.density) {
                    ForEach(Density.allCases) { item in
                        Text(item.label).tag(item)
                    }
                }
                .onChange(of: theme.density) { _, _ in theme.persist() }
                Picker(L10n.t("字号", "Type scale"), selection: $theme.typeScale) {
                    ForEach(TypeScale.allCases) { item in
                        Text(item.label).tag(item)
                    }
                }
                .onChange(of: theme.typeScale) { _, _ in theme.persist() }
            }
            Section(L10n.t("DeepSeek API 密钥", "DeepSeek API key")) {
                SecureField("sk-…", text: $apiKey)
                Text(L10n.t(
                    "保存在钥匙串，启动 dsh 时写入 DEEPSEEK_API_KEY。不会写入仓库。",
                    "Stored in Keychain and exported as DEEPSEEK_API_KEY when dsh starts. Never written to the repo."
                ))
                .font(.caption)
                .foregroundStyle(TokenPaint.color(tokens.text.secondary))
                HStack {
                    Button(L10n.t("保存", "Save")) {
                        _ = KeychainStore.saveAPIKey(apiKey)
                        saved = true
                    }
                    Button(L10n.t("清除", "Clear"), role: .destructive) {
                        KeychainStore.deleteAPIKey()
                        apiKey = ""
                    }
                    if saved {
                        Text(L10n.t("已保存", "Saved"))
                            .foregroundStyle(TokenPaint.color(tokens.text.secondary))
                    }
                }
            }
            Section(L10n.t("通知", "Notifications")) {
                Toggle(L10n.t("回合结束时通知", "Notify when a turn ends"), isOn: $model.notifyEnabled)
                    .onChange(of: model.notifyEnabled) { _, enabled in
                        if enabled {
                            model.notifications.start(enabled: true)
                        } else {
                            model.notifications.stop()
                        }
                    }
            }
            Section(L10n.t("桥接", "Bridge")) {
                LabeledContent("Web") { Text(model.webURL.absoluteString) }
                LabeledContent(L10n.t("控制端口", "Control port")) { Text("43180") }
                LabeledContent("Profile") { Text("studio") }
            }
        }
        .formStyle(.grouped)
        .padding(8)
        .onAppear {
            apiKey = KeychainStore.loadAPIKey() ?? ""
        }
    }
}
