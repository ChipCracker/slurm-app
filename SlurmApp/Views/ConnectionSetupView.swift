import SwiftUI
import UniformTypeIdentifiers

struct ConnectionSetupView: View {
    @EnvironmentObject var appState: AppState
    @State private var creds: Credentials = .kiz0Default
    /// Formular-Entwurf, der den Unmount während `.connecting` überlebt:
    /// RootView tauscht diese View gegen den Lade-Screen aus, was alle
    /// @State-Felder zerstört. Schlägt der Connect fehl, stellt onAppear den
    /// Entwurf (inkl. getipptem Passwort / eingefügtem PEM-Key) wieder her,
    /// statt auf die Defaults zurückzufallen. Nur im Speicher, nie persistiert.
    @MainActor private static var draftCreds: Credentials?
    @State private var showKeyImporter = false
    @State private var testResult: String?
    @State private var testing: Bool = false
    @State private var availableKeys: [SSHKeyFile] = []
    @State private var selectedKeyName: String?
    @State private var isPasting: Bool = false
    @State private var pasteBuffer: String = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 20) {
                        header
                        formCard
                        actions
                        if let result = testResult {
                            let isErr = result.hasPrefix("✗")
                            CopyableText(
                                text: result,
                                color: isErr ? Theme.danger : Theme.textSecondary,
                                iconColor: isErr ? Theme.danger : Theme.textSecondary
                            )
                            .cardStyle()
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("Verbindung")
            // Kein opaker Nav-Bar-Hintergrund — System-Bar = Liquid Glass.
        }
        .onAppear {
            if case .failed = appState.connectionStatus, let draft = Self.draftCreds {
                // Fehlgeschlagener Verbindungsversuch: die zuletzt getippten
                // Werte wiederherstellen (gespeicherte Credentials gibt es beim
                // Erstlauf noch nicht — die werden erst nach Erfolg gesichert).
                creds = draft
            } else if let stored = appState.credentials {
                creds = stored
            }
            availableKeys = SSHKeyLoader.discoverDefaultKeys()
        }
    }

    /// Freundlicher Willkommens-Header mit dem Slurmy-Maskottchen — der erste
    /// Marken-Moment der App (Glow-Schatten wie in `SlurmyEmptyState`,
    /// markenfest Blue Bright).
    private var header: some View {
        VStack(spacing: 14) {
            Image("SlurmyMascot")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 140)
                .shadow(color: Color(red: 0.16, green: 0.45, blue: 0.92).opacity(0.35),
                        radius: 24, y: 6)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("Willkommen bei Slurmy")
                    .font(.title2.bold())
                    .foregroundColor(Theme.textPrimary)
                Text("SSH-Verbindung zum kiz0-Login-Node")
                    .font(.subheadline)
                    .foregroundColor(Theme.textSecondary)
            }
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private var formCard: some View {
        VStack(spacing: 14) {
            field(label: "Host", text: $creds.host, prompt: "kiz0.in.ohmportal.de")
            HStack {
                field(label: "User", text: $creds.username, prompt: "username")
                portField
            }
            Picker("Auth", selection: $creds.authMethod) {
                ForEach(AuthMethod.allCases) { m in Text(m.label).tag(m) }
            }
            .pickerStyle(.segmented)
            switch creds.authMethod {
            case .password:
                secureField(label: "Passwort", text: Binding(
                    get: { creds.password ?? "" },
                    set: { creds.password = $0 }
                ))
            case .privateKey:
                privateKeyEditor
                secureField(label: "Passphrase (optional)", text: Binding(
                    get: { creds.passphrase ?? "" },
                    set: { creds.passphrase = $0 }
                ))
            }
        }
        .cardStyle()
    }

    private var privateKeyEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Privater Schlüssel")
                    .font(.caption)
                    .foregroundColor(Theme.textSecondary)
                Spacer()
                keyImportButton
            }
            if !availableKeys.isEmpty {
                keyPicker
            }
            keyStatusOrPaste
        }
        .fileImporter(
            isPresented: $showKeyImporter,
            allowedContentTypes: [.data, .text, .plainText, .item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let didStart = url.startAccessingSecurityScopedResource()
                defer { if didStart { url.stopAccessingSecurityScopedResource() } }
                if let content = try? String(contentsOf: url, encoding: .utf8) {
                    creds.privateKey = content
                    selectedKeyName = url.lastPathComponent
                    pasteBuffer = ""
                    isPasting = false
                }
            case .failure(let err):
                testResult = String(localized: "Datei konnte nicht gelesen werden: \(err.localizedDescription)")
            }
        }
    }

    @ViewBuilder
    private var keyStatusOrPaste: some View {
        if let pem = creds.privateKey, !pem.isEmpty, !isPasting {
            loadedKeyCard(pem: pem)
        } else {
            pasteEditor
        }
    }

    private func loadedKeyCard(pem: String) -> some View {
        let keyType = detectKeyType(pem)
        let bytes = pem.utf8.count
        let source = selectedKeyName ?? String(localized: "Schlüssel hinterlegt")
        return HStack(spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .foregroundColor(Theme.success)
            VStack(alignment: .leading, spacing: 2) {
                Text(source)
                    .font(.callout.bold())
                    .foregroundColor(Theme.textPrimary)
                Text("\(keyType) · \(bytes) Bytes · Inhalt wird nicht angezeigt")
                    .font(.caption2)
                    .foregroundColor(Theme.textSecondary)
            }
            Spacer()
            Button {
                pasteBuffer = ""
                isPasting = true
            } label: {
                Text("Ersetzen").font(.caption.bold())
            }
            .buttonStyle(.plain)
            .foregroundColor(Theme.accent)
            Button {
                creds.privateKey = nil
                selectedKeyName = nil
                pasteBuffer = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Entfernen")
        }
        .padding(10)
        .background(Theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var pasteEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PEM einfügen (wird nach Bestätigung verborgen)")
                .font(.caption2)
                .foregroundColor(Theme.textSecondary)
            // Mehrzeiliges TextEditor statt SecureField: ein einzeiliges Feld
            // zerstört beim Einfügen die Zeilenumbrüche des PEM, was libssh2 als
            // "Unsupported private key file format" ablehnt. Autokorrektur aus,
            // damit der Base64-Body nicht verfälscht wird.
            ZStack(alignment: .topLeading) {
                if pasteBuffer.isEmpty {
                    Text("-----BEGIN OPENSSH PRIVATE KEY-----…")
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundColor(Theme.textSecondary.opacity(0.5))
                        .padding(.horizontal, 12).padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $pasteBuffer)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 130, maxHeight: 220)
                    .padding(6)
                    .plainTextInput()
            }
            .background(Theme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 8) {
                Button {
                    let trimmed = pasteBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        creds.privateKey = trimmed
                        selectedKeyName = nil
                        isPasting = false
                        pasteBuffer = ""
                    }
                } label: {
                    Label("Übernehmen", systemImage: "checkmark")
                        .font(.caption.bold())
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Theme.accent.opacity(0.18))
                        .foregroundColor(Theme.accent)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(pasteBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if isPasting && creds.privateKey != nil {
                    Button {
                        isPasting = false
                        pasteBuffer = ""
                    } label: {
                        Text("Abbrechen")
                            .font(.caption.bold())
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Theme.surfaceElevated)
                            .foregroundColor(Theme.textSecondary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
        }
    }

    private func detectKeyType(_ pem: String) -> String {
        let trimmed = pem.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----") { return "OpenSSH" }
        if trimmed.hasPrefix("-----BEGIN RSA PRIVATE KEY-----")     { return "RSA (PKCS#1)" }
        if trimmed.hasPrefix("-----BEGIN EC PRIVATE KEY-----")      { return "EC (PEM)" }
        if trimmed.hasPrefix("-----BEGIN PRIVATE KEY-----")         { return "PKCS#8" }
        return String(localized: "Unbekannt")
    }

    private var keyImportButton: some View {
        Button {
            showKeyImporter = true
        } label: {
            Label("Datei wählen", systemImage: "folder")
                .font(.caption.bold())
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Theme.surfaceElevated)
                .foregroundColor(Theme.accent)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var keyPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Standard aus ~/.ssh").font(.caption2).foregroundColor(Theme.textSecondary)
            HStack(spacing: 6) {
                ForEach(availableKeys) { key in
                    Button {
                        loadKey(key)
                    } label: {
                        Text(key.name)
                            .font(.caption.monospaced())
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(selectedKeyName == key.name ? Theme.accent.opacity(0.22) : Theme.surfaceElevated)
                            .foregroundColor(selectedKeyName == key.name ? Theme.accent : Theme.textPrimary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func loadKey(_ key: SSHKeyFile) {
        do {
            creds.privateKey = try SSHKeyLoader.read(key)
            selectedKeyName = key.name
            testResult = nil
        } catch {
            testResult = String(localized: "Konnte \(key.name) nicht lesen: \(error.localizedDescription)")
        }
    }

    private var portField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Port")
                .font(.caption)
                .foregroundColor(Theme.textSecondary)
            TextField("22", value: $creds.port, format: .number)
                .numberInput()
                .padding(10)
                .background(Theme.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .foregroundColor(Theme.textPrimary)
        }
        .frame(width: 80)
    }

    // LocalizedStringKey statt String: Die Literal-Labels lokalisieren so
    // automatisch über den Katalog; die Prompts (Beispielwerte) bleiben roh.
    private func field(label: LocalizedStringKey, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(Theme.textSecondary)
            TextField(prompt, text: text)
                .plainTextInput()
                .padding(10)
                .background(Theme.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .foregroundColor(Theme.textPrimary)
        }
    }

    private func secureField(label: LocalizedStringKey, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(Theme.textSecondary)
            SecureField("•••", text: text)
                .padding(10)
                .background(Theme.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .foregroundColor(Theme.textPrimary)
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                Task { await testConnection() }
            } label: {
                Label(testing ? "Teste…" : "Verbindung testen", systemImage: "antenna.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.surfaceElevated)
                    .foregroundColor(Theme.textPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .disabled(testing || !canSubmit)

            Button {
                Self.draftCreds = creds
                Task { await appState.connect(using: creds) }
            } label: {
                Label("Verbinden", systemImage: "bolt.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.accent)
                    .foregroundColor(Theme.onAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .disabled(!canSubmit)

            if case .failed(let msg) = appState.connectionStatus {
                ErrorBanner(message: msg)
            }
        }
    }

    private var canSubmit: Bool {
        !creds.host.isEmpty && !creds.username.isEmpty &&
        (creds.authMethod == .password
            ? !(creds.password ?? "").isEmpty
            : !(creds.privateKey ?? "").isEmpty)
    }

    private func testConnection() async {
        testing = true; defer { testing = false }
        testResult = String(localized: "Verbinde mit \(creds.host):\(creds.port)…")
        do {
            let client = try await SSHClient.connect(credentials: creds)
            let info = try await client.ping()
            await client.close()
            testResult = String(localized: "✓ Verbindung ok\n\(info.trimmingCharacters(in: .whitespacesAndNewlines))")
        } catch {
            testResult = String(localized: "✗ Fehler: \(error.localizedDescription)")
        }
    }
}
