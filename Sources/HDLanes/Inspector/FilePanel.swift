import AppKit
import HDCore
import SwiftUI

/// File tab: read-only view of a file clicked in the session's terminal.
/// OWNER: git area (inspector).
struct FilePanel: View {
    let sessionID: UUID

    @Environment(AppModel.self) private var model
    @State private var content: FilePreview.Content?
    @State private var image: NSImage?
    /// "Open in Xcode" etc.; looked up once per file, not on every render.
    @State private var openTitle = L.openWithDefault
    @State private var reloadToken = 0

    var body: some View {
        if let url = model.filePreviews[sessionID] {
            VStack(spacing: 0) {
                header(url)
                Divider()
                body(for: url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .task(id: "\(url.path)|\(reloadToken)") {
                content = nil
                image = nil
                let (loaded, picture, app) = await Task.detached { () -> (FilePreview.Content, NSImage?, String?) in
                    let c = FilePreview.load(url)
                    let img = c == .image ? NSImage(contentsOf: url) : nil
                    let app = NSWorkspace.shared.urlForApplication(toOpen: url)
                        .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
                    return (c, img, app)
                }.value
                guard !Task.isCancelled else { return }
                image = picture
                openTitle = app.map(L.openIn) ?? L.openWithDefault
                content = loaded
            }
        } else {
            CompactEmptyState(title: L.fileEmptyTitle, symbol: "doc.text", detail: L.fileEmptyDetail)
        }
    }

    private func header(_ url: URL) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(displayPath(url))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(url.path)
            }
            Spacer(minLength: 4)
            Button { reloadToken += 1 } label: { Label(L.reload, systemImage: "arrow.clockwise").labelStyle(.iconOnly) }
                .help(L.reload)
            Menu {
                Button(openTitle) { model.openPreviewedFile(url) }
                Button(L.revealInFinder) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button(L.copyPath) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.path, forType: .string)
                }
            } label: {
                Label(L.openWithDefault, systemImage: "arrow.up.right.square").labelStyle(.iconOnly)
            } primaryAction: {
                model.openPreviewedFile(url)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(openTitle)
            Button { model.closeFilePreview(sessionID) } label: { Label(L.closeFile, systemImage: "xmark").labelStyle(.iconOnly) }
                .help(L.closeFile)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder private func body(for url: URL) -> some View {
        switch content {
        case nil:
            ProgressView().controlSize(.small)
        case .text(let text, let truncated):
            VStack(spacing: 0) {
                if truncated {
                    Text(L.fileTruncated(FilePreview.maxTextBytes / 1_000_000))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                    Divider()
                }
                ReadOnlyTextView(text: text, fontSize: model.state.settings.terminalFontSize ?? 13)
            }
        case .image:
            if let image {
                Image(nsImage: image).resizable().scaledToFit().padding(10)
            } else {
                notice(L.fileUnreadable, url)
            }
        case .binary: notice(L.fileBinary, url)
        case .missing: notice(L.fileMissing, nil)
        case .unreadable: notice(L.fileUnreadable, url)
        case .sensitive: notice(L.fileSensitive, nil)
        }
    }

    private func notice(_ text: String, _ url: URL?) -> some View {
        VStack(spacing: 8) {
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
            if let url { Button(openTitle) { model.openPreviewedFile(url) }.controlSize(.small) }
        }
    }

    /// Path relative to the session's folder when it is inside it, else with `~`.
    private func displayPath(_ url: URL) -> String {
        let path = url.path
        if let s = model.session(sessionID) {
            let base = (s.worktreePath ?? s.cwd).hasSuffix("/") ? (s.worktreePath ?? s.cwd) : (s.worktreePath ?? s.cwd) + "/"
            if path.hasPrefix(base) { return String(path.dropFirst(base.count)) }
        }
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

/// Selectable, non-editable monospaced text; NSTextView keeps large files fast.
private struct ReadOnlyTextView: NSViewRepresentable {
    let text: String
    let fontSize: Double

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        if let tv = scroll.documentView as? NSTextView {
            tv.isEditable = false
            tv.isSelectable = true
            tv.isRichText = false
            tv.drawsBackground = false
            tv.usesFindBar = true
            tv.isIncrementalSearchingEnabled = true
            tv.textContainerInset = NSSize(width: 8, height: 8)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        let font = NSFont.monospacedSystemFont(ofSize: CGFloat(max(10, fontSize - 1)), weight: .regular)
        if tv.string != text {
            tv.string = text
            tv.scrollToBeginningOfDocument(nil)
        }
        if tv.font != font { tv.font = font }
        tv.textColor = .textColor
    }
}
