import SwiftUI
import SynapseKit

/// A full-page database.
struct DatabaseScreen: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(AppModel.self) private var app
    let databaseID: UUID
    @State private var viewID: UUID?
    @State private var title = ""
    @State private var titleAtStart = ""
    @FocusState private var titleFocused: Bool
    @State private var showEmoji = false
    @State private var showSchema = false

    var body: some View {
        if let db = store.page(databaseID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let cover = db.cover { CoverView(cover: cover, height: 120) }
                    VStack(alignment: .leading, spacing: 6) {
                        Button { showEmoji = true } label: {
                            if db.icon.isEmpty {
                                Label("Add icon", systemImage: "face.smiling").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text(db.icon).font(.system(size: 44))
                            }
                        }
                        .buttonStyle(.plain)
                        TextField("Untitled database", text: $title, axis: .vertical)
                            .font(.largeTitle.bold())
                            .focused($titleFocused)
                            .onChange(of: title) { _, t in
                                if t.contains("\n") { title = t.replacingOccurrences(of: "\n", with: ""); titleFocused = false; return }
                                if t != store.page(databaseID)?.title { store.update(databaseID) { $0.title = t } }
                            }
                            .onChange(of: titleFocused) { _, f in
                                if f { titleAtStart = db.title } else if titleAtStart != title {
                                    store.update(databaseID) { $0.title = titleAtStart }
                                    store.rename(databaseID, to: title)
                                }
                            }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, db.cover == nil ? 12 : 0)
                    DatabaseHost(databaseID: databaseID, inline: false, viewID: $viewID)
                }
                .padding(.bottom, 40)
            }
            .navigationTitle(db.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                title = db.title
                store.markOpened(databaseID)
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { store.toggleFavorite(databaseID) } label: { Image(systemName: db.isFavorite ? "star.fill" : "star") }
                        .tint(db.isFavorite ? .yellow : nil)
                    Menu {
                        Button { showSchema = true } label: { Label("Properties", systemImage: "list.bullet.rectangle") }
                        Button { store.update(databaseID, touch: false) { $0.cover = $0.cover == nil ? Cover.randomGradient() : nil } } label: {
                            Label(db.cover == nil ? "Add cover" : "Remove cover", systemImage: "photo")
                        }
                        Button { app.push(.graph(focus: databaseID)) } label: { Label("Local graph", systemImage: "point.3.connected.trianglepath.dotted") }
                        Button { UIPasteboard.general.string = MarkdownCodec.export(db, in: store.workspace) } label: {
                            Label("Copy as Markdown table", systemImage: "doc.on.doc")
                        }
                        Button { if let c = store.duplicate(databaseID) { app.open(c) } } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                        Button(role: .destructive) {
                            store.trash(databaseID)
                            app.popOne()
                        } label: { Label("Move to trash", systemImage: "trash") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .sheet(isPresented: $showEmoji) {
                EmojiPicker(current: db.icon) { e in store.update(databaseID, touch: false) { $0.icon = e } }
            }
            .sheet(isPresented: $showSchema) { SchemaSheet(databaseID: databaseID) }
        }
    }
}

/// A database shown inside a page.
struct DatabaseBlockView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(AppModel.self) private var app
    let databaseID: UUID
    let blockViewID: UUID?
    let onSelectView: (UUID?) -> Void
    @State private var viewID: UUID?
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        if let db = store.page(databaseID) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Button { app.open(databaseID) } label: {
                        HStack(spacing: 6) {
                            PageIconView(page: db, size: 18)
                            Text(db.title.isEmpty ? "Untitled database" : db.title)
                                .font(.title3.bold())
                                .foregroundStyle(db.title.isEmpty ? .secondary : .primary)
                            Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button {
                        name = db.title
                        naming = true
                    } label: { Image(systemName: "pencil").font(.caption) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                DatabaseHost(databaseID: databaseID, inline: true, viewID: $viewID)
                    .padding(.horizontal, -20)
            }
            .padding(.vertical, 8)
            .onAppear { if viewID == nil { viewID = blockViewID } }
            .onChange(of: viewID) { _, v in if v != blockViewID { onSelectView(v) } }
            .alert("Database name", isPresented: $naming) {
                TextField("Name", text: $name)
                Button("Save") { store.rename(databaseID, to: name) }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}

/// What a property cell edit refers to.
struct CellTarget: Identifiable, Hashable {
    var id: String { rowID.uuidString + propertyID }
    var rowID: UUID
    var propertyID: String
}

/// View tabs, toolbar and the active view of a database.
struct DatabaseHost: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(AppModel.self) private var app
    let databaseID: UUID
    let inline: Bool
    @Binding var viewID: UUID?

    @State private var search = ""
    @State private var showSearch = false
    @State private var showSettings = false
    @State private var showSchema = false
    @State private var editing: CellTarget?
    @State private var renamingView = false
    @State private var viewName = ""

    var body: some View {
        if let db = store.page(databaseID), let schema = db.schema {
            let view = db.views.first { $0.id == viewID } ?? db.views.first ?? DatabaseView()
            let rows = DatabaseQuery.rows(for: view, database: db, in: store.workspace, search: search)
            VStack(alignment: .leading, spacing: 8) {
                viewBar(db, current: view)
                toolbar(db, view: view, schema: schema, count: rows.count)
                if showSearch {
                    TextField("Search this database", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal, 20)
                }
                Group {
                    switch view.type {
                    case .table: DBTableView(db: db, schema: schema, view: view, rows: rows, edit: { editing = $0 }, newRow: { newRow(db, view: view, schema: schema) })
                    case .board: DBBoardView(db: db, schema: schema, view: view, rows: rows, edit: { editing = $0 })
                    case .list: DBListView(db: db, schema: schema, view: view, rows: rows, newRow: { newRow(db, view: view, schema: schema) })
                    case .gallery: DBGalleryView(db: db, schema: schema, view: view, rows: rows, newRow: { newRow(db, view: view, schema: schema) })
                    case .calendar: DBCalendarView(db: db, schema: schema, view: view, rows: rows, edit: { editing = $0 })
                    case .timeline: DBTimelineView(db: db, schema: schema, view: view, rows: rows)
                    case .chart: DBChartView(db: db, schema: schema, view: view, rows: rows)
                    }
                }
            }
            .sheet(item: $editing) { target in
                PropertyEditorSheet(rowID: target.rowID, propertyID: target.propertyID, databaseID: databaseID)
            }
            .sheet(isPresented: $showSettings) { ViewSettingsSheet(databaseID: databaseID, viewID: view.id) }
            .sheet(isPresented: $showSchema) { SchemaSheet(databaseID: databaseID) }
            .alert("View name", isPresented: $renamingView) {
                TextField("Name", text: $viewName)
                Button("Save") { updateView(view.id) { $0.name = viewName } }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private func updateView(_ id: UUID, _ change: @escaping (inout DatabaseView) -> Void) {
        store.update(databaseID, touch: false) { p in
            if let i = p.views.firstIndex(where: { $0.id == id }) { change(&p.views[i]) }
        }
    }

    // MARK: View tabs

    private func viewBar(_ db: Page, current: DatabaseView) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(db.views) { v in
                    let selected = v.id == current.id
                    Button { viewID = v.id } label: {
                        Label(v.name, systemImage: v.type.symbol)
                            .font(.subheadline.weight(selected ? .semibold : .regular))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(selected ? Color(UIColor.tertiarySystemFill) : Color.clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(selected ? .primary : .secondary)
                    .contextMenu {
                        Button {
                            viewName = v.name
                            viewID = v.id
                            renamingView = true
                        } label: { Label("Rename", systemImage: "pencil") }
                        Button {
                            var copy = v
                            copy.id = UUID()
                            copy.name = v.name + " copy"
                            store.update(databaseID, touch: false) { $0.views.append(copy) }
                            viewID = copy.id
                        } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                        if db.views.count > 1 {
                            Button(role: .destructive) {
                                store.update(databaseID, touch: false) { $0.views.removeAll { $0.id == v.id } }
                                if viewID == v.id { viewID = nil }
                            } label: { Label("Delete view", systemImage: "trash") }
                        }
                    }
                }
                Menu {
                    ForEach(ViewType.allCases, id: \.self) { t in
                        Button { addView(t, db: db) } label: { Label(t.title, systemImage: t.symbol) }
                    }
                } label: {
                    Image(systemName: "plus").font(.subheadline).padding(8)
                }
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
        }
    }

    private func addView(_ type: ViewType, db: Page) {
        guard let schema = db.schema else { return }
        var v = DatabaseView(type: type)
        let groupable = DatabaseQuery.groupable(schema)
        if type == .board || type == .chart {
            v.groupBy = (groupable.first { $0.type == .status } ?? groupable.first)?.id
        }
        if type == .calendar || type == .timeline {
            var props = schema.properties.filter { $0.type == .date }
            if props.isEmpty {
                let p = PropertyDefinition(name: "Date", type: .date)
                store.update(databaseID, touch: false) { $0.schema?.properties.append(p) }
                props = [p]
            }
            v.dateProperty = props.first?.id
        }
        store.update(databaseID, touch: false) { $0.views.append(v) }
        viewID = v.id
    }

    // MARK: Toolbar

    private func toolbar(_ db: Page, view: DatabaseView, schema: DatabaseSchema, count: Int) -> some View {
        HStack(spacing: 14) {
            Button { showSettings = true } label: {
                Label(view.filters.isEmpty ? "Filter" : "\(view.filters.count) filter\(view.filters.count == 1 ? "" : "s")",
                      systemImage: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(view.filters.isEmpty ? Color.secondary : Palette.accent)
            }
            Button { showSettings = true } label: {
                Label(view.sorts.isEmpty ? "Sort" : "\(view.sorts.count) sort\(view.sorts.count == 1 ? "" : "s")", systemImage: "arrow.up.arrow.down")
                    .foregroundStyle(view.sorts.isEmpty ? Color.secondary : Palette.accent)
            }
            Button { withAnimation { showSearch.toggle() } } label: { Image(systemName: "magnifyingglass") }
                .foregroundStyle(showSearch ? Palette.accent : Color.secondary)
            Menu {
                Button { showSettings = true } label: { Label("View settings", systemImage: "slider.horizontal.3") }
                Button { showSchema = true } label: { Label("Properties", systemImage: "list.bullet.rectangle") }
            } label: { Image(systemName: "slider.horizontal.3") }
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(count)").font(.caption).foregroundStyle(.tertiary)
            Button { newRow(db, view: view, schema: schema) } label: {
                Label("New", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Palette.accent, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .labelStyle(.titleAndIcon)
        .font(.footnote)
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
    }

    /// A new row that satisfies the view's "equals" filters, opened as a page.
    private func newRow(_ db: Page, view: DatabaseView, schema: DatabaseSchema) {
        var props: [String: PropertyValue] = [:]
        for f in view.filters where f.op == .equals || f.op == .isChecked || f.op == .contains {
            guard let p = schema.property(id: f.propertyID) else { continue }
            switch p.type {
            case .select, .status:
                if let o = p.option(id: f.value) ?? p.option(named: f.value) { props[p.id] = .select(o.id) }
            case .multiSelect:
                if let o = p.option(id: f.value) ?? p.option(named: f.value) { props[p.id] = .multiSelect([o.id]) }
            case .checkbox: props[p.id] = .checkbox(f.op == .isChecked)
            case .text: props[p.id] = .text(f.value)
            default: break
            }
        }
        if (view.type == .calendar || view.type == .timeline), let d = view.dateProperty, props[d] == nil {
            props[d] = .date(DateValue(start: Calendar.current.startOfDay(for: Date())))
        }
        let template = store.workspace.templates(of: databaseID).first?.id
        if let id = store.newRow(in: databaseID, properties: props, template: template) {
            app.open(id)
        }
    }
}
