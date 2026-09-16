import AppKit
import SwiftUI

/// Own the toolbar field so Command-L can target its real window responder.
struct NavigationSearchField: NSViewRepresentable {
    @Binding var text: String
    let controller: Controller
    let onActivate: () -> Void

    func makeCoordinator() -> Controller { controller }

    func makeNSView(context: Context) -> NSTextField {
        let field = Field()
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 14, weight: .medium)
        field.textColor = NSColor(SpottyPalette.textPrimary)
        field.placeholderString = "What do you want to play?"
        field.usesSingleLineMode = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel("Search Spotify")
        field.delegate = context.coordinator
        field.onFocus = { [weak controller = context.coordinator] in controller?.activate() }
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onActivate = onActivate
        // Reassigning while the field editor is active would disturb selection and composition.
        if field.stringValue != text { field.stringValue = text }
    }

    @MainActor
    @Observable
    final class Controller: NSObject, NSTextFieldDelegate {
        private(set) var isFocused = false
        @ObservationIgnored weak var field: NSTextField?
        @ObservationIgnored var text: Binding<String> = .constant("")
        @ObservationIgnored var onActivate: () -> Void = {}

        func focus() {
            field?.selectText(nil)
            activate()
        }

        func blur() {
            guard let field, field.currentEditor() != nil else { return }
            field.window?.makeFirstResponder(nil)
        }

        func activate() {
            isFocused = field?.currentEditor() != nil
            onActivate()
        }

        func controlTextDidBeginEditing(_ notification: Notification) { activate() }

        func controlTextDidEndEditing(_ notification: Notification) { isFocused = false }

        func controlTextDidChange(_ notification: Notification) {
            if let field { text.wrappedValue = field.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            onActivate()
            return true
        }

    }

    private final class Field: NSTextField {
        var onFocus: () -> Void = {}

        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted { onFocus() }
            return accepted
        }
    }

}
