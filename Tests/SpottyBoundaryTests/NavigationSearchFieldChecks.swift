import AppKit
import SwiftUI
import Testing
@testable import SpottyCore

@Suite("Navigation search field")
@MainActor
struct NavigationSearchFieldChecks {
    @Test func focusTargetsNativeEditorAndPreservesEditingAcrossUpdates() async throws {
        var query = "Harbor"
        var activations = 0
        let controller = NavigationSearchField.Controller()
        func content() -> NavigationSearchField {
            NavigationSearchField(
                text: Binding(get: { query }, set: { query = $0 }), controller: controller,
                onActivate: { activations += 1 })
        }
        let host = NSHostingView(rootView: content())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 100), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let field = try #require(controller.field)
        #expect(field.accessibilityLabel() == "Search Spotify")
        controller.focus()
        let editor = try #require(field.currentEditor() as? NSTextView)
        #expect(window.firstResponder === editor)
        #expect(controller.isFocused)
        #expect(editor.selectedRange() == NSRange(location: 0, length: 6))
        editor.insertText("Night transit", replacementRange: editor.selectedRange())
        #expect(query == "Night transit")
        #expect(controller.isFocused)
        #expect(activations == 1)

        editor.setSelectedRange(NSRange(location: 2, length: 3))
        host.rootView = content()
        host.layoutSubtreeIfNeeded()
        #expect(controller.field === field)
        #expect(editor.selectedRange() == NSRange(location: 2, length: 3))
        controller.focus()
        #expect(editor.selectedRange() == NSRange(location: 0, length: 13))
        #expect(window.firstResponder === editor)
        #expect(activations == 1, "repeated Command-L selects the query without repeating navigation")
        controller.blur()
        #expect(field.currentEditor() == nil)
        #expect(!controller.isFocused)
        #expect(window.makeFirstResponder(field))
        #expect(controller.isFocused, "native focus updates styling before the first edit")
        #expect(activations == 2)
        controller.blur()
    }
}
