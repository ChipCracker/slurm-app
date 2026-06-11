import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// App-wide appearance preference, persisted via `@AppStorage("appearance")`.
/// `.system` follows the OS (auto) and is the default.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "Automatisch"
        case .light:  return "Hell"
        case .dark:   return "Dunkel"
        }
    }

    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max"
        case .dark:   return "moon"
        }
    }

    /// nil = follow the system (auto).
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

/// Selectable accent palette ("Theme"), persisted via
/// `@AppStorage("accentTheme")`. Drives `Theme.accent` (buttons, tint, focus
/// indicator, pills) while the semantic colors (success/warning/danger) stay
/// fixed so status meaning never changes between themes.
enum AppTheme: String, CaseIterable, Identifiable {
    case blue, indigo, teal, green, purple, orange, rose, graphite

    static let storageKey = "accentTheme"
    static let `default`: AppTheme = .blue

    var id: String { rawValue }

    var label: String {
        switch self {
        case .blue:     return "Blau"
        case .indigo:   return "Indigo"
        case .teal:     return "Türkis"
        case .green:    return "Grün"
        case .purple:   return "Violett"
        case .orange:   return "Orange"
        case .rose:     return "Rosé"
        case .graphite: return "Graphit"
        }
    }

    /// Cached lookup: `Color(light:dark:)` allocates a fresh dynamic platform
    /// color (NSColor/UIColor provider + closures) on every call, so each
    /// theme's accent is built exactly ONCE. This also keeps the accent
    /// value-stable across body passes, so SwiftUI's diffing doesn't see a
    /// "new" color on every render.
    var accent: Color { Self.accentCache[self] ?? Self.makeAccent(self) }

    private static let accentCache: [AppTheme: Color] =
        Dictionary(uniqueKeysWithValues: AppTheme.allCases.map { ($0, AppTheme.makeAccent($0)) })

    private static func makeAccent(_ theme: AppTheme) -> Color {
        switch theme {
        case .blue:
            return Color(light: Color(red: 0.13, green: 0.40, blue: 0.86),
                         dark:  Color(red: 0.49, green: 0.65, blue: 1.00))
        case .indigo:
            return Color(light: Color(red: 0.28, green: 0.26, blue: 0.80),
                         dark:  Color(red: 0.64, green: 0.62, blue: 1.00))
        case .teal:
            return Color(light: Color(red: 0.06, green: 0.52, blue: 0.58),
                         dark:  Color(red: 0.40, green: 0.84, blue: 0.90))
        case .green:
            return Color(light: Color(red: 0.17, green: 0.54, blue: 0.30),
                         dark:  Color(red: 0.50, green: 0.84, blue: 0.58))
        case .purple:
            return Color(light: Color(red: 0.50, green: 0.25, blue: 0.80),
                         dark:  Color(red: 0.80, green: 0.58, blue: 1.00))
        case .orange:
            return Color(light: Color(red: 0.80, green: 0.42, blue: 0.08),
                         dark:  Color(red: 1.00, green: 0.68, blue: 0.36))
        case .rose:
            return Color(light: Color(red: 0.80, green: 0.20, blue: 0.45),
                         dark:  Color(red: 1.00, green: 0.55, blue: 0.72))
        case .graphite:
            return Color(light: Color(red: 0.30, green: 0.34, blue: 0.42),
                         dark:  Color(red: 0.64, green: 0.70, blue: 0.82))
        }
    }

    static var current: AppTheme {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? `default`.rawValue
        return AppTheme(rawValue: raw) ?? `default`
    }
}

extension Color {
    /// Builds a color that resolves differently in light and dark mode, so the
    /// whole `Theme` palette adapts to the active appearance without an asset
    /// catalog round-trip.
    init(light: Color, dark: Color) {
        #if os(macOS)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        })
        #else
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
        #endif
    }
}

enum Theme {
    /// Cache der aufgelösten Palette. Eine Auflösung pro Zugriff wäre teuer
    /// (UserDefaults-Reads + Struct-Kopie + für das Standard-Thema eine frische
    /// dynamische Accent-Color — bei ~470 `Theme.*`-Reads pro Jobs-Render
    /// messbarer Main-Thread-Overhead und nie wert-gleiche Colors fürs
    /// SwiftUI-Diffing). Invalidiert über `UserDefaults.didChangeNotification`
    /// (deckt colorTheme, accentTheme UND die Override-Revision ab); der
    /// App-Root liest die @AppStorage-Keys weiterhin, damit der View-Baum bei
    /// einem Wechsel neu rendert (siehe SlurmApp.swift). Main-thread-only wie
    /// alle `Theme`-Zugriffe.
    private static var cachedPalette: ThemePalette?
    private static let cacheInvalidator: NSObjectProtocol =
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { _ in Theme.cachedPalette = nil }

    /// The resolved palette: the active colour theme + the accent override (for
    /// the standard theme). Resolved once and cached (see `cachedPalette`).
    static var palette: ThemePalette {
        _ = cacheInvalidator // Observer beim ersten Zugriff registrieren.
        if let p = cachedPalette { return p }
        let theme = AppColorTheme.current
        var p = theme.palette
        if theme.allowsAccentOverride { p.accent = AppTheme.current.accent }
        cachedPalette = p
        return p
    }

    static var background: Color      { palette.background }
    static var surface: Color         { palette.surface }
    static var surfaceElevated: Color { palette.surfaceElevated }
    static var border: Color          { palette.border }
    static var textPrimary: Color     { palette.textPrimary }
    static var textSecondary: Color   { palette.textSecondary }
    /// A user accent override (Settings → Eigene Farben) wins over the theme.
    static var accent: Color          { ThemeOverrideStore.shared.color(for: .accent) ?? palette.accent }
    static var success: Color         { palette.success }
    static var warning: Color         { palette.warning }
    static var danger: Color          { palette.danger }
    static var purple: Color          { palette.purple }
    static var cyan: Color            { palette.cyan }

    /// Text/glyph color that sits on top of an `accent`-filled surface.
    static var onAccent: Color        { palette.onAccent }
    /// Hairline color for dividers and 0.5pt strokes.
    static var hairline: Color        { palette.hairline }

    /// Gradient behind the LEGACY `GlassPanel` fallback (macOS 14/15) —
    /// themeable; mirrors the pre-Liquid-Glass look.
    static var glassGradient: [Color] {
        let p = palette
        return p.glassGradient
            ?? [accent.opacity(0.20), p.purple.opacity(0.12), p.background.opacity(0.4)]
    }

    /// Einzel-Tönung für natives Liquid Glass (macOS 26+/iOS 26): echtes Glas
    /// liefert Tiefe/Blur selbst, deshalb kollabiert der 3-Stop-`glassGradient`
    /// zu einem subtilen Akzent-Tint. Über `accent` bleibt das Glas voll
    /// Theme-/Override-reaktiv; opinionated Themes können via
    /// `ThemePalette.glassTint` überschreiben. Nicht mit `surface`/`background`
    /// tinten — das macht das Glas wieder opak.
    static var glassTint: Color {
        palette.glassTint ?? accent.opacity(0.14)
    }

    static func stateColor(_ state: String) -> Color {
        // A user override for this status slot wins over the theme colour.
        if let slot = ThemeSlot.forJobState(state),
           let c = ThemeOverrideStore.shared.color(for: slot) {
            return c
        }
        let p = palette // resolve once, read fields from the local
        switch state.uppercased() {
        case "R", "RUNNING":         return p.success
        case "PD", "PENDING":        return p.warning
        case "CG", "COMPLETING":     return p.cyan
        case "CD", "COMPLETED":      return p.textSecondary
        case "F", "FAILED",
             "CA", "CANCELLED",
             "TO", "TIMEOUT",
             "NF", "NODE_FAIL":      return p.danger
        case "S", "SUSPENDED":       return p.purple
        default:                     return p.textSecondary
        }
    }

    /// Stable per-QoS color so each QoS name always maps to the same hue across
    /// launches (deterministic djb2 hash, NOT Swift's randomized `hashValue`).
    /// Indexes into the active theme's QoS palette.
    static func qosColor(_ qos: String) -> Color {
        let pal = palette.qosPalette
        let key = qos.lowercased().trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !pal.isEmpty else { return textSecondary }
        var hash: UInt64 = 5381
        for scalar in key.unicodeScalars {
            hash = (hash &* 33) &+ UInt64(scalar.value)
        }
        return pal[Int(hash % UInt64(pal.count))]
    }

    static func utilizationColor(_ ratio: Double) -> Color {
        switch ratio {
        case ..<0.5:  return success
        case ..<0.85: return warning
        default:      return danger
        }
    }

    /// Colouring for GPU live stats, where the meaning is inverted vs. cluster
    /// capacity: HIGH utilisation is GOOD (the card is being used efficiently)
    /// → green; low is just idle → neutral grey, never an alarming red.
    static func gpuUtilColor(_ ratio: Double) -> Color {
        switch ratio {
        case 0.66...:     return success                    // well utilised → green
        case 0.33..<0.66: return success.opacity(0.55)      // partial → faded green
        default:          return textSecondary.opacity(0.7) // idle/low → neutral grey
        }
    }

    // GPU-allocation overlay colors (slurm-tui "earth tones"): green = mine,
    // red = others, neutral = free. Now theme-driven (see ThemePalette).
    static var ownNonPreempt: Color   { palette.ownNonPreempt }
    static var ownPreempt: Color      { palette.ownPreempt }
    static var otherNonPreempt: Color { palette.otherNonPreempt }
    static var otherPreempt: Color    { palette.otherPreempt }
    static var gpuFree: Color         { palette.gpuFree }
}

struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Theme.border, lineWidth: 1)
            )
    }
}

extension View {
    func cardStyle() -> some View { modifier(CardStyle()) }
}
