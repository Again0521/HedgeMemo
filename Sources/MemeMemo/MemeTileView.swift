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
    @Binding var insertionProposal: MemeInsertionProposal?
    let onReorder: (UUID, UUID, Bool) -> Void

    private var hasNote: Bool {
        !meme.note.isEmpty && meme.note != "未命名"
    }

    var body: some View {
        Button(action: { if isManaging { onSelection(meme.id) } else { onCopy() } }) {
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
            .overlay(alignment: insertionProposal?.insertAfter == true ? .trailing : .leading) {
                if insertionProposal?.targetID == meme.id {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 4)
                        .padding(.vertical, 5)
                        .shadow(color: Color.accentColor.opacity(0.35), radius: 3)
                }
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
            side: side,
            draggedID: $draggedID,
            insertionProposal: $insertionProposal,
            onReorder: onReorder
        ))
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

struct MemeInsertionProposal: Equatable {
    let targetID: UUID
    let insertAfter: Bool
}

private struct MemeDropDelegate: DropDelegate {
    let targetID: UUID
    let side: CGFloat
    @Binding var draggedID: UUID?
    @Binding var insertionProposal: MemeInsertionProposal?
    let onReorder: (UUID, UUID, Bool) -> Void

    func dropEntered(info: DropInfo) {
        updateProposal(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateProposal(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if insertionProposal?.targetID == targetID { insertionProposal = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let draggedID, draggedID != targetID else { return false }
        let insertAfter = info.location.x >= side / 2
        onReorder(draggedID, targetID, insertAfter)
        insertionProposal = nil
        self.draggedID = nil
        return true
    }

    private func updateProposal(_ info: DropInfo) {
        guard let draggedID, draggedID != targetID else {
            insertionProposal = nil
            return
        }
        insertionProposal = MemeInsertionProposal(targetID: targetID, insertAfter: info.location.x >= side / 2)
    }
}
