import SwiftUI
import SynapseKit

/// Shows any page: databases get the database screen, pages and rows get the document editor.
struct PageScreen: View {
    @Environment(WorkspaceStore.self) private var store
    let pageID: UUID

    var body: some View {
        if let page = store.page(pageID) {
            if page.kind == .database {
                DatabaseScreen(databaseID: pageID)
            } else {
                DocumentScreen(pageID: pageID)
            }
        } else {
            ContentUnavailableView("Page not found", systemImage: "doc.questionmark", description: Text("It may have been deleted."))
        }
    }
}

struct DocumentScreen: View {
    @Environment(WorkspaceStore.self) private var store
    let pageID: UUID
    @State private var model: PageEditorModel?

    var body: some View {
        Group {
            if let model {
                DocumentContent(model: model, pageID: pageID)
            } else {
                Color.clear
            }
        }
        .onAppear {
            if model == nil { model = PageEditorModel(pageID: pageID, store: store) } else { model?.reload() }
            store.markOpened(pageID)
        }
        .onDisappear { model?.commit() }
    }
}

struct DocumentContent: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(AppModel.self) private var app
    @Bindable var model: PageEditorModel
    let pageID: UUID

    @State private var showHistory = false
    @State private var showAI = false
    @State private var exportURL: URL?
    @State private var showAliases = false

    var body: some View {
        let page = store.page(pageID) ?? Page()
        let ctx = editorContext(page)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    PageHeaderView(pageID: pageID, onReturn: focusFirstBlock)
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.visible) { row in
                            BlockRowView(row: row, model: model, ctx: ctx)
                                .id(row.id)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 4)

                    Color.clear
                        .frame(height: 120)
                        .contentShape(Rectangle())
                        .onTapGesture { model.tapBelowContent() }

                    BacklinksSection(pageID: pageID)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 40)
                }
                .frame(maxWidth: page.fullWidth ? .infinity : 780, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.focusedID) { _, id in
                guard let id else { return }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: nil) }
                }
            }
            .onChange(of: model.scrollTarget) { _, id in
                guard let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .top) }
                model.scrollTarget = nil
            }
        }
        .safeAreaInset(edge: .bottom) {
            if model.slash != nil {
                SlashMenuView(model: model)
            } else if model.link != nil {
                LinkPickerView(model: model)
            }
        }
        .navigationTitle(page.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar(page) }
        .onChange(of: page.locked) { _, locked in model.readOnly = locked }
        .onChange(of: store.revision) { _, _ in
            // Pick up changes made outside the editor (AI inserts, history restore, link fixes).
            if model.focusedID == nil { model.reload() }
        }
        .onAppear {
            model.openPage = { id in app.open(id) }
            model.readOnly = page.locked
        }
        .sheet(item: Binding(get: { model.actionsFor.map { IDBox(id: $0) } }, set: { model.actionsFor = $0?.id })) { box in
            BlockActionsSheet(blockID: box.id, model: model)
        }
        .sheet(item: Binding(get: { model.pagePickerFor.map { IDBox(id: $0) } }, set: { model.pagePickerFor = $0?.id })) { box in
            PagePickerSheet(title: "Link to page", exclude: pageID) { picked in
                if let picked { model.update(box.id) { $0.pageID = picked } } else if model.item(box.id)?.block.pageID == nil { model.delete(box.id) }
            }
        }
        .sheet(item: $model.aiRequest) { req in
            AIEditSheet(request: req, model: model)
        }
        .sheet(isPresented: $model.showComments) {
            CommentsSheet(pageID: pageID, blockID: model.commentsBlock)
        }
        .sheet(isPresented: $showHistory) { HistorySheet(pageID: pageID) }
        .sheet(isPresented: $showAliases) { AliasesSheet(pageID: pageID) }
        .sheet(item: Binding(get: { exportURL.map { ShareFile(url: $0) } }, set: { exportURL = $0?.url })) { file in
            ShareSheet(items: [file.url])
        }
    }

    private func focusFirstBlock() {
        if let first = model.items.first, first.block.type.isTextual { model.focus(first.id, at: 0) }
    }

    private func editorContext(_ page: Page) -> EditorContext {
        let ws = store.workspace
        var counts: [UUID: Int] = [:]
        for c in page.comments where !c.resolved { if let b = c.blockID { counts[b, default: 0] += 1 } }
        return EditorContext(
            pageFont: page.font,
            smallText: page.smallText,
            resolves: { ws.resolve($0) != nil },
            openLink: { target in
                model.commit()
                if let id = store.pageForLink(target) { app.open(id) }
            },
            openURL: { url in UIApplication.shared.open(url) },
            openTag: { tag in app.push(.tag(tag)) },
            openDate: { d in
                if let date = DateText.parse(d) {
                    let id = store.mutate { $0.dailyNote(for: date) }
                    app.open(id)
                }
            },
            commentCounts: counts
        )
    }

    @ToolbarContentBuilder
    private func toolbar(_ page: Page) -> some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { store.toggleFavorite(pageID) } label: {
                Image(systemName: page.isFavorite ? "star.fill" : "star")
            }
            .tint(page.isFavorite ? .yellow : nil)
            .accessibilityLabel(page.isFavorite ? "Remove from favorites" : "Add to favorites")

            Button {
                model.aiRequest = EditorAIRequest(blockIDs: model.items.map(\.id), selectedText: "", range: nil)
            } label: { Image(systemName: "sparkles") }
            .accessibilityLabel("Ask AI about this page")

            Menu {
                PageMenuContent(pageID: pageID, showHistory: $showHistory, showAliases: $showAliases, onExport: exportMarkdown,
                                onComments: {
                                    model.commentsBlock = nil
                                    model.showComments = true
                                })
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private func exportMarkdown() {
        model.commit()
        guard let page = store.page(pageID) else { return }
        let md = MarkdownCodec.export(page, in: store.workspace, includeTitle: true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(MarkdownCodec.fileName(for: page.displayTitle) + ".md")
        try? md.data(using: .utf8)?.write(to: url)
        exportURL = url
    }
}

struct IDBox: Identifiable {
    var id: UUID
}

struct ShareFile: Identifiable {
    var id: URL { url }
    var url: URL
}

/// UIActivityViewController for files.
struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// The ••• menu of a page.
struct PageMenuContent: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let pageID: UUID
    @Binding var showHistory: Bool
    @Binding var showAliases: Bool
    var onExport: () -> Void
    var onComments: () -> Void

    var body: some View {
        if let page = store.page(pageID) {
            Section {
                Picker("Font", selection: Binding(get: { page.font }, set: { f in store.update(pageID, touch: false) { $0.font = f } })) {
                    ForEach(PageFont.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Small text", isOn: Binding(get: { page.smallText }, set: { v in store.update(pageID, touch: false) { $0.smallText = v } }))
                Toggle("Full width", isOn: Binding(get: { page.fullWidth }, set: { v in store.update(pageID, touch: false) { $0.fullWidth = v } }))
                Toggle("Lock page", isOn: Binding(get: { page.locked }, set: { v in store.update(pageID, touch: false) { $0.locked = v } }))
            }
            Section {
                Button(action: onComments) { Label("Comments", systemImage: "text.bubble") }
                Button { showHistory = true } label: { Label("Page history", systemImage: "clock.arrow.circlepath") }
                Button { showAliases = true } label: { Label("Aliases", systemImage: "tag") }
                Button { app.push(.graph(focus: pageID)) } label: { Label("Local graph", systemImage: "point.3.connected.trianglepath.dotted") }
            }
            Section {
                Button { UIPasteboard.general.string = "[[\(page.displayTitle)]]" } label: { Label("Copy [[link]]", systemImage: "link") }
                Button { UIPasteboard.general.url = AppModel.link(to: pageID) } label: { Label("Copy app link", systemImage: "link.badge.plus") }
                Button(action: onExport) { Label("Export Markdown", systemImage: "square.and.arrow.up") }
                Button { if let c = store.duplicate(pageID) { app.open(c) } } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                Button { app.open(store.newPage(parent: pageID)) } label: { Label("Add sub-page", systemImage: "doc.badge.plus") }
            }
            Section {
                Button(role: .destructive) {
                    store.trash(pageID)
                    app.popOne()
                } label: { Label("Move to trash", systemImage: "trash") }
            }
        }
    }
}

extension AppModel {
    /// Pop the top page of the current tab.
    func popOne() {
        switch tab {
        case .home: if !homePath.isEmpty { homePath.removeLast() }
        case .search: if !searchPath.isEmpty { searchPath.removeLast() }
        case .graph: if !graphPath.isEmpty { graphPath.removeLast() }
        case .ask: if !askPath.isEmpty { askPath.removeLast() }
        case .settings: if !settingsPath.isEmpty { settingsPath.removeLast() }
        }
    }
}
