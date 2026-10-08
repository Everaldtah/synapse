import SwiftUI
import SynapseKit

/// Settings that every row of a page shares.
struct EditorContext {
    var pageFont: PageFont
    var smallText: Bool
    var resolves: (String) -> Bool
    var openLink: (String) -> Void
    var openURL: (URL) -> Void
    var openTag: (String) -> Void
    var openDate: (String) -> Void
    var commentCounts: [UUID: Int]
}

struct BlockRowView: View {
    let row: VisibleBlock
    let model: PageEditorModel
    let ctx: EditorContext
    @State private var dropTargeted = false

    private var item: BlockItem { row.item }

    var body: some View {
        let b = item.block
        let focused = model.focusedID == item.id
        HStack(alignment: .top, spacing: 6) {
            prefix(b)
            content(b)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let n = ctx.commentCounts[item.id], n > 0 {
                Button {
                    model.commentsBlock = item.id
                    model.showComments = true
                } label: {
                    Label("\(n)", systemImage: "text.bubble").font(.caption2).labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            }
        }
        .padding(.leading, CGFloat(b.indent) * 24)
        .padding(.vertical, verticalPadding(b.type))
        .padding(.horizontal, hasBox(b) ? 12 : 0)
        .padding(.vertical, hasBox(b) ? 6 : 0)
        .background {
            if hasBox(b) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(b.background != .none ? b.background.background : Color(UIColor.secondarySystemBackground))
                    .padding(.leading, CGFloat(b.indent) * 24)
            }
        }
        .overlay(alignment: .topLeading) {
            if (focused || (b.type.isHeading && b.collapsed)) && !model.readOnly {
                handle(b)
                    .offset(x: -24 + CGFloat(b.indent) * 24, y: hasBox(b) ? 8 : 2)
            }
        }
        .overlay(alignment: .top) {
            if dropTargeted {
                Rectangle().fill(Palette.accent).frame(height: 2).offset(y: -1)
            }
        }
        .dropDestination(for: String.self) { ids, _ in
            guard let s = ids.first, let id = UUID(uuidString: s), id != item.id else { return false }
            // Dropping on a row puts the block before it: after the row above.
            if let i = model.index(of: item.id), i > 0 {
                model.move(id, after: model.items[i - 1].id)
            } else {
                model.move(id, after: item.id)
                model.moveUp(id)
            }
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private func hasBox(_ b: Block) -> Bool { b.type == .callout || (b.background != .none && b.type.isTextual) }

    private func verticalPadding(_ t: BlockType) -> CGFloat {
        switch t {
        case .heading1: return 10
        case .heading2: return 7
        case .heading3: return 4
        case .divider: return 6
        default: return 1
        }
    }

    private var lineHeight: CGFloat {
        BlockStyle.firstLineHeight(for: item.block.type, pageFont: ctx.pageFont, small: ctx.smallText)
    }

    // MARK: Handle (drag to reorder, tap for actions)

    private func handle(_ b: Block) -> some View {
        HStack(spacing: 0) {
            if b.type.isHeading {
                Button { model.toggleCollapsed(item.id) } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .rotationEffect(.degrees(b.collapsed ? 0 : 90))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            } else {
                Image(systemName: "line.3.horizontal")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
                    .onTapGesture { model.actionsFor = item.id }
                    .draggable(item.id.uuidString) {
                        Text(InlineMarkdown.plainText(item.text).isEmpty ? b.type.title : InlineMarkdown.plainText(item.text))
                            .lineLimit(1)
                            .padding(8)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
            }
        }
    }

    // MARK: Prefix (bullet, number, checkbox, toggle, quote bar, callout icon)

    @ViewBuilder private func prefix(_ b: Block) -> some View {
        switch b.type {
        case .bulleted:
            Text(["•", "◦", "▪︎"][b.indent % 3])
                .font(.system(size: BlockStyle.baseSize(small: ctx.smallText) * 1.1, weight: .bold))
                .frame(width: 18, height: lineHeight)
        case .numbered:
            Text("\(row.number ?? 1).")
                .font(.system(size: BlockStyle.baseSize(small: ctx.smallText)).monospacedDigit())
                .frame(minWidth: 20, alignment: .trailing)
                .frame(height: lineHeight)
        case .todo:
            Button { model.toggleChecked(item.id) } label: {
                Image(systemName: b.checked ? "checkmark.square.fill" : "square")
                    .font(.system(size: BlockStyle.baseSize(small: ctx.smallText) * 1.05))
                    .foregroundStyle(b.checked ? Palette.accent : Color.secondary)
                    .frame(width: 22, height: lineHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.readOnly)
        case .toggle:
            Button { model.toggleCollapsed(item.id) } label: {
                Image(systemName: "arrowtriangle.right.fill")
                    .font(.system(size: 11))
                    .rotationEffect(.degrees(b.collapsed ? 0 : 90))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: lineHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        case .quote:
            Rectangle().fill(Color.primary).frame(width: 3, height: lineHeight).padding(.trailing, 6)
        case .callout:
            Menu {
                ForEach(["💡", "📌", "⚠️", "✅", "❗", "📝", "🔥", "💬", "❓", "🚀", "🧠", "📅"], id: \.self) { e in
                    Button(e) { model.update(item.id) { $0.icon = e } }
                }
            } label: {
                Text(b.icon.isEmpty ? "💡" : b.icon).font(.system(size: BlockStyle.baseSize(small: ctx.smallText) * 1.1))
                    .frame(width: 26, height: lineHeight)
            }
        default:
            EmptyView()
        }
    }

    // MARK: Content

    @ViewBuilder private func content(_ b: Block) -> some View {
        if b.type.isTextual {
            BlockTextView(item: item, model: model, pageFont: ctx.pageFont, smallText: ctx.smallText,
                          resolves: ctx.resolves, onOpenLink: ctx.openLink, onOpenURL: ctx.openURL,
                          onOpenTag: ctx.openTag, onOpenDate: ctx.openDate)
                .padding(.top, b.type == .code || b.type == .equation ? 26 : 0)
                .padding(.horizontal, b.type == .code || b.type == .equation ? 12 : 0)
                .padding(.bottom, b.type == .code || b.type == .equation ? 8 : 0)
                .background {
                    if b.type == .code || b.type == .equation {
                        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(UIColor.secondarySystemBackground))
                    }
                }
                .overlay(alignment: .topLeading) {
                    if b.type == .code { CodeLanguageMenu(item: item, model: model).padding(.leading, 10).padding(.top, 4) }
                    if b.type == .equation {
                        Label("Equation", systemImage: "function").font(.caption2).foregroundStyle(.secondary)
                            .padding(.leading, 12).padding(.top, 6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if b.type == .code {
                        Button { UIPasteboard.general.string = item.text; Haptics.success() } label: {
                            Image(systemName: "doc.on.doc").font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .padding(8)
                    }
                }
        } else {
            SpecialBlockView(item: item, model: model, ctx: ctx)
                .contextMenu { BlockMenuItems(id: item.id, model: model) }
        }
    }
}

struct CodeLanguageMenu: View {
    let item: BlockItem
    let model: PageEditorModel
    static let languages = ["Plain text", "Swift", "Python", "JavaScript", "TypeScript", "JSON", "HTML", "CSS", "Bash", "SQL",
                            "Go", "Rust", "Kotlin", "Java", "C", "C++", "C#", "Ruby", "PHP", "YAML", "Markdown", "Mermaid"]

    var body: some View {
        Menu {
            ForEach(Self.languages, id: \.self) { lang in
                Button(lang) { model.update(item.id) { $0.language = lang == "Plain text" ? "" : lang.lowercased() } }
            }
        } label: {
            HStack(spacing: 3) {
                Text(item.block.language.isEmpty ? "Plain text" : item.block.language.capitalized)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
        }
    }
}

/// The block actions shared by the context menu and the actions sheet.
struct BlockMenuItems: View {
    let id: UUID
    let model: PageEditorModel

    var body: some View {
        Button { model.duplicate(id) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
        Button { model.moveUp(id) } label: { Label("Move up", systemImage: "arrow.up") }
        Button { model.moveDown(id) } label: { Label("Move down", systemImage: "arrow.down") }
        Button {
            model.commentsBlock = id
            model.showComments = true
        } label: { Label("Comment", systemImage: "text.bubble") }
        Button { model.aiRequest = EditorAIRequest(blockIDs: [id], selectedText: model.item(id)?.text ?? "", range: nil) } label: {
            Label("Ask AI", systemImage: "sparkles")
        }
        Divider()
        Button(role: .destructive) { model.delete(id) } label: { Label("Delete", systemImage: "trash") }
    }
}
