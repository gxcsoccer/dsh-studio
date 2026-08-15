import SwiftUI

struct EmptyWorkspaceView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        EmptyCanvas(
            title: L10n.t("还没有项目落在 Studio 里", "No workspace in Studio yet"),
            detail: L10n.t(
                "打开一个文件夹，会话会跟着这个工作区走。最近用过的也会出现在侧栏。",
                "Open a folder. Sessions stay with that workspace. Recents appear in the sidebar."
            ),
            actionTitle: L10n.t("打开文件夹", "Open folder"),
            action: { model.workspace.pickFolder() }
        )
    }
}

struct EmptySessionView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.tokens) private var tokens
    @Environment(\.density) private var density
    @Environment(\.typeScale) private var typeScale

    var body: some View {
        VStack(alignment: .leading, spacing: tokens.space("4", density: density)) {
            Text(L10n.t("这个工作区还没有对话", "This workspace has no conversation yet"))
                .font(.system(size: tokens.typeSize("display", scale: typeScale), weight: .semibold))
                .foregroundStyle(TokenPaint.color(tokens.text.primary))
            Text(L10n.t(
                "运行时起来之后，官方会话会出现在中间。你也可以先在输入栏写一句，复制到剪贴板。",
                "When the runtime is up, the official session lands in the middle. You can also draft in the composer — it copies to the clipboard."
            ))
            .font(.system(size: tokens.typeSize("md", scale: typeScale)))
            .foregroundStyle(TokenPaint.color(tokens.text.secondary))
            HStack(spacing: tokens.space("3", density: density)) {
                StudioButton(title: L10n.t("重启运行时", "Restart runtime"), prominent: true) {
                    Task { await model.restartRuntime() }
                }
                StudioButton(title: L10n.t("打开工作区", "Open workspace")) {
                    model.workspace.pickFolder()
                }
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
        .padding(tokens.space("6", density: density))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(TokenPaint.color(tokens.background))
    }
}

struct MissingKeyView: View {
    @Environment(\.tokens) private var tokens
    @Environment(\.density) private var density
    @Environment(\.typeScale) private var typeScale

    var body: some View {
        VStack(alignment: .leading, spacing: tokens.space("3", density: density)) {
            Text(L10n.t("模型还不能走", "The model cannot run yet"))
                .font(.system(size: tokens.typeSize("lg", scale: typeScale), weight: .semibold))
                .foregroundStyle(TokenPaint.color(tokens.text.primary))
            Text(L10n.t(
                "把 DeepSeek API 密钥放进钥匙串。设置里保存，不会写入仓库。",
                "Put the DeepSeek API key in the Keychain. Save it in Settings. It is never written to the repo."
            ))
            .font(.system(size: tokens.typeSize("sm", scale: typeScale)))
            .foregroundStyle(TokenPaint.color(tokens.text.secondary))
        }
        .padding(tokens.space("4", density: density))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TokenPaint.color(tokens.surface), in: RoundedRectangle(cornerRadius: tokens.radiusValue("md"), style: .continuous))
    }
}

struct ErrorCanvas: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.tokens) private var tokens
    @Environment(\.density) private var density
    @Environment(\.typeScale) private var typeScale

    var body: some View {
        VStack(alignment: .leading, spacing: tokens.space("4", density: density)) {
            Text(L10n.t("运行时没有起来", "The runtime did not come up"))
                .font(.system(size: tokens.typeSize("display", scale: typeScale), weight: .semibold))
                .foregroundStyle(TokenPaint.color(tokens.text.primary))
            if let error = model.lastError {
                Text(error)
                    .font(.system(size: tokens.typeSize("sm", scale: typeScale), design: .monospaced))
                    .foregroundStyle(TokenPaint.color(tokens.danger))
                    .textSelection(.enabled)
            }
            Text(L10n.t(
                "可以重启运行时，或修复 studio profile。预览版上游会破，旧日志只读。",
                "Restart the runtime, or repair the studio profile. Preview upstream will break; old logs stay read-only."
            ))
            .font(.system(size: tokens.typeSize("md", scale: typeScale)))
            .foregroundStyle(TokenPaint.color(tokens.text.secondary))
            HStack(spacing: tokens.space("3", density: density)) {
                StudioButton(title: L10n.t("重启运行时", "Restart runtime"), prominent: true) {
                    Task { await model.restartRuntime() }
                }
                StudioButton(title: L10n.t("修复 Profile", "Repair profile")) {
                    Task { await model.repairProfile() }
                }
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
        .padding(tokens.space("6", density: density))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(TokenPaint.color(tokens.background))
    }
}
