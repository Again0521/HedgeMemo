import Foundation

/// Resolves the shared Application Support root for both the meme library and
/// the clipboard history.
public enum AppSupportLocation {
    /// The pre-rename data directory. The app shipped as "MemeMemo" before it
    /// became HedgeMemo, so an existing installation has its library there.
    private static let legacyDirectoryName = "MemeMemo"
    private static let directoryName = "HedgeMemo"

    /// Returns `…/Application Support/HedgeMemo`, first moving a legacy
    /// `…/Application Support/MemeMemo` directory into place so an upgraded
    /// installation keeps its memes, categories and clipboard history.
    public static func defaultRoot(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = base.appendingPathComponent(directoryName, isDirectory: true)
        let legacy = base.appendingPathComponent(legacyDirectoryName, isDirectory: true)
        if !fileManager.fileExists(atPath: root.path), fileManager.fileExists(atPath: legacy.path) {
            // A failed move falls through to a fresh directory rather than
            // failing startup; the legacy data stays untouched for retry.
            try? fileManager.moveItem(at: legacy, to: root)
        }
        return root
    }
}
