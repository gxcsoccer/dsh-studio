import Combine
import Foundation

/// Folder picker plus security-scoped bookmark persistence.
@MainActor
final class WorkspaceStore: ObservableObject {
    static let bookmarkKey = "ai.dsh.studio.workspaceBookmark"
    static let pathKey = "ai.dsh.studio.workspacePath"
    static let recentsKey = "ai.dsh.studio.workspaceRecents"

    @Published private(set) var url: URL
    @Published private(set) var displayPath: String
    @Published private(set) var recents: [URL] = []
    @Published private(set) var hasChosenWorkspace = false

    private var bookmarkData: Data?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) {
            var stale = false
            if let resolved = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                _ = resolved.startAccessingSecurityScopedResource()
                bookmarkData = data
                url = resolved
                displayPath = resolved.path
                hasChosenWorkspace = true
                if stale { persist(url: resolved) }
                recents = Self.loadRecents()
                return
            }
        }
        if let path = UserDefaults.standard.string(forKey: Self.pathKey), !path.isEmpty {
            let fallback = URL(fileURLWithPath: path, isDirectory: true)
            if FileManager.default.fileExists(atPath: fallback.path) {
                url = fallback
                displayPath = fallback.path
                hasChosenWorkspace = true
                recents = Self.loadRecents()
                return
            }
        }
        url = FileManager.default.homeDirectoryForCurrentUser
        displayPath = url.path
        hasChosenWorkspace = false
        recents = Self.loadRecents()
    }

    func pickFolder() {
        guard let chosen = WorkspacePicker.present(startingAt: url) else { return }
        open(chosen)
    }

    func open(_ chosen: URL) {
        persist(url: chosen)
        url = chosen
        displayPath = chosen.path
        hasChosenWorkspace = true
        remember(chosen)
    }

    private func remember(_ url: URL) {
        var next = recents.filter { $0.standardizedFileURL != url.standardizedFileURL }
        next.insert(url, at: 0)
        if next.count > 8 { next = Array(next.prefix(8)) }
        recents = next
        UserDefaults.standard.set(next.map(\.path), forKey: Self.recentsKey)
    }

    private static func loadRecents() -> [URL] {
        let paths = UserDefaults.standard.stringArray(forKey: recentsKey) ?? []
        return paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func persist(url: URL) {
        UserDefaults.standard.set(url.path, forKey: Self.pathKey)
        let data = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        bookmarkData = data
        if let data {
            UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
        }
    }
}
