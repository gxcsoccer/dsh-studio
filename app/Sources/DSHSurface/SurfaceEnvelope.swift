import DSHKit
import Foundation

/// The private chrome channel between this process and our own client plugin.
///
/// Not a Harness seam. The official contract stays on `DSHKit`; this envelope
/// never crosses the carrier. A regular browser tab opening the loopback URL
/// has no `webkit.messageHandlers.studio` and the plugin simply does not
/// attach. Keep the shape in lockstep with `packages/bundle/src/surface-channel.js`:
///
///   { v: 1, type: "req", id, method, payload }
///   { v: 1, type: "res", id, ok: true,  value }
///   { v: 1, type: "res", id, ok: false, error }
///   { v: 1, type: "evt", method, payload }
public struct SurfaceFrame: Codable, Equatable, Sendable {
    public var v: Int
    public var type: Kind
    public var id: String?
    public var method: String?
    public var payload: JSONValue?
    public var ok: Bool?
    public var value: JSONValue?
    public var error: String?

    public enum Kind: String, Codable, Sendable {
        case req, res, evt
    }

    public static let version = 1
    public static let handlerName = "studio"

    public static func request(id: String, method: String, payload: JSONValue) -> SurfaceFrame {
        SurfaceFrame(v: version, type: .req, id: id, method: method, payload: payload)
    }

    public static func response(id: String, value: JSONValue) -> SurfaceFrame {
        SurfaceFrame(v: version, type: .res, id: id, ok: true, value: value)
    }

    public static func failure(id: String, error: String) -> SurfaceFrame {
        SurfaceFrame(v: version, type: .res, id: id, ok: false, error: error)
    }

    public static func event(method: String, payload: JSONValue = .object([:])) -> SurfaceFrame {
        SurfaceFrame(v: version, type: .evt, method: method, payload: payload)
    }
}

public struct OpenWorkspaceResult: Codable, Equatable, Sendable {
    public var workspaceId: String
    public var sessionId: String
}

public struct SurfaceSelection: Equatable, Sendable {
    public var sessionId: String?
    public var path: String?
    public var title: String?
}

/// The page's session list, mirrored for the native sidebar.
///
/// Grouping and titles are computed on the client store; this is a projection,
/// not a second registry.
public struct SurfaceCatalog: Codable, Equatable, Sendable {
    public var currentSessionId: String?
    public var workspaces: [SurfaceWorkspaceGroup]
    public var ungrouped: [SurfaceSessionRow]

    public static let empty = SurfaceCatalog(currentSessionId: nil, workspaces: [], ungrouped: [])

    /// Workspace the next New Session should land in: the group that owns the
    /// current row, otherwise the first group in the projection.
    public var inferredWorkspaceId: String? {
        if let current = currentSessionId {
            if let match = workspaces.first(where: { group in
                group.sessions.contains { $0.sessionId == current }
            }) {
                return match.workspaceId
            }
        }
        return workspaces.first?.workspaceId
    }

    /// Title/workspace substring match, then content hits from `session.search`.
    /// Blanks stay out: a draft is not something you search for. Content
    /// snippets attach to an already-listed row rather than duplicating it.
    public func hits(
        matching query: String,
        content: [SurfaceSearchSnippet] = [],
        limit: Int = 20
    ) -> [SurfaceCatalogHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var rows: [SurfaceCatalogHit] = []
        var seen = Set<String>()

        func add(_ workspace: String, _ session: SurfaceSessionRow, snippet: String? = nil) {
            guard !session.blank else { return }
            if let index = rows.firstIndex(where: { $0.session.sessionId == session.sessionId }) {
                if rows[index].snippet == nil { rows[index].snippet = snippet }
                return
            }
            guard !seen.contains(session.sessionId) else { return }
            seen.insert(session.sessionId)
            rows.append(SurfaceCatalogHit(workspace: workspace, session: session, snippet: snippet))
        }

        if needle.isEmpty { return [] }

        func considerTitle(_ workspace: String, _ session: SurfaceSessionRow) {
            if session.title.lowercased().contains(needle)
                || workspace.lowercased().contains(needle)
            {
                add(workspace, session)
            }
        }

        for group in workspaces {
            for session in group.sessions { considerTitle(group.title, session) }
        }
        for session in ungrouped { considerTitle("未分组", session) }

        if !needle.isEmpty {
            for snippet in content {
                if let found = lookup(snippet.sessionId) {
                    add(found.workspace, found.session, snippet: snippet.snippet)
                }
            }
        }

        if rows.count > limit { rows = Array(rows.prefix(limit)) }
        return rows
    }

    public func lookup(_ sessionId: String) -> (workspace: String, session: SurfaceSessionRow)? {
        for group in workspaces {
            if let session = group.sessions.first(where: { $0.sessionId == sessionId }) {
                return (group.title, session)
            }
        }
        if let session = ungrouped.first(where: { $0.sessionId == sessionId }) {
            return ("未分组", session)
        }
        return nil
    }

    /// Newest non-draft rows, for the empty command palette. The full catalog
    /// already lives in the sidebar; dumping it again is not a search.
    public func recents(limit: Int = 8) -> [SurfaceCatalogHit] {
        var rows: [SurfaceCatalogHit] = []
        for group in workspaces {
            for session in group.sessions where !session.blank {
                rows.append(SurfaceCatalogHit(workspace: group.title, session: session))
            }
        }
        for session in ungrouped where !session.blank {
            rows.append(SurfaceCatalogHit(workspace: "未分组", session: session))
        }
        rows.sort { $0.session.updatedAt > $1.session.updatedAt }
        if rows.count > limit { rows = Array(rows.prefix(limit)) }
        return rows
    }
}

public struct SurfaceSearchSnippet: Equatable, Sendable {
    public var sessionId: String
    public var snippet: String

    public init(sessionId: String, snippet: String) {
        self.sessionId = sessionId
        self.snippet = snippet
    }
}

public struct SurfaceCatalogHit: Equatable, Identifiable, Sendable {
    public var workspace: String
    public var session: SurfaceSessionRow
    public var snippet: String?
    public var id: String { session.sessionId }
}

public struct SurfaceWorkspaceGroup: Codable, Equatable, Identifiable, Sendable {
    public var workspaceId: String
    public var title: String
    public var path: String
    public var sessions: [SurfaceSessionRow]
    public var id: String { workspaceId }
}

public struct SurfaceSessionRow: Codable, Equatable, Identifiable, Sendable {
    public var sessionId: String
    public var title: String
    public var blank: Bool
    public var running: Bool
    public var updatedAt: Double
    public var id: String { sessionId }
}

public enum SurfaceError: Error, Equatable, Sendable, LocalizedError {
    case notReady
    case pageReset
    case detached
    case remote(String)
    case unexpected(String)

    public var errorDescription: String? {
        switch self {
        case .notReady: return "页面还没准备好"
        case .pageReset: return "页面正在重新加载"
        case .detached: return "通道已断开"
        case .remote(let message): return message
        case .unexpected(let message): return message
        }
    }
}

/// Turns a frame into the JavaScript the page-side hook already understands.
/// JSON is a valid JS expression, so the encoded object is dropped in as-is.
public enum SurfaceScript {
    public static let callPrefix = "window.__DSH_STUDIO__&&window.__DSH_STUDIO__.dispatch("
    /// `dispatch` returns a Promise. WKWebView cannot bridge that type and
    /// reports "unsupported type" — which Swift used to treat as a failed
    /// chrome call. The statement result must be `undefined`.
    public static let callSuffix = ");undefined"

    public static func dispatch(_ frame: SurfaceFrame) throws -> String {
        let data = try JSONEncoder().encode(frame)
        guard let json = String(data: data, encoding: .utf8) else {
            throw SurfaceError.unexpected("frame was not UTF-8")
        }
        return "\(callPrefix)\(json)\(callSuffix)"
    }

    public static func frameJSON(in script: String) -> String? {
        guard script.hasPrefix(callPrefix), script.hasSuffix(callSuffix) else { return nil }
        return String(script.dropFirst(callPrefix.count).dropLast(callSuffix.count))
    }
}
