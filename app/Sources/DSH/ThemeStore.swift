import AppKit
import Foundation
import SwiftUI

@MainActor
final class ThemeStore: ObservableObject {
    static let themeIdKey = "ai.dsh.studio.themeId"
    static let accentKey = "ai.dsh.studio.accent"
    static let densityKey = "ai.dsh.studio.density"
    static let typeScaleKey = "ai.dsh.studio.typeScale"
    static let sidebarKey = "ai.dsh.studio.slot.sidebar"
    static let inspectorKey = "ai.dsh.studio.slot.inspector"
    static let composerKey = "ai.dsh.studio.slot.composer"
    static let headerKey = "ai.dsh.studio.slot.header"
    static let statusKey = "ai.dsh.studio.slot.status"

    @Published private(set) var themeId: String
    @Published var accentOverride: String
    @Published var density: Density
    @Published var typeScale: TypeScale
    @Published var showSidebar: Bool
    @Published var showInspector: Bool
    @Published var showComposer: Bool
    @Published var showHeader: Bool
    @Published var showStatus: Bool
    @Published private(set) var packs: [ThemePackMeta] = []
    @Published private(set) var resolved: ThemeTokens
    @Published var commandPaletteOpen = false

    private var packTokens: [String: ThemeTokens] = [:]
    private var systemLight = ThemeTokens.studioLight
    private var systemDark = ThemeTokens.studioDark
    private let defaults = UserDefaults.standard
    private let bridgeTheme = URL(string: "http://127.0.0.1:43180/theme")!

    init() {
        themeId = UserDefaults.standard.string(forKey: Self.themeIdKey) ?? "system"
        accentOverride = UserDefaults.standard.string(forKey: Self.accentKey) ?? ""
        density = Density(rawValue: UserDefaults.standard.string(forKey: Self.densityKey) ?? "") ?? .comfortable
        typeScale = TypeScale(rawValue: UserDefaults.standard.string(forKey: Self.typeScaleKey) ?? "") ?? .medium
        showSidebar = UserDefaults.standard.object(forKey: Self.sidebarKey) as? Bool ?? true
        showInspector = UserDefaults.standard.object(forKey: Self.inspectorKey) as? Bool ?? true
        showComposer = UserDefaults.standard.object(forKey: Self.composerKey) as? Bool ?? true
        showHeader = UserDefaults.standard.object(forKey: Self.headerKey) as? Bool ?? true
        showStatus = UserDefaults.standard.object(forKey: Self.statusKey) as? Bool ?? true
        resolved = ThemeTokens.studioDark
        loadPacksFromDisk()
        recompute(appearance: nil)
    }

    var tokens: ThemeTokens {
        resolved.applying(accent: accentOverride.isEmpty ? nil : accentOverride)
    }

    func persist() {
        defaults.set(themeId, forKey: Self.themeIdKey)
        defaults.set(accentOverride, forKey: Self.accentKey)
        defaults.set(density.rawValue, forKey: Self.densityKey)
        defaults.set(typeScale.rawValue, forKey: Self.typeScaleKey)
        defaults.set(showSidebar, forKey: Self.sidebarKey)
        defaults.set(showInspector, forKey: Self.inspectorKey)
        defaults.set(showComposer, forKey: Self.composerKey)
        defaults.set(showHeader, forKey: Self.headerKey)
        defaults.set(showStatus, forKey: Self.statusKey)
    }

    func select(themeId: String) {
        self.themeId = themeId
        recompute(appearance: nil)
        persist()
        Task { await pushToBridge() }
    }

    func applyAppearance(_ scheme: ColorScheme) {
        recompute(appearance: scheme == .light ? "light" : "dark")
    }

    func hotSwapFromBridge() async {
        do {
            let (data, response) = try await URLSession.shared.data(from: bridgeTheme)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            if let id = obj["themeId"] as? String { themeId = id }
            if let tokens = obj["tokens"] as? [String: Any], let parsed = Self.parseTokens(tokens) {
                resolved = parsed
            }
        } catch {
            // Bridge may be down; local pack stays authoritative.
        }
    }

    func pushToBridge() async {
        var body: [String: Any] = ["themeId": themeId]
        let appearance = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        body["appearance"] = appearance == .darkAqua ? "dark" : "light"
        if !accentOverride.isEmpty {
            var tokens = resolved.applying(accent: accentOverride)
            body["tokens"] = [
                "accent": tokens.accent,
                "focusRing": tokens.focusRing,
            ]
        }
        var request = URLRequest(url: bridgeTheme)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: request)
    }

    private func recompute(appearance: String?) {
        let hint: String
        if let appearance {
            hint = appearance
        } else {
            hint = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light"
        }
        if themeId == "system" {
            resolved = hint == "light" ? systemLight : systemDark
        } else if let tokens = packTokens[themeId] {
            resolved = tokens
        } else {
            resolved = hint == "light" ? ThemeTokens.studioLight : ThemeTokens.studioDark
        }
    }

    func loadPacksFromDisk() {
        var metas: [ThemePackMeta] = []
        var tokensById: [String: ThemeTokens] = [:]
        for url in themeSearchURLs() {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil
            ) else { continue }
            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = obj["id"] as? String else { continue }
                let name = obj["name"] as? String ?? id
                let nameZh = obj["nameZh"] as? String
                let appearance = obj["appearance"] as? String ?? "dark"
                metas.append(ThemePackMeta(id: id, name: name, nameZh: nameZh, appearance: appearance))
                if appearance == "system" {
                    if let light = obj["light"] as? [String: Any], let parsed = Self.parseTokens(light) {
                        systemLight = parsed
                    }
                    if let dark = obj["dark"] as? [String: Any], let parsed = Self.parseTokens(dark) {
                        systemDark = parsed
                    }
                } else if let raw = obj["tokens"] as? [String: Any], let parsed = Self.parseTokens(raw) {
                    tokensById[id] = parsed
                }
            }
        }
        if !metas.contains(where: { $0.id == "system" }) {
            metas.insert(ThemePackMeta(id: "system", name: "System", nameZh: "跟随系统", appearance: "system"), at: 0)
        }
        if !metas.contains(where: { $0.id == "studio-dark" }) {
            metas.append(ThemePackMeta(id: "studio-dark", name: "Studio Dark", nameZh: "Studio 深色", appearance: "dark"))
            tokensById["studio-dark"] = .studioDark
        }
        if !metas.contains(where: { $0.id == "studio-light" }) {
            metas.append(ThemePackMeta(id: "studio-light", name: "Studio Light", nameZh: "Studio 浅色", appearance: "light"))
            tokensById["studio-light"] = .studioLight
        }
        var seen = Set<String>()
        packs = metas.filter { seen.insert($0.id).inserted }
        packTokens = tokensById
    }

    private func themeSearchURLs() -> [URL] {
        var urls: [URL] = []
        for bundle in Self.resourceBundles() {
            if let bundled = bundle.resourceURL?.appendingPathComponent("Themes", isDirectory: true) {
                urls.append(bundled)
            }
            if let nested = bundle.resourceURL?.appendingPathComponent("Resources/Themes", isDirectory: true) {
                urls.append(nested)
            }
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("DSHStudio/themes", isDirectory: true)
        if let support { urls.append(support) }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        urls.append(cwd.appendingPathComponent("themes"))
        urls.append(cwd.appendingPathComponent("app/Sources/DSH/Resources/Themes"))
        return urls
    }

    static func parseTokens(_ raw: [String: Any]) -> ThemeTokens? {
        let fallback = ThemeTokens.studioDark
        func str(_ key: String, _ fb: String) -> String {
            raw[key] as? String ?? fb
        }
        let text = raw["text"] as? [String: Any] ?? [:]
        let border = raw["border"] as? [String: Any] ?? [:]
        func scale(_ key: String, fallback: [String: CGFloat]) -> [String: CGFloat] {
            guard let obj = raw[key] as? [String: Any] else { return fallback }
            var out: [String: CGFloat] = fallback
            for (k, v) in obj {
                if let n = v as? NSNumber { out[k] = CGFloat(truncating: n) }
                else if let s = v as? String, let d = Double(s) { out[k] = CGFloat(d) }
            }
            return out
        }
        func shadows(_ key: String, fallback: [String: String]) -> [String: String] {
            guard let obj = raw[key] as? [String: Any] else { return fallback }
            var out = fallback
            for (k, v) in obj {
                if let s = v as? String { out[k] = s }
            }
            return out
        }
        func motion(_ key: String, fallback: [String: Double]) -> [String: Double] {
            guard let obj = raw[key] as? [String: Any] else { return fallback }
            var out = fallback
            for (k, v) in obj {
                if let n = v as? NSNumber {
                    let value = Double(truncating: n)
                    out[k] = value > 10 ? value / 1000 : value
                }
            }
            return out
        }
        return ThemeTokens(
            background: str("background", fallback.background),
            surface: str("surface", fallback.surface),
            elevated: str("elevated", fallback.elevated),
            text: TokenText(
                primary: text["primary"] as? String ?? fallback.text.primary,
                secondary: text["secondary"] as? String ?? fallback.text.secondary,
                tertiary: text["tertiary"] as? String ?? fallback.text.tertiary
            ),
            border: TokenBorder(
                subtle: border["subtle"] as? String ?? fallback.border.subtle,
                strong: border["strong"] as? String ?? fallback.border.strong
            ),
            accent: str("accent", fallback.accent),
            danger: str("danger", fallback.danger),
            warning: str("warning", fallback.warning),
            success: str("success", fallback.success),
            overlay: str("overlay", fallback.overlay),
            focusRing: str("focusRing", fallback.focusRing),
            radius: scale("radius", fallback: fallback.radius),
            space: scale("space", fallback: fallback.space),
            type: scale("type", fallback: fallback.type),
            shadow: shadows("shadow", fallback: fallback.shadow),
            motion: motion("motion", fallback: fallback.motion)
        )
    }
}

extension ThemeStore {
    static func resourceBundles() -> [Bundle] {
        var bundles = [Bundle.main]
        #if SWIFT_PACKAGE
        bundles.append(.module)
        #endif
        return bundles
    }
}
