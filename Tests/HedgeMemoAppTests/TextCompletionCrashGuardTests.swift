import AppKit
import XCTest

@testable import HedgeMemo

@MainActor
final class TextCompletionCrashGuardTests: XCTestCase {
    func testDisablesRemoteCompletionThroughoutWindowHierarchy() {
        let root = NSView()
        let container = NSView()
        let field = NSTextField(string: "search")
        let textView = NSTextView()
        field.isAutomaticTextCompletionEnabled = true
        textView.isAutomaticTextCompletionEnabled = true
        container.addSubview(field)
        container.addSubview(textView)
        root.addSubview(container)

        TextCompletionCrashGuard.disableRemoteCompletion(in: root)

        XCTAssertFalse(field.isAutomaticTextCompletionEnabled)
        XCTAssertFalse(textView.isAutomaticTextCompletionEnabled)
    }

    func testDisablesAnActiveFieldEditorAsWellAsItsField() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 24))
        field.isAutomaticTextCompletionEnabled = true
        window.contentView = field
        window.makeKey()
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = field.currentEditor() as? NSTextView
        editor?.isAutomaticTextCompletionEnabled = true

        TextCompletionCrashGuard.disableRemoteCompletion(in: window)

        XCTAssertFalse(field.isAutomaticTextCompletionEnabled)
        XCTAssertFalse(editor?.isAutomaticTextCompletionEnabled ?? true)
    }

    func testPreparingAWindowEndsOldEditingBeforeDestinationIsOrdered() {
        let source = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let sourceField = NSTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 24))
        source.contentView = sourceField
        source.makeKey()
        XCTAssertTrue(source.makeFirstResponder(sourceField))
        let sourceEditor = sourceField.currentEditor() as? NSTextView
        sourceField.isAutomaticTextCompletionEnabled = true
        sourceEditor?.isAutomaticTextCompletionEnabled = true

        let destination = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let destinationField = NSTextField(
            frame: NSRect(x: 20, y: 20, width: 200, height: 24)
        )
        destinationField.isAutomaticTextCompletionEnabled = true
        destination.contentView = destinationField

        TextCompletionCrashGuard.prepareToOrderOnScreen(
            destination,
            existingWindows: [source]
        )

        XCTAssertFalse(sourceField.isAutomaticTextCompletionEnabled)
        XCTAssertFalse(sourceEditor?.isAutomaticTextCompletionEnabled ?? true)
        XCTAssertFalse(source.firstResponder is NSTextView)
        XCTAssertFalse(destinationField.isAutomaticTextCompletionEnabled)
    }
}
