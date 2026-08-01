import AppKit
import XCTest

@testable import HedgeMemo

@MainActor
final class TextCompletionCrashGuardTests: XCTestCase {
    func testPanelSearchFieldDisablesRemoteServicesBeforeJoiningAWindow() {
        let field = CrashSafePanelTextField()
        XCTAssertFalse(field.isAutomaticTextCompletionEnabled)
        XCTAssertNil(field.contentType)
        if #available(macOS 15.2, *) { XCTAssertFalse(field.allowsWritingTools) }
        XCTAssertFalse(field.isBordered)
        XCTAssertFalse(field.drawsBackground)
    }

    func testDisablesRemoteCompletionThroughoutWindowHierarchy() {
        let root = NSView()
        let container = NSView()
        let field = NSTextField(string: "search")
        let textView = NSTextView()
        field.isAutomaticTextCompletionEnabled = true
        field.contentType = .password
        textView.isAutomaticTextCompletionEnabled = true
        textView.contentType = .oneTimeCode
        container.addSubview(field)
        container.addSubview(textView)
        root.addSubview(container)

        TextCompletionCrashGuard.disableRemoteCompletion(in: root)

        XCTAssertFalse(field.isAutomaticTextCompletionEnabled)
        XCTAssertNil(field.contentType)
        XCTAssertFalse(textView.isAutomaticTextCompletionEnabled)
        XCTAssertNil(textView.contentType)
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
        field.contentType = .password
        editor?.contentType = .oneTimeCode

        TextCompletionCrashGuard.disableRemoteCompletion(in: window)

        XCTAssertFalse(field.isAutomaticTextCompletionEnabled)
        XCTAssertNil(field.contentType)
        XCTAssertFalse(editor?.isAutomaticTextCompletionEnabled ?? true)
        XCTAssertNil(editor?.contentType)
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
        sourceField.contentType = .password
        sourceEditor?.isAutomaticTextCompletionEnabled = true
        sourceEditor?.contentType = .oneTimeCode

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
        destinationField.contentType = .password
        destination.contentView = destinationField

        TextCompletionCrashGuard.prepareToOrderOnScreen(
            destination,
            existingWindows: [source]
        )

        XCTAssertFalse(sourceField.isAutomaticTextCompletionEnabled)
        XCTAssertNil(sourceField.contentType)
        XCTAssertFalse(sourceEditor?.isAutomaticTextCompletionEnabled ?? true)
        XCTAssertNil(sourceEditor?.contentType)
        XCTAssertFalse(source.firstResponder is NSTextView)
        XCTAssertFalse(destinationField.isAutomaticTextCompletionEnabled)
        XCTAssertNil(destinationField.contentType)
    }

    func testUnifiedPopupSessionUsesSharedPanelChrome() {
        let session = UnifiedPopupSession(
            title: "Popup",
            size: NSSize(width: 400, height: 220)
        )

        XCTAssertEqual(session.panel.titleVisibility, .hidden)
        XCTAssertTrue(session.panel.titlebarAppearsTransparent)
        XCTAssertEqual(session.panel.titlebarSeparatorStyle, .none)
        XCTAssertFalse(session.panel.isOpaque)
        XCTAssertEqual(session.panel.backgroundColor, .clear)
        XCTAssertTrue(session.panel.hasShadow)
        XCTAssertFalse(session.panel.hidesOnDeactivate)
        XCTAssertFalse(session.panel.isMovableByWindowBackground)
        XCTAssertTrue(session.panel.collectionBehavior.contains(.moveToActiveSpace))
        XCTAssertTrue(session.panel.collectionBehavior.contains(.fullScreenAuxiliary))
    }

    func testTransientPanelReleaseDetachesHostedContentAndDelegate() {
        final class Delegate: NSObject, NSWindowDelegate {}

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let delegate = Delegate()
        let content = NSView()
        panel.isReleasedWhenClosed = false
        panel.delegate = delegate
        panel.contentView = content

        TransientPanelLifetime.release(panel)

        XCTAssertNil(panel.delegate)
        XCTAssertNil(panel.contentViewController)
        XCTAssertNil(panel.contentView)
        XCTAssertFalse(panel.isVisible)
    }
}
