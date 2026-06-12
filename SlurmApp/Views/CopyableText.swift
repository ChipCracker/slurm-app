import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum Clipboard {
    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        #endif
    }
}

/// Selectable, copyable message bubble. Tap the icon to copy; long-press the
/// text also works via `.textSelection(.enabled)`.
struct CopyableText: View {
    let text: String
    var color: Color = Theme.textPrimary
    var iconColor: Color = Theme.textSecondary
    var monospaced: Bool = true

    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(text)
                .font(monospaced ? .footnote.monospaced() : .footnote)
                .foregroundColor(color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Clipboard.copy(text)
                withMotion { copied = true }
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    withMotion { copied = false }
                }
            } label: {
                Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.callout)
                    .foregroundColor(copied ? Theme.success : iconColor)
            }
            .buttonStyle(.plain)
            .help("Kopieren")
        }
    }
}

/// Inline error banner that's always copyable. Drop-in replacement for the
/// scattered "Text(msg).foregroundColor(Theme.danger)" pattern.
struct ErrorBanner: View {
    let message: String
    var tint: Color = Theme.danger

    var body: some View {
        CopyableText(text: message, color: tint, iconColor: tint)
            .padding(10)
            .background(tint.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
