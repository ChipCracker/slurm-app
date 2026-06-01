import SwiftUI

enum Theme {
    static let background      = Color(red: 0.10, green: 0.11, blue: 0.16)
    static let surface         = Color(red: 0.14, green: 0.15, blue: 0.22)
    static let surfaceElevated = Color(red: 0.17, green: 0.19, blue: 0.27)
    static let border          = Color(red: 0.22, green: 0.25, blue: 0.35)
    static let textPrimary     = Color(red: 0.79, green: 0.84, blue: 0.95)
    static let textSecondary   = Color(red: 0.55, green: 0.61, blue: 0.78)
    static let accent          = Color(red: 0.49, green: 0.65, blue: 1.00)
    static let success         = Color(red: 0.62, green: 0.84, blue: 0.46)
    static let warning         = Color(red: 0.94, green: 0.78, blue: 0.50)
    static let danger          = Color(red: 0.95, green: 0.50, blue: 0.54)
    static let purple          = Color(red: 0.74, green: 0.58, blue: 0.98)
    static let cyan            = Color(red: 0.49, green: 0.85, blue: 0.91)

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

    static func utilizationColor(_ ratio: Double) -> Color {
        switch ratio {
        case ..<0.5:  return success
        case ..<0.85: return warning
        default:      return danger
        }
    }

    // GPU-allocation overlay colors (mirrors slurm-tui's "earth tones"
    // palette so users see the same coding across both clients).
    static let ownNonPreempt   = Color(red: 0.64, green: 0.75, blue: 0.55) // sage green
    static let ownPreempt      = Color(red: 0.85, green: 0.78, blue: 0.61) // warm cream
    static let otherNonPreempt = Color(red: 0.79, green: 0.48, blue: 0.43) // muted coral
    static let otherPreempt    = Color(red: 0.61, green: 0.54, blue: 0.64) // dusty mauve
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
