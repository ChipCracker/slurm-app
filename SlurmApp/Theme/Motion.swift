import SwiftUI

/// Shared animation tokens + reduce-motion-aware helpers. All app animations go
/// through these so "Bewegung reduzieren" (Accessibility) is honoured in one
/// place and the timing stays consistent.
enum Motion {
    /// Springy, for state changes / value glides.
    static let spring  = Animation.spring(duration: 0.45, bounce: 0.22)
    /// Smooth, for opacity / colour / subtle moves.
    static let smooth  = Animation.smooth(duration: 0.35)
    /// Quick, for taps / toggles.
    static let snappy  = Animation.snappy(duration: 0.22)
}

extension View {
    /// Apply an animation keyed on `value`, but skip it entirely when the user
    /// has Reduce Motion enabled (the change still applies, just without motion).
    func motion<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(MotionModifier(animation: animation, value: value))
    }
}

private struct MotionModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: V
    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

/// A small status dot that gently "breathes" while a condition holds (e.g. while
/// connecting). Static when calm or when Reduce Motion is on. Reusable across the
/// footer / settings / connection screens.
struct BreathingDot: View {
    let color: Color
    var active: Bool = false
    var size: CGFloat = 10
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .scaleEffect(active && pulse && !reduceMotion ? 1.18 : 1.0)
            .opacity(active && pulse && !reduceMotion ? 0.65 : 1.0)
            .overlay(
                Circle()
                    .stroke(color.opacity(active && !reduceMotion ? 0.0 : 0.0), lineWidth: 0)
            )
            .animation(active && !reduceMotion
                       ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                       : .default,
                       value: pulse)
            .onAppear { if active { pulse = true } }
            .onChange(of: active) { _, now in pulse = now }
    }
}
