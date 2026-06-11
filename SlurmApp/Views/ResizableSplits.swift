import SwiftUI

// Resizable split containers that OWN the divider geometry as their own @State.
// The panes are passed in as already-built view values (built once per parent
// render). Dragging a divider mutates only the container's state, so SwiftUI
// re-applies the new frame to the *same* stored pane value instead of
// re-evaluating the parent's body — the heavy jobs Table is never rebuilt mid-
// drag. That's what keeps resizing smooth.
//
// @State survives parent re-renders (SwiftUI keys it by position), so the chosen
// sizes persist across the ~10s polling refreshes. Across section switches
// (JobsView is destroyed when visiting Bookmarks/Settings) and relaunches the
// divider values are restored from UserDefaults via `storageKey` — mirroring how
// `inspectorOpen` is persisted. Double-clicking a divider resets it (and clears
// the stored value), matching the NSSplitView convention.

/// Reads a persisted divider value; nil when no key is set or nothing stored.
private func loadDividerValue(_ key: String?) -> CGFloat? {
    guard let key, let v = UserDefaults.standard.object(forKey: key) as? Double else { return nil }
    return CGFloat(v)
}

/// Persists a divider value; nil removes the entry (reset to default).
private func storeDividerValue(_ value: CGFloat?, key: String?) {
    guard let key else { return }
    if let value {
        UserDefaults.standard.set(Double(value), forKey: key)
    } else {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// Left fills, right is a fixed (resizable) width. `showRight` hides the right
/// pane + divider without losing the stored width.
struct ResizableHSplit2<L: View, R: View>: View {
    private let left: L
    private let right: R
    private let showRight: Bool
    private let minLeft: CGFloat
    private let minRight: CGFloat
    private let maxRight: CGFloat
    private let defaultRight: CGFloat
    private let storageKey: String?

    @State private var rightWidth: CGFloat
    @State private var base: CGFloat?

    init(showRight: Bool,
         defaultRight: CGFloat = 380,
         minLeft: CGFloat = 460,
         minRight: CGFloat = 300,
         maxRight: CGFloat = 640,
         storageKey: String? = "layout.split.inspectorWidth",
         @ViewBuilder left: () -> L,
         @ViewBuilder right: () -> R) {
        self.left = left()
        self.right = right()
        self.showRight = showRight
        self.minLeft = minLeft
        self.minRight = minRight
        self.maxRight = maxRight
        self.defaultRight = defaultRight
        self.storageKey = storageKey
        let stored = loadDividerValue(storageKey)
        self._rightWidth = State(initialValue: min(maxRight, max(minRight, stored ?? defaultRight)))
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
                        onEnd: {
                            base = nil
                            storeDividerValue(rightWidth, key: storageKey)
                        }
                    )
                    .onTapGesture(count: 2) {
                        rightWidth = defaultRight
                        storeDividerValue(nil, key: storageKey)
                    }
                    right.frame(width: rightWidth)
                }
                // Slide the column in/out from the trailing edge while the left
                // pane animates to fill — see the toolbar inspector toggle.
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .motion(.smooth(duration: 0.28), value: showRight)
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
    private let storageKey: String?

    @State private var override: CGFloat?
    @State private var base: CGFloat?

    init(autoTopHeight: CGFloat,
         minTop: CGFloat = 140,
         minBottom: CGFloat = 170,
         storageKey: String? = "layout.split.tableHeight",
         @ViewBuilder top: () -> T,
         @ViewBuilder bottom: () -> B) {
        self.top = top()
        self.bottom = bottom()
        self.autoTopHeight = autoTopHeight
        self.minTop = minTop
        self.minBottom = minBottom
        self.storageKey = storageKey
        self._override = State(initialValue: loadDividerValue(storageKey))
    }

    var body: some View {
        GeometryReader { geo in
            // 11pt = Höhe der PaneResizer-Hitbox. Der Override muss nach oben
            // geklemmt werden, sonst schiebt ein Drag bis an/unter die
            // Fensterkante den Divider samt Detail-Pane unerreichbar aus dem
            // sichtbaren Bereich.
            let resizerH: CGFloat = 11
            let maxTop = max(minTop, geo.size.height - minBottom - resizerH)
            VStack(spacing: 0) {
                topRegion(maxTop: maxTop)
                PaneResizer(
                    drag: .updown,
                    onChange: { delta in
                        let b = base ?? (override ?? autoTopHeight)
                        if base == nil { base = b }
                        var tx = Transaction(); tx.disablesAnimations = true
                        withTransaction(tx) { override = min(max(minTop, b + delta), maxTop) }
                    },
                    onEnd: {
                        base = nil
                        storeDividerValue(override, key: storageKey)
                    }
                )
                .onTapGesture(count: 2) {
                    // Doppelklick: zurück zur automatischen Höhe.
                    override = nil
                    storeDividerValue(nil, key: storageKey)
                }
                bottom.frame(minHeight: minBottom, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder private func topRegion(maxTop: CGFloat) -> some View {
        if let h = override {
            // Auch gespeicherte/ältere Overrides an die aktuelle Fenstergröße
            // klemmen (das Fenster kann seit dem Drag geschrumpft sein).
            top.frame(height: min(max(minTop, h), maxTop))
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
    private let keyH1: String?
    private let keyH2: String?

    @State private var h1: CGFloat?
    @State private var h2: CGFloat?
    @State private var base: CGFloat?

    init(minH: CGFloat = 120,
         storageKey: String? = "layout.split.cluster",
         @ViewBuilder a: () -> A,
         @ViewBuilder b: () -> B,
         @ViewBuilder c: () -> C) {
        self.a = a()
        self.b = b()
        self.c = c()
        self.minH = minH
        self.keyH1 = storageKey.map { $0 + ".h1" }
        self.keyH2 = storageKey.map { $0 + ".h2" }
        self._h1 = State(initialValue: loadDividerValue(keyH1))
        self._h2 = State(initialValue: loadDividerValue(keyH2))
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
                    onEnd: {
                        base = nil
                        storeDividerValue(h1, key: keyH1)
                    }
                )
                .onTapGesture(count: 2) {
                    h1 = nil
                    storeDividerValue(nil, key: keyH1)
                }
                region(b).frame(height: r2)
                PaneResizer(
                    drag: .updown,
                    onChange: { delta in
                        let bb = base ?? r2
                        if base == nil { base = bb }
                        var tx = Transaction(); tx.disablesAnimations = true
                        withTransaction(tx) { h2 = min(max(bb + delta, minH), avail - r1 - minH) }
                    },
                    onEnd: {
                        base = nil
                        storeDividerValue(h2, key: keyH2)
                    }
                )
                .onTapGesture(count: 2) {
                    h2 = nil
                    storeDividerValue(nil, key: keyH2)
                }
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
