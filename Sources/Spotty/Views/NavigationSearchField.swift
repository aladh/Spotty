import AppKit
import SwiftUI

/// Own the toolbar field so Command-L can target its real window responder.
struct NavigationSearchField: NSViewRepresentable {
    @Binding var text: String
    let controller: Controller
    let onActivate: () -> Void
    var resetGeneration: UInt64 = 0

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
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel("Search Spotify")
        field.delegate = context.coordinator
        field.onFocus = { [weak controller = context.coordinator] in controller?.activate() }
        field.onEndEditing = { [weak controller = context.coordinator] in controller?.endEditing() }
        context.coordinator.field = field
        context.coordinator.lastSynchronizedText = nil
        context.coordinator.lastResetGeneration = nil
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onActivate = onActivate
        // Marked text can change the live value before the bound query changes. Only a
        // changed model value may replace that editing; an account reset must also
        // discard composition when the committed query was already empty.
        if context.coordinator.lastSynchronizedText != text
            || context.coordinator.lastResetGeneration != resetGeneration
        {
            context.coordinator.lastSynchronizedText = text
            context.coordinator.lastResetGeneration = resetGeneration
            context.coordinator.isSynchronizingText = true
            defer { context.coordinator.isSynchronizingText = false }
            if field.stringValue != text { field.stringValue = text }
        }
    }

    static func dismantleNSView(_ field: NSTextField, coordinator: Controller) {
        if coordinator.field === field {
            coordinator.endEditing()
            coordinator.field = nil
        }
        field.delegate = nil
        if let field = field as? Field {
            field.onFocus = {}
            field.onEndEditing = {}
        }
    }

    @MainActor
    @Observable
    final class Controller: NSObject, NSTextFieldDelegate {
        private(set) var isFocused = false
        @ObservationIgnored weak var field: NSTextField?
        @ObservationIgnored var text: Binding<String> = .constant("")
        @ObservationIgnored var onActivate: () -> Void = {}
        @ObservationIgnored var lastSynchronizedText: String?
        @ObservationIgnored var lastResetGeneration: UInt64?
        @ObservationIgnored var isSynchronizingText = false
        @ObservationIgnored private weak var styledEditor: NSTextView?
        @ObservationIgnored private var originalCaretColor: NSColor?

        func focus() {
            guard let field else { return }
            if let editor = field.currentEditor() {
                editor.selectAll(nil)
            } else {
                field.selectText(nil)
            }
            if field.currentEditor() != nil { activate() }
        }

        func blur() {
            if let field, let window = field.window,
                window.firstResponder === field || field.currentEditor() != nil
            {
                window.makeFirstResponder(nil)
            }
            endEditing()
        }

        func activate() {
            if let editor = field?.currentEditor() as? NSTextView {
                if styledEditor !== editor {
                    restoreCaretColor()
                    styledEditor = editor
                    originalCaretColor = editor.insertionPointColor
                }
                editor.insertionPointColor = .white
            }
            guard !isFocused else { return }
            isFocused = true
            onActivate()
        }

        func controlTextDidBeginEditing(_ notification: Notification) { activate() }

        func controlTextDidEndEditing(_ notification: Notification) { endEditing() }

        func endEditing() {
            restoreCaretColor()
            isFocused = false
        }

        private func restoreCaretColor() {
            if let editor = styledEditor, let originalCaretColor {
                editor.insertionPointColor = originalCaretColor
            }
            styledEditor = nil
            originalCaretColor = nil
        }

        func controlTextDidChange(_ notification: Notification) {
            // Replacing marked text can synchronously commit the old composition.
            // Only native user edits may publish back through the model binding.
            guard !isSynchronizingText else { return }
            if let field {
                lastSynchronizedText = field.stringValue
                text.wrappedValue = field.stringValue
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            activate()
            return true
        }

    }

    private final class Field: NSTextField {
        var onFocus: () -> Void = {}
        var onEndEditing: () -> Void = {}

        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted { onFocus() }
            return accepted
        }

        override func textDidEndEditing(_ notification: Notification) {
            // Restore before AppKit hands the shared editor to the next control.
            onEndEditing()
            super.textDidEndEditing(notification)
        }
    }

}
