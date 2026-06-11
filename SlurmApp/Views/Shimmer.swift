import SwiftUI

/// Subtle horizontal sheen that loops across the view. Combined with
/// `.redacted(reason: .placeholder)`, it gives the standard SwiftUI
/// skeleton-loading look.
struct ShimmerModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceMotion {
            // "Bewegung reduzieren": keine endlos laufende Sheen-Schleife —
            // die statische Redaction der Aufrufseite reicht als Skeleton.
            content
        } else {
            content
                .overlay(
                    GeometryReader { geo in
                        let w = geo.size.width
                        LinearGradient(
                            gradient: Gradient(stops: [
                                .init(color: .white.opacity(0),    location: 0.0),
                                .init(color: .white.opacity(0.06), location: 0.45),
                                .init(color: .white.opacity(0.14), location: 0.5),
                                .init(color: .white.opacity(0.06), location: 0.55),
                                .init(color: .white.opacity(0),    location: 1.0),
                            ]),
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: w * 1.5)
                        .offset(x: phase * w)
                        .blendMode(.plusLighter)
                        .allowsHitTesting(false)
                    }
                    .mask(content)
                )
                .onAppear {
                    withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                        phase = 1.6
                    }
                }
        }
    }
}

extension View {
    /// Apply this *together* with `.redacted(reason: .placeholder)` for the
    /// canonical skeleton-loading look.
    func shimmering(_ enabled: Bool = true) -> some View {
        Group {
            if enabled { self.modifier(ShimmerModifier()) } else { self }
        }
    }
}
