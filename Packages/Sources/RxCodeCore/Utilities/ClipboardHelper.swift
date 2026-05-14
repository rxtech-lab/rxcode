import AppKit
import SwiftUI

/// Copies text to the clipboard and resets the `feedback` binding to false after 2 seconds.
@MainActor
public func copyToClipboard(_ text: String, feedback: Binding<Bool>) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    feedback.wrappedValue = true
    Task {
        try? await Task.sleep(for: .seconds(2))
        feedback.wrappedValue = false
    }
}
