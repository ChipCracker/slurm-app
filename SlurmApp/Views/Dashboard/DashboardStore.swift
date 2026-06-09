import SwiftUI

/// Hält das aktive Dashboard-Layout für den Jobs-Screen und persistiert es als
/// JSON in `UserDefaults`. Mutationen validieren das Raster (Clamping + Overlap)
/// zentral, damit die View dumm bleiben kann.
@MainActor
final class DashboardStore: ObservableObject {
    @Published private(set) var layout: DashboardLayout
    /// Name des aktiven Presets oder „Eigenes" nach manueller Änderung.
    @Published private(set) var presetName: String

    static let customName = "Eigenes"
    private static let layoutKey = "jobsDashboardLayout"
    private static let presetKey = "jobsDashboardPreset"

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.layoutKey),
           let decoded = try? JSONDecoder().decode(DashboardLayout.self, from: data),
           !decoded.placements.isEmpty {
            layout = decoded
        } else {
            layout = DashboardPreset.classic.layout
        }
        presetName = defaults.string(forKey: Self.presetKey) ?? DashboardPreset.classic.label
    }

    // MARK: – Presets

    func apply(_ preset: DashboardPreset) {
        layout = preset.layout
        presetName = preset.label
        persist()
    }

    func reset() { apply(.classic) }

    // MARK: – Editor-Mutationen

    /// Versucht, ein Widget auf einen neuen Rahmen zu setzen. Clamped ins Raster
    /// und lehnt Überlappungen ab (Rückgabe `false` → View animiert zurück).
    @discardableResult
    func update(_ widget: DashboardWidget, to frame: WidgetFrame) -> Bool {
        guard let idx = layout.placements.firstIndex(where: { $0.widget == widget }) else { return false }
        var f = frame
        let minSpan = widget.minSpan

        // Größe ins Raster zwingen.
        f.w = max(minSpan.w, min(f.w, layout.columns))
        f.h = max(minSpan.h, f.h)
        // Position clampen.
        f.x = max(0, min(f.x, layout.columns - f.w))
        f.y = max(0, f.y)

        // Overlap gegen alle anderen prüfen.
        let collides = layout.placements.contains { $0.widget != widget && $0.frame.intersects(f) }
        if collides { return false }

        guard f != layout.placements[idx].frame else { return true }
        layout.placements[idx].frame = f
        markCustom()
        persist()
        return true
    }

    /// Blendet ein Widget aus dem Layout aus.
    func hide(_ widget: DashboardWidget) {
        layout.placements.removeAll { $0.widget == widget }
        markCustom()
        persist()
    }

    /// Fügt ein verstecktes Widget wieder ein — sucht die erste freie Stelle.
    func show(_ widget: DashboardWidget) {
        guard layout.placement(for: widget) == nil else { return }
        let span = widget.minSpan
        let frame = firstFreeSlot(w: max(2, span.w), h: max(2, span.h))
        layout.placements.append(.init(widget: widget, frame: frame))
        markCustom()
        persist()
    }

    func toggle(_ widget: DashboardWidget) {
        if layout.placement(for: widget) == nil { show(widget) } else { hide(widget) }
    }

    // MARK: – Intern

    private func markCustom() {
        if presetName != Self.customName { presetName = Self.customName }
    }

    /// Erste rasterfreie Position (zeilenweise von oben), die `w×h` aufnimmt.
    private func firstFreeSlot(w: Int, h: Int) -> WidgetFrame {
        let cols = layout.columns
        let width = min(w, cols)
        var y = 0
        while y < 256 { // harte Obergrenze
            for x in 0...(cols - width) {
                let candidate = WidgetFrame(x: x, y: y, w: width, h: h)
                if !layout.placements.contains(where: { $0.frame.intersects(candidate) }) {
                    return candidate
                }
            }
            y += 1
        }
        return WidgetFrame(x: 0, y: layout.rows, w: width, h: h)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(layout) {
            UserDefaults.standard.set(data, forKey: Self.layoutKey)
        }
        UserDefaults.standard.set(presetName, forKey: Self.presetKey)
    }
}
