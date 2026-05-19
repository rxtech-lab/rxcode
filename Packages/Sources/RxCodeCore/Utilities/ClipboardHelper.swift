import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// Copies text to the clipboard and resets the `feedback` binding to false after 2 seconds.
@MainActor
public func copyToClipboard(_ text: String, feedback: Binding<Bool>) {
#if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
#elseif os(iOS)
    UIPasteboard.general.string = text
#endif
    feedback.wrappedValue = true
    Task {
        try? await Task.sleep(for: .seconds(2))
        feedback.wrappedValue = false
    }
}
