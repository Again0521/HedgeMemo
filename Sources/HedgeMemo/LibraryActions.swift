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
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = L10n.text("选择 ZIP")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let extracted = try MemeArchiveService.extract(from: url)
            defer { MemeArchiveService.removeExtraction(extracted.directory) }
            guard let selection = ArchiveImportSelectionPanel.run(manifest: extracted.manifest) else { return }
            let memeImagesDirectory = extracted.manifest.formatVersion == 1 ? "images" : "meme-images"
            let selectedMemeCategories =
                extracted.manifest.availableMemeCategories.filter {
                    selection.memeCategoryIDs.contains($0.id)
                }
            if selection.includesMemes,
               extracted.manifest.containsMemeRecords
                || !selectedMemeCategories.isEmpty {
                try memeStore.importArchive(
                    categories: selectedMemeCategories,
                    imagesURL: extracted.directory.appendingPathComponent(
                        memeImagesDirectory,
                        isDirectory: true
                    )
                ) { consume in
                    try MemeArchiveService.forEachMeme(in: extracted) { meme in
                        let selected = meme.categoryID.map(
                            selection.memeCategoryIDs.contains
                        ) ?? selection.includeUncategorizedMemes
                        if selected { try consume(meme) }
                    }
                }
            }
            if selection.includesClipboard,
               extracted.manifest.containsClipboardRecords {
                let keys = selection.clipboardCategoryKeys.compactMap(
                    ClipboardCategoryKey.init(storageValue:)
                )
                let customs =
                    extracted.manifest.availableClipboardSettings?.customCategories ?? []
                try clipboardStore.importArchive(
                    imagesURL: extracted.directory.appendingPathComponent("clipboard-images", isDirectory: true),
                    originalFormatsURL: extracted.directory.appendingPathComponent("clipboard-formats", isDirectory: true)
                ) { consume in
                    try MemeArchiveService.forEachClipboardEntry(in: extracted) { entry in
                        if keys.contains(where: {
                            entry.matches(key: $0, customCategories: customs)
                        }) {
                            try consume(entry)
                        }
                    }
                }
            }
        } catch {
            memeStore.report(error)
            UnifiedPopupPanel.showMessage(
                title: L10n.text("无法识别导入的 ZIP"),
                message: L10n.text("请选择由 HedgeMemo 导出的压缩包。")
            )
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

    private static func filteredMemeSnapshot(from snapshot: MemeSnapshot?, selection: ArchiveCategorySelection) -> MemeSnapshot? {
        guard let snapshot, selection.includesMemes else { return nil }
        let memes = snapshot.memes.filter {
            if let categoryID = $0.categoryID { return selection.memeCategoryIDs.contains(categoryID) }
            return selection.includeUncategorizedMemes
        }
        let categoryIDs = Set(memes.compactMap(\.categoryID))
        return MemeSnapshot(categories: snapshot.categories.filter { categoryIDs.contains($0.id) }, memes: memes)
    }

    private static func filteredClipboardSnapshot(from snapshot: ClipboardHistorySnapshot?, selection: ArchiveCategorySelection) -> ClipboardHistorySnapshot? {
        guard let snapshot, selection.includesClipboard else { return nil }
        let keys = selection.clipboardCategoryKeys.compactMap(ClipboardCategoryKey.init(storageValue:))
        let customs = snapshot.settings.customCategories ?? []
        let entries = snapshot.entries.filter { entry in
            keys.contains { entry.matches(key: $0, customCategories: customs) }
        }
        return ClipboardHistorySnapshot(entries: entries, settings: snapshot.settings)
    }
}
