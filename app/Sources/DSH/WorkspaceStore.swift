import AppKit
import Foundation

/// Recently opened project directories.
///
/// Opening the app should put you back where you were, so the last workspace is
/// remembered and reopened without asking. Directories are stored as bookmarks
/// rather than paths: a path that a user has since moved or renamed would
/// otherwise turn into a silent "workspace missing" on the next launch.
@Observable
final class WorkspaceStore {
    private(set) var recents: [URL] = []
    private let defaults = UserDefaults.standard
    private let key = "studio.recentWorkspaceBookmarks"

    init() { recents = load() }

    var current: URL? { recents.first }

    func remember(_ url: URL) {
        recents.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        recents.insert(url, at: 0)
        recents = Array(recents.prefix(8))
        save()
    }

    func forget(_ url: URL) {
        recents.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        save()
    }

    /// The native chooser. Note the app does not need this for the agent's own
    /// directory picking — the runtime already mounts the OS chooser through
    /// `dsh-host-directory-picker-native`. This one is for the desktop's own
    /// "open a project" affordance.
    @MainActor
    func chooseDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "打开"
        panel.message = "选择一个项目目录作为工作区"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        remember(url)
        return url
    }

    private func save() {
        let bookmarks = recents.compactMap { try? $0.bookmarkData(options: .withSecurityScope) }
        defaults.set(bookmarks, forKey: key)
    }

    private func load() -> [URL] {
        guard let bookmarks = defaults.array(forKey: key) as? [Data] else { return [] }
        return bookmarks.compactMap { data in
            var stale = false
            guard
                let url = try? URL(
                    resolvingBookmarkData: data,
                    options: .withSecurityScope,
                    bookmarkDataIsStale: &stale
                ),
                FileManager.default.fileExists(atPath: url.path)
            else { return nil }
            return url
        }
    }
}
