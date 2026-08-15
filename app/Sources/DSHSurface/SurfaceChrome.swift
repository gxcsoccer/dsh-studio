import Foundation

/// Compact relative time for the sidebar trailing slot. Buckets match
/// official `relativeTime` in `ui-workspace` (刚刚 / N分钟 / N小时 / …).
public enum SurfaceRelativeTime {
    public static func label(updatedAt: Double, now: Date = Date()) -> String {
        let millis = updatedAt > 0 && updatedAt < 1_000_000_000_000 ? updatedAt * 1000 : updatedAt
        let diff = max(0, now.timeIntervalSince1970 * 1000 - millis)
        if diff < 60_000 { return "刚刚" }
        if diff < 3_600_000 { return "\(Int(diff / 60_000))分钟" }
        if diff < 86_400_000 { return "\(Int(diff / 3_600_000))小时" }
        if diff < 30 * 86_400_000 { return "\(Int(diff / 86_400_000))天" }
        if diff < 365 * 86_400_000 { return "\(Int(diff / (30 * 86_400_000)))个月" }
        return "\(Int(diff / (365 * 86_400_000)))年"
    }
}

/// Window chrome title. WKWebView will try to use `document.title` (often
/// the workspace name); a blank draft must stay "新会话" even when the
/// page selection title is the workspace.
public enum SurfaceChromeTitle {
    public static let fallback = "DSH Studio"
    public static let draft = "新会话"

    public static func resolve(catalog: SurfaceCatalog, selection: SurfaceSelection?) -> String {
        if let id = catalog.currentSessionId ?? selection?.sessionId,
           let found = catalog.lookup(id)
        {
            if found.session.blank { return draft }
            let title = found.session.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
        }
        let raw = selection?.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? fallback : raw
    }
}

/// WKWebView reports `http://127.0.0.1:3099/` after load; we ask for
/// `http://127.0.0.1:3099`. Treating those as different reloads the page
/// on every SwiftUI pass.
public enum SurfacePageURL {
    public static func same(_ loaded: URL?, as wanted: URL) -> Bool {
        guard let loaded else { return false }
        return loaded.host == wanted.host
            && loaded.port == wanted.port
            && normalize(loaded.path) == normalize(wanted.path)
    }

    public static func normalize(_ path: String) -> String {
        path.isEmpty ? "/" : path
    }
}

/// `dispatch` returns a Promise. WKWebView cannot bridge that type and
/// reports WKErrorDomain 5 ("unsupported type"). The chrome channel
/// answers via `postMessage`, so that error is success.
public enum SurfaceEvaluate {
    public static let unsupportedResultCode = 5
    public static let webKitErrorDomain = "WKErrorDomain"

    public static func isUnsupportedResult(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == webKitErrorDomain && ns.code == unsupportedResultCode
    }
}
