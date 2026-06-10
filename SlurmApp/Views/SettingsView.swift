import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var dashboard: DashboardStore
    @State private var pingResult: String?
    @State private var pinging = false
    @State private var showForgetConfirm = false
    @AppStorage("jobsDashboardEnabled") private var dashboardEnabled = false
    @AppStorage("runningJobsFirst") private var runningJobsFirst = false
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSizeClass
    #endif

    /// Das Grid-Dashboard gibt es auf macOS und iPad (regular width) — auf dem
    /// iPhone bleibt die feste Liste, daher dort keine Layout-Sektion.
    private var dashboardAvailable: Bool {
        #if os(macOS)
        true
        #else
        hSizeClass == .regular
        #endif
    }

    @AppStorage("appearance") private var appearanceRaw: String = AppAppearance.system.rawValue
    @AppStorage(AppTheme.storageKey) private var accentThemeRaw: String = AppTheme.default.rawValue
    @AppStorage("textSizeIndex") private var textSizeIndex: Int = 3

    private let textSizeNames = ["XS", "S", "M", "L", "XL", "XXL", "XXXL"]
    private let defaultTextSizeIndex = 3

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        brandingHeader
                        appearanceCard
                        themeCard
                        jobsListCard
                        if dashboardAvailable {
                            dashboardCard
                        }
                        textSizeCard
                        connectionCard
                        pingCard
                        actionsCard
                        aboutFooter
                    }
                    .padding()
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Einstellungen")
            .navBarBackground(Theme.background)
        }
        .alert("Zugangsdaten löschen?", isPresented: $showForgetConfirm) {
            Button("Abbrechen", role: .cancel) {}
            Button("Löschen", role: .destructive) {
                Task { await appState.forgetCredentials() }
            }
        } message: {
            Text("Host, Benutzer und Schlüssel werden aus dem Schlüsselbund entfernt. Die Verbindung wird getrennt.")
        }
    }

    // MARK: – Branding header

    private var brandingHeader: some View {
        VStack(spacing: 10) {
            Image(nsImageOrUIImageNamed: "AppIconPreview")
                .resizable()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Theme.hairline, lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
            Text("Slurmy")
                .font(.title2.bold())
                .foregroundColor(Theme.textPrimary)
            Text("Slurm-Client für iPhone, iPad & Mac")
                .font(.caption)
                .foregroundColor(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: – Appearance

    private var appearanceCard: some View {
        SettingsSection(title: "Darstellung", systemImage: "paintbrush") {
            Picker("Erscheinungsbild", selection: $appearanceRaw) {
                ForEach(AppAppearance.allCases) { mode in
                    Label(mode.label, systemImage: mode.symbol).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("Automatisch folgt dem System (Hell/Dunkel).")
                .font(.caption)
                .foregroundColor(Theme.textSecondary)
        }
    }

    private var themeCard: some View {
        SettingsSection(title: "Farbthema", systemImage: "paintpalette") {
            let columns = [GridItem(.adaptive(minimum: 52), spacing: 12)]
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(AppTheme.allCases) { theme in
                    let selected = theme.rawValue == accentThemeRaw
                    Button {
                        accentThemeRaw = theme.rawValue
                    } label: {
                        VStack(spacing: 5) {
                            ZStack {
                                Circle()
                                    .fill(theme.accent)
                                    .frame(width: 34, height: 34)
                                if selected {
                                    Image(systemName: "checkmark")
                                        .font(.caption.bold())
                                        .foregroundColor(Theme.onAccent)
                                }
                            }
                            .overlay(
                                Circle().stroke(Theme.textPrimary.opacity(selected ? 0.9 : 0),
                                                lineWidth: 2)
                                    .padding(-3)
                            )
                            Text(theme.label)
                                .font(.caption2)
                                .foregroundColor(selected ? Theme.textPrimary : Theme.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Färbt Buttons, Akzente und die Fokus-Markierung. Status­farben (running/pending/fehlgeschlagen) bleiben unverändert.")
                .font(.caption)
                .foregroundColor(Theme.textSecondary)
        }
    }

    // MARK: – Jobs-Liste

    private var jobsListCard: some View {
        SettingsSection(title: "Jobs-Liste", systemImage: "list.bullet") {
            Toggle(isOn: $runningJobsFirst.animation()) {
                Text("Laufende Jobs immer oben")
                    .foregroundColor(Theme.textPrimary)
            }
            .toggleStyle(.switch)
            .tint(Theme.accent)

            Text("Sortiert laufende Jobs (running) unabhängig von der Spaltensortierung an den Anfang der Liste.")
                .font(.caption)
                .foregroundColor(Theme.textSecondary)
        }
    }

    // MARK: – Dashboard-Layout

    private var dashboardCard: some View {
        SettingsSection(title: "Dashboard (Jobs)", systemImage: "rectangle.3.group") {
            Toggle(isOn: $dashboardEnabled.animation()) {
                Text("Anpassbares Grid statt Split-Ansicht")
                    .foregroundColor(Theme.textPrimary)
            }
            .toggleStyle(.switch)
            .tint(Theme.accent)

            Text("Im Dashboard lässt sich jedes Panel frei verschieben und in der Größe ändern (Stift-Symbol oben rechts im Jobs-Tab).")
                .font(.caption)
                .foregroundColor(Theme.textSecondary)

            Text("Fertige Layouts")
                .font(.caption.bold())
                .foregroundColor(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)

            let columns = [GridItem(.adaptive(minimum: 150), spacing: 10)]
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(DashboardPreset.allCases) { preset in
                    presetButton(preset)
                }
            }

            HStack {
                Text("Aktiv: \(dashboard.presetName)")
                    .font(.caption.monospaced())
                    .foregroundColor(Theme.textSecondary)
                Spacer()
                Button("Zurücksetzen") { dashboard.reset() }
                    .font(.caption.bold())
                    .buttonStyle(.plain)
                    .foregroundColor(Theme.accent)
            }
            .padding(.top, 2)
        }
    }

    private func presetButton(_ preset: DashboardPreset) -> some View {
        let selected = dashboard.presetName == preset.label
        return Button {
            dashboard.apply(preset)
            withAnimation { dashboardEnabled = true }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: preset.symbol)
                    .font(.title3)
                    .foregroundColor(selected ? Theme.accent : Theme.textSecondary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.label)
                        .font(.callout.bold())
                        .foregroundColor(Theme.textPrimary)
                    Text(preset.subtitle)
                        .font(.caption2)
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.accent.opacity(0.12) : Theme.surfaceElevated)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(selected ? Theme.accent : Color.clear, lineWidth: 1.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var textSizeCard: some View {
        SettingsSection(title: "Textgröße", systemImage: "textformat.size") {
            HStack(spacing: 12) {
                Button {
                    textSizeIndex = max(0, currentTextIndex - 1)
                } label: {
                    Image(systemName: "minus").frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .background(Theme.surfaceElevated)
                .foregroundColor(Theme.textPrimary)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .disabled(currentTextIndex <= 0)

                Text(textSizeNames[currentTextIndex])
                    .font(.callout.monospaced().bold())
                    .foregroundColor(Theme.textPrimary)
                    .frame(maxWidth: .infinity)

                Button {
                    textSizeIndex = min(textSizeNames.count - 1, currentTextIndex + 1)
                } label: {
                    Image(systemName: "plus").frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .background(Theme.surfaceElevated)
                .foregroundColor(Theme.textPrimary)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .disabled(currentTextIndex >= textSizeNames.count - 1)
            }
            HStack {
                Text("Auch per ⌘+ / ⌘- / ⌘0 steuerbar.")
                    .font(.caption)
                    .foregroundColor(Theme.textSecondary)
                Spacer()
                if currentTextIndex != defaultTextSizeIndex {
                    Button("Zurücksetzen") { textSizeIndex = defaultTextSizeIndex }
                        .font(.caption.bold())
                        .buttonStyle(.plain)
                        .foregroundColor(Theme.accent)
                }
            }
        }
    }

    private var currentTextIndex: Int {
        min(max(textSizeIndex, 0), textSizeNames.count - 1)
    }

    // MARK: – Connection

    private var connectionCard: some View {
        SettingsSection(title: "Verbindung", systemImage: "network") {
            HStack {
                Circle().fill(statusColor).frame(width: 10, height: 10)
                Text(appState.connectionStatus.label)
                    .foregroundColor(Theme.textSecondary)
                Spacer()
            }
            if let c = appState.credentials {
                LabeledRow(label: "Host", value: c.host)
                LabeledRow(label: "Benutzer", value: c.username)
                LabeledRow(label: "Port", value: String(c.port))
                LabeledRow(label: "Auth", value: c.authMethod == .privateKey ? "SSH-Schlüssel" : "Passwort")
            } else {
                Text("Keine gespeicherten Zugangsdaten.")
                    .font(.caption)
                    .foregroundColor(Theme.textSecondary)
            }
        }
    }

    private var statusColor: Color {
        switch appState.connectionStatus {
        case .connected:    return Theme.success
        case .connecting:   return Theme.warning
        case .failed:       return Theme.danger
        case .disconnected: return Theme.textSecondary
        }
    }

    private var pingCard: some View {
        SettingsSection(title: "SSH-Test", systemImage: "antenna.radiowaves.left.and.right") {
            Button {
                Task { await ping() }
            } label: {
                HStack {
                    if pinging { ProgressView().controlSize(.small) }
                    else { Image(systemName: "bolt.horizontal") }
                    Text("Verbindung testen")
                }
                .frame(maxWidth: .infinity).padding(.vertical, 9)
                .background(Theme.accent.opacity(0.15))
                .foregroundColor(Theme.accent)
                .clipShape(RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .disabled(pinging || appState.slurm == nil)

            if let r = pingResult {
                let isErr = r.hasPrefix("✗")
                CopyableText(
                    text: r,
                    color: isErr ? Theme.danger : Theme.textPrimary,
                    iconColor: isErr ? Theme.danger : Theme.textSecondary
                )
            } else {
                Text("Führt echo + hostname + squeue --version auf dem Cluster aus.")
                    .font(.caption)
                    .foregroundColor(Theme.textSecondary)
            }
        }
    }

    private var actionsCard: some View {
        SettingsSection(title: "Konto", systemImage: "person.crop.circle") {
            Button {
                Task { await appState.disconnect() }
            } label: {
                Label("Verbindung trennen", systemImage: "link.badge.minus")
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background(Theme.surfaceElevated)
                    .foregroundColor(Theme.textPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(appState.slurm == nil)

            Button(role: .destructive) {
                showForgetConfirm = true
            } label: {
                Label("Zugangsdaten löschen", systemImage: "trash")
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background(Theme.danger.opacity(0.15))
                    .foregroundColor(Theme.danger)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
        }
    }

    private var aboutFooter: some View {
        VStack(spacing: 4) {
            Text("Version \(appVersion) (\(appBuild))")
                .font(.caption.monospaced())
                .foregroundColor(Theme.textSecondary)
            Text("Read-only by default · mutierende Befehle nur nach Bestätigung")
                .font(.caption2)
                .foregroundColor(Theme.textSecondary.opacity(0.8))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    private func ping() async {
        guard let slurm = appState.slurm else {
            pingResult = "✗ Keine Verbindung."
            return
        }
        pinging = true; defer { pinging = false }
        do {
            let txt = try await slurm.ping()
            pingResult = "✓ \(txt.trimmingCharacters(in: .whitespacesAndNewlines))"
        } catch {
            pingResult = "✗ \(error.localizedDescription)"
        }
    }
}

#Preview("Settings") {
    SettingsView()
        .environmentObject(AppState())
        .environmentObject(DashboardStore())
        .frame(width: 420, height: 900)
}

/// Titled card used to group related settings, matching the app's card style.
private struct SettingsSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.subheadline)
                    .foregroundColor(Theme.accent)
                Text(title)
                    .font(.headline)
                    .foregroundColor(Theme.textPrimary)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

private struct LabeledRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundColor(Theme.textSecondary)
            Spacer()
            Text(value)
                .font(.caption.monospaced())
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

/// Cross-platform `Image(named:)` so the Settings header can show the app icon
/// preview from the asset catalog on both AppKit and UIKit.
private extension Image {
    init(nsImageOrUIImageNamed name: String) {
        #if os(macOS)
        if let img = NSImage(named: name) {
            self = Image(nsImage: img)
        } else {
            self = Image(systemName: "square.grid.3x3.fill")
        }
        #else
        if let img = UIImage(named: name) {
            self = Image(uiImage: img)
        } else {
            self = Image(systemName: "square.grid.3x3.fill")
        }
        #endif
    }
}
