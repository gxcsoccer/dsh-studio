import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.tokens) private var tokens
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            TokenPaint.color(tokens.background).ignoresSafeArea()
            VStack(spacing: 0) {
                if theme.showHeader {
                    SessionHeaderSlot()
                    Hairline()
                }
                HStack(spacing: 0) {
                    if theme.showSidebar {
                        SidebarSlot()
                            .frame(width: theme.density == .compact ? 200 : 240)
                        VHairline()
                    }
                    sessionColumn
                    if theme.showInspector {
                        VHairline()
                        InspectorSlot()
                            .frame(width: theme.density == .compact ? 220 : 260)
                    }
                }
                if theme.showStatus {
                    Hairline()
                    StatusSlot()
                }
            }
            if theme.commandPaletteOpen {
                CommandPalette()
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .studioSurface(theme.tokens, density: theme.density, typeScale: theme.typeScale)
        .preferredColorScheme(preferredScheme)
        .onChange(of: colorScheme) { _, scheme in
            theme.applyAppearance(scheme)
        }
        .onChange(of: theme.showSidebar) { _, _ in theme.persist() }
        .onChange(of: theme.showInspector) { _, _ in theme.persist() }
        .onChange(of: theme.showComposer) { _, _ in theme.persist() }
        .onChange(of: theme.showHeader) { _, _ in theme.persist() }
        .onChange(of: theme.showStatus) { _, _ in theme.persist() }
        .onAppear { theme.applyAppearance(colorScheme) }
        .animation(reduceMotion ? nil : .easeOut(duration: tokens.duration("fast")), value: theme.showSidebar)
        .animation(reduceMotion ? nil : .easeOut(duration: tokens.duration("fast")), value: theme.commandPaletteOpen)
    }

    private var preferredScheme: ColorScheme? {
        switch theme.themeId {
        case "studio-dark": return .dark
        case "studio-light": return .light
        default: return nil
        }
    }

    @ViewBuilder
    private var sessionColumn: some View {
        VStack(spacing: 0) {
            sessionBody
            if theme.showComposer {
                Hairline()
                ComposerSlot()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var sessionBody: some View {
        if model.phase == .missingPrereqs {
            FirstRunView()
        } else if model.phase == .failed {
            ErrorCanvas()
        } else if !model.workspace.hasChosenWorkspace && model.phase == .ready {
            EmptyWorkspaceView()
        } else if model.phase == .ready && model.webHealthy {
            WebContainer(url: model.webURL, stylesheet: theme.tokens.stylesheet)
        } else if model.phase == .ready {
            EmptySessionView()
        } else {
            StatusPane()
        }
    }
}

struct StatusPane: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.tokens) private var tokens
    @Environment(\.density) private var density
    @Environment(\.typeScale) private var typeScale

    var body: some View {
        VStack(alignment: .leading, spacing: tokens.space("3", density: density)) {
            Text(L10n.t("运行日志", "Runtime log"))
                .font(.system(size: tokens.typeSize("md", scale: typeScale), weight: .semibold))
                .foregroundStyle(TokenPaint.color(tokens.text.primary))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.logLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: tokens.typeSize("xs", scale: typeScale), design: .monospaced))
                            .foregroundStyle(TokenPaint.color(tokens.text.secondary))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(tokens.space("3", density: density))
            .background(
                TokenPaint.color(tokens.surface),
                in: RoundedRectangle(cornerRadius: tokens.radiusValue("md"), style: .continuous)
            )
        }
        .padding(tokens.space("5", density: density))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TokenPaint.color(tokens.background))
    }
}
