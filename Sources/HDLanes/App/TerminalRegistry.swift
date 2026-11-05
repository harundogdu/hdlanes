import AppKit
import HDCore
import SwiftTerm

/// Owns one terminal view per session for the life of the app, so switching sessions in the
/// sidebar never restarts a process. SwiftUI only re-parents these views (see TerminalHost).
@MainActor
final class TerminalRegistry {
    weak var model: AppModel?
    private var views: [UUID: HDTerminalView] = [:]
    /// Views of closed sessions kept alive until their shell exits (or 30 s), so the PTY is drained
    /// and the child reaped instead of hanging on a full output buffer.
    private var draining: Set<HDTerminalView> = []

    func view(for id: UUID) -> HDTerminalView {
        if let v = views[id] { return v }
        let settings = model?.state.settings
        let v = HDTerminalView(sessionID: id,
                               font: TerminalTheme.font(family: settings?.terminalFont, size: settings?.terminalFontSize ?? 13),
                               palette: model?.terminalPalette ?? .standard)
        v.registry = self
        views[id] = v
        return v
    }

    func existingView(for id: UUID) -> HDTerminalView? { views[id] }

    func start(_ id: UUID, spec: LaunchSpec) {
        let v = view(for: id)
        v.startProcess(executable: spec.executable, args: spec.args, environment: spec.environmentList,
                       execName: nil, currentDirectory: spec.cwd)
        let rt = model?.runtime(for: id)
        rt?.isProcessRunning = true
        rt?.exitCode = nil
        rt?.startedAt = Date()
    }

    func isRunning(_ id: UUID) -> Bool { views[id]?.process.running ?? false }

    /// Shell pids (= terminal session ids) of every live terminal, including draining ones.
    func runningShellPids() -> [pid_t] {
        (Array(views.values) + Array(draining)).compactMap { v in
            v.process.running && v.process.shellPid > 0 ? v.process.shellPid : nil
        }
    }

    /// Raw bytes to the PTY, as if typed.
    func sendRaw(_ id: UUID, _ text: String) {
        views[id]?.send(txt: text)
    }

    /// Pastes text the way a terminal paste does: bracketed when the program asked for it, with
    /// escape characters stripped so the text can't end the paste early or inject control sequences.
    /// `submit` presses Return afterwards.
    func paste(_ id: UUID, _ text: String, submit: Bool) {
        guard let v = views[id] else { return }
        let clean = Self.sanitizeForPaste(text)
        if v.terminalInputStateSnapshot()?.bracketedPasteMode == true {
            v.send(txt: "\u{1b}[200~" + clean + "\u{1b}[201~")
        } else {
            v.send(txt: clean)
        }
        if submit {
            // A short gap so TUIs that debounce paste see Return as a separate key press.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak v] in v?.send(txt: "\r") }
        }
    }

    nonisolated static func sanitizeForPaste(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0A, 0x09: out.unicodeScalars.append(scalar)          // newline, tab
            case 0x0D: out.unicodeScalars.append("\n")
            case 0x00...0x1F, 0x7F, 0x80...0x9F: continue                // C0/C1 controls, ESC
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    func terminate(_ id: UUID) {
        views[id]?.terminate()
    }

    /// Forgets the view of a removed session; keeps it reading until the shell exits.
    func remove(_ id: UUID) {
        guard let v = views.removeValue(forKey: id) else { return }
        v.removeFromSuperview()
        if v.process.running {
            draining.insert(v)
            ProcessTree.hangUp(session: v.process.shellPid)
            v.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self, weak v] in
                if let v { self?.draining.remove(v) }
            }
        }
    }

    /// Re-applies font and colors to every open terminal after a settings change.
    func applyAppearance(font: NSFont, palette: TerminalPalette) {
        for v in views.values {
            if v.font != font { v.font = font }
            TerminalTheme.apply(palette, to: v)
        }
    }

    // MARK: Callbacks from views

    fileprivate func titleChanged(_ id: UUID, _ title: String) {
        model?.runtime(for: id).terminalTitle = title
        model?.handleTerminalTitle(sessionID: id, title: title)
    }

    fileprivate func programStatusChanged(_ id: UUID, _ records: [TerminalProgramStatus]) {
        model?.handleProgramStatus(sessionID: id, records: records)
    }

    fileprivate func processExited(_ view: HDTerminalView, code: Int32?) {
        if draining.contains(view) {
            draining.remove(view)
            return
        }
        let id = view.sessionID
        guard views[id] === view else { return }
        let rt = model?.runtime(for: id)
        rt?.isProcessRunning = false
        rt?.exitCode = code
        model?.handleProcessExit(sessionID: id, exitCode: code)
    }

    fileprivate func linkClicked(_ id: UUID, _ link: String) {
        model?.openTerminalLink(sessionID: id, link: link)
    }

    fileprivate func outputReceived(_ id: UUID, _ text: String) {
        let urls = URLDetector.localURLs(in: text)
        guard !urls.isEmpty, let rt = model?.runtime(for: id) else { return }
        for url in urls where rt.detectedURLs.last != url {
            rt.detectedURLs.removeAll { $0 == url }
            rt.detectedURLs.append(url)
        }
        if rt.detectedURLs.count > 8 { rt.detectedURLs.removeFirst(rt.detectedURLs.count - 8) }
    }
}

/// Finds dev-server URLs (localhost, 127.0.0.1, 0.0.0.0, [::1]) in terminal output.
enum URLDetector {
    private static let regex = try! NSRegularExpression(
        pattern: #"https?://(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\])(?::\d{2,5})?(?:/[^\s\x1b"'<>)\]]*)?"#)

    static func localURLs(in text: String) -> [URL] {
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { m in
            guard let r = Range(m.range, in: text) else { return nil }
            var s = String(text[r])
            while let last = s.last, ".,;:".contains(last) { s.removeLast() }
            s = s.replacingOccurrences(of: "://0.0.0.0", with: "://localhost")
            return URL(string: s)
        }
    }
}

/// Receives process callbacks; separate object because LocalProcessTerminalView already declares
/// methods with the same names.
private final class ProcessEvents: LocalProcessTerminalViewDelegate {
    weak var owner: HDTerminalView?

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        guard let owner else { return }
        onMain { owner.registry?.titleChanged(owner.sessionID, title) }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard let owner else { return }
        DispatchQueue.main.async { owner.registry?.processExited(owner, code: exitCode) }
    }

    func processFailedToStart(source: TerminalView, error: LocalProcessError) {
        guard let owner else { return }
        DispatchQueue.main.async { owner.registry?.processExited(owner, code: nil) }
    }

    func programStatusChanged(source: TerminalView, records: [TerminalProgramStatus]) {
        guard let owner else { return }
        onMain { owner.registry?.programStatusChanged(owner.sessionID, records) }
    }
}

/// Runs on the main actor now when already there (SwiftTerm delivers on .main), otherwise hops.
private func onMain(_ body: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated(body)
    } else {
        DispatchQueue.main.async { body() }
    }
}

final class HDTerminalView: LocalProcessTerminalView {
    let sessionID: UUID
    weak var registry: TerminalRegistry?
    private let events = ProcessEvents()

    init(sessionID: UUID, font: NSFont, palette: TerminalPalette) {
        self.sessionID = sessionID
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 500), font: font,
                   options: TerminalOptions(scrollback: 10_000))
        events.owner = self
        processDelegate = events
        // Option types the layout's character (⌥Q is "@" on a Turkish keyboard); it stays Meta only
        // for keys without a character (arrows, ⌥⌫, ⌥⏎).
        optionAsMetaKey = false
        optionAsMetaKeyForFunctionalKeys = true
        TerminalTheme.apply(palette, to: self)
        installOutputObserver()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// SwiftTerm calls this after its own link check; hdlanes decides where the link opens.
    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        registry?.linkClicked(sessionID, link)
    }

    /// Output arrived (called on SwiftTerm's parse thread). Throttled hop to main to scan the
    /// bottom of the screen for dev-server URLs.
    private nonisolated(unsafe) var scanScheduled = false

    private func installOutputObserver() {
        setProcessOutputHandler { [weak self] in
            guard let self, !self.scanScheduled else { return }
            self.scanScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                self.scanScheduled = false
                let text = self.lastLines(60).joined(separator: "\n")
                guard text.contains("http") else { return }
                self.registry?.outputReceived(self.sessionID, text)
            }
        }
    }

    /// The last `count` lines of scrollback + screen, trailing blanks removed.
    func lastLines(_ count: Int) -> [String] {
        guard let snapshot = terminalContentSnapshot(region: .history(maximumScrollbackRows: count)) else { return [] }
        var lines = snapshot.rows.map { String($0.text.reversed().drop { $0 == " " }.reversed()) }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        return Array(lines.suffix(count))
    }
}
