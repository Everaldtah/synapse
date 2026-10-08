import SwiftUI
import UniformTypeIdentifiers
import SynapseKit

/// The sidebar tree: pages and databases nested under their parents.
struct PageTree: View {
    @Environment(WorkspaceStore.self) private var store
    let parent: UUID?
    var depth = 0

    var body: some View {
        ForEach(store.workspace.children(of: parent)) { page in
            PageTreeRow(page: page, depth: depth, showChildren: true)
        }
    }
}

struct PageTreeRow: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(AppModel.self) private var app
    @AppStorage("expandedPages") private var expandedRaw = ""
    let page: Page
    let depth: Int
    var showChildren: Bool

    @State private var renaming = false
    @State private var newTitle = ""
    @State private var moving = false
    @State private var dropTargeted = false

    private var expanded: Bool { expandedRaw.contains(page.id.uuidString) }

    private func toggle() {
        var ids = Set(expandedRaw.split(separator: ",").map(String.init))
        if ids.contains(page.id.uuidString) { ids.remove(page.id.uuidString) } else { ids.insert(page.id.uuidString) }
        expandedRaw = ids.joined(separator: ",")
    }

    var body: some View {
        let hasChildren = showChildren && store.workspace.hasChildren(page.id)
        HStack(spacing: 6) {
            if showChildren {
                Button(action: toggle) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(hasChildren ? .secondary : .quaternary)
                        .rotationEffect(.degrees(expanded && hasChildren ? 90 : 0))
                        .frame(width: 18, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!hasChildren)
            }
            Button { app.open(page.id) } label: {
                HStack(spacing: 8) {
                    PageIconView(page: page, size: 16).frame(width: 22)
                    Text(page.displayTitle)
                        .foregroundStyle(page.title.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, CGFloat(depth) * 16)
        .listRowBackground(dropTargeted ? Palette.accent.opacity(0.15) : nil)
        .draggable(page.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            var moved = false
            for s in items {
                if let id = UUID(uuidString: s), id != page.id, store.move(id, to: page.id) { moved = true }
            }
            if moved && !expanded { toggle() }
            return moved
        } isTargeted: { dropTargeted = $0 }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { store.trash(page.id) } label: { Label("Delete", systemImage: "trash") }
            Button { store.toggleFavorite(page.id) } label: {
                Label(page.isFavorite ? "Unfavorite" : "Favorite", systemImage: page.isFavorite ? "star.slash" : "star")
            }
            .tint(.yellow)
        }
        .contextMenu { menu }
        .alert("Rename", isPresented: $renaming) {
            TextField("Title", text: $newTitle)
            Button("Save") { store.rename(page.id, to: newTitle) }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $moving) { MovePageSheet(pageID: page.id) }

        if hasChildren && expanded {
            PageTree(parent: page.id, depth: depth + 1)
        }
    }

    @ViewBuilder private var menu: some View {
        Button { app.open(store.newPage(parent: page.id)) } label: { Label("Add sub-page", systemImage: "plus") }
        Button {
            newTitle = page.title
            renaming = true
        } label: { Label("Rename", systemImage: "pencil") }
        Button { store.toggleFavorite(page.id) } label: {
            Label(page.isFavorite ? "Remove from favorites" : "Add to favorites", systemImage: page.isFavorite ? "star.slash" : "star")
        }
        Button { if let c = store.duplicate(page.id) { app.open(c) } } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
        Button { moving = true } label: { Label("Move to…", systemImage: "arrow.turn.up.right") }
        Button { UIPasteboard.general.string = "[[\(page.displayTitle)]]" } label: { Label("Copy [[link]]", systemImage: "link") }
        Button { app.push(.graph(focus: page.id)) } label: { Label("Local graph", systemImage: "point.3.connected.trianglepath.dotted") }
        Divider()
        Button(role: .destructive) { store.trash(page.id) } label: { Label("Move to trash", systemImage: "trash") }
    }
}

/// Pick a new parent for a page.
struct MovePageSheet: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let pageID: UUID
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                Button {
                    store.move(pageID, to: nil)
                    dismiss()
                } label: {
                    Label("Top level", systemImage: "tray.full")
                }
                let ws = store.workspace
                let candidates = ws.livePages.filter { p in
                    p.id != pageID && !ws.isDescendant(p.id, of: pageID) && p.kind != .row && !p.isTemplate
                        && (query.isEmpty || p.displayTitle.localizedCaseInsensitiveContains(query))
                }
                .sorted { $0.displayTitle.lowercased() < $1.displayTitle.lowercased() }
                ForEach(candidates) { p in
                    Button {
                        store.move(pageID, to: p.id)
                        dismiss()
                    } label: {
                        PageRowLabel(page: p, showPath: true)
                    }
                    .buttonStyle(.plain)
                }
            }
            .searchable(text: $query, prompt: "Move to…")
            .navigationTitle("Move to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
