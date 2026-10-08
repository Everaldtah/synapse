import SwiftUI
import SynapseKit

/// "Linked mentions" and "Unlinked mentions" under every page.
struct BacklinksSection: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(AppModel.self) private var app
    let pageID: UUID
    @State private var showLinked = true
    @State private var showUnlinked = false

    var body: some View {
        let mentions = store.linkIndex.linkedMentions(of: pageID)
        let grouped = Dictionary(grouping: mentions, by: \.sourceID)
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            DisclosureGroup(isExpanded: $showLinked) {
                if grouped.isEmpty {
                    Text("No pages link here yet. Type [[\(store.page(pageID)?.displayTitle ?? "")]] on another page.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                }
                ForEach(grouped.keys.sorted { (store.page($0)?.displayTitle ?? "") < (store.page($1)?.displayTitle ?? "") }, id: \.self) { source in
                    if let page = store.page(source) {
                        Button { app.open(source) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    PageIconView(page: page, size: 14)
                                    Text(page.displayTitle).font(.subheadline.weight(.semibold))
                                }
                                ForEach(grouped[source] ?? []) { m in
                                    Text(InlineMarkdown.plainText(m.snippet)).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Color(UIColor.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
            } label: {
                Label("\(grouped.count) linked mention\(grouped.count == 1 ? "" : "s")", systemImage: "arrow.turn.down.left")
                    .font(.subheadline.weight(.medium))
            }
            DisclosureGroup(isExpanded: $showUnlinked) {
                if showUnlinked { UnlinkedMentionsList(pageID: pageID) }
            } label: {
                Label("Unlinked mentions", systemImage: "link.badge.plus").font(.subheadline.weight(.medium))
            }
        }
        .tint(.secondary)
        .padding(.top, 8)
    }
}

struct UnlinkedMentionsList: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(AppModel.self) private var app
    let pageID: UUID

    var body: some View {
        if let page = store.page(pageID) {
            let mentions = LinkIndex.unlinkedMentions(of: page, in: store.workspace)
            if mentions.isEmpty {
                Text("No unlinked mentions of “\(page.displayTitle)”.").font(.footnote).foregroundStyle(.secondary).padding(.vertical, 4)
            }
            ForEach(mentions) { m in
                HStack(alignment: .top) {
                    Button { app.open(m.sourceID) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.page(m.sourceID)?.displayTitle ?? "").font(.subheadline.weight(.semibold))
                            Text(m.snippet).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button("Link") { link(m, page: page) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func link(_ m: Backlink, page: Page) {
        guard let blockID = m.blockID else { return }
        store.update(m.sourceID) { p in
            guard let i = p.blocks.firstIndex(where: { $0.id == blockID }) else { return }
            for name in [page.title] + page.aliases {
                if let t = LinkIndex.linkFirstMention(of: name, in: p.blocks[i].text, target: page.displayTitle) {
                    p.blocks[i].text = t
                    break
                }
            }
        }
        Haptics.success()
    }
}

/// Block actions: turn into, colour, move, duplicate, comment, AI, delete.
struct BlockActionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let blockID: UUID
    let model: PageEditorModel

    var body: some View {
        NavigationStack {
            List {
                if let item = model.item(blockID) {
                    Section("Turn into") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach([BlockType.paragraph, .heading1, .heading2, .heading3, .bulleted, .numbered, .todo, .toggle, .quote, .callout, .code], id: \.self) { t in
                                    Button {
                                        model.turnInto(blockID, t)
                                        dismiss()
                                    } label: {
                                        VStack(spacing: 4) {
                                            Image(systemName: t.symbol).font(.title3)
                                            Text(t.title).font(.caption2).lineLimit(1)
                                        }
                                        .frame(width: 74, height: 60)
                                        .background(item.block.type == t ? Palette.accent.opacity(0.18) : Color(UIColor.tertiarySystemFill),
                                                    in: RoundedRectangle(cornerRadius: 10))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    Section("Colour") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(Tint.allCases, id: \.self) { t in
                                    Button { model.update(blockID) { $0.textColor = t } } label: {
                                        Text("A").font(.headline).foregroundStyle(t.text)
                                            .frame(width: 34, height: 34)
                                            .overlay(Circle().stroke(item.block.textColor == t ? Palette.accent : Color.clear, lineWidth: 2))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(Tint.allCases, id: \.self) { t in
                                    Button { model.update(blockID) { $0.background = t } } label: {
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(t == .none ? Color(UIColor.systemBackground) : t.chip)
                                            .frame(width: 34, height: 34)
                                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(item.block.background == t ? Palette.accent : Color(UIColor.separator), lineWidth: item.block.background == t ? 2 : 0.5))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    Section {
                        Button { model.moveUp(blockID) } label: { Label("Move up", systemImage: "arrow.up") }
                        Button { model.moveDown(blockID) } label: { Label("Move down", systemImage: "arrow.down") }
                        Button { model.indent(blockID) } label: { Label("Indent", systemImage: "increase.indent") }
                        Button { model.outdent(blockID) } label: { Label("Outdent", systemImage: "decrease.indent") }
                        if item.block.type.canCollapse {
                            Button { model.toggleCollapsed(blockID) } label: {
                                Label(item.block.collapsed ? "Expand" : "Collapse", systemImage: "chevron.down.circle")
                            }
                        }
                    }
                    Section {
                        Button {
                            model.duplicate(blockID)
                            dismiss()
                        } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                        Button {
                            UIPasteboard.general.string = MarkdownCodec.blocksToMarkdown([item.full])
                            dismiss()
                        } label: { Label("Copy as Markdown", systemImage: "doc.on.doc") }
                        Button {
                            dismiss()
                            model.commentsBlock = blockID
                            model.showComments = true
                        } label: { Label("Comment", systemImage: "text.bubble") }
                        Button {
                            dismiss()
                            model.aiRequest = EditorAIRequest(blockIDs: [blockID], selectedText: item.text, range: nil)
                        } label: { Label("Ask AI", systemImage: "sparkles") }
                    }
                    Section {
                        Button(role: .destructive) {
                            model.delete(blockID)
                            dismiss()
                        } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }
            .navigationTitle("Block")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Pick any page (for link blocks and relations).
struct PagePickerSheet: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let title: String
    var exclude: UUID?
    let onPick: (UUID?) -> Void
    @State private var query = ""
    @State private var picked = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(Search.quickSwitch(query, in: store.workspace, limit: 40).filter { $0.id != exclude }) { page in
                    Button {
                        picked = true
                        onPick(page.id)
                        dismiss()
                    } label: { PageRowLabel(page: page, showPath: true) }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .onDisappear { if !picked { onPick(nil) } }
    }
}

/// Page and block comments.
struct CommentsSheet: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let pageID: UUID
    let blockID: UUID?
    @State private var draft = ""
    @State private var showResolved = false
    @AppStorage("commentAuthor") private var author = "You"

    var body: some View {
        NavigationStack {
            let page = store.page(pageID)
            let all = (page?.comments ?? []).filter { blockID == nil || $0.blockID == blockID }
            let shown = all.filter { showResolved || !$0.resolved }
            List {
                if let blockID, let block = page?.blocks.first(where: { $0.id == blockID }) {
                    Section {
                        Text(block.plainText.isEmpty ? block.type.title : block.plainText).font(.footnote).foregroundStyle(.secondary).lineLimit(4)
                    }
                }
                if shown.isEmpty {
                    Text("No comments yet.").foregroundStyle(.secondary)
                }
                ForEach(shown) { c in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(c.author).font(.subheadline.weight(.semibold))
                            Text(c.createdAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                            if c.resolved { Text("Resolved").font(.caption2).foregroundStyle(.green) }
                            if blockID == nil && c.blockID != nil { Image(systemName: "text.alignleft").font(.caption2).foregroundStyle(.secondary) }
                        }
                        Text(LocalizedStringKey(c.text))
                    }
                    .swipeActions {
                        Button(role: .destructive) { store.update(pageID, touch: false) { $0.comments.removeAll { $0.id == c.id } } } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button { store.update(pageID, touch: false) { p in
                            if let i = p.comments.firstIndex(where: { $0.id == c.id }) { p.comments[i].resolved.toggle() }
                        } } label: { Label(c.resolved ? "Reopen" : "Resolve", systemImage: "checkmark") }
                        .tint(.green)
                    }
                }
                if all.contains(where: \.resolved) {
                    Toggle("Show resolved", isOn: $showResolved)
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    TextField("Add a comment…", text: $draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        store.update(pageID, touch: false) { $0.comments.append(Comment(blockID: blockID, author: author, text: text)) }
                        draft = ""
                    } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding()
                .background(.bar)
            }
            .navigationTitle(blockID == nil ? "Comments" : "Block comments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Earlier versions of a page.
struct HistorySheet: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let pageID: UUID
    @State private var preview: Page?

    var body: some View {
        NavigationStack {
            let snaps = store.snapshots(for: pageID)
            List {
                if snaps.isEmpty {
                    Text("No earlier versions yet. Synapse keeps a version every 10 minutes while you edit.").foregroundStyle(.secondary)
                }
                ForEach(snaps) { s in
                    Button { preview = store.loadSnapshot(s) } label: {
                        VStack(alignment: .leading) {
                            Text(s.date.formatted(date: .abbreviated, time: .shortened))
                            Text(s.date, style: .relative).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Page history")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $preview) { p in
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(p.displayTitle).font(.title.bold())
                            Text(MarkdownCodec.blocksToMarkdown(p.blocks)).font(.callout.monospaced()).textSelection(.enabled)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .navigationTitle(p.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Back") { preview = nil } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Restore") {
                                store.restore(p)
                                preview = nil
                                dismiss()
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Other names a page's [[links]] resolve by.
struct AliasesSheet: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let pageID: UUID
    @State private var newAlias = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.page(pageID)?.aliases ?? [], id: \.self) { a in Text(a) }
                        .onDelete { idx in store.update(pageID, touch: false) { $0.aliases.remove(atOffsets: idx) } }
                    HStack {
                        TextField("Add alias", text: $newAlias)
                        Button("Add") {
                            let a = newAlias.trimmingCharacters(in: .whitespaces)
                            guard !a.isEmpty else { return }
                            store.update(pageID, touch: false) { $0.aliases.append(a) }
                            newAlias = ""
                        }
                    }
                } footer: {
                    Text("[[links]] to any of these names open this page.")
                }
            }
            .navigationTitle("Aliases")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}
