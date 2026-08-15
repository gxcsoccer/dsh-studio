import AppKit
import UniformTypeIdentifiers

/// Native folder picker. Bookmarks live on WorkspaceStore.
enum WorkspacePicker {
    @MainActor
    static func present(startingAt url: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = L10n.t("选择", "Choose")
        panel.message = L10n.t("选择工作区文件夹", "Choose a workspace folder")
        panel.directoryURL = url
        panel.allowedContentTypes = [UTType.folder]
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

