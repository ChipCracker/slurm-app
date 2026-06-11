import SwiftUI

// MARK: – Public modifiers

extension View {
    /// Present a translucent "liquid glass" modal overlay on top of this
    /// view when `item` becomes non-nil. Tapping the dimmed background or
    /// pressing Esc dismisses it. The `content` closure receives the
    /// non-nil item.
    func glassModal<Item: Identifiable, ModalContent: View>(
        item: Binding<Item?>,
        maxWidth: CGFloat = 960,
        maxHeight: CGFloat = 740,
        @ViewBuilder content: @escaping (Item) -> ModalContent
    ) -> some View {
        modifier(GlassModalItemModifier(item: item, maxWidth: maxWidth, maxHeight: maxHeight, modalContent: content))
    }

    /// Boolean variant for cases without a payload.
    func glassModal<ModalContent: View>(
        isPresented: Binding<Bool>,
        maxWidth: CGFloat = 960,
        maxHeight: CGFloat = 740,
        @ViewBuilder content: @escaping () -> ModalContent
    ) -> some View {
        modifier(GlassModalBoolModifier(isPresented: isPresented, maxWidth: maxWidth, maxHeight: maxHeight, modalContent: content))
    }
}

// MARK: – Reusable glass panel

/// The visual shell of a glass modal. Delegates to `slurmyGlass` (see
/// Theme/LiquidGlass.swift): native Liquid Glass on macOS 26+/iOS 26, the
/// legacy frosted look (gradient + ultraThinMaterial + hairline) on
/// macOS 14/15. The subtle `Theme.glassTint` keeps user color themes /
/// accent overrides coloring the glass. Exposed publicly so views can render
/// an inline glass card outside of a modal too.
struct GlassPanel<Content: View>: View {
    let cornerRadius: CGFloat
    @ViewBuilder var content: () -> Content

    init(cornerRadius: CGFloat = 24, @ViewBuilder content: @escaping () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content
    }

    var body: some View {
        content()
            // Das Panel ist auf macOS 26+/iOS 26 selbst eine `glassEffect`-
            // Fläche — Controls darin (slurmyGlassButton/-CircleButton) lesen
            // dieses Flag und de-glasen sich, damit kein Liquid Glass auf
            // Liquid Glass gestapelt wird (siehe Theme/LiquidGlass.swift).
            .environment(\.insideGlassPanel, true)
            // Greedy wie der frühere ZStack mit LinearGradient: das Panel
            // füllt den vom Container vorgeschlagenen (gedeckelten) Raum.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .slurmyGlass(cornerRadius: cornerRadius, tint: Theme.glassTint)
    }
}

// MARK: – Modifier implementations

private struct GlassModalItemModifier<Item: Identifiable, ModalContent: View>: ViewModifier {
    @Binding var item: Item?
    let maxWidth: CGFloat
    let maxHeight: CGFloat
    @ViewBuilder let modalContent: (Item) -> ModalContent

    func body(content: Content) -> some View {
        #if os(iOS)
        // iPhone/iPad: natives Bottom-Sheet mit Detents statt zentriertem
        // Desktop-Overlay. `glassModalDismiss` wird durchgereicht, damit die
        // Close-Buttons im Inhalt weiter funktionieren.
        // Kein opakes `presentationBackground` mehr — das System-Sheet bringt
        // auf iOS 26 nativ Liquid Glass mit (opak hätte es unterdrückt).
        content.sheet(item: $item) { value in
            modalContent(value)
                .environment(\.glassModalDismiss, { item = nil })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        #else
        content
            .overlay {
                if let value = item {
                    GlassModalContainer(
                        maxWidth: maxWidth,
                        maxHeight: maxHeight,
                        dismiss: { item = nil }
                    ) {
                        modalContent(value)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
            }
            .animation(.smooth(duration: 0.25), value: item?.id)
        #endif
    }
}

private struct GlassModalBoolModifier<ModalContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let maxWidth: CGFloat
    let maxHeight: CGFloat
    @ViewBuilder let modalContent: () -> ModalContent

    func body(content: Content) -> some View {
        #if os(iOS)
        // Wie oben: System-Sheet-Hintergrund (Liquid Glass) statt opakem Theme.
        content.sheet(isPresented: $isPresented) {
            modalContent()
                .environment(\.glassModalDismiss, { isPresented = false })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        #else
        content
            .overlay {
                if isPresented {
                    GlassModalContainer(
                        maxWidth: maxWidth,
                        maxHeight: maxHeight,
                        dismiss: { isPresented = false }
                    ) {
                        modalContent()
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
            }
            .animation(.smooth(duration: 0.25), value: isPresented)
        #endif
    }
}

/// Internal: the actual ZStack with dim-layer, tap-dismiss, glass panel and
/// shadow. Hidden behind the modifiers so callers stay declarative.
private struct GlassModalContainer<ModalContent: View>: View {
    let maxWidth: CGFloat
    let maxHeight: CGFloat
    let dismiss: () -> Void
    @ViewBuilder let body_content: () -> ModalContent

    init(
        maxWidth: CGFloat,
        maxHeight: CGFloat,
        dismiss: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> ModalContent
    ) {
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.dismiss = dismiss
        self.body_content = content
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }

            GlassPanel {
                body_content()
            }
            .frame(maxWidth: maxWidth, maxHeight: maxHeight)
            .shadow(color: .black.opacity(0.35), radius: 32, x: 0, y: 16)
            .padding(40)
            .contentShape(Rectangle())
            .onTapGesture { /* swallow taps inside the panel */ }
        }
        // Esc closes via the underlying button shortcut; callers that need
        // an explicit close button get the `dismiss` closure inside their
        // content via @Environment(\.dismiss) — wired here:
        .environment(\.glassModalDismiss, dismiss)
    }
}

// MARK: – Dismiss action available to modal content

/// Injected into the environment so a piece of modal content can fire
/// `@Environment(\.glassModalDismiss)()` without needing to know about its
/// presenting binding.
private struct GlassModalDismissKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var glassModalDismiss: () -> Void {
        get { self[GlassModalDismissKey.self] }
        set { self[GlassModalDismissKey.self] = newValue }
    }
}
