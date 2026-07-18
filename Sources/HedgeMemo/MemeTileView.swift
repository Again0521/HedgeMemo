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

struct MemeTileView: View {
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
        !meme.note.isEmpty && meme.note != "未命名"
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
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .named(MemeGridSpace.name))
                .onChanged { value in onDragChanged(meme.id, value.location) }
                .onEnded { _ in onDragEnded() }
        )
        .contextMenu { contextMenu }
        .help(isManaging ? "点击选择；拖动缩略图排序" : (hasNote ? "\(meme.note) · 拖动排序" : "点击复制；拖动排序"))
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("复制") { onCopy() }
        Button("修改备注") { onEditNote() }
        Menu("移动到") {
            Button("未分类") { onMove(nil) }
            ForEach(categories) { category in
                Button(category.name) { onMove(category.id) }
            }
        }
        Divider()
        Button("删除", role: .destructive) { onDelete() }
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
                if NSImage(contentsOf: imageURL) != nil {
                    AnimatedImageFileView(url: imageURL)
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
