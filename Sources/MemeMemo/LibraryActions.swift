import AppKit
import MemeMemoCore
import UniformTypeIdentifiers

/// Import/export entry points shared by the status bar menu and any in-panel controls.
@MainActor
enum LibraryActions {
    static func importImages(into store: MemeStore) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let image = NSImage(contentsOf: url) { _ = store.addImage(image) }
        }
    }

    static func importArchive(into store: MemeStore) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let extracted = try MemeArchiveService.extract(from: url)
            defer { MemeArchiveService.removeExtraction(extracted.directory) }
            let sourceImages = extracted.directory.appendingPathComponent("images", isDirectory: true)
            store.importArchive(extracted.manifest, imagesURL: sourceImages)
        } catch {
            store.report(error)
        }
    }

    static func exportArchive(from store: MemeStore) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "MemeMemo-Export.zip"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try MemeArchiveService.export(snapshot: store.snapshot(), repository: store.repository, destination: destination)
        } catch {
            store.report(error)
        }
    }
}
