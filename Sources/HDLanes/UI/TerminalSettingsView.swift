import AppKit
import HDCore
import SwiftUI
import UniformTypeIdentifiers

// OWNER: workspace area. Settings › Terminal: colors, font, size.
struct TerminalSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var themes: [TerminalPalette] = []
    @State private var families: [String] = []
    @State private var importing = false
    @State private var rejected: [String] = []

    var body: some View {
        Form {
            Section(L.appThemeSection) {
                Picker(L.appThemeLabel, selection: Binding(
                    get: { model.appTheme?.id ?? "" },
                    set: { model.setAppTheme($0.isEmpty ? nil : $0) })) {
                    Text(L.appThemeName(nil)).tag("")
                    ForEach(AppTheme.builtIn) { Text(L.appThemeName($0.id)).tag($0.id) }
                }
                HStack(spacing: 10) {
                    ForEach(AppTheme.builtIn) { ThemeSwatch(theme: $0, selected: model.appTheme?.id == $0.id) { model.setAppTheme($0) } }
                }
                Text(L.appThemeNote)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section(L.terminalColors) {
                Picker(L.terminalTheme, selection: Binding(
                    get: { model.terminalPalette.id },
                    set: { model.setTerminalTheme($0) })) {
                    ForEach(themes) { Text($0.name).tag($0.id) }
                    if !themes.contains(where: { $0.id == model.terminalPalette.id }) {
                        Text(model.terminalPalette.name).tag(model.terminalPalette.id)
                    }
                }
                PaletteSwatch(palette: model.terminalPalette, font: model.terminalFont)
                HStack {
                    Button(L.importThemeEllipsis) { importing = true }
                    Button(L.showThemesFolder) { model.revealThemesFolder() }
                    Button(L.reload) { reload() }
                }
                .controlSize(.small)
                Text(L.importThemeNote)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !rejected.isEmpty {
                    Text(L.themesRejected(rejected))
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
            }
            Section(L.terminalFontSection) {
                Picker(L.terminalFontFamily, selection: Binding(
                    get: { model.state.settings.terminalFont ?? "" },
                    set: { model.setTerminalFont(family: $0.isEmpty ? nil : $0) })) {
                    Text(L.terminalSystemFont).tag("")
                    ForEach(families, id: \.self) { Text($0).tag($0) }
                    if let f = model.state.settings.terminalFont, !families.contains(f) {
                        Text(f).tag(f)
                    }
                }
                Stepper(value: Binding(get: { model.state.settings.terminalFontSize ?? 13 },
                                       set: { model.setTerminalFontSize($0) }), in: 9...24, step: 1) {
                    Text(L.terminalFontSize(Int(model.state.settings.terminalFontSize ?? 13)))
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { reload() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .text, .propertyList],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            rejected = model.importTerminalThemes(urls)
            reload()
        }
    }

    private func reload() {
        themes = model.availableTerminalThemes()
        families = TerminalTheme.monospacedFamilies()
    }
}

/// Background, foreground sample text and the 16 ANSI colors of a palette.
private struct PaletteSwatch: View {
    let palette: TerminalPalette
    let font: NSFont

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L.terminalSample)
                .font(Font(NSFont(descriptor: font.fontDescriptor, size: 12) ?? font))
                .foregroundStyle(Color(nsColor: TerminalTheme.color(palette.foreground)))
            HStack(spacing: 3) {
                ForEach(0..<16, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(nsColor: TerminalTheme.color(palette.ansi[i])))
                        .frame(width: 18, height: 12)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: TerminalTheme.color(palette.background)), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// A small picture of a theme: sidebar, window and accent, clickable.
private struct ThemeSwatch: View {
    let theme: AppTheme
    let selected: Bool
    let pick: (String) -> Void

    var body: some View {
        Button { pick(theme.id) } label: {
            VStack(spacing: 5) {
                HStack(spacing: 0) {
                    Theme.color(theme.sidebar).frame(width: 26)
                    ZStack(alignment: .topLeading) {
                        Theme.color(theme.window)
                        VStack(alignment: .leading, spacing: 4) {
                            Capsule().fill(Theme.color(theme.accent)).frame(width: 30, height: 5)
                            Capsule().fill(Theme.color(theme.muted)).frame(width: 44, height: 4)
                            Capsule().fill(Theme.color(theme.accent2)).frame(width: 22, height: 4)
                        }
                        .padding(8)
                    }
                }
                .frame(width: 104, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: selected ? 2 : 1)
                }
                Text(L.appThemeName(theme.id)).font(.system(size: 11))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
