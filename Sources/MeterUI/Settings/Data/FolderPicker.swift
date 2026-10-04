import AppKit

/// Asks the user for one folder with the system open panel.
@MainActor enum FolderPicker {
    /// Returns the chosen folder, or nil when the user cancels. Hidden folders show, because
    /// Claude config dirs and Codex homes usually start with a dot.
    static func chooseFolder(title: String, message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.prompt = "Add"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        return panel.runModal() == .OK ? panel.url : nil
    }
}
