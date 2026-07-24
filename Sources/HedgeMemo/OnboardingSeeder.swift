import AppKit
import Foundation
import HedgeMemoCore

/// Seeds a small amount of first-run content — a few sample memes and a short
/// set of guidance entries in the clipboard — so a brand-new user sees what the
/// app is for. It runs at most once, and only for a genuine fresh install:
/// someone updating from an older build keeps their own data untouched, and a
/// sample they delete never comes back on the next launch or update.
@MainActor
enum OnboardingSeeder {
    /// One-time marker. Once set, seeding never runs again, so deletions stick.
    private static let seedCompletedKey = "com.hedgememo.onboarding.initialSeedCompleted"

    /// Sample memes, bundled in order. The build script copies these into the
    /// app's Resources; a missing file is simply skipped.
    private static let sampleMemeResourceNames = ["DefaultMeme1", "DefaultMeme2", "DefaultMeme3"]

    /// Guidance shown in the clipboard on first run — friendly, plain-spoken,
    /// and safe to delete. Index 0 lands at the top of the list.
    private static let guidanceLines = [
        L10n.text("复制过的文字与图片都会出现在这里，需要的时候回来拿就好。"),
        L10n.text("按 ⌘P 可以置顶到桌面，⌥P可以在剪切板内置顶"),
        L10n.text("鼠标停在一条上就能看到全部内容；常用的可以置顶，或钉到桌面当便签。"),
        L10n.text("这几条只是带你熟悉一下，看完随手删掉就行，之后不会再出现。"),
        L10n.text("任何问题与需求欢迎加群反馈：977808370"),
    ]

    static func seedIfFreshInstall(
        memeStore: MemeStore,
        clipboardStore: ClipboardHistoryStore,
        defaults: UserDefaults = .standard
    ) {
        let hasExistingData = memeStore.repository.hasPersistedLibrary
            || clipboardStore.repository.hasPersistedHistory
        let shouldSeed = OnboardingPolicy.shouldSeed(
            hasDecidedBefore: defaults.bool(forKey: seedCompletedKey),
            hasExistingData: hasExistingData
        )
        // Record the decision either way: an update user is now permanently
        // exempt, and a fresh install won't be re-seeded on the next launch.
        defer { defaults.set(true, forKey: seedCompletedKey) }
        guard shouldSeed else { return }

        seedSampleMemes(into: memeStore)
        seedGuidance(into: clipboardStore)
    }

    /// Samples may be provided in any common image format, so each base name is
    /// resolved against these extensions in turn.
    private static let sampleMemeExtensions = ["png", "jpg", "jpeg", "gif"]

    private static func seedSampleMemes(into store: MemeStore) {
        for name in sampleMemeResourceNames {
            guard let url = sampleMemeExtensions.lazy
                    .compactMap({ Bundle.main.url(forResource: name, withExtension: $0) })
                    .first,
                  let payload = ImageAssetData(fileURL: url) else { continue }
            _ = store.addImageData(payload)
        }
    }

    private static func seedGuidance(into store: ClipboardHistoryStore) {
        let now = Date()
        // Newest sorts first, so give index 0 the latest time; each later line
        // steps one second back to keep the reading order stable.
        let entries = guidanceLines.enumerated().map { index, line in
            ClipboardEntry(
                kind: .text,
                text: line,
                contentHash: Data(line.utf8).clipboardContentHash,
                createdAt: now.addingTimeInterval(-Double(index)),
                sourceApp: "HedgeMemo"
            )
        }
        store.addSeedEntries(entries)
    }
}
