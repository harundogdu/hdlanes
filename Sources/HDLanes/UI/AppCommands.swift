import HDCore
import SwiftUI

// OWNER: workspace area. Menu commands and keyboard shortcuts.
struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(L.newSessionEllipsis) { model.isNewSessionSheetPresented = true }
                .keyboardShortcut("n", modifiers: .command)
            Button(L.newTaskEllipsis) { model.isNewTaskSheetPresented = true }
                .keyboardShortcut("t", modifiers: .command)
            Divider()
            Button(L.addProjectEllipsis) { Task { await Panels.addProject(model: model) } }
        }
        CommandGroup(after: .sidebar) {
            Button(L.showBoard) { model.selection = .board }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Button(L.toggleInspector) { model.isInspectorVisible.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
        }
        CommandMenu(L.sessionMenu) {
            Button(L.nextNeedsYou) { model.selectNextNeedsYou() }
                .keyboardShortcut(.tab, modifiers: .control)
                .disabled(!model.hasSessionNeedingUser)
            Divider()
            ForEach(1..<10, id: \.self) { i in
                Button(L.selectSessionN(i)) { model.selectSession(atSidebarIndex: i - 1) }
                    .keyboardShortcut(KeyEquivalent(Character(String(i))), modifiers: .command)
            }
        }
    }
}
