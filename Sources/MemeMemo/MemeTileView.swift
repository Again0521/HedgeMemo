import AppKit
import MemeMemoCore
import SwiftUI
import UniformTypeIdentifiers

struct MemeTileView: View {
    let meme: MemeItem
    let imageURL: URL
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

    var body: some View {
        Button(action: { if isManaging { onSelection(meme.id) } else { onCopy() } }) {
            VStack(alignment: .leading, spacing: 5) {
                Group {
                    if let image = NSImage(contentsOf: imageURL) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "photo")
                            .resizable()
                            .scaledToFit()
                            .padding(18)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 82)
                .frame(maxWidth: .infinity)
                .clipped()
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                Text(meme.note)
                    .lineLimit(1)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(.primary)
            }
            .padding(5)
            .overlay(alignment: .topTrailing) {
                if isManaging {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(isSelected ? .tint : .secondary)
                        .padding(5)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
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
        .help("按住并拖动可排序")
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
