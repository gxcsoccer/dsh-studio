import SwiftUI

struct SidebarSlot: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.tokens) private var tokens
    @Environment(\.density) private var density
    @Environment(\.typeScale) private var typeScale

    var body: some View {
        VStack(alignment: .leading, spacing: tokens.space("3", density: density)) {
            Text(L10n.t("工作区", "Workspace"))
                .font(.system(size: tokens.typeSize("xs", scale: typeScale), weight: .semibold))
                .foregroundStyle(TokenPaint.color(tokens.text.tertiary))
                .textCase(.uppercase)
            Button {
                model.workspace.pickFolder()
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.workspace.url.lastPathComponent)
                        .font(.system(size: tokens.typeSize("md", scale: typeScale), weight: .medium))
                        .foregroundStyle(TokenPaint.color(tokens.text.primary))
                    Text(model.workspace.displayPath)
                        .font(.system(size: tokens.typeSize("xs", scale: typeScale)))
                        .foregroundStyle(TokenPaint.color(tokens.text.secondary))
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(tokens.space("3", density: density))
                .background(
                    TokenPaint.color(tokens.elevated),
                    in: RoundedRectangle(cornerRadius: tokens.radiusValue("md"), style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.t("当前工作区", "Current workspace"))

            if !model.workspace.recents.isEmpty {
                Text(L10n.t("最近", "Recents"))
                    .font(.system(size: tokens.typeSize("xs", scale: typeScale), weight: .semibold))
                    .foregroundStyle(TokenPaint.color(tokens.text.tertiary))
                    .textCase(.uppercase)
                ForEach(model.workspace.recents, id: \.path) { url in
                    Button {
                        model.workspace.open(url)
                    } label: {
                        Text(url.lastPathComponent)
                            .font(.system(size: tokens.typeSize("sm", scale: typeScale)))
                            .foregroundStyle(TokenPaint.color(tokens.text.secondary))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, tokens.space("1", density: density))
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer(minLength: 0)

            Text(L10n.t("运行时是官方默认能力", "Runtime is the official default set"))
                .font(.system(size: tokens.typeSize("xs", scale: typeScale)))
                .foregroundStyle(TokenPaint.color(tokens.text.tertiary))
        }
        .padding(tokens.space("4", density: density))
        .frame(maxHeight: .infinity, alignment: .top)
        .background(TokenPaint.color(tokens.surface))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("侧栏", "Sidebar"))
    }
}
