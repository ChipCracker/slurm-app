import SwiftUI

// Resizable split containers that OWN the divider geometry as their own @State.
// The panes are passed in as already-built view values (built once per parent
// render). Dragging a divider mutates only the container's state, so SwiftUI
// re-applies the new frame to the *same* stored pane value instead of
// re-evaluating the parent's body — the heavy jobs Table is never rebuilt mid-
// drag. That's what keeps resizing smooth.
//
// @State survives parent re-renders (SwiftUI keys it by position), so the chosen
// sizes persist across the ~10s polling refreshes.

/// Left fills, right is a fixed (resizable) width. `showRight` hides the right
/// pane + divider without losing the stored width.
struct ResizableHSplit2<L: View, R: View>: View {
    private let left: L
    private let right: R
    private let showRight: Bool
    private let minLeft: CGFloat
    private let minRight: CGFloat
    private let maxRight: CGFloat

    @State private var rightWidth: CGFloat
    @State private var base: CGFloat?

    init(showRight: Bool,
         defaultRight: CGFloat = 380,
         minLeft: CGFloat = 460,
         minRight: CGFloat = 300,
         maxRight: CGFloat = 640,
         @ViewBuilder left: () -> L,
         @ViewBuilder right: () -> R) {
        self.left = left()
        self.right = right()
        self.showRight = showRight
        self.minLeft = minLeft
        self.minRight = minRight
        self.maxRight = maxRight
        self._rightWidth = State(initialValue: defaultRight)
    }

    var body: some View {
        HStack(spacing: 0) {
            left.frame(minWidth: minLeft, maxWidth: .infinity)
            if showRight {
                HStack(spacing: 0) {
                    PaneResizer(
                        drag: .leftright,
                        onChange: { delta in
                            let b = base ?? rightWidth
                            if base == nil { base = b }
                            var tx = Transaction(); tx.disablesAnimations = true
                            withTransaction(tx) { rightWidth = min(maxRight, max(minRight, b - delta)) }
                        },
                        onEnd: { base = nil }
                    )
                    right.frame(width: rightWidth)
                }
                // Slide the column in/out from the trailing edge while the left
                // pane animates to fill — see the toolbar inspector toggle.
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.28), value: showRight)
    }
}

/// Top over bottom. The top defaults to `autoTopHeight` (e.g. hug the table's
/// content so a short list leaves no whitespace); once dragged it becomes a
/// fixed override. Bottom fills the remainder.
struct ResizableVSplit2<T: View, B: View>: View {
    private let top: T
    private let bottom: B
    private let autoTopHeight: CGFloat
    private let minTop: CGFloat
    private let minBottom: CGFloat

    @State private var override: CGFloat?
    @State private var base: CGFloat?

    init(autoTopHeight: CGFloat,
         minTop: CGFloat = 140,
         minBottom: CGFloat = 170,
         @ViewBuilder top: () -> T,
         @ViewBuilder bottom: () -> B) {
        self.top = top()
        self.bottom = bottom()
        self.autoTopHeight = autoTopHeight
        self.minTop = minTop
        self.minBottom = minBottom
    }

    var body: some View {
        VStack(spacing: 0) {
            topRegion
            PaneResizer(
                drag: .updown,
                onChange: { delta in
                    let b = base ?? (override ?? autoTopHeight)
                    if base == nil { base = b }
                    var tx = Transaction(); tx.disablesAnimations = true
                    withTransaction(tx) { override = max(minTop, b + delta) }
                },
                onEnd: { base = nil }
            )
            bottom.frame(minHeight: minBottom, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var topRegion: some View {
        if let h = override {
            top.frame(height: max(minTop, h))
        } else {
            top.frame(maxHeight: autoTopHeight)
        }
    }
}

/// Three stacked regions filling the height; the first two are resizable, the
/// last fills the remainder. Each region scrolls internally if its content is
/// taller than its slot. Used for the cluster column (GPU Allocation / Disk /
/// GPU Hours).
struct ResizableVSplit3<A: View, B: View, C: View>: View {
    private let a: A
    private let b: B
    private let c: C
    private let minH: CGFloat

    @State private var h1: CGFloat?
    @State private var h2: CGFloat?
    @State private var base: CGFloat?

    init(minH: CGFloat = 120,
         @ViewBuilder a: () -> A,
         @ViewBuilder b: () -> B,
         @ViewBuilder c: () -> C) {
        self.a = a()
        self.b = b()
        self.c = c()
        self.minH = minH
    }

    var body: some View {
        GeometryReader { geo in
            let rT: CGFloat = 11
            let avail = max(3 * minH, geo.size.height - 2 * rT)
            let r1 = min(max(h1 ?? avail * 0.50, minH), avail - 2 * minH)
            let r2 = min(max(h2 ?? avail * 0.24, minH), avail - r1 - minH)
            let r3 = max(minH, avail - r1 - r2)
            VStack(spacing: 0) {
                region(a).frame(height: r1)
                PaneResizer(
                    drag: .updown,
                    onChange: { delta in
                        let bb = base ?? r1
                        if base == nil { base = bb }
                        var tx = Transaction(); tx.disablesAnimations = true
                        withTransaction(tx) { h1 = min(max(bb + delta, minH), avail - 2 * minH) }
                    },
                    onEnd: { base = nil }
                )
                region(b).frame(height: r2)
                PaneResizer(
                    drag: .updown,
                    onChange: { delta in
                        let bb = base ?? r2
                        if base == nil { base = bb }
                        var tx = Transaction(); tx.disablesAnimations = true
                        withTransaction(tx) { h2 = min(max(bb + delta, minH), avail - r1 - minH) }
                    },
                    onEnd: { base = nil }
                )
                region(c).frame(height: r3)
            }
        }
    }

    private func region<V: View>(_ v: V) -> some View {
        ScrollView {
            v.padding(.horizontal, 8).padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
