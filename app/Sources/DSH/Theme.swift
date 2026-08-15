import AppKit
import SwiftUI

enum Density: String, CaseIterable, Identifiable {
    case comfortable
    case compact
    var id: String { rawValue }
    var label: String {
        switch self {
        case .comfortable: return L10n.t("舒适", "Comfortable")
        case .compact: return L10n.t("紧凑", "Compact")
        }
    }
    var factor: CGFloat { self == .compact ? 0.78 : 1.0 }
}

enum TypeScale: String, CaseIterable, Identifiable {
    case small
    case medium
    case large
    var id: String { rawValue }
    var label: String {
        switch self {
        case .small: return L10n.t("小", "Small")
        case .medium: return L10n.t("中", "Medium")
        case .large: return L10n.t("大", "Large")
        }
    }
    var factor: CGFloat {
        switch self {
        case .small: return 0.92
        case .medium: return 1.0
        case .large: return 1.12
        }
    }
}

struct TokenText: Equatable {
    var primary: String
    var secondary: String
    var tertiary: String
}

struct TokenBorder: Equatable {
    var subtle: String
    var strong: String
}

struct ThemeTokens: Equatable {
    var background: String
    var surface: String
    var elevated: String
    var text: TokenText
    var border: TokenBorder
    var accent: String
    var danger: String
    var warning: String
    var success: String
    var overlay: String
    var focusRing: String
    var radius: [String: CGFloat]
    var space: [String: CGFloat]
    var type: [String: CGFloat]
    var shadow: [String: String]
    var motion: [String: Double]

    static let studioDark = ThemeTokens(
        background: "#0B0B0C",
        surface: "#131316",
        elevated: "#1A1A1F",
        text: TokenText(primary: "#EDEDEC", secondary: "#9B9A97", tertiary: "#6F6E69"),
        border: TokenBorder(subtle: "#232326", strong: "#3A3A40"),
        accent: "#D4A574",
        danger: "#E5484D",
        warning: "#F5A524",
        success: "#46A758",
        overlay: "rgba(0,0,0,0.52)",
        focusRing: "#D4A574",
        radius: ["sm": 6, "md": 10, "lg": 14, "xl": 20],
        space: ["1": 4, "2": 8, "3": 12, "4": 16, "5": 24, "6": 32, "7": 40, "8": 56],
        type: ["xs": 11, "sm": 12, "md": 13, "lg": 15, "xl": 18, "display": 28],
        shadow: [
            "sm": "0 1px 2px rgba(0,0,0,0.28)",
            "md": "0 8px 24px rgba(0,0,0,0.36)",
            "lg": "0 16px 48px rgba(0,0,0,0.40)",
        ],
        motion: ["fast": 0.12, "normal": 0.2, "slow": 0.32]
    )

    static let studioLight = ThemeTokens(
        background: "#F7F6F3",
        surface: "#FFFFFF",
        elevated: "#FFFFFF",
        text: TokenText(primary: "#1C1C1A", secondary: "#6F6E69", tertiary: "#9B9A97"),
        border: TokenBorder(subtle: "#E8E6E1", strong: "#C9C7C0"),
        accent: "#B07D4F",
        danger: "#C62828",
        warning: "#B45309",
        success: "#1B7F4E",
        overlay: "rgba(20,18,14,0.40)",
        focusRing: "#B07D4F",
        radius: ["sm": 6, "md": 10, "lg": 14, "xl": 20],
        space: ["1": 4, "2": 8, "3": 12, "4": 16, "5": 24, "6": 32, "7": 40, "8": 56],
        type: ["xs": 11, "sm": 12, "md": 13, "lg": 15, "xl": 18, "display": 28],
        shadow: [
            "sm": "0 1px 2px rgba(28,28,26,0.06)",
            "md": "0 8px 24px rgba(28,28,26,0.08)",
            "lg": "0 16px 48px rgba(28,28,26,0.10)",
        ],
        motion: ["fast": 0.12, "normal": 0.2, "slow": 0.32]
    )

    func space(_ key: String, density: Density = .comfortable) -> CGFloat {
        (space[key] ?? 8) * density.factor
    }

    func typeSize(_ key: String, scale: TypeScale = .medium) -> CGFloat {
        (type[key] ?? 13) * scale.factor
    }

    func radiusValue(_ key: String) -> CGFloat {
        radius[key] ?? 10
    }

    func duration(_ key: String) -> Double {
        motion[key] ?? 0.2
    }

    func applying(accent override: String?) -> ThemeTokens {
        guard let override, TokenPaint.parse(override) != nil else { return self }
        var copy = self
        copy.accent = override
        copy.focusRing = override
        return copy
    }

    var cssVariables: [String: String] {
        var vars: [String: String] = [
            "--dsh-background": background,
            "--dsh-surface": surface,
            "--dsh-elevated": elevated,
            "--dsh-text-primary": text.primary,
            "--dsh-text-secondary": text.secondary,
            "--dsh-text-tertiary": text.tertiary,
            "--dsh-border-subtle": border.subtle,
            "--dsh-border-strong": border.strong,
            "--dsh-accent": accent,
            "--dsh-danger": danger,
            "--dsh-warning": warning,
            "--dsh-success": success,
            "--dsh-overlay": overlay,
            "--dsh-focus-ring": focusRing,
        ]
        for (k, v) in radius { vars["--dsh-radius-\(k)"] = "\(Int(v))px" }
        for (k, v) in space { vars["--dsh-space-\(k)"] = "\(Int(v))px" }
        for (k, v) in type { vars["--dsh-type-\(k)"] = "\(Int(v))px" }
        for (k, v) in shadow { vars["--dsh-shadow-\(k)"] = v }
        for (k, v) in motion { vars["--dsh-motion-\(k)"] = "\(Int(v * 1000))ms" }
        return vars
    }

    var stylesheet: String {
        let body = cssVariables
            .sorted { $0.key < $1.key }
            .map { "  \($0.key): \($0.value);" }
            .joined(separator: "\n")
        return ":root, :host, html, body {\n\(body)\n}\n"
    }
}

enum TokenPaint {
    static func parse(_ raw: String) -> NSColor? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("rgba") || value.lowercased().hasPrefix("rgb") {
            return parseRGB(value)
        }
        return parseHex(value)
    }

    static func color(_ raw: String) -> Color {
        if let ns = parse(raw) { return Color(nsColor: ns) }
        return Color(nsColor: .clear)
    }

    private static func parseHex(_ raw: String) -> NSColor? {
        var hex = raw
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard let int = UInt32(hex, radix: 16) else { return nil }
        switch hex.count {
        case 3:
            let r = CGFloat((int >> 8) & 0xF) / 15
            let g = CGFloat((int >> 4) & 0xF) / 15
            let b = CGFloat(int & 0xF) / 15
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        case 6:
            let r = CGFloat((int >> 16) & 0xFF) / 255
            let g = CGFloat((int >> 8) & 0xFF) / 255
            let b = CGFloat(int & 0xFF) / 255
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        case 8:
            let r = CGFloat((int >> 24) & 0xFF) / 255
            let g = CGFloat((int >> 16) & 0xFF) / 255
            let b = CGFloat((int >> 8) & 0xFF) / 255
            let a = CGFloat(int & 0xFF) / 255
            return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
        default:
            return nil
        }
    }

    private static func parseRGB(_ raw: String) -> NSColor? {
        let inner = raw
            .replacingOccurrences(of: "rgba(", with: "")
            .replacingOccurrences(of: "rgb(", with: "")
            .replacingOccurrences(of: ")", with: "")
        let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 3,
              let r = Double(parts[0]),
              let g = Double(parts[1]),
              let b = Double(parts[2]) else { return nil }
        let a = parts.count >= 4 ? Double(parts[3]) ?? 1 : 1
        let scale: CGFloat = r > 1 || g > 1 || b > 1 ? 255 : 1
        return NSColor(
            srgbRed: CGFloat(r) / scale,
            green: CGFloat(g) / scale,
            blue: CGFloat(b) / scale,
            alpha: CGFloat(a)
        )
    }
}

private struct TokensKey: EnvironmentKey {
    static let defaultValue = ThemeTokens.studioDark
}

private struct DensityKey: EnvironmentKey {
    static let defaultValue = Density.comfortable
}

private struct TypeScaleKey: EnvironmentKey {
    static let defaultValue = TypeScale.medium
}

extension EnvironmentValues {
    var tokens: ThemeTokens {
        get { self[TokensKey.self] }
        set { self[TokensKey.self] = newValue }
    }
    var density: Density {
        get { self[DensityKey.self] }
        set { self[DensityKey.self] = newValue }
    }
    var typeScale: TypeScale {
        get { self[TypeScaleKey.self] }
        set { self[TypeScaleKey.self] = newValue }
    }
}

extension View {
    func studioSurface(_ tokens: ThemeTokens, density: Density, typeScale: TypeScale) -> some View {
        environment(\.tokens, tokens)
            .environment(\.density, density)
            .environment(\.typeScale, typeScale)
    }
}

struct ThemePackMeta: Identifiable, Equatable {
    var id: String
    var name: String
    var nameZh: String?
    var appearance: String

    var displayName: String {
        if L10n.isChinese, let nameZh, !nameZh.isEmpty { return nameZh }
        return name
    }
}
