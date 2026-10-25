import SwiftUI
import PhotosUI
import SynapseKit

/// Blocks that aren't plain text: dividers, media, tables, page links, databases, outlines.
struct SpecialBlockView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(AppModel.self) private var app
    let item: BlockItem
    let model: PageEditorModel
    let ctx: EditorContext

    var body: some View {
        let b = item.block
        switch b.type {
        case .divider:
            Rectangle().fill(Color(UIColor.separator)).frame(height: 1).padding(.vertical, 10)
        case .image:
            ImageBlockView(item: item, model: model)
        case .bookmark, .embed, .file:
            LinkCardBlockView(item: item, model: model)
        case .table:
            TableBlockView(item: item, model: model)
        case .pageLink, .childPage:
            PageLinkBlockView(item: item, model: model)
        case .childDatabase:
            if let db = b.pageID, store.page(db)?.isTrashed == false {
                DatabaseBlockView(databaseID: db, blockViewID: b.viewID) { viewID in
                    model.update(item.id) { $0.viewID = viewID }
                }
            } else {
                Label("Deleted database", systemImage: "trash").foregroundStyle(.secondary).padding(.vertical, 6)
            }
        case .tableOfContents:
            TableOfContentsView(model: model)
        case .breadcrumb:
            BreadcrumbView(pageID: model.pageID)
        default:
            EmptyView()
        }
    }
}

// MARK: - Image

struct ImageBlockView: View {
    let item: BlockItem
    let model: PageEditorModel
    @State private var pick: PhotosPickerItem?
    @State private var urlText = ""
    @State private var showCaption = false

    var body: some View {
        let b = item.block
        VStack(alignment: .leading, spacing: 6) {
            if b.url.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Add an image", systemImage: "photo").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    if !model.readOnly {
                        PhotosPicker(selection: $pick, matching: .images) {
                            Label("Choose from Photos", systemImage: "photo.on.rectangle")
                        }
                        HStack {
                            TextField("Paste an image link", text: $urlText)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .textFieldStyle(.roundedBorder)
                            Button("Embed") {
                                let u = urlText.trimmingCharacters(in: .whitespaces)
                                if u.hasPrefix("http") { model.update(item.id) { $0.url = u } }
                            }
                            .disabled(!urlText.hasPrefix("http"))
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(UIColor.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            } else {
                StoredImage(source: b.url)
                    .frame(maxWidth: .infinity, maxHeight: 460)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .onTapGesture(count: 2) { showCaption = true }
                if !b.caption.isEmpty || showCaption {
                    TextField("Write a caption…", text: Binding(
                        get: { item.block.caption },
                        set: { v in model.update(item.id) { $0.caption = v } }))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .disabled(model.readOnly)
                }
            }
        }
        .padding(.vertical, 4)
        .onChange(of: pick) { _, newValue in
            guard let newValue else { return }
            Task {
                if let data = try? await newValue.loadTransferable(type: Data.self), let ref = AssetStore.saveImage(data) {
                    model.update(item.id) { $0.url = ref }
                }
                pick = nil
            }
        }
    }
}

// MARK: - Bookmark / embed / file

struct LinkCardBlockView: View {
    @Environment(\.openURL) private var openURL
    let item: BlockItem
    let model: PageEditorModel
    @State private var urlText = ""

    var body: some View {
        let b = item.block
        if b.type == .file && AssetStore.isAudio(b.url) {
            AudioAttachmentView(source: b.url, title: b.caption.isEmpty ? "Recording" : b.caption)
                .padding(.vertical, 4)
        } else if b.url.isEmpty {
            HStack {
                Image(systemName: b.type.symbol).foregroundStyle(.secondary)
                TextField(b.type == .file ? "Paste a file link" : "Paste a web link", text: $urlText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onSubmit(save)
                Button("Save", action: save).disabled(urlText.isEmpty)
            }
            .padding(12)
            .background(Color(UIColor.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            .padding(.vertical, 4)
            .disabled(model.readOnly)
        } else {
            let url = URL(string: b.url)
            Button {
                if let url { openURL(url) }
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(b.caption.isEmpty ? (url?.host ?? b.url) : b.caption)
                            .font(.subheadline.weight(.semibold)).lineLimit(2)
                        Text(b.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if b.type == .embed {
                            Label("Embed · opens in Safari", systemImage: "play.rectangle").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: b.type == .file ? "doc" : "globe")
                        .font(.title2)
                        .foregroundStyle(Palette.accent)
                        .frame(width: 52, height: 52)
                        .background(Palette.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).stroke(Color(UIColor.separator)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
        }
    }

    private func save() {
        var u = urlText.trimmingCharacters(in: .whitespaces)
        guard !u.isEmpty else { return }
        if !u.contains("://") { u = "https://" + u }
        model.update(item.id) { $0.url = u }
    }
}

// MARK: - Simple table

struct TableBlockView: View {
    let item: BlockItem
    let model: PageEditorModel

    var body: some View {
        let table = item.block.table
        let cols = table.map(\.count).max() ?? 0
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(table.indices, id: \.self) { r in
                        GridRow {
                            ForEach(0..<cols, id: \.self) { c in
                                cell(r, c, header: (item.block.headerRow && r == 0) || (item.block.headerColumn && c == 0))
                            }
                        }
                    }
                }
                .overlay(Rectangle().stroke(Color(UIColor.separator)))
            }
            if !model.readOnly {
                HStack(spacing: 16) {
                    Button { edit { $0.append(Array(repeating: "", count: max(1, cols))) } } label: { Label("Row", systemImage: "plus") }
                    Button { edit { t in for i in t.indices { t[i].append("") } } } label: { Label("Column", systemImage: "plus") }
                    Menu {
                        Toggle("Header row", isOn: Binding(get: { item.block.headerRow }, set: { v in model.update(item.id) { $0.headerRow = v } }))
                        Toggle("Header column", isOn: Binding(get: { item.block.headerColumn }, set: { v in model.update(item.id) { $0.headerColumn = v } }))
                        Button(role: .destructive) { edit { t in if t.count > 1 { t.removeLast() } } } label: { Label("Delete last row", systemImage: "minus") }
                        Button(role: .destructive) { edit { t in for i in t.indices where t[i].count > 1 { t[i].removeLast() } } } label: { Label("Delete last column", systemImage: "minus") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func edit(_ change: @escaping (inout [[String]]) -> Void) {
        model.update(item.id) { change(&$0.table) }
    }

    private func cell(_ r: Int, _ c: Int, header: Bool) -> some View {
        TextField("", text: Binding(
            get: { r < item.block.table.count && c < item.block.table[r].count ? item.block.table[r][c] : "" },
            set: { v in
                model.update(item.id) { b in
                    while b.table.count <= r { b.table.append([]) }
                    while b.table[r].count <= c { b.table[r].append("") }
                    b.table[r][c] = v
                }
            }), axis: .vertical)
            .font(header ? .subheadline.weight(.semibold) : .subheadline)
            .padding(8)
            .frame(width: 140, alignment: .topLeading)
            .frame(minHeight: 36, alignment: .topLeading)
            .background(header ? Color(UIColor.secondarySystemBackground) : Color.clear)
            .overlay(Rectangle().stroke(Color(UIColor.separator), lineWidth: 0.5))
            .disabled(model.readOnly)
    }
}

// MARK: - Page links

struct PageLinkBlockView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(AppModel.self) private var app
    let item: BlockItem
    let model: PageEditorModel

    var body: some View {
        let b = item.block
        if let id = b.pageID, let page = store.page(id), !page.isTrashed {
            Button { model.commit(); app.open(id) } label: {
                HStack(spacing: 8) {
                    PageIconView(page: page, size: 17)
                    Text(page.displayTitle)
                        .underline(color: Color.secondary.opacity(0.4))
                        .fontWeight(.medium)
                    if b.type == .pageLink {
                        Image(systemName: "arrow.up.right").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else if b.pageID == nil {
            Button { model.pagePickerFor = item.id } label: {
                Label("Choose a page to link", systemImage: "arrow.up.right.square").foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
        } else {
            Label("Deleted page", systemImage: "trash").foregroundStyle(.secondary).padding(.vertical, 6)
        }
    }
}

struct TableOfContentsView: View {
    let model: PageEditorModel

    var body: some View {
        let headings = model.items.filter { $0.block.type.isHeading }
        VStack(alignment: .leading, spacing: 6) {
            if headings.isEmpty {
                Text("Add headings to build a table of contents.").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(headings) { h in
                Button { model.scrollTarget = h.id } label: {
                    Text(InlineMarkdown.plainText(h.text).isEmpty ? "Untitled" : InlineMarkdown.plainText(h.text))
                        .font(.subheadline)
                        .underline(color: Color.secondary.opacity(0.3))
                        .foregroundStyle(.secondary)
                        .padding(.leading, h.block.type == .heading1 ? 0 : (h.block.type == .heading2 ? 14 : 28))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
    }
}

struct BreadcrumbView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(AppModel.self) private var app
    let pageID: UUID

    var body: some View {
        let path = store.workspace.ancestors(of: pageID) + [store.page(pageID)].compactMap { $0 }
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(path.enumerated()), id: \.element.id) { i, p in
                    if i > 0 { Text("/").foregroundStyle(.tertiary) }
                    Button { app.open(p.id) } label: {
                        HStack(spacing: 3) {
                            PageIconView(page: p, size: 12)
                            Text(p.displayTitle).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(p.id == pageID)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}
