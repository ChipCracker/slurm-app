import SwiftUI

/// Generischer Grid-Snap-Container. Positioniert jedes Widget des `store`-Layouts
/// in einem Spaltenraster; im `editing`-Modus liefert er Drag- (verschieben) und
/// Eck-Griff-Gesten (Größe), die in ganze Zellen einrasten. Der konkrete Inhalt
/// jedes Widgets wird per `content` injiziert — die Engine kennt keine Slurm-Views.
struct DashboardGridView<Content: View>: View {
    @ObservedObject var store: DashboardStore
    var editing: Bool
    /// Höhe einer Rasterzeile in Punkten.
    var rowHeight: CGFloat = 168
    var spacing: CGFloat = 10
    @ViewBuilder var content: (DashboardWidget) -> Content

    var body: some View {
        GeometryReader { geo in
            let cols = store.layout.columns
            let rows = store.layout.rows
            let cellW = max(1, (geo.size.width - spacing * CGFloat(cols - 1)) / CGFloat(cols))
            // Ansichtsmodus: Zeilenhöhe so skalieren, dass das Raster den
            // Viewport EXAKT füllt — nie außen scrollen; zu kleine Widgets
            // scrollen in sich (ihre Inhalte bringen eigene ScrollViews mit).
            // Unter 96 pt pro Zeile wird Inhalt unbedienbar, dann greift doch
            // der äußere Scroll als Notausgang. Im Edit-Modus feste Höhe,
            // damit Platz zum Ziehen/Vergrößern bleibt.
            let fitRowH = (geo.size.height - spacing * CGFloat(rows - 1)) / CGFloat(max(1, rows))
            let rowH = editing ? rowHeight : max(96, fitRowH)
            let canvasH = CGFloat(rows) * (rowH + spacing) - spacing

            ScrollView(.vertical) {
                ZStack(alignment: .topLeading) {
                    if editing {
                        GridBackdrop(columns: cols, rows: rows,
                                     cellW: cellW, rowH: rowH, spacing: spacing)
                    }
                    ForEach(store.layout.placements) { placement in
                        WidgetTile(
                            placement: placement,
                            cellW: cellW,
                            rowH: rowH,
                            spacing: spacing,
                            editing: editing,
                            content: content(placement.widget),
                            commit: { store.update(placement.widget, to: $0) },
                            onHide: { store.hide(placement.widget) }
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: max(rowH, canvasH), alignment: .topLeading)
                .padding(.bottom, editing ? rowHeight : 0) // Platz zum Vergrößern nach unten
            }
            .scrollDisabled(false)
        }
        .padding(spacing)
        // Die Leinwand HINTER den Widgets: Liquid Glas (wenn aktiv) — die
        // Widgets selbst frosten opak (siehe WidgetTile).
        .background(SlurmyPaneBackground().ignoresSafeArea())
    }
}

/// Ein einzelnes platziertes Widget inkl. Edit-Chrome und Gesten.
private struct WidgetTile<Content: View>: View {
    let placement: WidgetPlacement
    let cellW: CGFloat
    let rowH: CGFloat
    let spacing: CGFloat
    let editing: Bool
    let content: Content
    /// Liefert `true`, wenn der neue Rahmen akzeptiert wurde (sonst Snap-Back).
    let commit: (WidgetFrame) -> Bool
    let onHide: () -> Void

    @State private var dragOffset: CGSize = .zero
    @State private var resizeDelta: CGSize = .zero
    @State private var dragging = false

    private var stepX: CGFloat { cellW + spacing }
    private var stepY: CGFloat { rowH + spacing }

    private func originX(_ x: Int) -> CGFloat { CGFloat(x) * stepX }
    private func originY(_ y: Int) -> CGFloat { CGFloat(y) * stepY }
    private func pxW(_ w: Int) -> CGFloat { CGFloat(w) * cellW + CGFloat(w - 1) * spacing }
    private func pxH(_ h: Int) -> CGFloat { CGFloat(h) * rowH + CGFloat(h - 1) * spacing }

    var body: some View {
        let f = placement.frame
        let w = max(cellW, pxW(f.w) + resizeDelta.width)
        let h = max(rowH, pxH(f.h) + resizeDelta.height)

        tileBody
            .frame(width: w, height: h, alignment: .topLeading)
            .offset(x: originX(f.x) + dragOffset.width,
                    y: originY(f.y) + dragOffset.height)
            .zIndex(dragging ? 10 : 0)
            .motion(.spring(response: 0.3, dampingFraction: 0.85), value: f)
    }

    private var tileBody: some View {
        ZStack(alignment: .topLeading) {
            content
                // Frost-Element: durchgehend opak (Pane-Hintergründe im
                // Inneren de-glasen sich über das Environment-Flag) mit
                // Hairline — Glas gibt es nur ZWISCHEN den Widgets.
                .environment(\.insideFrostElement, true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Theme.hairline, lineWidth: 0.5)
                )
                .disabled(editing)
                .allowsHitTesting(!editing)

            if editing {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(dragging ? 0.9 : 0.5),
                                  style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                editHeader
                resizeHandle
            }
        }
        .contentShape(Rectangle())
        .gesture(editing ? moveGesture : nil)
    }

    // MARK: – Edit-Chrome

    private var editHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: placement.widget.symbol)
            Text(placement.widget.title)
                .font(.caption.bold())
                .lineLimit(1)
            Spacer(minLength: 4)
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.caption2)
                .foregroundColor(Theme.textSecondary)
            Button(action: onHide) {
                Image(systemName: "eye.slash")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundColor(Theme.danger)
            .help("Widget ausblenden")
        }
        .foregroundColor(Theme.textPrimary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(true)
    }

    private var resizeHandle: some View {
        Image(systemName: "arrow.down.right")
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(Theme.onAccent)
            .frame(width: 26, height: 26)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .contentShape(Rectangle())
            .gesture(resizeGesture)
    }

    // MARK: – Gesten

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { v in
                dragging = true
                dragOffset = v.translation
            }
            .onEnded { v in
                let f = placement.frame
                var candidate = f
                candidate.x = Int((originX(f.x) + v.translation.width) / stepX + 0.5)
                candidate.y = Int(max(0, (originY(f.y) + v.translation.height) / stepY + 0.5))
                let accepted = commit(candidate)
                _ = accepted // bei Ablehnung sorgt Reset für Snap-Back
                withMotion(.spring(response: 0.3, dampingFraction: 0.85)) {
                    dragOffset = .zero
                    dragging = false
                }
            }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { v in
                dragging = true
                resizeDelta = v.translation
            }
            .onEnded { v in
                let f = placement.frame
                var candidate = f
                candidate.w = Int((pxW(f.w) + v.translation.width + spacing) / stepX + 0.5)
                candidate.h = Int((pxH(f.h) + v.translation.height + spacing) / stepY + 0.5)
                _ = commit(candidate)
                withMotion(.spring(response: 0.3, dampingFraction: 0.85)) {
                    resizeDelta = .zero
                    dragging = false
                }
            }
    }
}

/// Dezentes Punktraster im Hintergrund, nur im Edit-Modus sichtbar.
private struct GridBackdrop: View {
    let columns: Int
    let rows: Int
    let cellW: CGFloat
    let rowH: CGFloat
    let spacing: CGFloat

    var body: some View {
        Canvas { ctx, _ in
            for c in 0..<columns {
                for r in 0..<rows {
                    let x = CGFloat(c) * (cellW + spacing)
                    let y = CGFloat(r) * (rowH + spacing)
                    let rect = CGRect(x: x, y: y, width: cellW, height: rowH)
                    let path = Path(roundedRect: rect, cornerRadius: 12)
                    ctx.fill(path, with: .color(Theme.surface.opacity(0.5)))
                    ctx.stroke(path, with: .color(Theme.border.opacity(0.4)), lineWidth: 1)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
