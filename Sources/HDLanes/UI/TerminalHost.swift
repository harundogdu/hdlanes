import AppKit
import HDCore
import SwiftUI

// OWNER: workspace area.

/// Hosts the long-lived terminal view of a session. The registry owns the view; SwiftUI only moves it
/// into this container, so switching sessions never restarts a process.
struct TerminalHost: NSViewRepresentable {
    let sessionID: UUID
    @Environment(AppModel.self) private var model

    func makeNSView(context: Context) -> TerminalContainerView {
        let container = TerminalContainerView()
        container.host(model.terminals.view(for: sessionID))
        return container
    }

    func updateNSView(_ container: TerminalContainerView, context: Context) {
        container.host(model.terminals.view(for: sessionID))
    }
}

final class TerminalContainerView: NSView {
    override var isFlipped: Bool { true }

    func host(_ terminal: NSView) {
        guard terminal.superview !== self else { return }
        subviews.filter { $0 !== terminal }.forEach { $0.removeFromSuperview() }
        terminal.removeFromSuperview()
        terminal.frame = bounds
        terminal.autoresizingMask = [.width, .height]
        addSubview(terminal)
        // Focus once, when the terminal arrives; the window may not be attached yet.
        DispatchQueue.main.async { [weak self, weak terminal] in
            guard let self, let terminal, terminal.superview === self else { return }
            self.window?.makeFirstResponder(terminal)
        }
    }

    private var sheetObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let sheetObserver { NotificationCenter.default.removeObserver(sheetObserver) }
        sheetObserver = nil
        guard let window else { return }
        // A sheet (new session, rename…) takes focus while it is up; give it back to the terminal
        // when it closes, so typing goes to the agent right away.
        sheetObserver = NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification,
                                                               object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.focusTerminal() }
        }
        if window.firstResponder == nil || window.firstResponder === window {
            focusTerminal()
        }
    }

    private func focusTerminal() {
        guard let terminal = subviews.first, let window, window.attachedSheet == nil else { return }
        window.makeFirstResponder(terminal)
    }

    deinit {
        if let sheetObserver { NotificationCenter.default.removeObserver(sheetObserver) }
    }
}
