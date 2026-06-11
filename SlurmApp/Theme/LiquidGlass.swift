import SwiftUI

// MARK: – Liquid Glass (macOS 26+ / iOS 26) mit Legacy-Fallback
//
// Strategie: Das gesamte "Frosted Glass" der App läuft über die Helfer in
// dieser Datei. Auf macOS 26+ und iOS (Deployment-Target 26 ⇒ dort immer
// verfügbar) rendern sie natives Liquid Glass (`glassEffect`,
// `.buttonStyle(.glass)`) — sofern der Settings-Schalter "Liquid Glass"
// (`LiquidGlassSetting`/`\.liquidGlassEnabled`) es erlaubt; auf macOS 14/15
// und bei deaktiviertem Schalter replizieren sie den bisherigen Custom-Frost:
// `Theme.glassGradient` + `.ultraThinMaterial` + 0.5pt Hairline-Rahmen
// (gleiche Geometrie, Theme-getönte Flächen ⇒ farb- und layoutkompatibel).
// Die Tönung kommt aus `Theme.glassTint`, damit Farb-Themes und eigene
// Akzentfarben das Glas weiter einfärben.
//
// HIG-Disziplin: Diese Helfer gehören ausschließlich auf die SCHWEBENDE
// Ebene (Modals, Overlays, Header-Buttons, schwebende Controls). Karten in
// scrollendem Inhalt bleiben opake `Theme.surface`-Karten — kein Glas auf
// Content und niemals Glas-auf-Glas. Damit Letzteres auch für Controls gilt,
// setzt `GlassPanel` das Environment-Flag `insideGlassPanel`: Die
// Button-Helfer unten prüfen es und fallen INNERHALB eines Glas-Panels
// (macOS-26-Overlay-Modal) auf ihren Legacy-Look zurück, statt eigenes
// Liquid Glass auf die Glasfläche zu stapeln. Auf iOS liegen die Modals in
// System-Sheets (kein GlassPanel) — dort bleiben die Buttons nativ aus Glas.

// MARK: – Schalter: Liquid Glass an/aus (Settings → Darstellung)

/// Zentrale, billige Abfrage des "liquidGlassEnabled"-Schalters: ein gecachtes
/// Bool, invalidiert über `UserDefaults.didChangeNotification` — gleicher
/// Mechanismus wie der Paletten-Cache in Theme.swift, kein UserDefaults-Read
/// pro View-Body. Der App-Root liest den Key zusätzlich via @AppStorage und
/// injiziert ihn ins Environment (`\.liquidGlassEnabled`), damit der Baum beim
/// Umschalten neu rendert. Gilt nur für die app-eigenen Glas-Pfade —
/// System-Chrome (Toolbar/Sidebar/Sheet-Rahmen) bleibt vom Schalter unberührt.
enum LiquidGlassSetting {
    static let storageKey = "liquidGlassEnabled"
    /// Glas-Intensität 0…1 (Settings-Slider „Getönt … Klar"): steuert, wie
    /// stark das Fenster-Material durch die Theme-Tönung der Panes scheint.
    static let intensityKey = "liquidGlassIntensity"
    static let defaultIntensity = 0.5

    private static var cached: Bool?
    private static var cachedIntensity: Double?
    private static let cacheInvalidator: NSObjectProtocol =
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { _ in
            LiquidGlassSetting.cached = nil
            LiquidGlassSetting.cachedIntensity = nil
        }

    /// true (Default) ⇒ native Glas-Effekte erlaubt (sofern das OS sie kann).
    static var isEnabled: Bool {
        _ = cacheInvalidator // Observer beim ersten Zugriff registrieren.
        if let cached { return cached }
        let v = UserDefaults.standard.object(forKey: storageKey) as? Bool ?? true
        cached = v
        return v
    }

    static var intensity: Double {
        _ = cacheInvalidator
        if let cachedIntensity { return cachedIntensity }
        let v = UserDefaults.standard.object(forKey: intensityKey) as? Double ?? defaultIntensity
        cachedIntensity = v
        return v
    }

    /// Tönungs-Deckkraft der Panes aus der Intensität: 0 ⇒ 0.9 (kaum Glas),
    /// 0.5 ⇒ 0.55 (Default), 1 ⇒ 0.2 (fast voll Glas). Textkontrast bleibt
    /// auch bei „Klar" tragfähig, weil das Material selbst diffundiert.
    static func paneTintOpacity(intensity: Double) -> Double {
        0.9 - 0.7 * min(max(intensity, 0), 1)
    }
}

private struct LiquidGlassEnabledKey: EnvironmentKey {
    /// Fallback ohne Root-Injection (Previews etc.): der gecachte Settings-Wert.
    static var defaultValue: Bool { LiquidGlassSetting.isEnabled }
}

private struct LiquidGlassIntensityKey: EnvironmentKey {
    static var defaultValue: Double { LiquidGlassSetting.intensity }
}

extension EnvironmentValues {
    /// Vom App-Root (SlurmApp.swift) aus @AppStorage injiziert; die Glas-Helfer
    /// lesen ihn, damit ein Umschalten in den Settings sofort neu rendert.
    var liquidGlassEnabled: Bool {
        get { self[LiquidGlassEnabledKey.self] }
        set { self[LiquidGlassEnabledKey.self] = newValue }
    }

    /// Glas-Intensität 0…1 (s. LiquidGlassSetting.intensityKey) — ebenfalls
    /// vom Root injiziert, damit der Slider live wirkt.
    var liquidGlassIntensity: Double {
        get { self[LiquidGlassIntensityKey.self] }
        set { self[LiquidGlassIntensityKey.self] = newValue }
    }
}

// MARK: – Environment: sitzt die View in einem GlassPanel?

private struct InsideGlassPanelKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Von `GlassPanel` (GlassModal.swift) auf `true` gesetzt, damit
    /// verschachtelte Glas-Controls sich selbst de-glasen können.
    var insideGlassPanel: Bool {
        get { self[InsideGlassPanelKey.self] }
        set { self[InsideGlassPanelKey.self] = newValue }
    }
}

/// Baut den nativen `Glass`-Stil aus Tönung + Interaktivität zusammen.
@available(macOS 26.0, iOS 26.0, *)
private func slurmyGlassStyle(tint: Color?, interactive: Bool) -> Glass {
    var glass: Glass = .regular
    if let tint { glass = glass.tint(tint) }
    if interactive { glass = glass.interactive() }
    return glass
}

extension View {
    /// Natives Liquid-Glass-Panel auf macOS 26+/iOS 26 (sofern der
    /// Settings-Schalter es erlaubt), sonst Legacy-Frost (Theme.glassGradient
    /// + ultraThinMaterial + Hairline-Border) — gleiche Geometrie, nur
    /// Theme-getönte Flächen statt echtem Glas.
    func slurmyGlass(cornerRadius: CGFloat = 24, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(SlurmyGlassModifier(cornerRadius: cornerRadius, tint: tint, interactive: interactive))
    }

    /// Button-Style-Helfer: .glass/.glassProminent wenn verfügbar, sonst
    /// .bordered/.borderedProminent. In einem `GlassPanel` immer der
    /// Bordered-Look — kein Glas-auf-Glas.
    func slurmyGlassButton(prominent: Bool = false) -> some View {
        modifier(SlurmyGlassButtonModifier(prominent: prominent))
    }

    /// Runder Glas-Icon-Button für Modal-Header (Refresh / Close / Copy).
    /// Nativ: `.glass` in Kreisform; Legacy: heutiger Look
    /// (`.plain` + Material-Kreis), damit macOS 14/15 unverändert bleibt.
    /// In einem `GlassPanel` ebenfalls der Material-Kreis — kein Glas-auf-Glas.
    func slurmyGlassCircleButton() -> some View {
        modifier(SlurmyGlassCircleButtonModifier())
    }
}

/// ViewModifier statt View-Extension, damit `liquidGlassEnabled` aus dem
/// Environment gelesen werden kann (in einer Extension-Funktion geht das nicht).
private struct SlurmyGlassModifier: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color?
    let interactive: Bool
    @Environment(\.liquidGlassEnabled) private var liquidGlassEnabled

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, iOS 26.0, *), liquidGlassEnabled {
            // Inhalt zuerst auf die Glasform clippen (ScrollViews etc. würden
            // sonst über die runden Ecken hinausragen), dann das echte Glas
            // in derselben Form dahinter rendern. Immer die Form übergeben —
            // der Default wäre eine Capsule.
            content
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .glassEffect(
                    slurmyGlassStyle(tint: tint, interactive: interactive),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
        } else {
            // Custom-Frost, 1:1 aus dem alten GlassPanel übernommen — dient
            // sowohl macOS 14/15 als auch dem deaktivierten Glas-Schalter.
            content
                .background(
                    ZStack {
                        LinearGradient(
                            colors: Theme.glassGradient,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        Rectangle().fill(.ultraThinMaterial)
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Theme.hairline, lineWidth: 0.5)
                )
        }
    }
}

/// ViewModifier statt View-Extension, damit `insideGlassPanel` /
/// `liquidGlassEnabled` aus dem Environment gelesen werden können.
private struct SlurmyGlassButtonModifier: ViewModifier {
    let prominent: Bool
    @Environment(\.insideGlassPanel) private var insideGlassPanel
    @Environment(\.liquidGlassEnabled) private var liquidGlassEnabled

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, iOS 26.0, *), liquidGlassEnabled {
            if insideGlassPanel {
                bordered(content)
            } else if prominent {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        } else {
            bordered(content)
        }
    }

    @ViewBuilder
    private func bordered(_ content: Content) -> some View {
        if prominent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

private struct SlurmyGlassCircleButtonModifier: ViewModifier {
    @Environment(\.insideGlassPanel) private var insideGlassPanel
    @Environment(\.liquidGlassEnabled) private var liquidGlassEnabled

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, iOS 26.0, *), liquidGlassEnabled {
            if insideGlassPanel {
                materialCircle(content)
            } else {
                content
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
            }
        } else {
            materialCircle(content)
        }
    }

    private func materialCircle(_ content: Content) -> some View {
        content
            .buttonStyle(.plain)
            .background(.thinMaterial, in: Circle())
    }
}

// MARK: – Transluzentes Fenster ("glossy"), wenn Liquid Glass aktiv ist

extension View {
    /// Fenster-Material unter dem GESAMTEN Fenster (macOS): Desktop/dahinter-
    /// liegende Fenster schimmern durch, die System-Toolbar bekommt echten
    /// Inhalt zum Brechen. Nur bei aktivem Liquid Glass; sonst unverändert
    /// opak. Auf dem App-Root (MacRootView) anwenden.
    func slurmyWindowGlass() -> some View { modifier(SlurmyWindowGlassModifier()) }

    /// Content-Hintergrund der Panes: opak ohne Glas, halbtransparent getönt
    /// mit — die Theme-Farbe bleibt sichtbar (Farbkompatibilität), aber das
    /// Fenster-Material scheint durch. Ersetzt `.background(Theme.background)`.
    func slurmyContentBackground() -> some View { modifier(SlurmyContentBackgroundModifier()) }
}

private struct SlurmyWindowGlassModifier: ViewModifier {
    @Environment(\.liquidGlassEnabled) private var liquidGlassEnabled
    @Environment(\.liquidGlassIntensity) private var liquidGlassIntensity

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(macOS)
        if #available(macOS 26.0, *), liquidGlassEnabled {
            // Hohe Intensität ⇒ noch dünneres Material: der ganze
            // Hintergrund wird praktisch Glas.
            if liquidGlassIntensity > 0.7 {
                content.containerBackground(.ultraThinMaterial, for: .window)
            } else {
                content.containerBackground(.thinMaterial, for: .window)
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

private struct SlurmyContentBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.background(SlurmyPaneBackground())
    }
}

/// ZStack-Grundschicht-Variante: ersetzt `Theme.background` als unterste
/// Ebene eines Panes. Transluzenz NUR auf macOS — auf iOS liegt kein
/// Fenster-Material darunter, dort würde die Theme-Farbe nur verblassen.
struct SlurmyPaneBackground: View {
    @Environment(\.liquidGlassEnabled) private var liquidGlassEnabled
    @Environment(\.liquidGlassIntensity) private var liquidGlassIntensity

    var body: some View {
        #if os(macOS)
        if #available(macOS 26.0, *), liquidGlassEnabled {
            // Deckkraft folgt dem Intensitäts-Slider (Getönt … Klar);
            // Default 0.5 ⇒ 0.55 Tönung über dem Fenster-Material.
            Theme.background.opacity(LiquidGlassSetting.paneTintOpacity(intensity: liquidGlassIntensity))
        } else {
            Theme.background
        }
        #else
        Theme.background
        #endif
    }
}

/// Gruppiert benachbarte Glas-Buttons (z. B. Refresh + Close im Modal-Header)
/// in einem `GlassEffectContainer`, damit ihre Formen nativ ineinander
/// verschmelzen/morphen können; vor macOS 26 schlicht ein HStack.
struct SlurmyGlassButtonGroup<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content
    @Environment(\.liquidGlassEnabled) private var liquidGlassEnabled

    init(spacing: CGFloat = 12, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        if #available(macOS 26.0, iOS 26.0, *), liquidGlassEnabled {
            GlassEffectContainer(spacing: spacing) {
                HStack(spacing: spacing) { content() }
            }
        } else {
            HStack(spacing: spacing) { content() }
        }
    }
}
