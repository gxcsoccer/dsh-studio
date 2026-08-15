import SwiftUI

struct SessionHeaderSlot: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.tokens) private var tokens
    @Environment(\.density) private var density
    @Environment(\.typeScale) private var typeScale

    var body: some View {
        HStack(spacing: tokens.space("3", density: density)) {
            VStack(alignment: .leading, spacing: 2) {
                Text("DSH Studio")
                    .font(.system(size: tokens.typeSize("md", scale: typeScale), weight: .semibold))
                    .foregroundStyle(TokenPaint.color(tokens.text.primary))
                Text(model.workspace.hasChosenWorkspace
                     ? model.workspace.displayPath
                     : L10n.t("尚未选择工作区", "No workspace selected"))
                    .font(.system(size: tokens.typeSize("xs", scale: typeScale)))
                    .foregroundStyle(TokenPaint.color(tokens.text.secondary))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if let sent = model.lastComposerSent {
                Text(sent)
                    .font(.system(size: tokens.typeSize("xs", scale: typeScale)))
                    .foregroundStyle(TokenPaint.color(tokens.text.tertiary))
                    .lineLimit(1)
            }
            StudioButton(title: L10n.t("工作区", "Workspace")) {
                model.workspace.pickFolder()
            }
            StudioButton(title: L10n.t("重启", "Restart")) {
                Task { await model.restartRuntime() }
            }
        }
        .padding(.horizontal, tokens.space("4", density: density))
        .padding(.vertical, tokens.space("3", density: density))
        .background(TokenPaint.color(tokens.surface))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("会话顶栏", "Session header"))
    }
}
