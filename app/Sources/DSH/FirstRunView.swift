import SwiftUI

struct FirstRunView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.tokens) private var tokens
    @Environment(\.density) private var density
    @Environment(\.typeScale) private var typeScale

    var body: some View {
        VStack(alignment: .leading, spacing: tokens.space("5", density: density)) {
            Text(L10n.t("先把运行时装好", "Install the runtime first"))
                .font(.system(size: tokens.typeSize("display", scale: typeScale), weight: .semibold))
                .foregroundStyle(TokenPaint.color(tokens.text.primary))
            Text(L10n.t(
                "Studio 是官方 dsh 的原生宿主，不会内置 Node。缺什么，做一个动作，而不是读一篇 Cordis 教程。",
                "Studio is a native host for official dsh. It does not ship Node. Missing pieces get an action, not a Cordis lesson."
            ))
            .font(.system(size: tokens.typeSize("md", scale: typeScale)))
            .foregroundStyle(TokenPaint.color(tokens.text.secondary))

            row(
                ok: PathResolver.nodeMeetsMinimum(model.nodeVersion),
                title: L10n.t("Node.js 22.19+", "Node.js 22.19+"),
                detail: model.nodeVersion ?? L10n.t("未找到 node", "node not found")
            )
            row(
                ok: model.hasDSH,
                title: L10n.t("dsh 或 npx", "dsh or npx"),
                detail: L10n.t("需要全局 dsh，或可用 npx 调用官方包", "Need a global dsh, or npx for the official package")
            )
            row(
                ok: KeychainStore.hasAPIKey,
                title: L10n.t("API 密钥（可选，可稍后）", "API key (optional, later is fine)"),
                detail: L10n.t("保存在钥匙串，启动时写入 DEEPSEEK_API_KEY", "Stored in Keychain, exported as DEEPSEEK_API_KEY at launch")
            )

            HStack(spacing: tokens.space("3", density: density)) {
                StudioButton(title: L10n.t("重新检查", "Recheck"), prominent: true) {
                    Task { await model.bootstrap() }
                }
                StudioButton(title: L10n.t("仍要启动", "Start anyway")) {
                    Task { await model.startRuntime() }
                }
            }
            Spacer()
        }
        .padding(tokens.space("7", density: density))
        .frame(maxWidth: 640, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(TokenPaint.color(tokens.background))
    }

    private func row(ok: Bool, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: tokens.space("3", density: density)) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(TokenPaint.color(ok ? tokens.success : tokens.warning))
                .accessibilityLabel(ok ? L10n.t("已就绪", "Ready") : L10n.t("缺失", "Missing"))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: tokens.typeSize("md", scale: typeScale), weight: .medium))
                    .foregroundStyle(TokenPaint.color(tokens.text.primary))
                Text(detail)
                    .font(.system(size: tokens.typeSize("sm", scale: typeScale)))
                    .foregroundStyle(TokenPaint.color(tokens.text.secondary))
            }
        }
    }
}
