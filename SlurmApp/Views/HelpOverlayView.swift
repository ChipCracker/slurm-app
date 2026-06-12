import SwiftUI

/// Glass-modal content listing every keyboard binding the app exposes.
/// Driven by `Shortcut.allCases` so it stays in sync with the actual
/// bindings without any extra wiring.
struct HelpOverlayView: View {
    @Environment(\.glassModalDismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Theme.hairline)
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 340, maximum: 540), spacing: 16, alignment: .top)],
                    alignment: .leading,
                    spacing: 16
                ) {
                    ForEach(Shortcut.Category.allCases, id: \.self) { category in
                        sectionCard(category)
                    }
                }
                .padding(32)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(Theme.accent.opacity(0.18)).frame(width: 48, height: 48)
                Image(systemName: "keyboard")
                    .font(.title2)
                    .foregroundColor(Theme.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("SHORTCUTS")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text("Tastatur-Navigation")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.primary)
            }
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.title3)
                    .frame(width: 32, height: 32)
            }
            .slurmyGlassCircleButton()
            .keyboardShortcut(.cancelAction)
            .help("Schliessen (Esc)")
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
    }

    private func sectionCard(_ category: Shortcut.Category) -> some View {
        let rows = Shortcut.helpRows(in: category)
        return VStack(alignment: .leading, spacing: 8) {
            Text(category.label.uppercased())
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            ForEach(rows, id: \.humanKey) { r in
                staticRow(key: r.humanKey, desc: r.description)
            }
            // String-Parameter lokalisieren nicht automatisch → String(localized:).
            if category == .jobs {
                staticRow(key: "↑/↓", desc: String(localized: "Job auswählen (Tabelle)"))
                staticRow(key: "⇧ + ↑/↓", desc: String(localized: "Mehrere Jobs auswählen"))
                staticRow(key: "⌘A", desc: String(localized: "Alle Jobs auswählen"))
                staticRow(key: String(localized: "Leertaste"), desc: String(localized: "Job markieren / Modal öffnen-schliessen"))
                staticRow(key: "↑/↓", desc: String(localized: "Inspector-Item wählen (Pane fokussiert)"))
                staticRow(key: "Tab", desc: String(localized: "Pane wechseln"))
            }
            if category == .detail {
                staticRow(key: String(localized: "Leertaste"), desc: String(localized: "Log vergrössert öffnen/schliessen"))
                staticRow(key: String(localized: "Klick"), desc: String(localized: "Log-Fenster vergrössert öffnen"))
            }
        }
        .padding(16)
        // Opake Content-Karte auf dem Glas-Overlay (kein Glas-auf-Glas).
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 0.5)
        )
    }

    private func staticRow(key: String, desc: String) -> some View {
        HStack(spacing: 12) {
            Text(key)
                .font(.callout.monospaced().bold())
                .foregroundColor(Theme.accent)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 6))
                .frame(minWidth: 56, alignment: .center)
            Text(desc)
                .font(.callout)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
    }
}
