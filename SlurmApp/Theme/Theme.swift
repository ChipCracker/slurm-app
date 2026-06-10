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

    var accent: Color {
        switch self {
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
    static let background = Color(
        light: Color(red: 0.95, green: 0.96, blue: 0.98),
        dark:  Color(red: 0.10, green: 0.11, blue: 0.16))
    static let surface = Color(
        light: Color(red: 1.00, green: 1.00, blue: 1.00),
        dark:  Color(red: 0.14, green: 0.15, blue: 0.22))
    static let surfaceElevated = Color(
        light: Color(red: 0.93, green: 0.95, blue: 0.98),
        dark:  Color(red: 0.17, green: 0.19, blue: 0.27))
    static let border = Color(
        light: Color(red: 0.84, green: 0.86, blue: 0.91),
        dark:  Color(red: 0.22, green: 0.25, blue: 0.35))
    static let textPrimary = Color(
        light: Color(red: 0.11, green: 0.13, blue: 0.20),
        dark:  Color(red: 0.79, green: 0.84, blue: 0.95))
    static let textSecondary = Color(
        light: Color(red: 0.38, green: 0.43, blue: 0.54),
        dark:  Color(red: 0.55, green: 0.61, blue: 0.78))
    /// Driven by the selected `AppTheme` so a theme switch recolors the whole
    /// app. Computed (not a stored constant) so every `body` re-render — which
    /// the App triggers on change — picks up the new accent.
    static var accent: Color { AppTheme.current.accent }
    static let success = Color(
        light: Color(red: 0.24, green: 0.58, blue: 0.20),
        dark:  Color(red: 0.62, green: 0.84, blue: 0.46))
    static let warning = Color(
        light: Color(red: 0.72, green: 0.50, blue: 0.08),
        dark:  Color(red: 0.94, green: 0.78, blue: 0.50))
    static let danger = Color(
        light: Color(red: 0.81, green: 0.22, blue: 0.26),
        dark:  Color(red: 0.95, green: 0.50, blue: 0.54))
    static let purple = Color(
        light: Color(red: 0.47, green: 0.31, blue: 0.80),
        dark:  Color(red: 0.74, green: 0.58, blue: 0.98))
    static let cyan = Color(
        light: Color(red: 0.08, green: 0.52, blue: 0.60),
        dark:  Color(red: 0.49, green: 0.85, blue: 0.91))

    /// Text/glyph color that sits on top of an `accent`-filled surface (e.g. a
    /// primary button). Resolves to a legible contrast in each appearance.
    static let onAccent = Color(
        light: .white,
        dark:  Color(red: 0.07, green: 0.08, blue: 0.13))

    /// Hairline color for dividers and 0.5pt strokes — adapts so separators
    /// stay visible in light mode (a `.white` hairline would vanish on white).
    static let hairline = Color(
        light: Color(red: 0.00, green: 0.00, blue: 0.00).opacity(0.10),
        dark:  Color(red: 1.00, green: 1.00, blue: 1.00).opacity(0.10))

    static func stateColor(_ state: String) -> Color {
        switch state.uppercased() {
        case "R", "RUNNING":         return success
        case "PD", "PENDING":        return warning
        case "CG", "COMPLETING":     return cyan
        case "CD", "COMPLETED":      return textSecondary
        case "F", "FAILED",
             "CA", "CANCELLED",
             "TO", "TIMEOUT",
             "NF", "NODE_FAIL":      return danger
        case "S", "SUSPENDED":       return purple
        default:                     return textSecondary
        }
    }

    /// Distinct, theme-neutral hues for QoS pills — chosen to read in both
    /// light and dark and to stay clear of the status palette (so a QoS never
    /// looks like a "failed" badge).
    private static let qosPalette: [Color] = [
        Color(light: Color(red: 0.47, green: 0.31, blue: 0.80),  // violet
              dark:  Color(red: 0.74, green: 0.58, blue: 0.98)),
        Color(light: Color(red: 0.08, green: 0.52, blue: 0.60),  // teal
              dark:  Color(red: 0.49, green: 0.85, blue: 0.91)),
        Color(light: Color(red: 0.72, green: 0.45, blue: 0.05),  // amber
              dark:  Color(red: 0.95, green: 0.76, blue: 0.40)),
        Color(light: Color(red: 0.16, green: 0.50, blue: 0.78),  // azure
              dark:  Color(red: 0.52, green: 0.74, blue: 1.00)),
        Color(light: Color(red: 0.78, green: 0.24, blue: 0.52),  // magenta
              dark:  Color(red: 1.00, green: 0.58, blue: 0.80)),
        Color(light: Color(red: 0.27, green: 0.55, blue: 0.30),  // green
              dark:  Color(red: 0.60, green: 0.86, blue: 0.62)),
        Color(light: Color(red: 0.80, green: 0.40, blue: 0.16),  // orange
              dark:  Color(red: 0.98, green: 0.66, blue: 0.42)),
        Color(light: Color(red: 0.34, green: 0.34, blue: 0.74),  // indigo
              dark:  Color(red: 0.66, green: 0.66, blue: 1.00)),
        Color(light: Color(red: 0.56, green: 0.42, blue: 0.28),  // brown
              dark:  Color(red: 0.82, green: 0.68, blue: 0.50)),
        Color(light: Color(red: 0.30, green: 0.44, blue: 0.52),  // slate
              dark:  Color(red: 0.62, green: 0.76, blue: 0.86)),
    ]

    /// Stable per-QoS color so each QoS name always maps to the same hue across
    /// launches (uses a deterministic djb2 hash, NOT Swift's per-process
    /// randomized `hashValue`).
    static func qosColor(_ qos: String) -> Color {
        let key = qos.lowercased().trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return textSecondary }
        var hash: UInt64 = 5381
        for scalar in key.unicodeScalars {
            hash = (hash &* 33) &+ UInt64(scalar.value)
        }
        return qosPalette[Int(hash % UInt64(qosPalette.count))]
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

    // GPU-allocation overlay colors (mirrors slurm-tui's "earth tones"
    // palette so users see the same coding across both clients). Slightly
    // deepened in light mode so the segments read on a white surface.
    static let ownNonPreempt = Color(
        light: Color(red: 0.45, green: 0.58, blue: 0.36),
        dark:  Color(red: 0.64, green: 0.75, blue: 0.55)) // sage green
    static let ownPreempt = Color(
        light: Color(red: 0.58, green: 0.72, blue: 0.42),
        dark:  Color(red: 0.76, green: 0.86, blue: 0.60)) // light beige-green
    // "Not mine" == occupied by others → red, so a glance reads "belegt".
    // Two shades mirror the own greens: strong red = non-preemptible, lighter
    // red = preemptible (others' jobs you could in principle preempt).
    static let otherNonPreempt = Color(
        light: Color(red: 0.80, green: 0.27, blue: 0.24),
        dark:  Color(red: 0.86, green: 0.40, blue: 0.36)) // strong red
    static let otherPreempt = Color(
        light: Color(red: 0.89, green: 0.50, blue: 0.46),
        dark:  Color(red: 0.90, green: 0.58, blue: 0.53)) // light red
    // Free / available GPUs — a calm neutral so the empty part of the bar reads
    // as "verfügbar" without competing with the green (mine) / red (others) tones.
    static let gpuFree = Color(
        light: Color(red: 0.71, green: 0.75, blue: 0.82),
        dark:  Color(red: 0.32, green: 0.36, blue: 0.42)) // slate gray
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
