import SwiftUI
import SynapseKit

struct TrashView: View {
    @Environment(WorkspaceStore.self) private var store
    @State private var confirmEmpty = false

    var body: some View {
        let items = store.workspace.trash
        List {
            if items.isEmpty {
                ContentUnavailableView("Trash is empty", systemImage: "trash", description: Text("Deleted pages stay here until you remove them."))
            }
            ForEach(items) { page in
                HStack {
                    PageRowLabel(page: page, subtitle: page.trashedAt.map { "Deleted " + $0.formatted(.relative(presentation: .named)) })
                    Spacer()
                    Button { store.restore(page.id); Haptics.success() } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(.borderless)
                }
                .swipeActions {
                    Button(role: .destructive) { store.deleteForever(page.id) } label: { Label("Delete forever", systemImage: "trash.slash") }
                    Button { store.restore(page.id) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }.tint(.green)
                }
            }
        }
        .navigationTitle("Trash")
        .toolbar {
            if !items.isEmpty {
                Button("Empty", role: .destructive) { confirmEmpty = true }
            }
        }
        .confirmationDialog("Delete everything in the trash forever?", isPresented: $confirmEmpty, titleVisibility: .visible) {
            Button("Empty trash", role: .destructive) { store.emptyTrash() }
        }
    }
}

struct TemplateGallery: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(AppModel.self) private var app
    let parent: UUID?

    var body: some View {
        List {
            Section("Pages") {
                ForEach(TemplateKind.allCases.filter { !$0.isDatabase }) { t in row(t) }
            }
            Section("Databases") {
                ForEach(TemplateKind.allCases.filter(\.isDatabase)) { t in row(t) }
            }
        }
        .navigationTitle("Templates")
    }

    private func row(_ t: TemplateKind) -> some View {
        Button {
            let id = store.mutate { Templates.instantiate(t, in: &$0, parent: parent) }
            app.open(id)
        } label: {
            HStack(spacing: 12) {
                Text(t.icon).font(.title2).frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.title).font(.body.weight(.medium))
                    Text(t.summary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "plus.circle").foregroundStyle(Palette.accent)
            }
        }
        .buttonStyle(.plain)
    }
}

struct TagsView: View {
    @Environment(WorkspaceStore.self) private var store

    var body: some View {
        let tags = store.linkIndex.tagCounts
        List {
            if tags.isEmpty {
                ContentUnavailableView("No tags yet", systemImage: "number", description: Text("Type #tag in any page. Nested tags like #project/alpha work too."))
            }
            ForEach(tags, id: \.tag) { t in
                NavigationLink(value: Route.tag(t.tag)) {
                    HStack {
                        Text("#" + t.tag).foregroundStyle(Palette.accent)
                        Spacer()
                        Text("\(t.count)").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Tags")
    }
}

struct TagPagesView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(AppModel.self) private var app
    let tag: String

    var body: some View {
        let key = tag.lowercased()
        // Nested tags: #project includes #project/alpha.
        let ids = store.linkIndex.tags.filter { $0.key == key || $0.key.hasPrefix(key + "/") }.flatMap(\.value)
        let pages = Set(ids).compactMap { store.page($0) }.sorted { $0.updatedAt > $1.updatedAt }
        List {
            ForEach(pages) { page in
                Button { app.open(page.id) } label: { PageRowLabel(page: page, subtitle: page.excerpt(maxLength: 100)) }
                    .buttonStyle(.plain)
            }
        }
        .navigationTitle("#" + tag)
        .toolbar {
            Button {
                let id = store.newPage(title: "", blocks: [Block(text: "#" + tag + " ")])
                app.open(id)
            } label: { Image(systemName: "plus") }
        }
    }
}

struct DatabasesListView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(AppModel.self) private var app

    var body: some View {
        List {
            ForEach(store.workspace.databases) { db in
                Button { app.open(db.id) } label: {
                    PageRowLabel(page: db, subtitle: "\(store.workspace.rows(of: db.id).count) rows · \(db.schema?.properties.count ?? 0) properties")
                }
                .buttonStyle(.plain)
            }
            Button {
                app.open(store.newDatabase(title: ""))
            } label: { Label("New database", systemImage: "plus") }
        }
        .navigationTitle("Databases")
    }
}
