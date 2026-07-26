import Foundation

public enum ClipboardPasteQueueError: LocalizedError, Equatable {
    case entryNotFound
    case queueEmpty
    case protectedEntryLocked
    case pasteboardWriteFailed

    public var errorDescription: String? {
        switch self {
        case .entryNotFound:
            L10n.text("找不到要加入队列的条目。")
        case .queueEmpty:
            L10n.text("粘贴队列为空。")
        case .protectedEntryLocked:
            L10n.text("请先解锁密码分类，再粘贴此队列项目。")
        case .pasteboardWriteFailed:
            L10n.text("无法写入系统剪贴板。")
        }
    }
}
