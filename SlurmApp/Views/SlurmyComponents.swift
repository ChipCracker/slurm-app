import SwiftUI

/// Abstracted Slurmy: a row of rounded "node" squares (the caterpillar's
/// segments) that glow in a travelling cyan wave — the brand's loading
/// indicator. On macOS 26+/iOS 26 the segments are native Liquid-Glass shapes
/// in a `GlassEffectContainer`: the wave lifts each segment slightly
/// (inchworm arch) and drifts neighbours close enough that the glass merges —
/// the "slurp". On macOS 14–15 it falls back to the classic flat squircle
/// wave. Driven by `TimelineView(.animation)` so it stays smooth without a
/// manual animation loop and pauses when off-screen. Honours "Bewegung
/// reduzieren": static lit segments, no crawl.
struct SlurmyLoadingView: View {
    var nodeSize: CGFloat = 14
    var count: Int = 5
    /// Lit-node color. Defaults to the brand cyan glow.
    var tint: Color = Color(red: 0.62, green: 0.88, blue: 1.0)
    var idle: Color = Theme.textSecondary

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                caterpillar(at: nil)
            } else {
                TimelineView(.animation) { timeline in
                    caterpillar(at: timeline.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .accessibilityLabel("Lädt")
    }

    /// Ein Frame der Raupe. `t == nil` → statische Pose (Reduce Motion).
    @ViewBuilder
    private func caterpillar(at t: Double?) -> some View {
        if #available(macOS 26.0, *) {
            glassCaterpillar(at: t)
        } else {
            legacyWave(at: t)
        }
    }

    /// Glow-Gewicht 0…1 für Segment `i`. Ohne Zeit (`t == nil`) ein statischer
    /// Verlauf, der zum Kopf hin heller wird — lesbar auch ohne Bewegung.
    private func weight(_ i: Int, at t: Double?) -> Double {
        guard let t else {
            guard count > 1 else { return 0.7 }
            return 0.25 + 0.55 * Double(i) / Double(count - 1)
        }
        let raw = (sin(t * 3.0 - Double(i) * 0.9) + 1) / 2   // 0…1
        return pow(raw, 3)                                   // sharpen the pulse
    }

    // MARK: Legacy (macOS 14–15) — der bisherige flache Squircle-Wave.

    private func legacyWave(at t: Double?) -> some View {
        HStack(spacing: nodeSize * 0.5) {
            ForEach(0..<count, id: \.self) { i in
                let w = weight(i, at: t)
                RoundedRectangle(cornerRadius: nodeSize * 0.32, style: .continuous)
                    .fill(idle.opacity(0.22).blend(tint, w))
                    .frame(width: nodeSize, height: nodeSize)
                    .scaleEffect(0.82 + 0.30 * w)
                    .shadow(color: tint.opacity(w * 0.85), radius: w * nodeSize * 0.6)
            }
        }
    }

    // MARK: Liquid Glass (macOS 26+/iOS 26)

    /// Liquid-Glass-Raupe: jedes Segment ist eine echte Glasform; beim
    /// Krabbeln driften Nachbarn nah genug zusammen, dass der Container das
    /// Glas verschmelzen lässt. Maximal 8 Glasformen, keine extra Timer.
    @available(macOS 26.0, *)
    private func glassCaterpillar(at t: Double?) -> some View {
        let n = min(count, 8)
        return GlassEffectContainer(spacing: nodeSize * 0.5) {
            HStack(spacing: nodeSize * 0.5) {
                ForEach(0..<n, id: \.self) { i in
                    glassSegment(i, of: n, at: t)
                }
            }
        }
        // Platz für Hebung + Antennen, damit in engen Layouts nichts abschneidet.
        .padding(.top, nodeSize)
    }

    @available(macOS 26.0, *)
    private func glassSegment(_ i: Int, of n: Int, at t: Double?) -> some View {
        let w = weight(i, at: t)
        let isHead = i == n - 1
        let size = nodeSize * (isHead ? 1.14 : 1.0)
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        // Glas-Tönung: ruhig fast neutral, im Wellenkamm hell Zyan.
        let glow = idle.opacity(0.28).blend(tint.opacity(0.9), w)
        // Inchworm-Krabbeln: im Wellenkamm hebt sich das Segment leicht an und
        // driftet horizontal — Nachbarsegmente stauchen sich, das Glas fließt
        // ineinander. Statisch (Reduce Motion) bleibt alles in Reihe.
        var lift: CGFloat = 0
        var drift: CGFloat = 0
        if let t {
            lift = -nodeSize * 0.42 * CGFloat(w)
            drift = nodeSize * 0.20 * CGFloat(cos(t * 3.0 - Double(i) * 0.9))
        }

        return Color.clear
            .frame(width: size, height: size)
            .glassEffect(.regular.tint(glow), in: shape)
            .overlay(alignment: .top) {
                if isHead { antennae(w) }
            }
            .scaleEffect(0.92 + 0.16 * w)
            .offset(x: drift, y: lift)
            .shadow(color: tint.opacity(0.25 + 0.6 * w), radius: nodeSize * (0.15 + 0.45 * w))
    }

    /// Zwei winzige leuchtende Fühler-Punkte über dem Kopfsegment.
    private func antennae(_ w: Double) -> some View {
        HStack(spacing: nodeSize * 0.30) {
            antennaDot
            antennaDot
        }
        .offset(y: -nodeSize * 0.34)
        .opacity(0.45 + 0.55 * w)
    }

    private var antennaDot: some View {
        Circle()
            .fill(tint)
            .frame(width: nodeSize * 0.16, height: nodeSize * 0.16)
            .shadow(color: tint.opacity(0.9), radius: nodeSize * 0.12)
    }
}

/// Centered loader with an optional caption — drop-in for "connecting…" /
/// "loading jobs…" states.
struct SlurmyLoadingState: View {
    var caption: String? = nil
    var body: some View {
        VStack(spacing: 16) {
            SlurmyLoadingView(nodeSize: 18, count: 6)
            if let caption {
                Text(caption)
                    .font(.callout)
                    .foregroundColor(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Friendly empty / disconnected state featuring the Slurmy mascot.
struct SlurmyEmptyState: View {
    let title: String
    var message: String? = nil
    var mascotWidth: CGFloat = 200
    /// Optional call-to-action.
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            Image("SlurmyMascot")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: mascotWidth)
                .shadow(color: Color(red: 0.16, green: 0.45, blue: 0.92).opacity(0.35),
                        radius: 24, y: 6)
            Text(title)
                .font(.title3.bold())
                .foregroundColor(Theme.textPrimary)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.callout.bold())
                        .padding(.horizontal, 18).padding(.vertical, 9)
                        .background(Theme.accent)
                        .foregroundColor(Theme.onAccent)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: 380)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

private extension Color {
    /// Linear blend toward `other` by `t` (0…1). Used so a node fades from the
    /// idle tone up to the lit cyan as the wave passes.
    func blend(_ other: Color, _ t: Double) -> Color {
        let a = resolvedRGBA(); let b = other.resolvedRGBA()
        let f = max(0, min(1, t))
        return Color(
            red:   a.r + (b.r - a.r) * f,
            green: a.g + (b.g - a.g) * f,
            blue:  a.b + (b.b - a.b) * f,
            opacity: a.a + (b.a - a.a) * f
        )
    }

    func resolvedRGBA() -> (r: Double, g: Double, b: Double, a: Double) {
        #if os(macOS)
        let n = NSColor(self).usingColorSpace(.sRGB) ?? .clear
        return (Double(n.redComponent), Double(n.greenComponent), Double(n.blueComponent), Double(n.alphaComponent))
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b), Double(a))
        #endif
    }
}

#Preview("Loader") {
    VStack(spacing: 40) {
        SlurmyLoadingView()
        SlurmyLoadingState(caption: "Verbinde mit Cluster…")
        SlurmyEmptyState(title: "Keine Jobs",
                         message: "Alles ruhig im Cluster.",
                         actionTitle: "Aktualisieren") {}
    }
    .padding()
    .frame(width: 420, height: 700)
    .background(Theme.background)
}
