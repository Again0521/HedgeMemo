import AppKit
import Combine
import CoreGraphics
import Foundation

/// A zero-materialization ordered view over the canonical clipboard history.
///
/// The store already computes ordinary and desktop-pinned index partitions.
/// Older callers then concatenated those indexes and mapped every index into a
/// second `[ClipboardEntry]` on each SwiftUI read. This collection keeps both
/// partition buffers shared and performs the fixed insertion mapping only when
/// an element is actually requested.
public struct ClipboardOrderedResults: RandomAccessCollection, Sendable {
    public typealias Element = ClipboardEntry
    public typealias Index = Int

    private let source: [ClipboardEntry]
    private let ordinaryPositions: [Int]
    private let desktopPinnedPositions: [Int]
    private let revealedSecretTexts: [UUID: String]?

    init(
        source: [ClipboardEntry],
        ordinaryPositions: [Int],
        desktopPinnedPositions: [Int],
        revealedSecretTexts: [UUID: String]? = nil
    ) {
        self.source = source
        self.ordinaryPositions = ordinaryPositions
        self.desktopPinnedPositions = desktopPinnedPositions
        self.revealedSecretTexts = revealedSecretTexts
    }

    public static var empty: Self {
        Self(source: [], ordinaryPositions: [], desktopPinnedPositions: [])
    }

    public var startIndex: Int { 0 }
    public var endIndex: Int {
        ordinaryPositions.count + desktopPinnedPositions.count
    }

    public subscript(position: Int) -> ClipboardEntry {
        let insertion = Swift.min(
            ClipboardHistoryPolicy.desktopPinnedInsertionIndex,
            ordinaryPositions.count
        )
        let sourcePosition: Int
        if position < insertion {
            sourcePosition = ordinaryPositions[position]
        } else if position < insertion + desktopPinnedPositions.count {
            sourcePosition = desktopPinnedPositions[position - insertion]
        } else {
            sourcePosition = ordinaryPositions[position - desktopPinnedPositions.count]
        }
        let entry = source[sourcePosition]
        guard let revealedSecretTexts else { return entry }
        return entry.displayProjection(revealedSecret: revealedSecretTexts[entry.id])
    }

    public func displayingSecrets(_ plaintextByID: [UUID: String]) -> Self {
        Self(
            source: source,
            ordinaryPositions: ordinaryPositions,
            desktopPinnedPositions: desktopPinnedPositions,
            revealedSecretTexts: plaintextByID
        )
    }

    var retainedPositionCount: Int {
        ordinaryPositions.count + desktopPinnedPositions.count
    }
}

/// Reuses the backing storage of repeated metadata strings across a history
/// Store. SQLite/JSON decoding otherwise creates a separate heap buffer for the
/// same source identity, custom-category key and rich-text type on every row.
@MainActor
private final class ClipboardMetadataStringInterner {
    private static let capacity = 1_024
    private var strings: [String: String] = [:]
    private var sourceMetadataBoxes:
        [ClipboardSourceMetadataBox: ClipboardSourceMetadataBox] = [:]
    private(set) var canonicalizedAssignmentCount = 0
    private(set) var peakUniqueStringCount = 0
    private(set) var peakUniqueSourceMetadataCount = 0

    func canonicalize(_ source: ClipboardSourceApplication?) -> ClipboardSourceApplication? {
        guard let source else { return nil }
        return ClipboardSourceApplication(
            bundleIdentifier: intern(source.bundleIdentifier),
            displayName: intern(source.displayName) ?? source.displayName,
            bundleURLPath: intern(source.bundleURLPath)
        )
    }

    func canonicalize(_ entry: ClipboardEntry) -> ClipboardEntry {
        var result = entry
        result.replaceSourceMetadata(
            displayName: intern(entry.sourceApp),
            bundleIdentifier: intern(entry.sourceBundleIdentifier),
            bundleURLPath: intern(entry.sourceBundleURLPath)
        )
        if let sourceMetadata = result.sourceMetadataBoxForInterning {
            if let canonical = sourceMetadataBoxes[sourceMetadata] {
                result.reuseSourceMetadataBox(canonical)
            } else {
                if sourceMetadataBoxes.count >= Self.capacity {
                    sourceMetadataBoxes.removeAll(keepingCapacity: true)
                }
                sourceMetadataBoxes[sourceMetadata] = sourceMetadata
                peakUniqueSourceMetadataCount = max(
                    peakUniqueSourceMetadataCount,
                    sourceMetadataBoxes.count
                )
            }
        }
        result.manualCategoryStorageValue = intern(entry.manualCategoryStorageValue)
        if let formats = entry.originalFormats {
            result.originalFormats = formats.map { format in
                ClipboardOriginalFormat(
                    typeIdentifier: intern(format.typeIdentifier) ?? format.typeIdentifier,
                    fileName: format.fileName,
                    byteCount: format.byteCount
                )
            }
        }
        return result
    }

    func canonicalizeMetadata(_ value: String?) -> String? {
        intern(value)
    }

    func canonicalizeInPlace(_ entries: inout [ClipboardEntry]) {
        for index in entries.indices {
            entries[index] = canonicalize(entries[index])
        }
    }

    var uniqueStringCount: Int { strings.count }
    var uniqueSourceMetadataCount: Int { sourceMetadataBoxes.count }

    private func intern(_ value: String?) -> String? {
        guard let value else { return nil }
        canonicalizedAssignmentCount += 1
        if let existing = strings[value] { return existing }
        if strings.count >= Self.capacity {
            strings.removeAll(keepingCapacity: true)
        }
        strings[value] = value
        peakUniqueStringCount = max(peakUniqueStringCount, strings.count)
        return strings[value]
    }
}

@MainActor
public final class ClipboardHistoryStore: ObservableObject {
    struct ArchiveImportMetrics: Equatable {
        let seededHashCount: Int
        let candidateHashCount: Int
        let appliedRecordCount: Int
        let peakResidentHashCount: Int
        let peakResidentHashKeyByteCount: Int
        let hashIndexCacheSizeKiB: Int
        let hashIndexMmapSizeBytes: Int
        let peakIndexedHashCount: Int
        let entriesPublicationCount: Int
        let stagedTextBodyCount: Int
        let peakResidentTextBodyCount: Int
        let peakLiveMetadataCount: Int
        let peakSlotCount: Int
        let peakTrimHeapNodeCount: Int
    }

    private struct ArchiveImportSlot {
        var entry: ClipboardEntry
        var sequence: Int64
        var generation: Int64
    }

    private struct ArchiveTrimNode {
        let createdAt: Date
        let sequence: Int64
        let slotIndex: Int
        let generation: Int64
    }

    private struct ArchiveTrimHeap {
        private(set) var nodes: [ArchiveTrimNode] = []

        var count: Int { nodes.count }

        mutating func insert(_ node: ArchiveTrimNode) {
            nodes.append(node)
            var index = nodes.count - 1
            while index > 0 {
                let parent = (index - 1) / 2
                guard Self.precedes(nodes[index], nodes[parent]) else { break }
                nodes.swapAt(index, parent)
                index = parent
            }
        }

        mutating func popFirst() -> ArchiveTrimNode? {
            guard !nodes.isEmpty else { return nil }
            if nodes.count == 1 { return nodes.removeLast() }
            let first = nodes[0]
            nodes[0] = nodes.removeLast()
            var index = 0
            while true {
                let left = index * 2 + 1
                guard left < nodes.count else { break }
                let right = left + 1
                var child = left
                if right < nodes.count,
                   Self.precedes(nodes[right], nodes[left]) {
                    child = right
                }
                guard Self.precedes(nodes[child], nodes[index]) else { break }
                nodes.swapAt(index, child)
                index = child
            }
            return first
        }

        private static func precedes(
            _ lhs: ArchiveTrimNode,
            _ rhs: ArchiveTrimNode
        ) -> Bool {
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            if lhs.sequence != rhs.sequence {
                return lhs.sequence < rhs.sequence
            }
            return lhs.slotIndex < rhs.slotIndex
        }
    }

    @Published public private(set) var entries: [ClipboardEntry] = [] {
        didSet {
            entriesRevision &+= 1
            invalidateDerivedState()
        }
    }
    /// Monotonic counter bumped whenever `entries` changes.
    ///
    /// Views need to react to list changes, but comparing two snapshots of a
    /// large history element by element — which is what observing `entries`
    /// itself costs — runs on every clipboard capture. Observing this instead
    /// is a single integer comparison.
    @Published public private(set) var entriesRevision: Int = 0
    /// `orderedEntries` is asked several times per UI pass (rows, key handling,
    /// height math), and every miss filters and sorts the entire history.
    /// Results are memoized per (category, query) until entries or settings
    /// change. Not published: reads during view rendering must stay silent.
    private struct IndexPartitions {
        var ordinary: [Int]
        var desktopPinned: [Int]

        var retainedPositionCount: Int {
            ordinary.count + desktopPinned.count
        }
    }

    private var orderedMemo: [String: IndexPartitions] = [:]
    private var orderedMemoPositionCount = 0
    /// Bounded because each value can hold the whole history: over a large
    /// history an unbounded table of past queries is real memory, and a miss
    /// is cheap now that category filtering is cached separately.
    private static let orderedMemoCapacity = 8
    private static let orderedMemoPositionBudget = 100_000
    private var sortedPartitionMemo: (
        key: String,
        value: IndexPartitions
    )?
    /// Category/source filtering keyed independently of the search query, so
    /// typing re-runs only the text matcher. Classifying (or regex-matching)
    /// every entry is by far the most expensive part of building a category.
    private var categoryPartitionMemo: [String: IndexPartitions] = [:]
    /// The most recent query result, kept so the next keystroke can narrow it
    /// instead of rescanning the category. One entry is enough: search text is
    /// typed one character at a time.
    private var incrementalQueryChain: (
        categoryKey: String,
        query: String,
        partitions: IndexPartitions
    )?
    private var sourceApplicationMemos: [String: [ClipboardSourceApplication]] = [:]
    private var sourceApplicationMemoItemCount = 0
    private static let sourceApplicationMemoEntryLimit = 8
    private static let sourceApplicationMemoItemBudget = 2_048
    private var hasUnknownSourceMemos: [String: Bool] = [:]
    /// Validated paste-queue identifiers. `pasteQueueCount` is read from the
    /// category bar on every render pass, and resolving it walks the whole
    /// history; the memo keeps that off the render path.
    private var validPasteQueueMemo: [UUID]?

    private func invalidateDerivedState() {
        orderedMemo.removeAll(keepingCapacity: true)
        orderedMemoPositionCount = 0
        sortedPartitionMemo = nil
        categoryPartitionMemo.removeAll(keepingCapacity: true)
        incrementalQueryChain = nil
        sourceApplicationMemos.removeAll(keepingCapacity: true)
        sourceApplicationMemoItemCount = 0
        hasUnknownSourceMemos.removeAll(keepingCapacity: true)
        validPasteQueueMemo = nil
    }
    // Mutating `settings` inside its own didSet re-enters the @Published setter;
    // without this guard normalize() recurses until the stack overflows.
    private var isNormalizingSettings = false
    private var isApplyingArchiveImport = false
    private var settingsMutationRequiresSnapshot = false
    @Published public var settings: ClipboardHistorySettings {
        didSet {
            // Most settings are presentation/capture preferences and do not
            // change any derived history result. Invalidating every cached
            // category for a hot-key, item-size or auto-paste edit made the
            // next panel open rescan the entire history for no reason.
            if oldValue.customCategories != settings.customCategories {
                invalidateDerivedState()
            } else if oldValue.pasteQueueEntryIDs != settings.pasteQueueEntryIDs {
                validPasteQueueMemo = nil
            }
            guard !isApplyingArchiveImport else { return }
            guard !isNormalizingSettings else { return }
            isNormalizingSettings = true
            settings.normalize()
            isNormalizingSettings = false
            do {
                try settings.validateCustomCategories()
            } catch {
                lastError = error.localizedDescription
            }
            let deletedIDs = trimToLimit()
            if settingsMutationRequiresSnapshot {
                settingsMutationRequiresSnapshot = false
                persist()
            } else {
                persistSettings(deletedIDs: deletedIDs)
            }
        }
    }
    @Published public private(set) var lastError: String?
    private(set) var lastArchiveImportMetrics = ArchiveImportMetrics(
        seededHashCount: 0,
        candidateHashCount: 0,
        appliedRecordCount: 0,
        peakResidentHashCount: 0,
        peakResidentHashKeyByteCount: 0,
        hashIndexCacheSizeKiB: 0,
        hashIndexMmapSizeBytes: 0,
        peakIndexedHashCount: 0,
        entriesPublicationCount: 0,
        stagedTextBodyCount: 0,
        peakResidentTextBodyCount: 0,
        peakLiveMetadataCount: 0,
        peakSlotCount: 0,
        peakTrimHeapNodeCount: 0
    )
    private(set) var lastArchiveImportStagingURL: URL?
    /// While the meme library is capturing clipboard images, history recording is
    /// paused so the captured content doesn't also pile up in the clipboard list.
    public var isRecordingPaused = false
    /// Mirrors `AppLockSettings.capturesPasswords`. Owned by the lock store but
    /// read on the capture path, so the app keeps it in sync rather than making
    /// the history store depend on the lock store.
    public var capturesPasswords = false

    public let repository: ClipboardHistoryRepository
    private let metadataStringInterner = ClipboardMetadataStringInterner()

    /// Upper bounds on a single captured item. A runaway clipboard (a giant
    /// pasted document or a full-resolution screenshot from another app) would
    /// otherwise sit in memory and create excessive database/asset pressure.
    /// Oversized content is skipped rather than truncated so partial,
    /// misleading copies are never stored.
    public static let maxTextByteCount = 2_000_000      // ~2 MB of UTF-8 text
    public static let maxImageByteCount = 40_000_000    // ~40 MB encoded image

    /// nspasteboard.org convention markers. Password managers (1Password,
    /// KeePassXC, browsers…) and other tools flag a copy as concealed/transient
    /// to ask clipboard managers not to persist it. Honoring them keeps secrets
    /// out of the on-disk history entirely.
    private static let privatePasteboardTypes: Set<NSPasteboard.PasteboardType> = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"),
    ]

    /// Internal (not private) so a `@testable` test can assert secrets are
    /// recognized without driving the whole `NSPasteboard.general` poll.
    static func isPrivatePasteboard(_ pasteboard: NSPasteboard) -> Bool {
        guard let types = pasteboard.types else { return false }
        return !privatePasteboardTypes.isDisjoint(with: types)
    }

    /// Coalesces the high-frequency `markUsed` write (a burst of ⌘1–9 pastes can
    /// fire several times per second) so a large history is not fully re-encoded
    /// on each. Every other mutation still persists immediately; this pending
    /// write is flushed on stop/teardown so a use-count update is never lost.
    private var pendingSaveWork: DispatchWorkItem?
    private var pendingSaveEntryIDs = Set<UUID>()
    private var timer: Timer?
    private var observedChangeCount = NSPasteboard.general.changeCount
    private var suppressedChangeCount: Int?
    /// Sleep/wake observers so the poll can be torn down while nothing can copy.
    private var sleepWakeObservers: [NSObjectProtocol] = []
    /// True between `startMonitoring()` and `stopMonitoring()`. Distinguishes a
    /// deliberate stop from a sleep-induced suspend so the timer only rebuilds
    /// on wake when monitoring is actually meant to be running.
    private var isMonitoringEnabled = false
    /// An alternate pasteboard consumer (currently meme capture) can take
    /// temporary ownership without turning a UI toggle into a disk flush.
    private var isPollingExternallySuspended = false

    public init(repository: ClipboardHistoryRepository = .default) {
        self.repository = repository
        do {
            var snapshot = try repository.load()
            settings = snapshot.settings
            // Mutate the uniquely owned load result before publishing it. A
            // `map` here briefly retained two complete metadata arrays.
            metadataStringInterner.canonicalizeInPlace(&snapshot.entries)
            entries = snapshot.entries
        } catch {
            settings = ClipboardHistorySettings()
            entries = []
            lastError = error.localizedDescription
        }
        do {
            try settings.validateCustomCategories()
        } catch {
            // Invalid user-authored rules must be visible, but they must never
            // make otherwise healthy clipboard history disappear.
            lastError = error.localizedDescription
        }
        let removedDuplicates = collapsePersistedDuplicates()
        let removedStaleQueueReferences = normalizePasteQueueReferences()
        if removedDuplicates || removedStaleQueueReferences || normalizeDesktopPinnedOrders() {
            persist()
        }
    }

    public func startMonitoring() {
        stopMonitoring()
        isMonitoringEnabled = true
        isPollingExternallySuspended = false
        observedChangeCount = NSPasteboard.general.changeCount
        schedulePollTimer()
        installSleepWakeObservers()
    }

    public func stopMonitoring() {
        isMonitoringEnabled = false
        flushPendingSave()
        timer?.invalidate()
        timer = nil
        let center = NSWorkspace.shared.notificationCenter
        for observer in sleepWakeObservers { center.removeObserver(observer) }
        sleepWakeObservers.removeAll()
    }

    /// Temporarily yields pasteboard polling to another in-process consumer.
    /// Unlike `stopMonitoring`, this does not flush a potentially huge snapshot
    /// or tear down sleep/wake observers, so enabling capture stays responsive.
    public func setPollingSuspended(_ suspended: Bool) {
        guard isPollingExternallySuspended != suspended else { return }
        isPollingExternallySuspended = suspended
        if suspended {
            timer?.invalidate()
            timer = nil
        } else {
            observedChangeCount = NSPasteboard.general.changeCount
            resumePollingIfNeeded()
        }
    }

    private func schedulePollTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.55, repeats: true) { [weak self] _ in
            // A RunLoop timer is delivered on the main thread, but its closure
            // is not actor-isolated. Hop explicitly instead of using
            // `assumeIsolated`, whose runtime assertion can crash while AppKit
            // is processing another event.
            Task { @MainActor [weak self] in
                self?.inspectPasteboard()
            }
        }
        // This poll runs for the whole session in the background. A generous
        // tolerance lets the OS coalesce its wakeups with other timers, which
        // cuts idle energy/CPU use noticeably; a copy is still picked up within
        // roughly a second, which is imperceptible for a clipboard manager.
        timer.tolerance = 0.25
        // `.default` mode matches the previous `scheduledTimer` behavior exactly
        // (it pauses only during menu/event tracking); the sole change here is
        // the added tolerance.
        RunLoop.main.add(timer, forMode: .default)
        self.timer = timer
    }

    /// Nothing can be copied while the display is asleep or the machine is
    /// suspended, so tear the poll timer down for those windows and rebuild it
    /// on wake. Over a locked-and-away laptop this removes one to two CPU
    /// wakeups per second for hours; on wake the change-count comparison still
    /// captures whatever was last on the pasteboard.
    private func installSleepWakeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        let sleepNames: [NSNotification.Name] = [
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.willSleepNotification,
        ]
        let wakeNames: [NSNotification.Name] = [
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.didWakeNotification,
        ]
        for name in sleepNames {
            sleepWakeObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.suspendPolling() }
            })
        }
        for name in wakeNames {
            sleepWakeObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.resumePollingIfNeeded() }
            })
        }
    }

    private func suspendPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func resumePollingIfNeeded() {
        guard isMonitoringEnabled, !isPollingExternallySuspended, timer == nil else { return }
        schedulePollTimer()
    }

    public func orderedEntries(
        query: String = "",
        key: ClipboardCategoryKey? = nil,
        advancedOptions: ClipboardAdvancedOptions? = nil
    ) -> ClipboardOrderedResults {
        if let key, !settings.isCategoryEnabled(key) { return .empty }
        let canonicalQuery = PercentFuzzyMatcher(query: query).cacheKey
        let memoKey = (key?.storageValue ?? "*")
            + "\u{1}" + canonicalQuery
            + "\u{1}" + (advancedOptions?.cacheKey ?? "standard")
        if let cached = orderedMemo[memoKey] {
            return orderedResults(for: cached)
        }
        let partitions = HedgeMemoPerformance.measure("ClipboardOrdering") {
            queryFilteredPartitions(
                query: canonicalQuery,
                key: key,
                advancedOptions: advancedOptions
            )
        }
        let cost = partitions.retainedPositionCount
        if orderedMemo.count >= Self.orderedMemoCapacity
            || orderedMemoPositionCount + cost > Self.orderedMemoPositionBudget {
            orderedMemo.removeAll(keepingCapacity: true)
            orderedMemoPositionCount = 0
        }
        orderedMemo[memoKey] = partitions
        orderedMemoPositionCount += cost
        return orderedResults(for: partitions)
    }

    private func orderedResults(
        for partitions: IndexPartitions
    ) -> ClipboardOrderedResults {
        ClipboardOrderedResults(
            source: entries,
            ordinaryPositions: partitions.ordinary,
            desktopPinnedPositions: partitions.desktopPinned
        )
    }

    /// Applies the search query, continuing from the previous keystroke's
    /// result when it can.
    ///
    /// Searching a long history means scanning every stored text, which is the
    /// bulk of a keystroke's cost. Typing only ever extends the query, and text
    /// that fails a query cannot pass a longer query beginning with it, so the
    /// next character can filter the previous (already much smaller) result
    /// instead of the whole category. Editing the query any other way —
    /// backspacing, pasting a different term — simply falls back to a full
    /// pass, exactly as before.
    private func queryFilteredPartitions(
        query: String,
        key: ClipboardCategoryKey?,
        advancedOptions: ClipboardAdvancedOptions?
    ) -> IndexPartitions {
        let categoryKey = (key?.storageValue ?? "*")
            + "\u{1}" + (advancedOptions?.cacheKey ?? "standard")
        let base: IndexPartitions
        if let chain = incrementalQueryChain,
           chain.categoryKey == categoryKey,
           query.hasPrefix(chain.query),
           // Wildcard and plain queries match through different comparisons,
           // so only chain within one kind.
           chain.query.isEmpty || chain.query.contains("%") == query.contains("%") {
            if chain.query == query { return chain.partitions }
            base = chain.partitions
        } else {
            base = categoryFilteredPartitions(key: key, advancedOptions: advancedOptions)
        }
        let matcher = PercentFuzzyMatcher(query: query)
        let filtered: IndexPartitions
        if matcher.matchesEveryCandidate {
            filtered = base
        } else {
            filtered = IndexPartitions(
                ordinary: base.ordinary.filter { entries[$0].matchesQuery(matcher) },
                desktopPinned: base.desktopPinned.filter { entries[$0].matchesQuery(matcher) }
            )
        }
        incrementalQueryChain = (categoryKey, query, filtered)
        return filtered
    }

    /// Sorted, category-filtered entries for one category and source filter.
    /// Both stages are independent of the search query, so the panel pays for
    /// them once per category rather than once per keystroke.
    private func categoryFilteredPartitions(
        key: ClipboardCategoryKey?,
        advancedOptions: ClipboardAdvancedOptions?
    ) -> IndexPartitions {
        let sortKey: String
        let sortOptions: ClipboardAdvancedOptions?
        if let advancedOptions {
            sortKey = advancedOptions.sortField.rawValue
                + "\u{2}" + advancedOptions.sortDirection.rawValue
            sortOptions = ClipboardAdvancedOptions(
                sourceIdentifier: nil,
                sortField: advancedOptions.sortField,
                sortDirection: advancedOptions.sortDirection
            )
        } else {
            sortKey = "standard"
            sortOptions = nil
        }
        let categoryKey = sortKey
            + "\u{1}" + (key?.storageValue ?? "*")
            + "\u{1}" + (advancedOptions?.sourceIdentifier ?? "*")
        if let cached = categoryPartitionMemo[categoryKey] { return cached }

        let partitions: IndexPartitions
        if let memo = sortedPartitionMemo, memo.key == sortKey {
            partitions = memo.value
        } else {
            partitions = sortedIndexPartitions(advancedOptions: sortOptions)
            sortedPartitionMemo = (sortKey, partitions)
        }
        let customs = settings.customCategories ?? []
        func matches(_ index: Int) -> Bool {
            let entry = entries[index]
            return entry.matches(key: key, customCategories: customs)
                && (advancedOptions?.matchesSource(entry) ?? true)
        }
        let filtered: IndexPartitions
        if key == nil, advancedOptions?.sourceIdentifier == nil {
            filtered = partitions
        } else {
            filtered = IndexPartitions(
                ordinary: partitions.ordinary.filter(matches),
                desktopPinned: partitions.desktopPinned.filter(matches)
            )
        }
        if categoryPartitionMemo.count >= Self.orderedMemoCapacity {
            categoryPartitionMemo.removeAll(keepingCapacity: true)
        }
        categoryPartitionMemo[categoryKey] = filtered
        return filtered
    }

    private func sortedIndexPartitions(
        advancedOptions: ClipboardAdvancedOptions?
    ) -> IndexPartitions {
        var ordinary: [Int] = []
        var desktopPinned: [Int] = []
        ordinary.reserveCapacity(entries.count)
        desktopPinned.reserveCapacity(min(entries.count, 32))
        for index in entries.indices {
            if entries[index].isDesktopPinned == true {
                desktopPinned.append(index)
            } else {
                ordinary.append(index)
            }
        }
        desktopPinned.sort { lhsIndex, rhsIndex in
            let lhs = entries[lhsIndex]
            let rhs = entries[rhsIndex]
            let leftOrder = lhs.desktopPinnedOrder ?? Int.max
            let rightOrder = rhs.desktopPinnedOrder ?? Int.max
            if leftOrder != rightOrder { return leftOrder < rightOrder }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
            return lhs.createdAt < rhs.createdAt
        }
        ordinary.sort { lhsIndex, rhsIndex in
            let lhs = entries[lhsIndex]
            let rhs = entries[rhsIndex]
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
            if lhs.isPinned {
                return (lhs.pinnedOrder ?? Int.max) < (rhs.pinnedOrder ?? Int.max)
            }
            return advancedOptions?.comesBefore(lhs, rhs) ?? (lhs.createdAt > rhs.createdAt)
        }
        return IndexPartitions(ordinary: ordinary, desktopPinned: desktopPinned)
    }

    /// Source menus are read during every panel render, including hover-driven
    /// renders. Build the de-duplicated list only when entries change instead
    /// of rescanning a 10,000-item history for every pointer movement.
    public func sourceApplicationsForFiltering(
        key: ClipboardCategoryKey? = nil,
        includeSecrets: Bool = false
    ) -> [ClipboardSourceApplication] {
        let memoKey = sourceFilterMemoKey(key: key, includeSecrets: includeSecrets)
        if let memo = sourceApplicationMemos[memoKey] { return memo }
        var seen = Set<String>()
        let customs = settings.customCategories ?? []
        var applications: [ClipboardSourceApplication] = []
        for entry in entries {
            guard (includeSecrets || !entry.isSecret),
                  entry.matches(key: key, customCategories: customs),
                  let application = entry.sourceApplication,
                  seen.insert(application.stableIdentifier).inserted else {
                continue
            }
            applications.append(application)
        }
        applications.sort {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        if sourceApplicationMemos.count >= Self.sourceApplicationMemoEntryLimit
            || sourceApplicationMemoItemCount + applications.count
                > Self.sourceApplicationMemoItemBudget {
            // A source menu can itself exceed the budget when every captured
            // row came from a distinct app. Keep that current menu responsive,
            // but never retain older category menus beside it.
            sourceApplicationMemos.removeAll(keepingCapacity: true)
            sourceApplicationMemoItemCount = 0
            hasUnknownSourceMemos.removeAll(keepingCapacity: true)
        }
        sourceApplicationMemos[memoKey] = applications
        sourceApplicationMemoItemCount += applications.count
        return applications
    }

    public func hasUnknownSourceForFiltering(
        key: ClipboardCategoryKey? = nil,
        includeSecrets: Bool = false
    ) -> Bool {
        let memoKey = sourceFilterMemoKey(key: key, includeSecrets: includeSecrets)
        if let memo = hasUnknownSourceMemos[memoKey] { return memo }
        let customs = settings.customCategories ?? []
        let value = entries.contains {
            (includeSecrets || !$0.isSecret)
                && $0.sourceApplication == nil
                && $0.matches(key: key, customCategories: customs)
        }
        if hasUnknownSourceMemos.count >= Self.sourceApplicationMemoEntryLimit {
            hasUnknownSourceMemos.removeAll(keepingCapacity: true)
        }
        hasUnknownSourceMemos[memoKey] = value
        return value
    }

    private func sourceFilterMemoKey(
        key: ClipboardCategoryKey?,
        includeSecrets: Bool
    ) -> String {
        "\(includeSecrets ? 1 : 0)|\(key?.storageValue ?? "*")"
    }

    /// Returns plaintext for an already-authorized UI projection without
    /// changing the persisted entry. The caller owns the unlock check and must
    /// discard the result as soon as the protected surface closes or re-locks.
    public func plaintextForUnlockedDisplay(_ entry: ClipboardEntry) -> String? {
        guard entry.isSecret, let ciphertext = entry.text else {
            return nil
        }
        return try? SecretVault.decrypt(ciphertext)
    }

    @discardableResult
    public func addText(_ text: String, sourceApp: String? = nil) -> Bool {
        addText(
            text,
            source: sourceApp.map {
                ClipboardSourceApplication(bundleIdentifier: nil, displayName: $0)
            }
        )
    }

    @discardableResult
    public func addText(_ text: String, source: ClipboardSourceApplication?) -> Bool {
        let source = metadataStringInterner.canonicalize(source)
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return false }
        guard text.utf8.count <= Self.maxTextByteCount else { return false }
        let hash = Data(cleaned.utf8).clipboardContentHash
        let entry = ClipboardEntry(
            kind: .text,
            text: text,
            contentHash: hash,
            sourceApp: source?.displayName,
            sourceBundleIdentifier: source?.bundleIdentifier,
            sourceBundleURLPath: source?.bundleURLPath
        )
        guard shouldRecord(entry) else { return false }
        if promoteExistingEntry(
            contentHash: hash,
            source: source,
            replacementOriginalFormats: [],
            replacesOriginalFormats: true
        ) {
            persist()
            return false
        }
        entries.append(entry)
        let deletedIDs = trimToLimit()
        persistAppendedEntry(entry, deletedIDs: deletedIDs)
        return true
    }

    /// Stores plain text for search/preview and keeps supported original
    /// representations in repository sidecars for lossless copying later.
    @discardableResult
    public func addRichText(
        _ payload: ClipboardRichTextPayload,
        source: ClipboardSourceApplication?
    ) throws -> Bool {
        let source = metadataStringInterner.canonicalize(source)
        let text = payload.plainText
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return false }
        guard text.utf8.count <= Self.maxTextByteCount else { return false }
        guard !payload.formats.isEmpty else { return addText(text, source: source) }
        var totalFormatByteCount = 0
        for format in payload.formats {
            guard ClipboardRichTextPayload.supports(typeIdentifier: format.typeIdentifier) else {
                throw ClipboardRichTextError.unsupportedRepresentation(format.typeIdentifier)
            }
            let (newTotal, overflow) = totalFormatByteCount.addingReportingOverflow(format.data.count)
            guard !overflow, newTotal <= ClipboardRichTextPayload.maxOriginalFormatByteCount else {
                throw ClipboardRichTextError.originalFormatsTooLarge(newTotal)
            }
            totalFormatByteCount = newTotal
        }

        let hash = Data(cleaned.utf8).clipboardContentHash
        var entry = ClipboardEntry(
            kind: .text,
            text: text,
            contentHash: hash,
            sourceApp: source?.displayName,
            sourceBundleIdentifier: source?.bundleIdentifier,
            sourceBundleURLPath: source?.bundleURLPath
        )
        guard shouldRecord(entry) else { return false }
        entry.originalFormats = try repository.saveOriginalFormats(payload.formats)
        entry = metadataStringInterner.canonicalize(entry)

        if promoteExistingEntry(
            contentHash: hash,
            source: source,
            replacementOriginalFormats: entry.originalFormats,
            replacesOriginalFormats: true
        ) {
            persist()
            return false
        }
        entries.append(entry)
        let deletedIDs = trimToLimit()
        persistAppendedEntry(entry, deletedIDs: deletedIDs)
        return true
    }

    /// Records a concealed copy as an encrypted 密码 entry.
    ///
    /// The stored `text` is ciphertext, so the on-disk history never contains
    /// the secret in the clear. The content hash is taken over the *plaintext*
    /// so re-copying the same password still de-duplicates — hashing the
    /// ciphertext would defeat that, since AES-GCM uses a fresh nonce each time.
    @discardableResult
    public func addPassword(_ secret: String, sourceApp: String? = nil) -> Bool {
        addPassword(
            secret,
            source: sourceApp.map {
                ClipboardSourceApplication(bundleIdentifier: nil, displayName: $0)
            }
        )
    }

    @discardableResult
    public func addPassword(_ secret: String, source: ClipboardSourceApplication?) -> Bool {
        let source = metadataStringInterner.canonicalize(source)
        guard !secret.isEmpty, secret.utf8.count <= Self.maxTextByteCount else { return false }
        let hash = Data(secret.utf8).clipboardContentHash
        let candidate = ClipboardEntry(
            kind: .text,
            contentHash: hash,
            sourceApp: source?.displayName,
            sourceBundleIdentifier: source?.bundleIdentifier,
            sourceBundleURLPath: source?.bundleURLPath,
            origin: .concealedPassword
        )
        guard shouldRecord(candidate) else { return false }
        if promoteExistingEntry(contentHash: hash, source: source, isSecret: true) {
            persist()
            return false
        }
        guard let ciphertext = try? SecretVault.encrypt(secret) else {
            lastError = L10n.text("无法加密密码，已跳过记录。")
            return false
        }
        let entry = ClipboardEntry(
            kind: .text,
            text: ciphertext,
            contentHash: hash,
            sourceApp: source?.displayName,
            sourceBundleIdentifier: source?.bundleIdentifier,
            sourceBundleURLPath: source?.bundleURLPath,
            origin: .concealedPassword
        )
        entries.append(entry)
        let deletedIDs = trimToLimit()
        persistAppendedEntry(entry, deletedIDs: deletedIDs)
        return true
    }

    @discardableResult
    public func addImage(
        _ image: NSImage,
        note: String? = nil,
        sourceApp: String? = nil,
        origin: ClipboardEntryOrigin? = nil
    ) -> Bool {
        guard let data = image.pngData else { return false }
        return addImageData(ImageAssetData(data: data, fileExtension: "png"), note: note, sourceApp: sourceApp, origin: origin)
    }

    @discardableResult
    public func addImageData(
        _ payload: ImageAssetData,
        note: String? = nil,
        sourceApp: String? = nil,
        origin: ClipboardEntryOrigin? = nil
    ) -> Bool {
        addImageData(
            payload,
            note: note,
            source: sourceApp.map {
                ClipboardSourceApplication(bundleIdentifier: nil, displayName: $0)
            },
            origin: origin
        )
    }

    @discardableResult
    public func addImageData(
        _ payload: ImageAssetData,
        note: String? = nil,
        source: ClipboardSourceApplication?,
        origin: ClipboardEntryOrigin? = nil
    ) -> Bool {
        let source = metadataStringInterner.canonicalize(source)
        guard settings.savesImages else { return false }
        guard payload.data.count <= Self.maxImageByteCount else { return false }
        do {
            let candidate = ClipboardEntry(
                kind: .image,
                text: note,
                contentHash: payload.data.clipboardContentHash,
                sourceApp: source?.displayName,
                sourceBundleIdentifier: source?.bundleIdentifier,
                sourceBundleURLPath: source?.bundleURLPath,
                origin: origin
            )
            guard shouldRecord(candidate) else { return false }
            if promoteExistingEntry(contentHash: candidate.contentHash, source: source) {
                persist()
                return false
            }
            let stored = try repository.saveImageData(
                payload.data,
                fileExtension: payload.fileExtension,
                precomputedContentHash: candidate.contentHash
            )
            let entry = ClipboardEntry(
                kind: .image,
                text: note,
                imageFileName: stored.fileName,
                contentHash: stored.contentHash,
                sourceApp: source?.displayName,
                sourceBundleIdentifier: source?.bundleIdentifier,
                sourceBundleURLPath: source?.bundleURLPath,
                origin: origin
            )
            entries.append(entry)
            let deletedIDs = trimToLimit()
            persistAppendedEntry(entry, deletedIDs: deletedIDs)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Records images created by HedgeMemo's screenshot flow separately from
    /// images copied by other apps, then consumes the pasteboard change so the
    /// monitor cannot add a duplicate to the generic 图片 category.
    @discardableResult
    public func recordScreenshot(_ payload: ImageAssetData) -> Bool {
        let changeCount = NSPasteboard.general.changeCount
        observedChangeCount = changeCount
        suppressedChangeCount = changeCount
        return addImageData(payload, source: .hedgeMemo, origin: .hedgeMemoScreenshot)
    }

    /// Marks the pasteboard's current change as one the app made itself (e.g. a
    /// meme click that puts an image on the system clipboard to paste). The next
    /// poll then treats it as already handled instead of recording it back into
    /// the history, so pasting a meme never pollutes the clipboard list. Call
    /// this immediately after the app's own pasteboard write.
    public func suppressCurrentPasteboardChange() {
        let changeCount = NSPasteboard.general.changeCount
        observedChangeCount = changeCount
        suppressedChangeCount = changeCount
    }

    public func delete(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let removed = entries.remove(at: index)
        setPasteQueueIDs(settings.resolvedPasteQueueEntryIDs.filter { $0 != id })
        removeBackingAssets(removed)
        normalizePinOrders()
        persist()
    }

    public func clearHistory() {
        let removed = entries
        entries.removeAll()
        setPasteQueueIDs([])
        for entry in removed { removeBackingAssets(entry) }
        persist()
    }

    /// Number of unique entries covered by a set of categories. Custom regex
    /// categories may overlap built-ins or one another, so entries are counted
    /// once even when several selected keys match them.
    public func entryCount(matching keys: Set<ClipboardCategoryKey>) -> Int {
        guard !keys.isEmpty else { return 0 }
        let customs = settings.customCategories ?? []
        return entries.lazy.filter { entry in
            keys.contains { entry.matches(key: $0, customCategories: customs) }
        }.count
    }

    /// Clears only entries matched by at least one selected category, including
    /// backing image files. Category configuration and enabled state are kept.
    public func clearHistory(matching keys: Set<ClipboardCategoryKey>) {
        guard !keys.isEmpty else { return }
        let customs = settings.customCategories ?? []
        let removed = entries.filter { entry in
            keys.contains { entry.matches(key: $0, customCategories: customs) }
        }
        guard !removed.isEmpty else { return }
        let removedIDs = Set(removed.map(\.id))
        entries.removeAll { removedIDs.contains($0.id) }
        setPasteQueueIDs(settings.resolvedPasteQueueEntryIDs.filter {
            !removedIDs.contains($0)
        })
        for entry in removed { removeBackingAssets(entry) }
        normalizePinOrders()
        persist()
    }

    /// The snapshot handed to ZIP export. Password entries are deliberately
    /// excluded: their ciphertext is bound to a content key that lives in this
    /// Mac's keychain, so exporting them would only ever produce data no machine
    /// (including this one, after a keychain reset) could decrypt — while still
    /// shipping the user's secrets off the device.
    public func snapshot() -> ClipboardHistorySnapshot {
        let exportedEntries = entries.filter { !$0.isSecret }
        let exportedIDs = Set(exportedEntries.map(\.id))
        var exportedSettings = settings
        exportedSettings.pasteQueueEntryIDs = settings.resolvedPasteQueueEntryIDs.filter {
            exportedIDs.contains($0)
        }
        return ClipboardHistorySnapshot(entries: exportedEntries, settings: exportedSettings)
    }

    /// The full in-memory state, secrets included. Only persistence uses this.
    private func persistableSnapshot() -> ClipboardHistorySnapshot {
        ClipboardHistorySnapshot(entries: entries, settings: settings)
    }

    /// Appends first-run guidance entries the caller has already ordered and
    /// timestamped, then persists. Only first-install seeding uses this; it is
    /// deliberately separate from `addText`, which timestamps with `.now` and
    /// merges consecutive duplicates.
    public func addSeedEntries(_ seedEntries: [ClipboardEntry]) {
        guard !seedEntries.isEmpty else { return }
        entries.reserveCapacity(entries.count + seedEntries.count)
        for entry in seedEntries {
            entries.append(metadataStringInterner.canonicalize(entry))
        }
        _ = collapsePersistedDuplicates()
        trimToLimit()
        persist()
    }

    /// Archive import deliberately reuses the ordinary storage path so imported
    /// image assets are re-hashed and never overwrite an existing clipboard file.
    public func importArchive(
        _ snapshot: ClipboardHistorySnapshot,
        imagesURL: URL,
        originalFormatsURL: URL
    ) throws {
        try importArchive(
            imagesURL: imagesURL,
            originalFormatsURL: originalFormatsURL
        ) { consume in
            for entry in snapshot.entries { try consume(entry) }
        }
    }

    /// Streams archive entries into a local batch while reusing the ordinary
    /// validation and exact de-duplication semantics. The observable history
    /// is published once, after every record and sidecar has been validated.
    public func importArchive(
        imagesURL: URL,
        originalFormatsURL: URL,
        enumerateEntries: (
            _ consume: (ClipboardEntry) throws -> Void
        ) throws -> Void
    ) throws {
        var nextSequence = Int64(entries.count)
        var nextGeneration = Int64(entries.count)
        var slots = entries.enumerated().map { index, entry in
            Optional.some(
                ArchiveImportSlot(
                    entry: entry,
                    sequence: Int64(index),
                    generation: Int64(index)
                )
            )
        }
        var freeSlotIndices: [Int] = []
        var liveMetadataCount = entries.count
        var liveRemovableCount = entries.reduce(into: 0) { count, entry in
            if Self.isArchiveImportRemovable(entry) { count += 1 }
        }
        var trimHeap = ArchiveTrimHeap()
        for (slotIndex, slot) in slots.enumerated() {
            guard let slot,
                  Self.isArchiveImportRemovable(slot.entry) else { continue }
            trimHeap.insert(
                ArchiveTrimNode(
                    createdAt: slot.entry.createdAt,
                    sequence: slot.sequence,
                    slotIndex: slotIndex,
                    generation: slot.generation
                )
            )
        }
        var peakLiveMetadataCount = liveMetadataCount
        var peakSlotCount = slots.count
        var peakTrimHeapNodeCount = trimHeap.count
        let hashIndex = try FileBackedHashIndex(
            existingHashes: EmptyCollection<String>()
        )
        lastArchiveImportStagingURL = hashIndex.storageURL
        for (index, slot) in slots.enumerated() {
            guard let slot else { continue }
            let key = Self.archiveDedupKey(for: slot.entry)
            _ = try hashIndex.insertIfNew(key)
            try hashIndex.setPosition(index, for: key)
        }
        let seededHashCount = hashIndex.storedHashCount
        let stagingTextProvider = hashIndex.makeTextProvider()
        var candidateHashCount = 0
        var appliedRecordCount = 0
        var entriesPublicationCount = 0
        var createdImageFileNames = Set<String>()
        var createdFormatsByName: [String: ClipboardOriginalFormat] = [:]
        var originalImageFilesPendingDeletion = Set<String>()
        var originalFormatsPendingDeletion:
            [String: ClipboardOriginalFormat] = [:]

        defer {
            lastArchiveImportMetrics = ArchiveImportMetrics(
                seededHashCount: seededHashCount,
                candidateHashCount: candidateHashCount,
                appliedRecordCount: appliedRecordCount,
                peakResidentHashCount: hashIndex.peakResidentHashCount,
                peakResidentHashKeyByteCount:
                    hashIndex.peakResidentKeyByteCount,
                hashIndexCacheSizeKiB:
                    hashIndex.configuredCacheSizeKiB,
                hashIndexMmapSizeBytes:
                    hashIndex.configuredMmapSizeBytes,
                peakIndexedHashCount: hashIndex.peakStoredHashCount,
                entriesPublicationCount: entriesPublicationCount,
                stagedTextBodyCount: hashIndex.stagedTextBodyCount,
                peakResidentTextBodyCount:
                    hashIndex.peakResidentTextBodyCount,
                peakLiveMetadataCount: peakLiveMetadataCount,
                peakSlotCount: peakSlotCount,
                peakTrimHeapNodeCount: peakTrimHeapNodeCount
            )
        }

        func recordHeapPeak() {
            peakTrimHeapNodeCount = max(
                peakTrimHeapNodeCount,
                trimHeap.count
            )
        }

        func addToTrimHeap(
            slotIndex: Int,
            slot: ArchiveImportSlot
        ) {
            guard Self.isArchiveImportRemovable(slot.entry) else { return }
            trimHeap.insert(
                ArchiveTrimNode(
                    createdAt: slot.entry.createdAt,
                    sequence: slot.sequence,
                    slotIndex: slotIndex,
                    generation: slot.generation
                )
            )
            recordHeapPeak()
        }

        func rebuildTrimHeapIfNeeded() {
            let threshold = max(64, liveRemovableCount * 2 + 32)
            guard trimHeap.count > threshold else { return }
            var rebuilt = ArchiveTrimHeap()
            for (slotIndex, slot) in slots.enumerated() {
                guard let slot,
                      Self.isArchiveImportRemovable(slot.entry) else {
                    continue
                }
                rebuilt.insert(
                    ArchiveTrimNode(
                        createdAt: slot.entry.createdAt,
                        sequence: slot.sequence,
                        slotIndex: slotIndex,
                        generation: slot.generation
                    )
                )
            }
            trimHeap = rebuilt
        }

        func retireAssets(
            of discarded: ClipboardEntry,
            retaining retained: ClipboardEntry? = nil
        ) throws {
            if let fileName = discarded.imageFileName,
               fileName != retained?.imageFileName {
                if createdImageFileNames.contains(fileName) {
                    try repository.removeImage(named: fileName)
                    createdImageFileNames.remove(fileName)
                } else {
                    originalImageFilesPendingDeletion.insert(fileName)
                }
            }

            let retainedFormats = retained?.originalFormats ?? []
            for format in discarded.originalFormats ?? []
            where !retainedFormats.contains(where: {
                $0.fileName == format.fileName
            }) {
                if createdFormatsByName[format.fileName] != nil {
                    try repository.removeOriginalFormats([format])
                    createdFormatsByName.removeValue(forKey: format.fileName)
                } else {
                    originalFormatsPendingDeletion[format.fileName] = format
                }
            }
        }

        func popOldestLiveRemovable() -> ArchiveTrimNode? {
            while let node = trimHeap.popFirst() {
                guard slots.indices.contains(node.slotIndex),
                      let slot = slots[node.slotIndex],
                      slot.generation == node.generation,
                      Self.isArchiveImportRemovable(slot.entry) else {
                    continue
                }
                return node
            }
            return nil
        }

        func trimToBoundIfNeeded() throws {
            while liveMetadataCount > settings.maxEntries,
                  let node = popOldestLiveRemovable(),
                  let slot = slots[node.slotIndex] {
                let key = Self.archiveDedupKey(for: slot.entry)
                try hashIndex.remove(key)
                try hashIndex.removeStagedText(for: slot.entry.id)
                try retireAssets(of: slot.entry)
                slots[node.slotIndex] = nil
                freeSlotIndices.append(node.slotIndex)
                liveMetadataCount -= 1
                liveRemovableCount -= 1
            }
            rebuildTrimHeapIfNeeded()
        }

        func append(_ entry: ClipboardEntry, key: Data) throws {
            let slotIndex = freeSlotIndices.last ?? slots.count
            guard try hashIndex.insertIfNew(key) else {
                throw ClipboardHistoryDatabaseError.execute(
                    "临时导入索引出现重复定位"
                )
            }
            do {
                try hashIndex.setPosition(slotIndex, for: key)
            } catch {
                try? hashIndex.remove(key)
                throw error
            }
            let slot = ArchiveImportSlot(
                entry: entry,
                sequence: nextSequence,
                generation: nextGeneration
            )
            nextSequence += 1
            nextGeneration += 1
            if let reusedIndex = freeSlotIndices.popLast() {
                slots[reusedIndex] = slot
            } else {
                slots.append(slot)
            }
            liveMetadataCount += 1
            if Self.isArchiveImportRemovable(entry) {
                liveRemovableCount += 1
                addToTrimHeap(slotIndex: slotIndex, slot: slot)
            }
            peakLiveMetadataCount = max(
                peakLiveMetadataCount,
                liveMetadataCount
            )
            peakSlotCount = max(peakSlotCount, slots.count)
            appliedRecordCount += 1
            try trimToBoundIfNeeded()
        }

        func promote(
            key: Data,
            source: ClipboardSourceApplication?,
            replacementOriginalFormats: [ClipboardOriginalFormat]? = nil,
            replacesOriginalFormats: Bool = false
        ) throws -> Bool {
            guard let slotIndex = try hashIndex.position(for: key),
                  slots.indices.contains(slotIndex),
                  let existingSlot = slots[slotIndex] else {
                return false
            }
            let discarded = existingSlot.entry
            var current = discarded
            current.createdAt = .now
            current.updatedAt = current.createdAt
            if let source {
                current.sourceApp = source.displayName
                current.sourceBundleIdentifier = source.bundleIdentifier
                current.sourceBundleURLPath = source.bundleURLPath
            }
            if replacesOriginalFormats {
                current.originalFormats = replacementOriginalFormats ?? []
            }
            try retireAssets(of: discarded, retaining: current)
            let promoted = ArchiveImportSlot(
                entry: current,
                sequence: nextSequence,
                generation: nextGeneration
            )
            nextSequence += 1
            nextGeneration += 1
            slots[slotIndex] = promoted
            addToTrimHeap(slotIndex: slotIndex, slot: promoted)
            rebuildTrimHeapIfNeeded()
            appliedRecordCount += 1
            return true
        }

        func stageText(
            _ text: String?,
            in entry: ClipboardEntry
        ) throws -> ClipboardEntry {
            guard let text else { return entry }
            let automaticCategory = entry.automaticContentCategory
            try hashIndex.stageText(text, for: entry.id)
            var deferred = entry
            deferred.deferText(
                to: stagingTextProvider,
                automaticCategory: automaticCategory
            )
            return deferred
        }

        func rollbackCreatedAssets() {
            for fileName in createdImageFileNames {
                try? repository.removeImage(named: fileName)
            }
            try? repository.removeOriginalFormats(
                Array(createdFormatsByName.values)
            )
        }

        do {
            try enumerateEntries { entry in
                // Export strips secrets, so any here came from a hand-made archive.
                // Importing one would drop its origin and surface the ciphertext as
                // an ordinary readable entry.
                guard !entry.isSecret else { return }
                let source = entry.sourceApplication
                switch entry.kind {
                case .text:
                    let text = entry.text ?? ""
                    let cleaned = text.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    guard !cleaned.isEmpty,
                          text.utf8.count <= Self.maxTextByteCount else {
                        return
                    }
                    let hash = Data(cleaned.utf8).clipboardContentHash
                    var candidate = ClipboardEntry(
                        kind: .text,
                        text: text,
                        contentHash: hash,
                        sourceApp: source?.displayName,
                        sourceBundleIdentifier: source?.bundleIdentifier,
                        sourceBundleURLPath: source?.bundleURLPath
                    )
                    guard shouldRecord(candidate) else { return }
                    candidateHashCount += 1
                    let key = Self.archiveDedupKey(for: candidate)
                    let formats = try (entry.originalFormats ?? []).map { format -> ClipboardFormatData in
                        guard let url = MemeArchiveService.safeContainedURL(
                            base: originalFormatsURL,
                            fileName: format.fileName
                        ) else {
                            throw ClipboardRichTextError.unsafeStoredFileName(format.fileName)
                        }
                        return ClipboardFormatData(
                            typeIdentifier: format.typeIdentifier,
                            data: try Data(contentsOf: url)
                        )
                    }
                    if formats.isEmpty {
                        if try !promote(
                            key: key,
                            source: source,
                            replacementOriginalFormats: [],
                            replacesOriginalFormats: true
                        ) {
                            try append(
                                try stageText(text, in: candidate),
                                key: key
                            )
                        }
                    } else {
                        var totalFormatByteCount = 0
                        for format in formats {
                            guard ClipboardRichTextPayload.supports(
                                typeIdentifier: format.typeIdentifier
                            ) else {
                                throw ClipboardRichTextError
                                    .unsupportedRepresentation(
                                        format.typeIdentifier
                                    )
                            }
                            let (newTotal, overflow) =
                                totalFormatByteCount.addingReportingOverflow(
                                    format.data.count
                                )
                            guard !overflow,
                                  newTotal <= ClipboardRichTextPayload
                                    .maxOriginalFormatByteCount else {
                                throw ClipboardRichTextError
                                    .originalFormatsTooLarge(newTotal)
                            }
                            totalFormatByteCount = newTotal
                        }
                        let storedFormats = try repository.saveOriginalFormats(
                            formats
                        )
                        for format in storedFormats {
                            createdFormatsByName[format.fileName] = format
                        }
                        candidate.originalFormats = storedFormats
                        if try !promote(
                            key: key,
                            source: source,
                            replacementOriginalFormats: storedFormats,
                            replacesOriginalFormats: true
                        ) {
                            try append(
                                try stageText(text, in: candidate),
                                key: key
                            )
                        }
                    }
                case .image:
                    guard settings.savesImages,
                          let fileName = entry.imageFileName,
                          let url = MemeArchiveService.safeContainedURL(
                            base: imagesURL,
                            fileName: fileName
                          ),
                          let payload = ImageAssetData(fileURL: url),
                          payload.data.count <= Self.maxImageByteCount else {
                        return
                    }
                    let hash = payload.data.clipboardContentHash
                    let note = entry.text
                    let candidate = ClipboardEntry(
                        kind: .image,
                        text: note,
                        contentHash: hash,
                        sourceApp: source?.displayName,
                        sourceBundleIdentifier: source?.bundleIdentifier,
                        sourceBundleURLPath: source?.bundleURLPath,
                        origin: entry.origin
                    )
                    guard shouldRecord(candidate) else { return }
                    candidateHashCount += 1
                    let key = Self.archiveDedupKey(for: candidate)
                    if try promote(key: key, source: source) { return }
                    let stored: StoredImage
                    do {
                        stored = try repository.saveImageData(
                            payload.data,
                            fileExtension: payload.fileExtension,
                            precomputedContentHash: hash
                        )
                    } catch {
                        lastError = error.localizedDescription
                        return
                    }
                    createdImageFileNames.insert(stored.fileName)
                    let imported = ClipboardEntry(
                        kind: .image,
                        text: note,
                        imageFileName: stored.fileName,
                        contentHash: stored.contentHash,
                        sourceApp: source?.displayName,
                        sourceBundleIdentifier: source?.bundleIdentifier,
                        sourceBundleURLPath: source?.bundleURLPath,
                        origin: entry.origin
                    )
                    var stagedTextID: UUID?
                    do {
                        let staged = try stageText(note, in: imported)
                        if note != nil { stagedTextID = imported.id }
                        try append(staged, key: key)
                    } catch {
                        try? repository.removeImage(named: stored.fileName)
                        createdImageFileNames.remove(stored.fileName)
                        if let id = stagedTextID {
                            try? hashIndex.removeStagedText(for: id)
                        }
                        throw error
                    }
                }
            }
        } catch {
            rollbackCreatedAssets()
            throw error
        }

        guard appliedRecordCount > 0 else { return }
        var orderedSlotIndices = slots.indices.filter { slots[$0] != nil }
        orderedSlotIndices.sort { lhs, rhs in
            guard let left = slots[lhs], let right = slots[rhs] else {
                return lhs < rhs
            }
            return left.sequence < right.sequence
        }
        var publishedEntries: [ClipboardEntry] = []
        publishedEntries.reserveCapacity(liveMetadataCount)
        for slotIndex in orderedSlotIndices {
            if let slot = slots[slotIndex] {
                publishedEntries.append(slot.entry)
            }
        }
        Self.normalizeArchivePinOrders(&publishedEntries)

        let retainedIDs = Set(publishedEntries.map(\.id))
        var importedSettings = settings
        importedSettings.pasteQueueEntryIDs =
            settings.resolvedPasteQueueEntryIDs.filter(retainedIDs.contains)

        do {
            isApplyingArchiveImport = true
            defer { isApplyingArchiveImport = false }
            // `publishedEntries` is the archive's sole final metadata array.
            // Canonicalize it in place so source sharing does not reintroduce
            // a second whole-library peak at publication.
            metadataStringInterner.canonicalizeInPlace(&publishedEntries)
            entries = publishedEntries
            if importedSettings != settings {
                settings = importedSettings
            }
        }
        entriesPublicationCount = 1
        // Publication now owns the only complete Swift metadata array needed
        // beyond this point. Release scratch slots, free-list capacity and
        // stale heap nodes before asset reconciliation and snapshot encoding.
        slots.removeAll(keepingCapacity: false)
        freeSlotIndices.removeAll(keepingCapacity: false)
        orderedSlotIndices.removeAll(keepingCapacity: false)
        trimHeap = ArchiveTrimHeap()

        let retainedImages = Set(publishedEntries.compactMap(\.imageFileName))
        let retainedFormats = Set(
            publishedEntries.flatMap {
                ($0.originalFormats ?? []).map(\.fileName)
            }
        )
        for fileName in createdImageFileNames
        where !retainedImages.contains(fileName) {
            try? repository.removeImage(named: fileName)
        }
        try? repository.removeOriginalFormats(
            createdFormatsByName.values.filter {
                !retainedFormats.contains($0.fileName)
            }
        )
        for fileName in originalImageFilesPendingDeletion
        where !retainedImages.contains(fileName) {
            try? repository.removeImage(named: fileName)
        }
        try? repository.removeOriginalFormats(
            originalFormatsPendingDeletion.values.filter {
                !retainedFormats.contains($0.fileName)
            }
        )
        persist()
    }

    /// Disabling a category is destructive by design: its current entries are
    /// removed from disk and it will no longer collect matching clipboard data.
    public func setCategory(_ key: ClipboardCategoryKey, enabled: Bool) {
        guard settings.isCategoryEnabled(key) != enabled else { return }
        if !enabled {
            clearEntries(matching: key)
            settingsMutationRequiresSnapshot = true
        }
        settings.setCategory(key, enabled: enabled)
        if !settings.isCategoryEnabled(settings.activeCategoryKey) {
            settings.activeCategoryKey = settings.enabledCategoryKeys.first ?? .builtin(.text)
        }
    }

    public func togglePinned(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        if entries[index].isPinned {
            entries[index].isPinned = false
            entries[index].pinnedOrder = nil
        } else {
            let nextOrder = (entries.compactMap(\.pinnedOrder).max() ?? -1) + 1
            entries[index].isPinned = true
            entries[index].pinnedOrder = nextOrder
        }
        entries[index].updatedAt = .now
        normalizePinOrders()
        persist()
    }

    public func toggleDesktopPinned(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        // A desktop note is permanently visible and has no gate of its own, so
        // pinning a secret would place it on screen forever — the exact thing
        // the 密码 lock exists to prevent. (It would also render ciphertext,
        // since a note shows the stored text verbatim.) Un-pinning stays
        // allowed so an entry pinned by an older build can still be cleared.
        if entries[index].isSecret, entries[index].isDesktopPinned != true { return }
        if entries[index].isDesktopPinned == true {
            entries[index].isDesktopPinned = false
            entries[index].desktopPinnedOrder = nil
        } else {
            let nextOrder = (entries.compactMap(\.desktopPinnedOrder).max() ?? -1) + 1
            entries[index].isDesktopPinned = true
            entries[index].desktopPinnedOrder = nextOrder
        }
        entries[index].updatedAt = .now
        _ = normalizeDesktopPinnedOrders()
        persist()
    }

    /// Applies an in-place edit to a text-kind entry's content. The content
    /// hash is recomputed so later dedup/merge checks see the edited text, not
    /// the one originally captured. Image entries are left untouched — they
    /// have no editable text body.
    public func updateText(id: UUID, text: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].kind == .text else { return }
        // A secret is stored encrypted and never shown, so there is nothing
        // meaningful to edit — and writing the draft back would replace the
        // ciphertext with plain text.
        guard !entries[index].isSecret else { return }
        let obsoleteFormats = entries[index].originalFormats ?? []
        entries[index].text = text
        entries[index].contentHash = Data(text.utf8).clipboardContentHash
        entries[index].originalFormats = []
        entries[index].updatedAt = .now
        do { try repository.removeOriginalFormats(obsoleteFormats) }
        catch { lastError = error.localizedDescription }
        _ = collapsePersistedDuplicates()
        persist()
    }

    /// Applies or clears a user-selected category. The entry itself remains the
    /// same persisted item. Moving text into or out of 密码 also converts its
    /// persisted representation so that category never stores readable text.
    @discardableResult
    public func setManualCategory(id: UUID, key: ClipboardCategoryKey?) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        let original = entries[index]
        if let key {
            guard settings.isCategoryEnabled(key), original.supportsManualCategory(key) else {
                return false
            }
            if case .custom(let customID) = key {
                guard settings.customCategory(id: customID) != nil else { return false }
            }
        }

        let movesToPassword = key == .builtin(.password)
        let changesSecrecy = original.isSecret != movesToPassword && key != nil
        guard original.manualCategoryKey != key || changesSecrecy else { return false }

        var updated = original
        var obsoleteFormats: [ClipboardOriginalFormat] = []
        if movesToPassword, !original.isSecret {
            guard let plaintext = original.text,
                  let ciphertext = try? SecretVault.encrypt(plaintext) else {
                lastError = L10n.text("无法加密密码，已跳过记录。")
                return false
            }
            updated.text = ciphertext
            updated.origin = .concealedPassword
            obsoleteFormats = updated.originalFormats ?? []
            updated.originalFormats = []
        } else if original.isSecret, let key, key != .builtin(.password) {
            guard let ciphertext = original.text,
                  let plaintext = try? SecretVault.decrypt(ciphertext) else {
                lastError = L10n.text("无法解密密码。")
                return false
            }
            updated.text = plaintext
            updated.origin = nil
        }
        updated.manualCategoryStorageValue = metadataStringInterner.canonicalizeMetadata(
            key?.storageValue
        )
        updated.updatedAt = .now
        entries[index] = updated
        do { try repository.removeOriginalFormats(obsoleteFormats) }
        catch { lastError = error.localizedDescription }

        // `@Published` announces in willSet. A SwiftUI subscriber can therefore
        // ask for an already-memoized target category before `entries.didSet`
        // clears the cache, then receive no later invalidation. Publish once
        // more after both the new value and the cleared cache are observable.
        objectWillChange.send()
        persist()
        return true
    }

    @discardableResult
    public func copyToPasteboard(
        _ entry: ClipboardEntry,
        to pasteboard: NSPasteboard = .general,
        autoPaste: Bool = false
    ) -> Bool {
        do {
            try writeToPasteboard(entry, pasteboard: pasteboard)
        } catch {
            lastError = error.localizedDescription
            return false
        }
        finishPasteboardWrite(entry: entry, pasteboard: pasteboard, autoPaste: autoPaste)
        return true
    }

    public var pasteQueueCount: Int {
        validPasteQueueIDs.count
    }

    public func pasteQueuePosition(of id: UUID) -> Int? {
        validPasteQueueIDs.firstIndex(of: id).map { $0 + 1 }
    }

    @discardableResult
    public func enqueueForPaste(id: UUID) throws -> Int {
        guard entries.contains(where: { $0.id == id }) else {
            return try failQueue(.entryNotFound)
        }
        var ids = validPasteQueueIDs
        if let existing = ids.firstIndex(of: id) { return existing + 1 }
        ids.append(id)
        settings.pasteQueueEntryIDs = ids
        return ids.count
    }

    public func removeFromPasteQueue(id: UUID) {
        setPasteQueueIDs(validPasteQueueIDs.filter { $0 != id })
    }

    public func clearPasteQueue() {
        setPasteQueueIDs([])
    }

    /// Copies and removes exactly the first queued item. A failed write or a
    /// locked secret remains at the head so FIFO order is never silently lost.
    @discardableResult
    public func pasteNextQueued(
        to pasteboard: NSPasteboard = .general,
        autoPaste: Bool = false,
        allowsProtectedEntries: Bool = false
    ) throws -> ClipboardEntry {
        let ids = validPasteQueueIDs
        guard let id = ids.first else { return try failQueue(.queueEmpty) }
        guard let entry = entries.first(where: { $0.id == id }) else {
            return try failQueue(.entryNotFound)
        }
        guard !entry.isSecret || allowsProtectedEntries else {
            return try failQueue(.protectedEntryLocked)
        }
        do {
            try writeToPasteboard(entry, pasteboard: pasteboard)
        } catch {
            lastError = error.localizedDescription
            throw error
        }
        setPasteQueueIDs(Array(ids.dropFirst()))
        finishPasteboardWrite(entry: entry, pasteboard: pasteboard, autoPaste: autoPaste)
        return entry
    }

    private var validPasteQueueIDs: [UUID] {
        if let memo = validPasteQueueMemo { return memo }
        let queued = settings.resolvedPasteQueueEntryIDs
        // The common case is an empty queue, which must not walk the history.
        guard !queued.isEmpty else {
            validPasteQueueMemo = []
            return []
        }
        let existing = Set(entries.map(\.id))
        let resolved = queued.filter { existing.contains($0) }
        validPasteQueueMemo = resolved
        return resolved
    }

    /// Writes the queue back only when it actually changes.
    ///
    /// `settings` is `@Published`, and its `didSet` re-normalizes, re-validates
    /// and persists the whole snapshot. Several maintenance paths (trimming,
    /// deleting, clearing a category) used to assign an identical queue and
    /// trigger that entire cascade — including a second full snapshot write —
    /// on every clipboard capture once the history reached its limit.
    private func setPasteQueueIDs(_ ids: [UUID]) {
        guard ids != settings.resolvedPasteQueueEntryIDs else { return }
        settings.pasteQueueEntryIDs = ids
    }

    private func failQueue<T>(_ error: ClipboardPasteQueueError) throws -> T {
        lastError = error.localizedDescription
        throw error
    }

    private func writeToPasteboard(
        _ entry: ClipboardEntry,
        pasteboard: NSPasteboard
    ) throws {
        pasteboard.clearContents()
        switch entry.kind {
        case .text:
            if entry.isSecret {
                // Decrypt only at the moment of use, and re-declare the copy
                // concealed so other clipboard managers (and our own monitor)
                // treat it as a secret rather than as ordinary text.
                // UI projections may carry plaintext for display after unlock;
                // always resolve the original persisted ciphertext by ID so a
                // copy action never depends on that transient projection.
                guard let protectedText = entries.first(where: { $0.id == entry.id })?.text ?? entry.text else {
                    throw ClipboardPasteQueueError.pasteboardWriteFailed
                }
                let secret = try SecretVault.decrypt(protectedText)
                pasteboard.declareTypes(
                    [.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")],
                    owner: nil
                )
                guard pasteboard.setString(secret, forType: .string) else {
                    throw ClipboardPasteQueueError.pasteboardWriteFailed
                }
            } else {
                guard let text = entry.text else {
                    throw ClipboardPasteQueueError.pasteboardWriteFailed
                }
                let formats = try repository.loadOriginalFormats(for: entry)
                if formats.isEmpty {
                    guard pasteboard.setString(text, forType: .string) else {
                        throw ClipboardPasteQueueError.pasteboardWriteFailed
                    }
                } else {
                    try ClipboardRichTextPayload(plainText: text, formats: formats).write(to: pasteboard)
                }
            }
        case .image:
            guard let url = repository.imageURL(for: entry),
                  let payload = ImageAssetData(fileURL: url),
                  payload.write(to: pasteboard) else {
                throw ClipboardPasteQueueError.pasteboardWriteFailed
            }
        }
    }

    private func finishPasteboardWrite(
        entry: ClipboardEntry,
        pasteboard: NSPasteboard,
        autoPaste: Bool
    ) {
        suppressedChangeCount = pasteboard.changeCount
        observedChangeCount = pasteboard.changeCount
        markUsed(id: entry.id)
        if autoPaste { scheduleAutoPaste() }
    }

    /// Injecting ⌘V immediately would land in the still-open clipboard panel
    /// (a non-activating panel that holds key focus, e.g. its search field).
    /// Defer the keystroke so the panel's own dismissal can return focus to the
    /// app the user was in, which is where the paste belongs.
    private func scheduleAutoPaste() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.pasteIntoFocusedAppIfAllowed()
        }
    }

    private func markUsed(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].lastUsedAt = .now
        entries[index].useCount = (entries[index].useCount ?? 0) + 1
        persistCoalesced(entryID: id)
    }

    /// Re-copying content already held by HedgeMemo is a recency update, not a
    /// new history item. Explicit pin states remain intact; ordinary items move
    /// forward through the same creation-time ordering as a newly captured item.
    @discardableResult
    private func promoteExistingEntry(
        contentHash: String,
        source: ClipboardSourceApplication?,
        replacementOriginalFormats: [ClipboardOriginalFormat]? = nil,
        replacesOriginalFormats: Bool = false,
        isSecret: Bool = false,
        now: Date = .now
    ) -> Bool {
        // One indexed scan instead of filtering the history twice (once here,
        // once inside the replacement): this runs for every clipboard capture.
        let compactContentHash = CompactContentHash(contentHash)
        var matchedIndices: [Int] = []
        for (index, entry) in entries.enumerated()
        where entry.compactContentHash == compactContentHash
            && entry.isSecret == isSecret {
            matchedIndices.append(index)
        }
        guard !matchedIndices.isEmpty else { return false }
        var merged = mergedEntry(from: matchedIndices.map { entries[$0] })
        merged.createdAt = now
        merged.updatedAt = now
        if let source {
            merged.sourceApp = source.displayName
            merged.sourceBundleIdentifier = source.bundleIdentifier
            merged.sourceBundleURLPath = source.bundleURLPath
        }
        if replacesOriginalFormats {
            merged.originalFormats = replacementOriginalFormats ?? []
        }
        collapseGroups([(indices: matchedIndices, merged: merged)])
        // `normalizePinOrders` finishes with the desktop pass, so a second
        // explicit call only repeated a full scan of the history.
        normalizePinOrders()
        return true
    }

    /// Older snapshots can already contain non-consecutive duplicates. Collapse
    /// them once on load (and after edit/seed paths) without changing recency.
    @discardableResult
    private func collapsePersistedDuplicates() -> Bool {
        // Grouped by secrecy as well as content: an encrypted password and an
        // identical plain copy share a hash (the hash is over the plaintext),
        // and collapsing them together would drop the secret in favour of the
        // readable one.
        var indicesByKey: [DedupKey: [Int]] = [:]
        for (index, entry) in entries.enumerated() {
            indicesByKey[
                DedupKey(
                    hash: entry.compactContentHash,
                    isSecret: entry.isSecret
                ),
                default: []
            ]
                .append(index)
        }
        // Rewriting the array once per duplicate group made loading a history
        // that had accumulated duplicates quadratic. Merge every group first,
        // then rebuild the list in a single pass.
        let groups = indicesByKey.values
            .filter { $0.count > 1 }
            .sorted { ($0.last ?? 0) < ($1.last ?? 0) }
            .map { (indices: $0, merged: mergedEntry(from: $0.map { entries[$0] })) }
        guard !groups.isEmpty else { return false }
        collapseGroups(groups)
        normalizePinOrders()
        return true
    }

    /// Replaces each group of duplicate entries with its merged result.
    ///
    /// Merged entries move to the end of the list, which is where the previous
    /// remove-then-append implementation placed them; with several groups they
    /// now follow the order of the entries they replace instead of an arbitrary
    /// dictionary order.
    private func collapseGroups(_ groups: [(indices: [Int], merged: ClipboardEntry)]) {
        guard !groups.isEmpty else { return }
        var replacedIndices = Set<Int>()
        var replacementIDByReplacedID: [UUID: UUID] = [:]
        for group in groups {
            replacedIndices.formUnion(group.indices)
            let preservedFormats = Set((group.merged.originalFormats ?? []).map(\.fileName))
            for index in group.indices {
                let entry = entries[index]
                replacementIDByReplacedID[entry.id] = group.merged.id
                if entry.id != group.merged.id, entry.kind == .image,
                   let fileName = entry.imageFileName, fileName != group.merged.imageFileName {
                    do { try repository.removeImage(named: fileName) }
                    catch { lastError = error.localizedDescription }
                }
                let obsoleteFormats = (entry.originalFormats ?? []).filter {
                    !preservedFormats.contains($0.fileName)
                }
                do { try repository.removeOriginalFormats(obsoleteFormats) }
                catch { lastError = error.localizedDescription }
            }
        }

        var collapsed: [ClipboardEntry] = []
        collapsed.reserveCapacity(entries.count - replacedIndices.count + groups.count)
        for (index, entry) in entries.enumerated() where !replacedIndices.contains(index) {
            collapsed.append(entry)
        }
        collapsed.append(contentsOf: groups.map(\.merged))
        entries = collapsed

        let queue = settings.resolvedPasteQueueEntryIDs
        guard !queue.isEmpty else { return }
        var mergedQueue: [UUID] = []
        var seenQueueIDs = Set<UUID>()
        for id in queue {
            let resolvedID = replacementIDByReplacedID[id] ?? id
            if seenQueueIDs.insert(resolvedID).inserted { mergedQueue.append(resolvedID) }
        }
        setPasteQueueIDs(mergedQueue)
    }

    private struct DedupKey: Hashable {
        let hash: CompactContentHash
        let isSecret: Bool
    }

    private static func archiveDedupKey(for entry: ClipboardEntry) -> Data {
        entry.compactContentHash.archiveDedupKey(isSecret: entry.isSecret)
    }

    private static func isArchiveImportRemovable(
        _ entry: ClipboardEntry
    ) -> Bool {
        !entry.isPinned && entry.isDesktopPinned != true
    }

    /// Bulk import prepares the final value off to the side, so pin order can
    /// be compacted without publishing the library once per adjusted element.
    private static func normalizeArchivePinOrders(
        _ entries: inout [ClipboardEntry]
    ) {
        var pinnedIndices = entries.indices.filter { entries[$0].isPinned }
        pinnedIndices.sort { lhs, rhs in
            let left = entries[lhs].pinnedOrder ?? Int.max
            let right = entries[rhs].pinnedOrder ?? Int.max
            if left != right { return left < right }
            return entries[lhs].createdAt < entries[rhs].createdAt
        }
        for (order, index) in pinnedIndices.enumerated() {
            entries[index].pinnedOrder = order
        }

        var desktopIndices = entries.indices.filter {
            entries[$0].isDesktopPinned == true
        }
        desktopIndices.sort { lhs, rhs in
            let left = entries[lhs].desktopPinnedOrder ?? Int.max
            let right = entries[rhs].desktopPinnedOrder ?? Int.max
            if left != right { return left < right }
            if entries[lhs].updatedAt != entries[rhs].updatedAt {
                return entries[lhs].updatedAt < entries[rhs].updatedAt
            }
            return entries[lhs].createdAt < entries[rhs].createdAt
        }
        for (order, index) in desktopIndices.enumerated() {
            entries[index].desktopPinnedOrder = order
        }
    }

    private func mergedEntry(from matches: [ClipboardEntry]) -> ClipboardEntry {
        precondition(!matches.isEmpty)
        var merged = matches.max { $0.createdAt < $1.createdAt }!
        let pinned = matches.filter(\.isPinned)
        let desktopPinned = matches.filter { $0.isDesktopPinned == true }
        merged.isPinned = !pinned.isEmpty
        merged.pinnedOrder = pinned.compactMap(\.pinnedOrder).min()
        merged.isDesktopPinned = !desktopPinned.isEmpty
        merged.desktopPinnedOrder = desktopPinned.compactMap(\.desktopPinnedOrder).min()
        merged.lastUsedAt = matches.compactMap(\.lastUsedAt).max()
        let totalUseCount = matches.compactMap(\.useCount).reduce(0, +)
        merged.useCount = totalUseCount == 0 ? nil : totalUseCount
        return merged
    }

    @discardableResult
    private func normalizePasteQueueReferences() -> Bool {
        let normalized = validPasteQueueIDs
        guard normalized != settings.resolvedPasteQueueEntryIDs else { return false }
        settings.pasteQueueEntryIDs = normalized
        return true
    }

    @discardableResult
    public func copyPinned(number: Int, autoPaste: Bool = false) -> Bool {
        guard let entry = ClipboardHistoryPolicy.quickEntry(in: entries, number: number) else { return false }
        return copyToPasteboard(entry, autoPaste: autoPaste)
    }

    public func imageURL(for entry: ClipboardEntry) -> URL? { repository.imageURL(for: entry) }

    public func clearError() { lastError = nil }

    /// Classifies stored text ahead of time, off the main thread.
    ///
    /// Deciding whether an entry is text, code or a link is the expensive part
    /// of building any category, and the results are cached for the life of
    /// the process — but the first panel open of a long history would pay for
    /// all of it at once, on the main thread, while the window is coming up.
    /// This does the same work in the background shortly after launch instead.
    /// It only fills a shared cache: nothing here mutates the store, so a copy
    /// captured now stays valid even as new entries arrive.
    public func warmContentClassification() {
        // SQLite-backed entries persist their automatic category and keep text
        // bodies deferred, so startup no longer needs to copy and walk the
        // complete history. Kept as a compatibility no-op for preview/tests.
    }

    /// Search/category results are presentation caches, not user data. Drop them
    /// when the clipboard panel closes so a large history does not keep several
    /// full filtered arrays alive while the app is idle.
    public func releaseTransientCaches() {
        orderedMemo.removeAll(keepingCapacity: false)
        orderedMemoPositionCount = 0
        sortedPartitionMemo = nil
        categoryPartitionMemo.removeAll(keepingCapacity: false)
        incrementalQueryChain = nil
        sourceApplicationMemos.removeAll(keepingCapacity: false)
        sourceApplicationMemoItemCount = 0
        hasUnknownSourceMemos.removeAll(keepingCapacity: false)
        repository.releaseTransientMemory()
    }

    var orderedMemoMetrics: (entryCount: Int, retainedPositionCount: Int) {
        (orderedMemo.count, orderedMemoPositionCount)
    }

    var sourceApplicationMemoMetrics: (
        entryCount: Int,
        retainedApplicationCount: Int,
        unknownEntryCount: Int
    ) {
        (
            sourceApplicationMemos.count,
            sourceApplicationMemoItemCount,
            hasUnknownSourceMemos.count
        )
    }

    var sourceStringInternerMetrics: (
        uniqueStringCount: Int,
        canonicalizedAssignmentCount: Int,
        peakUniqueStringCount: Int,
        uniqueSourceMetadataCount: Int,
        peakUniqueSourceMetadataCount: Int
    ) {
        (
            metadataStringInterner.uniqueStringCount,
            metadataStringInterner.canonicalizedAssignmentCount,
            metadataStringInterner.peakUniqueStringCount,
            metadataStringInterner.uniqueSourceMetadataCount,
            metadataStringInterner.peakUniqueSourceMetadataCount
        )
    }

    /// Preview/self-check only: swap the in-memory list without touching the
    /// persisted history, so UI stress flows can run against dense fake data.
    /// Persistence is disabled from this point on for the whole process —
    /// otherwise any later mutation (a settings change, a clipboard event)
    /// would overwrite the user's real history with the fakes.
    public func injectPreviewEntries(_ previewEntries: [ClipboardEntry]) {
        isPersistenceDisabled = true
        var canonical = previewEntries
        metadataStringInterner.canonicalizeInPlace(&canonical)
        entries = canonical
    }

    private var isPersistenceDisabled = false

    /// Internal (not private) so a `@testable` integration test can drive one
    /// poll deterministically instead of waiting on the real timer.
    func inspectPasteboard() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != observedChangeCount else { return }
        observedChangeCount = pasteboard.changeCount
        if suppressedChangeCount == pasteboard.changeCount {
            suppressedChangeCount = nil
            return
        }
        // Keep observedChangeCount current (done above) so resuming won't capture
        // whatever was copied while the meme library was grabbing images.
        guard !isRecordingPaused else { return }
        // The copy happened within the last polling interval, so the frontmost
        // app is a good approximation of where the content came from.
        let source = Self.sourceApplication(from: NSWorkspace.shared.frontmostApplication)
        capturePasteboardContents(pasteboard, source: source)
    }

    /// The deterministic capture half of `inspectPasteboard`, separated so
    /// policy and pasteboard-type behavior can be tested without touching the
    /// user's general clipboard or relying on the polling timer.
    func capturePasteboardContents(
        _ pasteboard: NSPasteboard,
        source: ClipboardSourceApplication?
    ) {
        // Apply the policy before asking the pasteboard to materialize any
        // representation. Excluded content therefore never enters app memory,
        // classification, encryption or persistence.
        guard settings.allowsCapture(from: source) else { return }
        // Content a password manager (or a browser password field) marked
        // concealed. Unless the user has explicitly opted in, it is dropped
        // exactly as before — that stays the default. When opted in it is
        // recorded only as an encrypted 密码 entry, never as ordinary text.
        if Self.isPrivatePasteboard(pasteboard) {
            guard capturesPasswords,
                  pasteboard.types?.contains(.string) == true,
                  let secret = pasteboard.string(forType: .string) else { return }
            _ = addPassword(secret, source: source)
            return
        }
        // Require an explicitly declared text payload. Asking AppKit to convert
        // a Finder file URL to `.string` can resolve the external file and cause
        // a broad Documents permission prompt during background monitoring.
        do {
            if let richText = try ClipboardRichTextPayload.read(from: pasteboard) {
                if richText.formats.isEmpty {
                    _ = addText(richText.plainText, source: source)
                } else {
                    _ = try addRichText(richText, source: source)
                }
                return
            }
        } catch {
            lastError = error.localizedDescription
            return
        }
        if settings.savesImages, let image = ImageAssetData.read(from: pasteboard, allowFileURLs: false) {
            _ = addImageData(image, source: source)
        }
    }

    private static func sourceApplication(from application: NSRunningApplication?) -> ClipboardSourceApplication? {
        guard let application else { return nil }
        let name = application.localizedName
            ?? application.bundleURL?.deletingPathExtension().lastPathComponent
            ?? application.bundleIdentifier
            ?? L10n.text("未知")
        return ClipboardSourceApplication(
            bundleIdentifier: application.bundleIdentifier,
            displayName: name,
            bundleURLPath: application.bundleURL?.standardizedFileURL.path
        )
    }

    private func shouldRecord(_ entry: ClipboardEntry) -> Bool {
        guard settings.isCategoryEnabled(.builtin(entry.contentCategory)) else { return false }
        for custom in settings.customCategories ?? [] {
            let key = ClipboardCategoryKey.custom(custom.id)
            if !settings.isCategoryEnabled(key), entry.matches(key: key, customCategories: [custom]) {
                return false
            }
        }
        return true
    }

    private func clearEntries(matching key: ClipboardCategoryKey) {
        let customs = settings.customCategories ?? []
        // Partitioned in one pass. Splitting this into a filter and a separate
        // removal ran the category rules over every entry twice, and mutating
        // a published array in place copies its whole buffer anyway.
        var removed: [ClipboardEntry] = []
        var kept: [ClipboardEntry] = []
        kept.reserveCapacity(entries.count)
        for entry in entries {
            if entry.matches(key: key, customCategories: customs) {
                removed.append(entry)
            } else {
                kept.append(entry)
            }
        }
        guard !removed.isEmpty else { return }
        let removedIDs = Set(removed.map(\.id))
        entries = kept
        setPasteQueueIDs(settings.resolvedPasteQueueEntryIDs.filter {
            !removedIDs.contains($0)
        })
        for entry in removed { removeBackingAssets(entry) }
        normalizePinOrders()
    }

    @discardableResult
    private func trimToLimit() -> [UUID] {
        let trimmed = ClipboardHistoryPolicy.idsToTrim(from: entries, maxEntries: settings.maxEntries)
        guard !trimmed.isEmpty else { return [] }
        let ids = Set(trimmed)
        // One pass produces both halves. A history sitting at its limit trims
        // on every single capture, so this is a hot path.
        var removed: [ClipboardEntry] = []
        removed.reserveCapacity(ids.count)
        var kept: [ClipboardEntry] = []
        kept.reserveCapacity(entries.count - ids.count)
        for entry in entries {
            if ids.contains(entry.id) { removed.append(entry) } else { kept.append(entry) }
        }
        entries = kept
        setPasteQueueIDs(settings.resolvedPasteQueueEntryIDs.filter {
            !ids.contains($0)
        })
        for entry in removed { removeBackingAssets(entry) }
        return trimmed
    }

    /// Compacts both pin orders.
    ///
    /// These run after every capture, delete and trim. Two properties keep them
    /// cheap against a large history: they work on entry *indices*, so the
    /// pinned subset is never copied out and re-matched by id, and they leave
    /// `entries` untouched when the stored orders are already correct — which
    /// is the normal case. That last point matters because `entries` is
    /// `@Published`: every element write republishes the entire list and can
    /// copy its whole buffer.
    private func normalizePinOrders() {
        // Read the list once. `entries` is a published property, so touching it
        // from inside a sort comparator repeats that access for every
        // comparison.
        let current = entries
        var pinnedIndices: [Int] = []
        for (index, entry) in current.enumerated() where entry.isPinned {
            pinnedIndices.append(index)
        }
        if !pinnedIndices.isEmpty {
            pinnedIndices.sort { lhs, rhs in
                let left = current[lhs].pinnedOrder ?? Int.max
                let right = current[rhs].pinnedOrder ?? Int.max
                if left != right { return left < right }
                return current[lhs].createdAt < current[rhs].createdAt
            }
            applyOrders(pinnedIndices) { entry, order in
                guard entry.pinnedOrder != order else { return false }
                entry.pinnedOrder = order
                return true
            }
        }
        _ = normalizeDesktopPinnedOrders()
    }

    /// Assigns stable order to snapshots created before desktop pin order was
    /// persisted, and compacts gaps after an unpin/delete. `updatedAt` is the
    /// best available approximation of first-pin time for legacy snapshots.
    @discardableResult
    private func normalizeDesktopPinnedOrders() -> Bool {
        let current = entries
        var pinnedIndices: [Int] = []
        for (index, entry) in current.enumerated() where entry.isDesktopPinned == true {
            pinnedIndices.append(index)
        }
        guard !pinnedIndices.isEmpty else { return false }
        pinnedIndices.sort { lhs, rhs in
            let left = current[lhs].desktopPinnedOrder ?? Int.max
            let right = current[rhs].desktopPinnedOrder ?? Int.max
            if left != right { return left < right }
            if current[lhs].updatedAt != current[rhs].updatedAt {
                return current[lhs].updatedAt < current[rhs].updatedAt
            }
            return current[lhs].createdAt < current[rhs].createdAt
        }
        return applyOrders(pinnedIndices) { entry, order in
            guard entry.desktopPinnedOrder != order else { return false }
            entry.desktopPinnedOrder = order
            return true
        }
    }

    /// Writes sequential orders to the given entries, publishing at most once.
    @discardableResult
    private func applyOrders(
        _ indices: [Int],
        assign: (inout ClipboardEntry, Int) -> Bool
    ) -> Bool {
        var updated: [ClipboardEntry]?
        for (order, index) in indices.enumerated() {
            var candidate = entries[index]
            guard assign(&candidate, order) else { continue }
            if updated == nil { updated = entries }
            updated?[index] = candidate
        }
        guard let updated else { return false }
        entries = updated
        return true
    }

    private func removeBackingAssets(_ entry: ClipboardEntry) {
        if let fileName = entry.imageFileName {
            do { try repository.removeImage(named: fileName) }
            catch { lastError = error.localizedDescription }
        }
        do { try repository.removeOriginalFormats(entry.originalFormats ?? []) }
        catch { lastError = error.localizedDescription }
    }

    /// Enqueues the newest value snapshot and drops any delayed mark-used write.
    /// SQLite reconciliation runs on the repository's serial I/O queue; a
    /// reload or explicit flush is a durability barrier.
    private func persist() {
        pendingSaveWork?.cancel()
        pendingSaveWork = nil
        pendingSaveEntryIDs.removeAll(keepingCapacity: true)
        writeSnapshot()
    }

    /// Persists the normal capture path without materializing a second copy of
    /// the complete history. The repository writes exactly the appended row and
    /// any rows trimmed at the configured limit.
    private func persistAppendedEntry(_ entry: ClipboardEntry, deletedIDs: [UUID]) {
        guard !isPersistenceDisabled else { return }
        repository.saveDeltaAsync(
            upserts: [entry],
            deletedIDs: deletedIDs,
            appendingIDs: [entry.id],
            settings: settings
        ) { [weak self] errorMessage in
            Task { @MainActor [weak self] in
                if let errorMessage {
                    self?.lastError = errorMessage
                } else {
                    self?.deferPersistedBody(matching: entry)
                }
            }
        }
    }

    private func persistSettings(deletedIDs: [UUID]) {
        guard !isPersistenceDisabled else { return }
        repository.saveDeltaAsync(
            upserts: [],
            deletedIDs: deletedIDs,
            settings: settings
        ) { [weak self] errorMessage in
            guard let errorMessage else { return }
            Task { @MainActor [weak self] in
                self?.lastError = errorMessage
            }
        }
    }

    private func persistCoalesced(entryID: UUID) {
        guard !isPersistenceDisabled else { return }
        pendingSaveEntryIDs.insert(entryID)
        pendingSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.writePendingEntryDeltas()
        }
        pendingSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func writePendingEntryDeltas() {
        pendingSaveWork = nil
        let ids = pendingSaveEntryIDs
        pendingSaveEntryIDs.removeAll(keepingCapacity: true)
        guard !ids.isEmpty else { return }
        let updatedEntries = entries.filter { ids.contains($0.id) }
        repository.saveDeltaAsync(
            upserts: updatedEntries,
            settings: settings
        ) { [weak self] errorMessage in
            guard let errorMessage else { return }
            Task { @MainActor [weak self] in
                self?.lastError = errorMessage
            }
        }
    }

    /// Flushes a pending coalesced write immediately. Called on teardown so a
    /// just-recorded use count is never lost, and available to tests that need
    /// the on-disk snapshot to be current before reloading.
    public func flushPendingSave() {
        if pendingSaveWork != nil {
            pendingSaveWork?.cancel()
            writePendingEntryDeltas()
        }
        repository.flushSnapshotWrites()
    }

    private func writeSnapshot() {
        guard !isPersistenceDisabled else { return }
        let snapshot = persistableSnapshot()
        repository.saveAsync(snapshot) { [weak self] errorMessage, didWrite in
            Task { @MainActor [weak self] in
                if let errorMessage {
                    self?.lastError = errorMessage
                } else if didWrite {
                    self?.deferPersistedBodiesInOrder(matching: snapshot.entries)
                }
            }
        }
    }

    /// Once a write is durable, replace matching in-memory bodies with compact
    /// SQLite-backed references. A newer edit is never deferred against an
    /// older write: both its content hash and update timestamp must match.
    private func deferPersistedBody(matching persisted: ClipboardEntry) {
        guard let index = entries.firstIndex(where: { $0.id == persisted.id })
        else { return }
        let current = entries[index]
        guard current.decodedStoredText != nil,
              current.compactContentHash == persisted.compactContentHash,
              current.updatedAt == persisted.updatedAt else { return }
        entries[index] = repository.deferredProjection(of: current)
        repository.releaseTransientTextCache()
    }

    func deferPersistedBodiesInOrder(
        matching persistedEntries: [ClipboardEntry]
    ) {
        var compacted: [ClipboardEntry]?
        for index in 0..<min(entries.count, persistedEntries.count) {
            let current = entries[index]
            let persisted = persistedEntries[index]
            guard current.id == persisted.id,
                  current.compactContentHash == persisted.compactContentHash,
                  current.updatedAt == persisted.updatedAt else {
                continue
            }
            if current.decodedStoredText == nil {
                repository.redirectDeferredTextToRepository(for: current)
                continue
            }
            if compacted == nil { compacted = entries }
            compacted?[index] = repository.deferredProjection(of: current)
        }
        if let compacted { entries = compacted }
        repository.releaseTransientTextCache()
    }

    private func pasteIntoFocusedAppIfAllowed() {
        guard AXIsProcessTrusted() else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
