import AppKit
import MemeMemoCore
import SwiftUI
import UniformTypeIdentifiers

struct MemeTileView: View {
    let meme: MemeItem
    let imageURL: URL
    let side: CGFloat
    let isManaging: Bool
    let isSelected: Bool
    let categories: [MemeCategory]
    let onSelection: (UUID) -> Void
    let onCopy: () -> Void
    let onEditNote: () -> Void
    let onMove: (UUID?) -> Void
    let onDelete: () -> Void
    @Binding var draggedID: UUID?
    let onReorder: (UUID, UUID) -> Void

    private var hasNote: Bool {
        !meme.note.isEmpty && meme.note != "未命名"
    }

    var body: some View {
        Button(action: { if isManaging { onSelection(meme.id) } else { onCopy() } }) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.quaternary)
                Group {
                    if let image = NSImage(contentsOf: imageURL) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
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
        .buttonStyle(.plain)
        .contextMenu { contextMenu }
        .onDrag {
            draggedID = meme.id
            return NSItemProvider(object: meme.id.uuidString as NSString)
        }
        .onDrop(of: [UTType.plainText], delegate: MemeDropDelegate(
            targetID: meme.id,
            draggedID: $draggedID,
            onReorder: onReorder
        ))
        .help(hasNote ? meme.note : "按住并拖动可排序")
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

private struct MemeDropDelegate: DropDelegate {
    let targetID: UUID
    @Binding var draggedID: UUID?
    let onReorder: (UUID, UUID) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggedID, draggedID != targetID else { return }
        onReorder(draggedID, targetID)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedID = nil
        return true
    }
}
