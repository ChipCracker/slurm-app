import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// A clean, symmetric divider-with-grip between two panes. A hairline track in
/// the border colour with a centered capsule grip; on hover/drag it brightens to
/// the accent and shows a subtle highlight, plus the right resize cursor.
///
/// `onChange` receives the cumulative drag translation along the resize axis
/// (global coordinate space, so it stays stable while the divider itself moves);
/// the owner captures a base value at the first change and clamps.
struct PaneResizer: View {
    enum Drag { case updown, leftright }   // updown = horizontal bar; leftright = vertical bar

    let drag: Drag
    let onChange: (CGFloat) -> Void
    let onEnd: () -> Void

    @State private var hovering = false
    @State private var active = false

    private var isVerticalBar: Bool { drag == .leftright }

    var body: some View {
        let strong = hovering || active
        ZStack {
            RoundedRectangle(cornerRadius: 0.5)
                .fill(Theme.border.opacity(0.55))
                .frame(width: isVerticalBar ? 1 : nil,
                       height: isVerticalBar ? nil : 1)
            Capsule()
                .fill(strong ? Theme.accent : Theme.textSecondary.opacity(0.45))
                .frame(width: isVerticalBar ? 4 : 40,
                       height: isVerticalBar ? 40 : 4)
                .animation(.easeOut(duration: 0.12), value: strong)
        }
        // A roomy invisible hit area around the thin line.
        .frame(width: isVerticalBar ? 11 : nil,
               height: isVerticalBar ? nil : 11)
        .frame(maxWidth: isVerticalBar ? nil : .infinity,
               maxHeight: isVerticalBar ? .infinity : nil)
        .background(strong ? Theme.accent.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in
                    active = true
                    onChange(isVerticalBar ? v.translation.width : v.translation.height)
                }
                .onEnded { _ in active = false; onEnd() }
        )
        #if os(macOS)
        .onHover { h in
            hovering = h
            if h {
                (isVerticalBar ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
            } else {
                NSCursor.pop()
            }
        }
        #endif
    }
}
