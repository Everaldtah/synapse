import SwiftUI
import SynapseKit

/// An entry in the "/" menu: a block to insert or an AI action.
enum SlashItem: Hashable, Identifiable {
    case block(BlockType)
    case ai(AIAction)

    var id: String {
        switch self {
        case .block(let t): return "b." + t.rawValue
        case .ai(let a): return "a." + a.rawValue
        }
    }

    var title: String {
        switch self {
        case .block(let t): return t.title
        case .ai(let a): return a == .custom ? "Ask AI" : a.title
        }
    }

    var summary: String {
        switch self {
        case .block(let t): return t.summary
        case .ai: return "Claude writes for you."
        }
    }

    var symbol: String {
        switch self {
        case .block(let t): return t.symbol
        case .ai(let a): return a.symbol
        }
    }

    var keywords: [String] {
        switch self {
        case .block(let t): return t.keywords
        case .ai(let a): return ["ai", "claude", a.rawValue.lowercased()]
        }
    }
}

enum SlashMenu {
    static let all: [SlashItem] = {
        let blocks: [BlockType] = [.paragraph, .heading1, .heading2, .heading3, .todo, .bulleted, .numbered, .toggle, .quote, .callout,
                                   .divider, .code, .childPage, .pageLink, .childDatabase, .table, .image, .bookmark, .embed,
                                   .equation, .tableOfContents, .breadcrumb]
        return blocks.map { SlashItem.block($0) } + [.ai(.custom), .ai(.continueWriting), .ai(.summarize), .ai(.actionItems), .ai(.brainstorm), .ai(.outline)]
    }()

    static func matches(_ query: String) -> [SlashItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return all }
        let scored: [(SlashItem, Int)] = all.compactMap { item in
            let title = item.title.lowercased()
            if title.hasPrefix(q) { return (item, 0) }
            if item.keywords.contains(where: { $0.hasPrefix(q) }) { return (item, 1) }
            if title.contains(q) { return (item, 2) }
            if item.keywords.contains(where: { $0.contains(q) }) { return (item, 3) }
            return nil
        }
        return scored.sorted { $0.1 < $1.1 }.map(\.0)
    }
}

extension PageEditorModel {
    func apply(_ item: SlashItem) {
        switch item {
        case .block(let t):
            applySlash(t)
        case .ai(let action):
            guard let s = slash, let block = self.item(s.blockID) else { slash = nil; return }
            let ns = block.text as NSString
            let len = min(ns.length - s.start, 1 + (s.query as NSString).length)
            if s.start >= 0, len > 0, s.start + len <= ns.length {
                block.text = ns.replacingCharacters(in: NSRange(location: s.start, length: len), with: "")
            }
            slash = nil
            scheduleCommit()
            aiRequest = EditorAIRequest(blockIDs: [block.id], selectedText: "", range: nil, action: action)
        }
    }
}

/// The "/" menu, shown above the keyboard while typing after a slash.
struct SlashMenuView: View {
    let model: PageEditorModel

    var body: some View {
        let items = SlashMenu.matches(model.slash?.query ?? "")
        VStack(spacing: 0) {
            HStack {
                Text(items.isEmpty ? "No results" : "Blocks").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { model.slash = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 4)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        Button { model.apply(item) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: item.symbol)
                                    .font(.system(size: 16))
                                    .frame(width: 36, height: 36)
                                    .background(Color(UIColor.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.title).font(.subheadline.weight(.medium))
                                    Text(item.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 250)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }
}

/// The "[[" page picker, shown above the keyboard.
struct LinkPickerView: View {
    @Environment(WorkspaceStore.self) private var store
    let model: PageEditorModel

    var body: some View {
        let query = model.link?.query ?? ""
        let pages = Search.quickSwitch(query, in: store.workspace, limit: 8).filter { $0.id != model.pageID }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Link to page").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { model.link = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(pages) { page in
                        Button { model.applyLink(title: page.displayTitle) } label: {
                            PageRowLabel(page: page, showPath: true)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                        }
                        .buttonStyle(.plain)
                    }
                    if !trimmed.isEmpty && store.workspace.resolve(trimmed) == nil {
                        Button { model.applyLink(title: trimmed) } label: {
                            Label("New page “\(trimmed)”", systemImage: "plus")
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                        }
                    }
                }
            }
            .frame(maxHeight: 240)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }
}
