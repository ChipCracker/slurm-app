import SwiftUI

@main
struct SlurmApp: App {
    @StateObject private var appState = AppState()

    /// Textgröße über Dynamic Type. ⌘+/⌘-/⌘0 stufen durch die Standardgrößen;
    /// der Index wird persistiert. `.large` ist der Default (Index 3).
    @AppStorage("textSizeIndex") private var textSizeIndex: Int = 3

    private let sizes: [DynamicTypeSize] =
        [.xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge]
    private let defaultIndex = 3

    private var currentIndex: Int { min(max(textSizeIndex, 0), sizes.count - 1) }
    private func setSize(_ i: Int) { textSizeIndex = min(max(i, 0), sizes.count - 1) }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                // Nur überschreiben, wenn der Nutzer per ⌘+/⌘- abgewichen ist —
                // sonst die System-Textgröße (iOS Dynamic Type) durchlassen.
                .modifier(TextScale(size: currentIndex == defaultIndex ? nil : sizes[currentIndex]))
                .macWindowSizing()
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 720)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified(showsTitle: true))
        #endif
        .commands {
            #if os(macOS)
            CommandGroup(replacing: .newItem) {}
            #endif
            CommandMenu("Darstellung") {
                Button("Schrift vergrößern") { setSize(currentIndex + 1) }
                    .keyboardShortcut("+", modifiers: .command)
                    .disabled(currentIndex >= sizes.count - 1)
                Button("Schrift verkleinern") { setSize(currentIndex - 1) }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(currentIndex <= 0)
                Button("Originalgröße") { setSize(defaultIndex) }
                    .keyboardShortcut("0", modifiers: .command)
            }
        }
    }
}

/// Wendet eine feste Dynamic-Type-Größe an, wenn gesetzt; sonst no-op (System).
private struct TextScale: ViewModifier {
    let size: DynamicTypeSize?
    func body(content: Content) -> some View {
        if let size {
            content.dynamicTypeSize(size)
        } else {
            content
        }
    }
}
