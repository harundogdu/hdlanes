import HDCore
import SwiftUI

// OWNER: workspace area.
struct MainWindow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Text(verbatim: L.appName)
    }
}

struct SettingsView: View {
    var body: some View {
        Text(verbatim: L.appName)
    }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        EmptyCommands()
    }
}
