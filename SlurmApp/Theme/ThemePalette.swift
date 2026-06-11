import SwiftUI

extension Color {
    /// Hex constructor for compact palette definitions (0xRRGGBB).
    init(hex: UInt32) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8)  & 0xFF) / 255,
                  blue:  Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
    /// Light/dark hex pair — uses the existing `Color(light:dark:)` dynamic
    /// provider so every palette colour stays appearance-adaptive.
    init(lightHex: UInt32, darkHex: UInt32) {
        self.init(light: Color(hex: lightHex), dark: Color(hex: darkHex))
    }
}

/// A complete semantic colour palette. Every colour is light/dark-adaptive, so a
/// theme works in both appearances unless it forces one
/// (`AppColorTheme.forcedColorScheme`).
struct ThemePalette {
    var background: Color
    var surface: Color
    var surfaceElevated: Color
    var border: Color
    var textPrimary: Color
    var textSecondary: Color
    /// For the standard theme this is replaced by the user's accent choice
    /// (`AppTheme`); opinionated themes ship their own accent.
    var accent: Color
    var onAccent: Color
    var success: Color
    var warning: Color
    var danger: Color
    var purple: Color
    var cyan: Color
    var hairline: Color
    /// Distinct QoS hues — must stay clear of the danger/red palette so a QoS
    /// pill never reads like a "failed" badge.
    var qosPalette: [Color]
    // GPU-allocation overlay (slurm-tui "earth tones"): green = mine,
    // red = others, neutral = free. Keep these semantics in every theme.
    var ownNonPreempt: Color
    var ownPreempt: Color
    var otherNonPreempt: Color
    var otherPreempt: Color
    var gpuFree: Color
    /// Gradient behind `GlassPanel`. nil ⇒ derived from accent/purple/background
    /// (today's look); themes may override.
    var glassGradient: [Color]? = nil
}

extension ThemePalette {
    /// The 10 QoS hues shared by themes that don't override them. Verbatim from
    /// the original Theme.swift.
    static let standardQosPalette: [Color] = [
        Color(light: Color(red: 0.47, green: 0.31, blue: 0.80),  dark: Color(red: 0.74, green: 0.58, blue: 0.98)),
        Color(light: Color(red: 0.08, green: 0.52, blue: 0.60),  dark: Color(red: 0.49, green: 0.85, blue: 0.91)),
        Color(light: Color(red: 0.72, green: 0.45, blue: 0.05),  dark: Color(red: 0.95, green: 0.76, blue: 0.40)),
        Color(light: Color(red: 0.16, green: 0.50, blue: 0.78),  dark: Color(red: 0.52, green: 0.74, blue: 1.00)),
        Color(light: Color(red: 0.78, green: 0.24, blue: 0.52),  dark: Color(red: 1.00, green: 0.58, blue: 0.80)),
        Color(light: Color(red: 0.27, green: 0.55, blue: 0.30),  dark: Color(red: 0.60, green: 0.86, blue: 0.62)),
        Color(light: Color(red: 0.80, green: 0.40, blue: 0.16),  dark: Color(red: 0.98, green: 0.66, blue: 0.42)),
        Color(light: Color(red: 0.34, green: 0.34, blue: 0.74),  dark: Color(red: 0.66, green: 0.66, blue: 1.00)),
        Color(light: Color(red: 0.56, green: 0.42, blue: 0.28),  dark: Color(red: 0.82, green: 0.68, blue: 0.50)),
        Color(light: Color(red: 0.30, green: 0.44, blue: 0.52),  dark: Color(red: 0.62, green: 0.76, blue: 0.86)),
    ]

    /// Exactly today's values — so switching the standard theme on changes
    /// nothing visually.
    static let standard = ThemePalette(
        background:      Color(light: Color(red: 0.95, green: 0.96, blue: 0.98),  dark: Color(red: 0.10, green: 0.11, blue: 0.16)),
        surface:         Color(light: Color(red: 1.00, green: 1.00, blue: 1.00),  dark: Color(red: 0.14, green: 0.15, blue: 0.22)),
        surfaceElevated: Color(light: Color(red: 0.93, green: 0.95, blue: 0.98),  dark: Color(red: 0.17, green: 0.19, blue: 0.27)),
        border:          Color(light: Color(red: 0.84, green: 0.86, blue: 0.91),  dark: Color(red: 0.22, green: 0.25, blue: 0.35)),
        textPrimary:     Color(light: Color(red: 0.11, green: 0.13, blue: 0.20),  dark: Color(red: 0.79, green: 0.84, blue: 0.95)),
        textSecondary:   Color(light: Color(red: 0.38, green: 0.43, blue: 0.54),  dark: Color(red: 0.55, green: 0.61, blue: 0.78)),
        accent:          AppTheme.default.accent,
        onAccent:        Color(light: .white,                                     dark: Color(red: 0.07, green: 0.08, blue: 0.13)),
        success:         Color(light: Color(red: 0.24, green: 0.58, blue: 0.20),  dark: Color(red: 0.62, green: 0.84, blue: 0.46)),
        warning:         Color(light: Color(red: 0.72, green: 0.50, blue: 0.08),  dark: Color(red: 0.94, green: 0.78, blue: 0.50)),
        danger:          Color(light: Color(red: 0.81, green: 0.22, blue: 0.26),  dark: Color(red: 0.95, green: 0.50, blue: 0.54)),
        purple:          Color(light: Color(red: 0.47, green: 0.31, blue: 0.80),  dark: Color(red: 0.74, green: 0.58, blue: 0.98)),
        cyan:            Color(light: Color(red: 0.08, green: 0.52, blue: 0.60),  dark: Color(red: 0.49, green: 0.85, blue: 0.91)),
        hairline:        Color(light: Color.black.opacity(0.10),                  dark: Color.white.opacity(0.10)),
        qosPalette:      standardQosPalette,
        ownNonPreempt:   Color(light: Color(red: 0.45, green: 0.58, blue: 0.36),  dark: Color(red: 0.64, green: 0.75, blue: 0.55)),
        ownPreempt:      Color(light: Color(red: 0.58, green: 0.72, blue: 0.42),  dark: Color(red: 0.76, green: 0.86, blue: 0.60)),
        otherNonPreempt: Color(light: Color(red: 0.80, green: 0.27, blue: 0.24),  dark: Color(red: 0.86, green: 0.40, blue: 0.36)),
        otherPreempt:    Color(light: Color(red: 0.89, green: 0.50, blue: 0.46),  dark: Color(red: 0.90, green: 0.58, blue: 0.53)),
        gpuFree:         Color(light: Color(red: 0.71, green: 0.75, blue: 0.82),  dark: Color(red: 0.32, green: 0.36, blue: 0.42)))

    // MARK: – Opinionated palettes

    /// Nord (https://www.nordtheme.com) — cool polar blues. Dark uses Polar
    /// Night / Snow Storm; light uses Snow Storm with darker frost text.
    static let nord = ThemePalette(
        background:      Color(lightHex: 0xECEFF4, darkHex: 0x2E3440),
        surface:         Color(lightHex: 0xFFFFFF, darkHex: 0x3B4252),
        surfaceElevated: Color(lightHex: 0xE5E9F0, darkHex: 0x434C5E),
        border:          Color(lightHex: 0xD8DEE9, darkHex: 0x4C566A),
        textPrimary:     Color(lightHex: 0x2E3440, darkHex: 0xECEFF4),
        textSecondary:   Color(lightHex: 0x4C566A, darkHex: 0xD8DEE9),
        accent:          Color(lightHex: 0x5E81AC, darkHex: 0x88C0D0),
        onAccent:        Color(lightHex: 0xFFFFFF, darkHex: 0x2E3440),
        success:         Color(lightHex: 0x4F7A4F, darkHex: 0xA3BE8C),
        warning:         Color(lightHex: 0xB48A2E, darkHex: 0xEBCB8B),
        danger:          Color(lightHex: 0xBF616A, darkHex: 0xBF616A),
        purple:          Color(lightHex: 0x7D6B9E, darkHex: 0xB48EAD),
        cyan:            Color(lightHex: 0x3B7C86, darkHex: 0x8FBCBB),
        hairline:        Color(light: Color.black.opacity(0.08), dark: Color.white.opacity(0.10)),
        qosPalette: [
            Color(lightHex: 0x5E81AC, darkHex: 0x81A1C1), Color(lightHex: 0x3B7C86, darkHex: 0x8FBCBB),
            Color(lightHex: 0xB48A2E, darkHex: 0xEBCB8B), Color(lightHex: 0x7D6B9E, darkHex: 0xB48EAD),
            Color(lightHex: 0x4F7A4F, darkHex: 0xA3BE8C), Color(lightHex: 0xA85A4A, darkHex: 0xD08770),
            Color(lightHex: 0x4C7DA8, darkHex: 0x88C0D0), Color(lightHex: 0x6B7089, darkHex: 0x9aa3bd),
        ],
        ownNonPreempt:   Color(lightHex: 0x6E8F5E, darkHex: 0xA3BE8C),
        ownPreempt:      Color(lightHex: 0x8AA86F, darkHex: 0xB5CE9E),
        otherNonPreempt: Color(lightHex: 0xBF616A, darkHex: 0xBF616A),
        otherPreempt:    Color(lightHex: 0xD08770, darkHex: 0xD08770),
        gpuFree:         Color(lightHex: 0xCBD3E0, darkHex: 0x434C5E))

    /// Solarized (Ethan Schoonover). Distinctive low-contrast base tones.
    static let solarized = ThemePalette(
        background:      Color(lightHex: 0xFDF6E3, darkHex: 0x002B36),
        surface:         Color(lightHex: 0xFBF1D8, darkHex: 0x073642),
        surfaceElevated: Color(lightHex: 0xEEE8D5, darkHex: 0x0A4250),
        border:          Color(lightHex: 0xE4DCC4, darkHex: 0x0F4D5C),
        textPrimary:     Color(lightHex: 0x586E75, darkHex: 0x93A1A1),
        textSecondary:   Color(lightHex: 0x839496, darkHex: 0x657B83),
        accent:          Color(lightHex: 0x268BD2, darkHex: 0x268BD2),
        onAccent:        Color(lightHex: 0xFDF6E3, darkHex: 0x002B36),
        success:         Color(lightHex: 0x859900, darkHex: 0x859900),
        warning:         Color(lightHex: 0xB58900, darkHex: 0xB58900),
        danger:          Color(lightHex: 0xDC322F, darkHex: 0xDC322F),
        purple:          Color(lightHex: 0x6C71C4, darkHex: 0x6C71C4),
        cyan:            Color(lightHex: 0x2AA198, darkHex: 0x2AA198),
        hairline:        Color(light: Color.black.opacity(0.08), dark: Color.white.opacity(0.08)),
        qosPalette: [
            Color(hex: 0x6C71C4), Color(hex: 0x2AA198), Color(hex: 0xB58900), Color(hex: 0x268BD2),
            Color(hex: 0xD33682), Color(hex: 0x859900), Color(hex: 0xCB4B16), Color(hex: 0x839496),
        ],
        ownNonPreempt:   Color(hex: 0x859900),
        ownPreempt:      Color(lightHex: 0x9BB300, darkHex: 0x9BB300),
        otherNonPreempt: Color(hex: 0xDC322F),
        otherPreempt:    Color(hex: 0xCB4B16),
        gpuFree:         Color(lightHex: 0xD7CFB8, darkHex: 0x0A3A46))

    /// Terminal Green — monochrome phosphor look. Forces dark mode.
    static let terminalGreen = ThemePalette(
        background:      Color(hex: 0x021008),
        surface:         Color(hex: 0x07210F),
        surfaceElevated: Color(hex: 0x0B3016),
        border:          Color(hex: 0x14502A),
        textPrimary:     Color(hex: 0x4AF07A),
        textSecondary:   Color(hex: 0x2E9E55),
        accent:          Color(hex: 0x39FF6A),
        onAccent:        Color(hex: 0x021008),
        success:         Color(hex: 0x39FF6A),
        warning:         Color(hex: 0xC8E04A),
        danger:          Color(hex: 0xFF6B6B),
        purple:          Color(hex: 0x6FE0A0),
        cyan:            Color(hex: 0x4FE0C0),
        hairline:        Color.green.opacity(0.18),
        qosPalette: [
            Color(hex: 0x39FF6A), Color(hex: 0x4FE0C0), Color(hex: 0xC8E04A), Color(hex: 0x6FE0A0),
            Color(hex: 0x2EC95E), Color(hex: 0x8AE070), Color(hex: 0x5AD0A0), Color(hex: 0x9AE060),
        ],
        ownNonPreempt:   Color(hex: 0x2EA85A),
        ownPreempt:      Color(hex: 0x49C97A),
        otherNonPreempt: Color(hex: 0xC0402E),
        otherPreempt:    Color(hex: 0xC86B4A),
        gpuFree:         Color(hex: 0x123A20),
        glassGradient: [Color(hex: 0x39FF6A).opacity(0.14), Color(hex: 0x0B3016).opacity(0.5), Color(hex: 0x021008).opacity(0.6)])
}

/// Full colour theme, persisted via `@AppStorage("colorTheme")`. Orthogonal to
/// the appearance ("appearance") and — for the standard theme — the accent
/// ("accentTheme").
enum AppColorTheme: String, CaseIterable, Identifiable {
    case standard, nord, solarized, terminalGreen

    static let storageKey = "colorTheme"
    static let `default`: AppColorTheme = .standard

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard:      return "Slurmy"
        case .nord:          return "Nord"
        case .solarized:     return "Solarized"
        case .terminalGreen: return "Terminal"
        }
    }

    /// Themes with a single sensible appearance force it (and the appearance
    /// picker is then disabled in Settings).
    var forcedColorScheme: ColorScheme? {
        self == .terminalGreen ? .dark : nil
    }

    /// Only the standard theme honours the free accent choice (`AppTheme`);
    /// opinionated palettes bring their own accent.
    var allowsAccentOverride: Bool { self == .standard }

    var palette: ThemePalette {
        switch self {
        case .standard:      return .standard
        case .nord:          return .nord
        case .solarized:     return .solarized
        case .terminalGreen: return .terminalGreen
        }
    }

    /// Same mechanism as `AppTheme.current` — a per-access UserDefaults read,
    /// which Foundation caches in memory (cheap).
    static var current: AppColorTheme {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? `default`.rawValue
        return AppColorTheme(rawValue: raw) ?? `default`
    }
}
