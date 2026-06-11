import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// User-overridable colour slots. Layered ON TOP of the predefined theme:
/// resolution is `override ?? theme ?? builtin`, so "reset" returns to the
/// active theme's colour, not a hardcoded one. RawValue = JSON key.
enum ThemeSlot: String, CaseIterable, Codable, Identifiable {
    case accent
    case stateRunning, statePending, stateCompleting
    case stateCompleted, stateFailed, stateSuspended

    var id: String { rawValue }

    var label: String {
        switch self {
        case .accent:          return "Akzentfarbe"
        case .stateRunning:    return "Running"
        case .statePending:    return "Pending"
        case .stateCompleting: return "Completing"
        case .stateCompleted:  return "Completed"
        case .stateFailed:     return "Failed / Cancelled"
        case .stateSuspended:  return "Suspended"
        }
    }

    /// Default without an override — references the (theme-driven) Theme statics,
    /// so reset follows the active theme.
    var builtinDefault: Color {
        switch self {
        case .accent:          return AppTheme.current.accent
        case .stateRunning:    return Theme.success
        case .statePending:    return Theme.warning
        case .stateCompleting: return Theme.cyan
        case .stateCompleted:  return Theme.textSecondary
        case .stateFailed:     return Theme.danger
        case .stateSuspended:  return Theme.purple
        }
    }

    /// Same mapping as `Theme.stateColor` — single source for state → slot.
    static func forJobState(_ state: String) -> ThemeSlot? {
        switch state.uppercased() {
        case "R", "RUNNING":         return .stateRunning
        case "PD", "PENDING":        return .statePending
        case "CG", "COMPLETING":     return .stateCompleting
        case "CD", "COMPLETED":      return .stateCompleted
        case "F", "FAILED", "CA", "CANCELLED",
             "TO", "TIMEOUT", "NF", "NODE_FAIL": return .stateFailed
        case "S", "SUSPENDED":       return .stateSuspended
        default:                      return nil
        }
    }
}

/// A colour as extended-sRGB components. `Color` is not Codable; hex strings
/// would clip Display-P3 picks to 8-bit sRGB. Extended sRGB allows components
/// outside 0…1 and round-trips P3 losslessly.
struct CodableColor: Codable, Equatable {
    var r: Double, g: Double, b: Double, a: Double
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }

    init(_ color: Color, dark: Bool) {
        let c = color.rgbaComponents(dark: dark)
        self.init(r: c.r, g: c.g, b: c.b, a: c.a)
    }
    init(r: Double, g: Double, b: Double, a: Double) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }
}

/// Light + dark variant of a slot — matches the app's `Color(light:dark:)`.
struct AdaptiveColorValue: Codable, Equatable {
    var light: CodableColor
    var dark: CodableColor
    var color: Color { Color(light: light.color, dark: dark.color) }
}

/// The persisted blob — ONE UserDefaults key (keeps a future iCloud-KVS sync
/// trivial: one key, last-writer-wins via `updatedAt`).
struct ThemeOverridePalette: Codable, Equatable {
    var version: Int = 1
    var updatedAt: Date = Date()
    /// Key = ThemeSlot.rawValue. Unknown keys (newer app) are carried through.
    var colors: [String: AdaptiveColorValue] = [:]
}

/// Main-thread-only (like `AppTheme.current`). Read from the static Theme funcs.
final class ThemeOverrideStore: ObservableObject {
    static let shared = ThemeOverrideStore()
    static let storageKey  = "themeOverridesV1"
    /// Incremented on every change; SlurmApp reads it via @AppStorage so the
    /// whole tree re-renders and the computed Theme statics pick up new values.
    static let revisionKey = "themeOverridesRevision"

    @Published private(set) var palette: ThemeOverridePalette

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let p = try? JSONDecoder().decode(ThemeOverridePalette.self, from: data) {
            palette = p
        } else {
            palette = ThemeOverridePalette()
        }
    }

    var hasOverrides: Bool { !palette.colors.isEmpty }

    /// Fast synchronous lookup — read from Theme.accent/stateColor in every body,
    /// so only a dictionary access, no JSON decode in the hot path.
    func color(for slot: ThemeSlot) -> Color? { palette.colors[slot.rawValue]?.color }
    func value(for slot: ThemeSlot) -> AdaptiveColorValue? { palette.colors[slot.rawValue] }
    func hasOverride(_ slot: ThemeSlot) -> Bool { palette.colors[slot.rawValue] != nil }

    func set(_ value: AdaptiveColorValue?, for slot: ThemeSlot) {
        if let value { palette.colors[slot.rawValue] = value }
        else         { palette.colors.removeValue(forKey: slot.rawValue) }
        persist()
    }

    func reset(_ slot: ThemeSlot) { set(nil, for: slot) }

    func resetAll() {
        palette.colors.removeAll()
        persist()
    }

    private func persist() {
        palette.updatedAt = Date()
        if let data = try? JSONEncoder().encode(palette) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
        let d = UserDefaults.standard
        d.set(d.integer(forKey: Self.revisionKey) + 1, forKey: Self.revisionKey)
    }
}

extension Color {
    /// Resolve for light/dark and return extended-sRGB components. Works for
    /// dynamic `Color(light:dark:)` values and for flat picker colours in any
    /// colour space (P3, grayscale, …).
    func rgbaComponents(dark: Bool) -> (r: Double, g: Double, b: Double, a: Double) {
        #if os(macOS)
        let base = NSColor(self)
        var resolved: NSColor?
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            resolved = base.usingColorSpace(.extendedSRGB)
        }
        guard let c = resolved else { return (0, 0, 0, 1) }
        return (Double(c.redComponent), Double(c.greenComponent),
                Double(c.blueComponent), Double(c.alphaComponent))
        #else
        let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        let ui = UIColor(self).resolvedColor(with: traits)
        guard let space = CGColorSpace(name: CGColorSpace.extendedSRGB),
              let cg = ui.cgColor.converted(to: space, intent: .defaultIntent, options: nil),
              let comps = cg.components, comps.count >= 3 else { return (0, 0, 0, 1) }
        return (Double(comps[0]), Double(comps[1]), Double(comps[2]), Double(cg.alpha))
        #endif
    }
}

/// WCAG contrast helper — warns when a chosen colour is unreadable on the glass
/// surface. Advisory only (never blocks the user's choice).
enum ContrastGuard {
    static func relativeLuminance(r: Double, g: Double, b: Double) -> Double {
        func lin(_ c: Double) -> Double {
            let c = min(max(c, 0), 1)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    static func ratio(_ fg: Color, on bg: Color, dark: Bool) -> Double {
        let f = fg.rgbaComponents(dark: dark)
        let b = bg.rgbaComponents(dark: dark)
        let lf = relativeLuminance(r: f.r, g: f.g, b: f.b)
        let lb = relativeLuminance(r: b.r, g: b.g, b: b.b)
        let (hi, lo) = lf >= lb ? (lf, lb) : (lb, lf)
        return (hi + 0.05) / (lo + 0.05)
    }

    /// nil = fine; otherwise a German warning. Checks both surface and
    /// background (the glass material blends over the background), in both
    /// appearances; threshold 3.0 (WCAG for UI components / large text).
    static func warning(for color: Color) -> String? {
        var worst = Double.greatestFiniteMagnitude
        for dark in [false, true] {
            worst = min(worst, ratio(color, on: Theme.surface, dark: dark))
            worst = min(worst, ratio(color, on: Theme.background, dark: dark))
        }
        return worst < 3.0
            ? "Niedriger Kontrast (\(String(format: "%.1f", worst)):1) – evtl. schwer lesbar."
            : nil
    }
}
