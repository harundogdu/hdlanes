import AppKit
import HDCore

// OWNER: git area (inspector). Links clicked in a session's terminal open inside hdlanes when they can.
extension AppModel {
    /// SwiftTerm has already checked the link (unsafe characters, custom schemes) before this runs.
    /// Files go to the File tab, folders to Finder, local dev servers to the Browser tab, the rest to macOS.
    func openTerminalLink(sessionID: UUID, link: String) {
        guard let url = URL(string: link) else { return }
        if url.isFileURL {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                NSWorkspace.shared.activateFileViewerSelecting([url])
                return
            }
            showFile(url.standardizedFileURL, in: sessionID)
        } else if FilePreview.isLocalWebURL(url), session(sessionID) != nil {
            BrowserSessions.session(for: sessionID, keeping: Set(state.sessions.map(\.id))).load(url)
            inspectorTab = .browser
            isInspectorVisible = true
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    func showFile(_ url: URL, in sessionID: UUID) {
        filePreviews[sessionID] = url
        inspectorTab = .file
        isInspectorVisible = true
    }

    func closeFilePreview(_ sessionID: UUID) {
        filePreviews[sessionID] = nil
        if inspectorTab == .file { inspectorTab = .changes }
    }
}
