import AppKit
import HedgeMemoCore
import SwiftUI

/// The coordinate space shared by the meme grid and every tile's drag gesture.
/// Reordering is implemented with a plain `DragGesture` plus fixed slot math —
/// deliberately *not* with the AppKit drag-and-drop session behind
/// `onDrag`/`onDrop`. Inside an NSPopover that session proved unreliable
/// twice: `performDrop` was sometimes swallowed (release did nothing), and
/// tiles animating between slots re-triggered `dropEntered` under a
/// stationary pointer, shuffling the grid on its own. A gesture reports pure
/// pointer coordinates, the target slot is derived from those coordinates
/// alone, and `onEnded` always runs on mouse-up.
enum MemeGridSpace {
    static let name = "memeGrid"
}

/// Equatable over its data (the action closures are recreated by every parent
/// pass but capture equal values) and installed with `.equatable()`, so a drag
/// or selection change re-renders only the affected tiles instead of the whole
/// grid on every mouse move.
struct MemeTileView: View, Equatable {
    nonisolated static func == (lhs: MemeTileView, rhs: MemeTileView) -> Bool {
        lhs.meme == rhs.meme
            && lhs.imageURL == rhs.imageURL
            && lhs.side == rhs.side
            && lhs.isManaging == rhs.isManaging
            && lhs.isSelected == rhs.isSelected
            && lhs.isDragged == rhs.isDragged
            && lhs.categories == rhs.categories
    }

    let meme: MemeItem
    let imageURL: URL
    let side: CGFloat
    let isManaging: Bool
    let isSelected: Bool
    let isDragged: Bool
    let categories: [MemeCategory]
    let onSelection: (UUID, NSEvent.ModifierFlags) -> Void
    let onCopy: () -> Void
    let onEditNote: () -> Void
    let onMove: (UUID?) -> Void
    let onDelete: () -> Void
    /// Reports pointer movement in `MemeGridSpace` while this tile is dragged.
    let onDragChanged: (UUID, CGPoint) -> Void
    let onDragEnded: () -> Void

    private var hasNote: Bool {
        !meme.note.isEmpty
            && meme.note != "未命名"
            && meme.note != L10n.text("未命名", language: .english)
    }

    var body: some View {
        MemeTileContent(
            meme: meme,
            imageURL: imageURL,
            side: side,
            isManaging: isManaging,
            isSelected: isSelected,
            hasNote: hasNote
        )
        // While dragged, the tile itself stays as a dimmed placeholder marking
        // the slot the meme will land in; a floating copy follows the pointer.
        .opacity(isDragged ? 0.3 : 1)
        .contentShape(Rectangle())
        // A plain tap keeps working exactly like the old Button: the drag
        // gesture only claims the interaction after 4pt of movement.
        .onTapGesture {
            if isManaging { onSelection(meme.id, NSEvent.modifierFlags) } else { onCopy() }
        }
        // A deliberate reorder needs more travel than an ordinary click's
        // jitter, so a plain selection tap in management mode is never stolen
        // by this drag and mistaken for a no-op reorder onto the same tile.
        .gesture(
            DragGesture(minimumDistance: 10, coordinateSpace: .named(MemeGridSpace.name))
                .onChanged { value in onDragChanged(meme.id, value.location) }
                .onEnded { _ in onDragEnded() }
        )
        .contextMenu { contextMenu }
        .help(isManaging ? L10n.text("点击选择；拖动缩略图排序") : (hasNote ? L10n.format("备注拖动排序格式", meme.note) : L10n.text("点击复制；拖动排序")))
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button(L10n.text("复制")) { onCopy() }
        Button(L10n.text("修改备注")) { onEditNote() }
        Menu(L10n.text("移动到")) {
            Button(L10n.text("未分类")) { onMove(nil) }
            ForEach(categories) { category in
                Button(category.name) { onMove(category.id) }
            }
        }
        Divider()
        Button(L10n.text("删除"), role: .destructive) { onDelete() }
    }
}

/// The tile's visual body, shared by the grid cell and the floating drag copy.
struct MemeTileContent: View {
    let meme: MemeItem
    let imageURL: URL
    let side: CGFloat
    var isManaging = false
    var isSelected = false
    var hasNote = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary)
            Group {
                // A cheap file-existence check replaces the previous
                // full-resolution `NSImage(contentsOf:)` decode that ran purely
                // as a nil-check (and then decoded the same file a second time
                // in the image view) — the meme grid's main scroll cost.
                if FileManager.default.fileExists(atPath: imageURL.path) {
                    ThumbnailImageView(url: imageURL, targetPoints: side, contentIdentity: meme.contentHash)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Image(systemName: "photo")
                        .resizable()
                        .scaledToFit()
                        .padding(20)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(4)
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .bottom) {
            if hasNote {
                Text(meme.note)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.45))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if isManaging {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .padding(4)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        }
    }
}
