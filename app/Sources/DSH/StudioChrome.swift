import SwiftUI

struct TokenBackground: View {
    @Environment(\.tokens) private var tokens
    var body: some View {
        TokenPaint.color(tokens.background)
    }
}

struct Hairline: View {
    @Environment(\.tokens) private var tokens
    var strong = false
    var body: some View {
        Rectangle()
            .fill(TokenPaint.color(strong ? tokens.border.strong : tokens.border.subtle))
            .frame(height: 1)
    }
}

struct VHairline: View {
    @Environment(\.tokens) private var tokens
    var body: some View {
        Rectangle()
            .fill(TokenPaint.color(tokens.border.subtle))
            .frame(width: 1)
    }
}

struct StudioButton: View {
    @Environment(\.tokens) private var tokens
    @Environment(\.density) private var density
    @Environment(\.typeScale) private var typeScale
    let title: String
    var prominent = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: tokens.typeSize("sm", scale: typeScale), weight: .medium))
                .padding(.horizontal, tokens.space("3", density: density))
                .padding(.vertical, tokens.space("2", density: density) * 0.7)
                .foregroundStyle(prominent ? TokenPaint.color(tokens.background) : TokenPaint.color(tokens.text.primary))
                .background(
                    TokenPaint.color(prominent ? tokens.accent : tokens.elevated),
                    in: RoundedRectangle(cornerRadius: tokens.radiusValue("sm"), style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: tokens.radiusValue("sm"), style: .continuous)
                        .stroke(TokenPaint.color(tokens.border.subtle), lineWidth: prominent ? 0 : 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

struct StatusDot: View {
    @Environment(\.tokens) private var tokens
    enum Kind { case ready, warning, danger, idle }
    var kind: Kind
    var body: some View {
        let color: String = {
            switch kind {
            case .ready: return tokens.success
            case .warning: return tokens.warning
            case .danger: return tokens.danger
            case .idle: return tokens.text.tertiary
            }
        }()
        Circle()
            .fill(TokenPaint.color(color))
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
    }
}

struct EmptyCanvas: View {
    @Environment(\.tokens) private var tokens
    @Environment(\.density) private var density
    @Environment(\.typeScale) private var typeScale
    let title: String
    let detail: String
    let actionTitle: String
    var action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: tokens.space("4", density: density)) {
            Text(title)
                .font(.system(size: tokens.typeSize("display", scale: typeScale), weight: .semibold))
                .foregroundStyle(TokenPaint.color(tokens.text.primary))
            Text(detail)
                .font(.system(size: tokens.typeSize("md", scale: typeScale)))
                .foregroundStyle(TokenPaint.color(tokens.text.secondary))
                .fixedSize(horizontal: false, vertical: true)
            StudioButton(title: actionTitle, prominent: true, action: action)
        }
        .frame(maxWidth: 480, alignment: .leading)
        .padding(tokens.space("6", density: density))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(TokenPaint.color(tokens.background))
    }
}
