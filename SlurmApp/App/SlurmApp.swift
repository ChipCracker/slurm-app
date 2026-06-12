import SwiftUI
#if os(iOS)
import UIKit
#endif

@main
struct SlurmApp: App {
    @StateObject private var appState = AppState()

    /// Textgröße über Dynamic Type. ⌘+/⌘-/⌘0 stufen durch die Standardgrößen;
    /// der Index wird persistiert. `.large` ist der Default (Index 3).
    @AppStorage("textSizeIndex") private var textSizeIndex: Int = 3

    /// Light/Dark/Auto. Default is `.system` (automatic) — set in Settings.
    @AppStorage("appearance") private var appearanceRaw: String = AppAppearance.system.rawValue
    private var appearance: AppAppearance { AppAppearance(rawValue: appearanceRaw) ?? .system }

    /// Selected accent palette. Read here so the whole content tree re-renders
    /// (and `Theme.accent` re-resolves) the moment the user picks a new theme.
    @AppStorage(AppTheme.storageKey) private var accentThemeRaw: String = AppTheme.default.rawValue
    /// Full colour theme. Reading it here is load-bearing: it forces the tree
    /// re-render on a theme switch so the computed `Theme.*` statics re-resolve.
    @AppStorage(AppColorTheme.storageKey) private var colorThemeRaw: String = AppColorTheme.default.rawValue
    /// Bumped whenever a custom colour override changes — reading it here forces
    /// the tree to re-render so the computed `Theme.*` statics pick up overrides.
    @AppStorage(ThemeOverrideStore.revisionKey) private var themeOverrideRevision: Int = 0
    /// Liquid Glass an/aus (Settings → Darstellung). Hier gelesen und ins
    /// Environment injiziert — gleicher Mechanismus wie appearance/accentTheme,
    /// damit der Baum beim Umschalten neu rendert und die Glas-Helfer
    /// (Theme/LiquidGlass.swift) sofort den neuen Wert sehen.
    @AppStorage(LiquidGlassSetting.storageKey) private var liquidGlassEnabled: Bool = true
    @AppStorage(LiquidGlassSetting.intensityKey) private var liquidGlassIntensity: Double = LiquidGlassSetting.defaultIntensity
    private var colorTheme: AppColorTheme { AppColorTheme(rawValue: colorThemeRaw) ?? .default }
    /// A custom accent override wins; else the standard theme uses the chosen
    /// accent and opinionated themes their own.
    private var accentColor: Color {
        if let c = ThemeOverrideStore.shared.color(for: .accent) { return c }
        return colorTheme.allowsAccentOverride
            ? (AppTheme(rawValue: accentThemeRaw) ?? .default).accent
            : colorTheme.palette.accent
    }
    /// A theme may pin an appearance (Terminal → dark); otherwise the user's
    /// appearance preference wins.
    private var effectiveColorScheme: ColorScheme? {
        colorTheme.forcedColorScheme ?? appearance.colorScheme
    }

    private let sizes: [DynamicTypeSize] =
        [.xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge]
    private let defaultIndex = 3

    init() {
        // Sprache: Deutsch ist der App-Default — auch auf englischen Systemen.
        // Registrierter Default für alle UserDefaults-Leser; ein vom Nutzer in
        // den Einstellungen gewählter (persistierter) AppleLanguages-Wert
        // gewinnt dauerhaft, „Deutsch" entfernt ihn wieder.
        UserDefaults.standard.register(defaults: ["AppleLanguages": ["de"]])
        // CFBundle (String-Katalog-Auflösung) liest die Registration-Domain
        // NICHT — ohne persistierten Wert würde ein englisches System trotzdem
        // Englisch laden. Daher einmal pro Start säen, solange der Nutzer
        // nichts anderes persistiert hat (Settings → Sprache räumt bei
        // „Deutsch" auf, dieser Seed stellt den de-Default dann wieder her).
        let persisted = Bundle.main.bundleIdentifier
            .flatMap { UserDefaults.standard.persistentDomain(forName: $0) }?["AppleLanguages"]
        if persisted == nil {
            UserDefaults.standard.set(["de"], forKey: "AppleLanguages")
        }
        // Load the InjectionIII bundle at launch so live hot reloading works in
        // Debug on macOS (no-op in Release / when InjectionIII isn't installed).
        #if DEBUG && os(macOS)
        loadInjectionBundleIfAvailable()
        #endif
        #if os(iOS)
        // iPad: Das Grid-Dashboard (Liste + Detail + Cluster nebeneinander)
        // ist dort der sinnvolle Default statt der gestreckten Telefon-Liste.
        // Als registrierter Default statt `set`: Ein bewusstes Abschalten in
        // den Einstellungen (expliziter Wert) gewinnt dauerhaft; @AppStorage
        // liest registrierte Defaults vor seinem Initialwert.
        if UIDevice.current.userInterfaceIdiom == .pad {
            UserDefaults.standard.register(defaults: ["jobsDashboardEnabled": true])
        }
        #endif
    }

    private var currentIndex: Int { min(max(textSizeIndex, 0), sizes.count - 1) }
    private func setSize(_ i: Int) { textSizeIndex = min(max(i, 0), sizes.count - 1) }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .preferredColorScheme(effectiveColorScheme)
                .tint(accentColor)
                .environment(\.liquidGlassEnabled, liquidGlassEnabled)
                .environment(\.liquidGlassIntensity, liquidGlassIntensity)
                // Nur überschreiben, wenn der Nutzer per ⌘+/⌘- abgewichen ist —
                // sonst die System-Textgröße (iOS Dynamic Type) durchlassen.
                .modifier(TextScale(size: currentIndex == defaultIndex ? nil : sizes[currentIndex]))
                .macWindowSizing()
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 720)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified(showsTitle: true))
        #endif
        .commands {
            #if os(macOS)
            CommandGroup(replacing: .newItem) {}
            #endif
            // In das System-"Darstellung"/"View"-Menü einhängen statt eines
            // eigenen Top-Level-Menüs — sonst stehen zwei Darstellungs-Menüs
            // (das automatische der NavigationSplitView und ein eigenes)
            // nebeneinander in der Menüleiste.
            CommandGroup(after: .toolbar) {
                Divider()
                Button("Schrift vergrößern") { setSize(currentIndex + 1) }
                    .keyboardShortcut("+", modifiers: .command)
                    .disabled(currentIndex >= sizes.count - 1)
                Button("Schrift verkleinern") { setSize(currentIndex - 1) }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(currentIndex <= 0)
                Button("Originalgröße") { setSize(defaultIndex) }
                    .keyboardShortcut("0", modifiers: .command)
            }
        }
    }
}

/// Wendet eine feste Dynamic-Type-Größe an, wenn gesetzt; sonst no-op (System).
private struct TextScale: ViewModifier {
    let size: DynamicTypeSize?
    func body(content: Content) -> some View {
        if let size {
            content.dynamicTypeSize(size)
        } else {
            content
        }
    }
}
