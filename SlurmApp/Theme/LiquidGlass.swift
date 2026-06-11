import SwiftUI

// MARK: – Liquid Glass (macOS 26+ / iOS 26) mit Legacy-Fallback
//
// Strategie: Das gesamte "Frosted Glass" der App läuft über die Helfer in
// dieser Datei. Auf macOS 26+ und iOS (Deployment-Target 26 ⇒ dort immer
// verfügbar) rendern sie natives Liquid Glass (`glassEffect`,
// `.buttonStyle(.glass)`); auf macOS 14/15 replizieren sie den bisherigen
// Custom-Frost: `Theme.glassGradient` + `.ultraThinMaterial` + 0.5pt
// Hairline-Rahmen. Die Tönung kommt aus `Theme.glassTint`, damit
// Farb-Themes und eigene Akzentfarben das Glas weiter einfärben.
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
    /// Natives Liquid-Glass-Panel auf macOS 26+/iOS 26, Legacy-Frost
    /// (Theme.glassGradient + ultraThinMaterial + Hairline-Border) auf macOS 14–15.
    @ViewBuilder
    func slurmyGlass(cornerRadius: CGFloat = 24, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            // Inhalt zuerst auf die Glasform clippen (ScrollViews etc. würden
            // sonst über die runden Ecken hinausragen), dann das echte Glas
            // in derselben Form dahinter rendern. Immer die Form übergeben —
            // der Default wäre eine Capsule.
            self
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .glassEffect(
                    slurmyGlassStyle(tint: tint, interactive: interactive),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
        } else {
            // Heutiger Custom-Frost, 1:1 aus dem alten GlassPanel übernommen.
            self
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

/// ViewModifier statt View-Extension, damit `insideGlassPanel` aus dem
/// Environment gelesen werden kann (in einer Extension-Funktion geht das nicht).
private struct SlurmyGlassButtonModifier: ViewModifier {
    let prominent: Bool
    @Environment(\.insideGlassPanel) private var insideGlassPanel

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
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

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
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

/// Gruppiert benachbarte Glas-Buttons (z. B. Refresh + Close im Modal-Header)
/// in einem `GlassEffectContainer`, damit ihre Formen nativ ineinander
/// verschmelzen/morphen können; vor macOS 26 schlicht ein HStack.
struct SlurmyGlassButtonGroup<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    init(spacing: CGFloat = 12, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                HStack(spacing: spacing) { content() }
            }
        } else {
            HStack(spacing: spacing) { content() }
        }
    }
}
