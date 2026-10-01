import AppKit
import SwiftUI
import Testing
@testable import SpottyCore

@Suite("Navigation search field")
@MainActor
struct NavigationSearchFieldChecks {
    @Test func removalReleasesTheDepartedOwnerFromNativeBindingsAndActions() {
        final class Owner {
            var query = ""
            var activations = 0
        }
        var owner: Owner? = Owner()
        weak let departed = owner
        let controller = NavigationSearchField.Controller()
        let field = NSTextField()
        controller.field = field
        controller.text = Binding(
            get: { [retained = owner!] in retained.query },
            set: { [retained = owner!] in retained.query = $0 })
        controller.onActivate = { [retained = owner!] in retained.activations += 1 }
        owner = nil
        #expect(departed != nil)
        NavigationSearchField.dismantleNSView(field, coordinator: controller)
        #expect(departed == nil, "Departed root/account owners must not remain in native editing callbacks")
    }

    @Test func accountResetDiscardsProvisionalTextEvenWhenCommittedQueryIsAlreadyEmpty() throws {
        var query = ""
        var accountEpoch: UInt64 = 1
        var publications: [String] = []
        let controller = NavigationSearchField.Controller()
        func content() -> NavigationSearchField {
            NavigationSearchField(
                text: Binding(
                    get: { query },
                    set: {
                        query = $0; publications.append($0)
                    }),
                controller: controller, onActivate: {}, resetGeneration: accountEpoch)
        }
        let host = NSHostingView(rootView: content())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 100), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let field = try #require(controller.field)
        controller.focus()
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.setMarkedText(
            "夜", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
        try #require(editor.hasMarkedText())
        try #require(query.isEmpty)
        host.rootView = content()
        host.layoutSubtreeIfNeeded()
        #expect(editor.hasMarkedText(), "Same-account updates preserve native composition")
        accountEpoch += 1
        host.rootView = content()
        host.layoutSubtreeIfNeeded()
        #expect(editor.string.isEmpty)
        #expect(field.stringValue.isEmpty)
        #expect(!editor.hasMarkedText())
        #expect(query.isEmpty)
        #expect(publications.isEmpty)
        controller.blur()
        #expect(query.isEmpty)
        #expect(publications.isEmpty, "Old provisional text must never reach the replacement account's query")
    }

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
        #expect(editor.insertionPointColor == .white, "Search uses Spotify's white caret before typing")
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
        editor.setMarkedText(
            "夜", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
        #expect(editor.hasMarkedText())
        #expect(field.stringValue == "夜", "AppKit exposes provisional text through the live field")
        #expect(query == "Night transit", "The query stays committed while the native editor owns composition")
        let markedRange = editor.markedRange()
        let compositionSelection = editor.selectedRange()
        host.rootView = content()
        host.layoutSubtreeIfNeeded()
        #expect(editor.hasMarkedText())
        #expect(editor.markedRange() == markedRange)
        #expect(editor.selectedRange() == compositionSelection)
        #expect(editor.insertionPointColor == .white)
        query = ""
        host.rootView = content()
        host.layoutSubtreeIfNeeded()
        #expect(editor.string.isEmpty, "An intentional model reset wins over provisional native text")
        #expect(!editor.hasMarkedText())
        controller.blur()
        #expect(field.currentEditor() == nil)
        #expect(!controller.isFocused)
        #expect(window.makeFirstResponder(field))
        #expect(controller.isFocused, "native focus updates styling before the first edit")
        #expect(activations == 2)
        controller.blur()
        #expect(window.firstResponder !== field)
        #expect(field.currentEditor() == nil)
        #expect(!controller.isFocused)
    }

    @Test func whiteCaretRestoresSharedEditorAcrossBlurAndNativeFieldHandoff() throws {
        let controller = NavigationSearchField.Controller()
        let host = NSHostingView(
            rootView: NavigationSearchField(
                text: .constant("Harbor"), controller: controller, onActivate: {}))
        host.frame = NSRect(x: 0, y: 60, width: 500, height: 60)
        let ordinary = NSTextField(string: "Ordinary field")
        ordinary.frame = NSRect(x: 20, y: 20, width: 400, height: 24)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 120))
        container.addSubview(host)
        container.addSubview(ordinary)
        let window = NSWindow(
            contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = container
        host.layoutSubtreeIfNeeded()
        let search = try #require(controller.field)

        ordinary.selectText(nil)
        let sharedEditor = try #require(ordinary.currentEditor() as? NSTextView)
        let ordinaryCaretColor = sharedEditor.insertionPointColor
        try #require(window.makeFirstResponder(nil))
        controller.focus()
        #expect(search.currentEditor() === sharedEditor)
        #expect(sharedEditor.insertionPointColor == .white)
        controller.blur()
        #expect(sharedEditor.insertionPointColor == ordinaryCaretColor, "Blur returns the shared editor's prior style")

        ordinary.selectText(nil)
        #expect(ordinary.currentEditor() === sharedEditor)
        #expect(sharedEditor.insertionPointColor == ordinaryCaretColor)
        controller.focus()
        #expect(search.currentEditor() === sharedEditor)
        #expect(sharedEditor.insertionPointColor == .white)
        ordinary.selectText(nil)
        #expect(ordinary.currentEditor() === sharedEditor)
        #expect(
            sharedEditor.insertionPointColor == ordinaryCaretColor, "Native focus handoff must not leak Search's caret")
        #expect(!controller.isFocused)

        controller.focus()
        #expect(sharedEditor.insertionPointColor == .white)
        NavigationSearchField.dismantleNSView(search, coordinator: controller)
        #expect(sharedEditor.insertionPointColor == ordinaryCaretColor, "Removal releases the shared editor style")
        #expect(!controller.isFocused)
        #expect(controller.field == nil)
        try #require(window.makeFirstResponder(nil))
        ordinary.selectText(nil)
        #expect(ordinary.currentEditor() === sharedEditor)
        #expect(sharedEditor.insertionPointColor == ordinaryCaretColor)
    }
}
