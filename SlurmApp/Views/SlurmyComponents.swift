import SwiftUI

/// Abstracted Slurmy: a row of rounded "node" squares (the caterpillar's
/// segments) that glow in a travelling cyan wave — the brand's loading
/// indicator. Driven by `TimelineView(.animation)` so it stays smooth without
/// a manual animation loop and pauses when off-screen.
struct SlurmyLoadingView: View {
    var nodeSize: CGFloat = 14
    var count: Int = 5
    /// Lit-node color. Defaults to the brand cyan glow.
    var tint: Color = Color(red: 0.62, green: 0.88, blue: 1.0)
    var idle: Color = Theme.textSecondary

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: nodeSize * 0.5) {
                ForEach(0..<count, id: \.self) { i in
                    let raw = (sin(t * 3.0 - Double(i) * 0.9) + 1) / 2   // 0…1
                    let w = pow(raw, 3)                                  // sharpen the pulse
                    RoundedRectangle(cornerRadius: nodeSize * 0.32, style: .continuous)
                        .fill(idle.opacity(0.22).blend(tint, w))
                        .frame(width: nodeSize, height: nodeSize)
                        .scaleEffect(0.82 + 0.30 * w)
                        .shadow(color: tint.opacity(w * 0.85), radius: w * nodeSize * 0.6)
                }
            }
        }
        .accessibilityLabel("Lädt")
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
