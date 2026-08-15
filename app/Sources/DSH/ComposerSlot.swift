import SwiftUI

struct ComposerSlot: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.tokens) private var tokens
    @Environment(\.density) private var density
    @Environment(\.typeScale) private var typeScale
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: tokens.space("3", density: density)) {
            TextField(
                L10n.t("写给 Agent…", "Write to the agent…"),
                text: $model.composerDraft,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.system(size: tokens.typeSize("md", scale: typeScale)))
            .foregroundStyle(TokenPaint.color(tokens.text.primary))
            .focused($focused)
            .lineLimit(1...6)
            .onSubmit { model.submitComposer() }
            .accessibilityLabel(L10n.t("输入栏", "Composer"))

            StudioButton(title: L10n.t("发送", "Send"), prominent: true) {
                model.submitComposer()
            }
            .keyboardShortcut(.return, modifiers: [.command])
        }
        .padding(tokens.space("3", density: density))
        .background(
            TokenPaint.color(tokens.elevated),
            in: RoundedRectangle(cornerRadius: tokens.radiusValue("md"), style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: tokens.radiusValue("md"), style: .continuous)
                .stroke(
                    TokenPaint.color(focused ? tokens.focusRing : tokens.border.subtle),
                    lineWidth: focused ? 1.5 : 1
                )
        )
        .padding(.horizontal, tokens.space("4", density: density))
        .padding(.vertical, tokens.space("3", density: density))
        .background(TokenPaint.color(tokens.background))
    }
}
