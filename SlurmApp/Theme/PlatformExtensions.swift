import SwiftUI

extension View {
    /// Inline-Navigationstitel auf iOS. macOS hat keine Nav-Bar → no-op.
    func inlineNavTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// Färbt den Navigations-Bar-Hintergrund (iOS) passend zum dunklen Theme.
    /// macOS hat keine Nav-Bar → no-op.
    func navBarBackground(_ color: Color) -> some View {
        #if os(iOS)
        self.toolbarBackground(color, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        #else
        self
        #endif
    }

    /// Numerische Tastatur (iOS) für Felder wie den Port.
    func numberInput() -> some View {
        #if os(iOS)
        self.keyboardType(.numbersAndPunctuation)
        #else
        self
        #endif
    }

    /// Keine Autokorrektur/Autokapitalisierung für Hosts, User, Keys.
    func plainTextInput() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        self.autocorrectionDisabled()
        #endif
    }

    /// Sinnvolle Default-Fenstergröße — nur macOS, auf iOS no-op.
    func macWindowSizing() -> some View {
        #if os(macOS)
        self.frame(minWidth: 900, minHeight: 600)
        #else
        self
        #endif
    }

    func platformGroupedListStyle() -> some View {
        #if os(iOS)
        self.listStyle(.insetGrouped)
        #else
        self.listStyle(.inset)
        #endif
    }

    /// Vergrößert die Trefferfläche kleiner Icon-Buttons auf iOS auf die von
    /// Apple empfohlenen ~44pt. Auf macOS (Maus) unverändert.
    func iosTouchTarget() -> some View {
        #if os(iOS)
        self.frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        #else
        self
        #endif
    }
}
