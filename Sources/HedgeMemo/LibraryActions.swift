import AppKit
import HedgeMemoCore
import UniformTypeIdentifiers

/// Import/export entry points shared by the status bar menu and any in-panel controls.
@MainActor
enum LibraryActions {
    static func importArchive(into memeStore: MemeStore, clipboardStore: ClipboardHistoryStore) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let extracted = try MemeArchiveService.extract(from: url)
            defer { MemeArchiveService.removeExtraction(extracted.directory) }
            let memeImagesDirectory = extracted.manifest.formatVersion == 1 ? "images" : "meme-images"
            memeStore.importArchive(extracted.manifest, imagesURL: extracted.directory.appendingPathComponent(memeImagesDirectory, isDirectory: true))
            if let clipboardSnapshot = extracted.manifest.clipboardSnapshot {
                clipboardStore.importArchive(clipboardSnapshot, imagesURL: extracted.directory.appendingPathComponent("clipboard-images", isDirectory: true))
            }
        } catch {
            memeStore.report(error)
            let alert = NSAlert(error: error)
            alert.messageText = "无法识别导入的 ZIP"
            alert.informativeText = "请选择由 HedgeMemo 导出的压缩包。"
            alert.runModal()
        }
    }

    static func exportArchive(from memeStore: MemeStore, clipboardStore: ClipboardHistoryStore) {
        guard let selection = ArchiveExportSelectionPanel.run(memeStore: memeStore, clipboardStore: clipboardStore) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "HedgeMemo-Export.zip"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            let memeSnapshot = filteredMemeSnapshot(from: memeStore.snapshot(), selection: selection)
            let clipboardSnapshot = filteredClipboardSnapshot(from: clipboardStore.snapshot(), selection: selection)
            try MemeArchiveService.export(
                memeSnapshot: memeSnapshot,
                memeRepository: memeStore.repository,
                clipboardSnapshot: clipboardSnapshot,
                clipboardRepository: clipboardStore.repository,
                destination: destination
            )
        } catch {
            memeStore.report(error)
        }
    }

    private static func filteredMemeSnapshot(from snapshot: MemeSnapshot, selection: ArchiveExportSelection) -> MemeSnapshot? {
        guard selection.exportsMemes else { return nil }
        let memes = snapshot.memes.filter {
            if let categoryID = $0.categoryID { return selection.memeCategoryIDs.contains(categoryID) }
            return selection.includeUncategorizedMemes
        }
        let categoryIDs = Set(memes.compactMap(\.categoryID))
        return MemeSnapshot(categories: snapshot.categories.filter { categoryIDs.contains($0.id) }, memes: memes)
    }

    private static func filteredClipboardSnapshot(from snapshot: ClipboardHistorySnapshot, selection: ArchiveExportSelection) -> ClipboardHistorySnapshot? {
        guard selection.exportsClipboard else { return nil }
        let keys = selection.clipboardCategoryKeys.compactMap(ClipboardCategoryKey.init(storageValue:))
        let customs = snapshot.settings.customCategories ?? []
        let entries = snapshot.entries.filter { entry in
            keys.contains { entry.matches(key: $0, customCategories: customs) }
        }
        return ClipboardHistorySnapshot(entries: entries, settings: snapshot.settings)
    }
}
