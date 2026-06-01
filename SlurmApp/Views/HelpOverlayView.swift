import SwiftUI

/// Glass-modal content listing every keyboard binding the app exposes.
/// Driven by `Shortcut.allCases` so it stays in sync with the actual
/// bindings without any extra wiring.
struct HelpOverlayView: View {
    @Environment(\.glassModalDismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(.white.opacity(0.08))
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
            .buttonStyle(.plain)
            .background(.thinMaterial, in: Circle())
            .keyboardShortcut(.cancelAction)
            .help("Schliessen (Esc)")
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
    }

    private func sectionCard(_ category: Shortcut.Category) -> some View {
        let rows = Shortcut.helpRows(in: category)
        return VStack(alignment: .leading, spacing: 8) {
            Text(category.rawValue.uppercased())
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            ForEach(rows, id: \.humanKey) { r in
                staticRow(key: r.humanKey, desc: r.description)
            }
            if category == .jobs {
                staticRow(key: "↑/↓", desc: "Job auswählen (Tabelle)")
                staticRow(key: "⇧ + ↑/↓", desc: "Mehrere Jobs auswählen")
                staticRow(key: "⌘A", desc: "Alle Jobs auswählen")
                staticRow(key: "Leertaste", desc: "Job markieren / Modal öffnen-schliessen")
                staticRow(key: "↑/↓", desc: "Inspector-Item wählen (Pane fokussiert)")
                staticRow(key: "Tab", desc: "Pane wechseln")
            }
            if category == .detail {
                staticRow(key: "Leertaste", desc: "Log vergrössert öffnen/schliessen")
                staticRow(key: "Klick", desc: "Log-Fenster vergrössert öffnen")
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 0.5)
        )
    }

    private func staticRow(key: String, desc: String) -> some View {
        HStack(spacing: 12) {
            Text(key)
                .font(.callout.monospaced().bold())
                .foregroundColor(Theme.accent)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                .frame(minWidth: 56, alignment: .center)
            Text(desc)
                .font(.callout)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
    }
}
