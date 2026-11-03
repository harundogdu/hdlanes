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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let terminal = subviews.first, let window else { return }
        if window.firstResponder == nil || window.firstResponder === window {
            window.makeFirstResponder(terminal)
        }
    }
}
