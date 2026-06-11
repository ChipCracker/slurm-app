import SwiftUI

/// Settings card: user-customizable accent + per-job-state colours, layered over
/// the active theme. Live preview, per-row reset, WCAG contrast warning, and a
/// debounced persist so dragging the colour wheel doesn't thrash the whole tree.
struct CustomColorsCard: View {
    @ObservedObject private var store = ThemeOverrideStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "eyedropper.halffull")
                    .font(.subheadline).foregroundColor(Theme.accent)
                Text("Eigene Farben").font(.headline).foregroundColor(Theme.textPrimary)
                Spacer()
                if store.hasOverrides {
                    Button("Alle zurücksetzen") { store.resetAll() }
                        .font(.caption.bold()).buttonStyle(.plain).foregroundColor(Theme.accent)
                }
            }

            ForEach(ThemeSlot.allCases) { slot in
                ColorSlotRow(slot: slot)
                if slot != ThemeSlot.allCases.last {
                    Divider().background(Theme.hairline)
                }
            }

            Text("Überschreibt Akzent und Statusfarben für das aktive Thema. „Zurücksetzen“ stellt die Themenfarbe wieder her. Hell und Dunkel sind getrennt einstellbar.")
                .font(.caption).foregroundColor(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

/// One overridable colour slot with separate light/dark pickers.
private struct ColorSlotRow: View {
    let slot: ThemeSlot
    @ObservedObject private var store = ThemeOverrideStore.shared
    @State private var light: Color
    @State private var dark: Color
    @State private var commitTask: Task<Void, Never>?

    init(slot: ThemeSlot) {
        self.slot = slot
        let existing = ThemeOverrideStore.shared.value(for: slot)
        _light = State(initialValue: existing?.light.color ?? slot.builtinDefault)
        _dark  = State(initialValue: existing?.dark.color ?? slot.builtinDefault)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                preview
                Text(slot.label).font(.callout).foregroundColor(Theme.textPrimary)
                Spacer()
                ColorPicker("", selection: $light, supportsOpacity: false)
                    .labelsHidden().help("Hell")
                ColorPicker("", selection: $dark, supportsOpacity: false)
                    .labelsHidden().help("Dunkel")
                if store.hasOverride(slot) {
                    Button {
                        light = slot.builtinDefault; dark = slot.builtinDefault
                        store.reset(slot)
                    } label: {
                        Image(systemName: "arrow.uturn.backward").font(.caption)
                    }
                    .buttonStyle(.plain).foregroundColor(Theme.textSecondary)
                    .help("Auf Themenfarbe zurücksetzen")
                }
            }
            if let w = ContrastGuard.warning(for: store.hasOverride(slot) ? slotColor : light) {
                Label(w, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundColor(Theme.warning)
            }
        }
        .onChange(of: light) { _, _ in scheduleCommit() }
        .onChange(of: dark)  { _, _ in scheduleCommit() }
    }

    private var slotColor: Color { store.color(for: slot) ?? slot.builtinDefault }

    /// Small live swatch: a state pill for state slots, an accent capsule for accent.
    @ViewBuilder private var preview: some View {
        let c = slotColor
        if slot == .accent {
            Capsule().fill(c).frame(width: 26, height: 14)
        } else {
            Circle().fill(c).frame(width: 14, height: 14)
                .overlay(Circle().stroke(c.opacity(0.4), lineWidth: 3).padding(-2))
        }
    }

    /// Persist after 150 ms of no change, so a colour-wheel drag (continuous
    /// updates) commits once instead of bumping the tree on every tick.
    private func scheduleCommit() {
        commitTask?.cancel()
        let l = light, d = dark
        commitTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return }
            let value = AdaptiveColorValue(
                light: CodableColor(l, dark: false),
                dark:  CodableColor(d, dark: true))
            store.set(value, for: slot)
        }
    }
}
