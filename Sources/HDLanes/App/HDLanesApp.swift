import AppKit
import HDCore
import SwiftUI

@main
struct HDLanesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup(L.appName, id: "main") {
            MainWindow()
                .environment(delegate.model)
                .frame(minWidth: 960, minHeight: 560)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { AppCommands(model: delegate.model) }

        Settings {
            SettingsView()
                .environment(delegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        L.language = model.state.settings.language ?? .system
        // Launched from a terminal (swift run), the process isn't a regular app until told so.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        model.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = model.state.sessions.filter { model.terminals.isRunning($0.id) }.count
        guard running > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = L.quitConfirmTitle(running)
        alert.informativeText = L.quitConfirmBody
        alert.addButton(withTitle: L.quitConfirmQuit)
        alert.addButton(withTitle: L.cancel)
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.saveNow()
        model.stopRuntimeServices()
    }
}

extension L {
    static func quitConfirmTitle(_ n: Int) -> String {
        pick(n == 1 ? "1 session is still running" : "\(n) sessions are still running",
             "\(n) oturum hâlâ çalışıyor")
    }
    static var quitConfirmBody: String {
        pick("Quitting stops their agents. You can resume Claude and Codex sessions later from the sidebar.",
             "Çıkarsan ajanları durur. Claude ve Codex oturumlarını daha sonra kenar çubuğundan sürdürebilirsin.")
    }
    static var quitConfirmQuit: String { pick("Quit", "Çık") }
}
