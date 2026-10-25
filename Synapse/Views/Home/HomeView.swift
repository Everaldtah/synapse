import SwiftUI
import SynapseKit

struct HomeView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(AppModel.self) private var app
    @State private var showImporter = false
    @State private var showMeeting = false
    @State private var renamingWorkspace = false
    @State private var workspaceName = ""

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        default: return "Good evening"
        }
    }

    var body: some View {
        let ws = store.workspace
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(greeting).font(.largeTitle.bold())
                    Text(DateText.long(Date())).foregroundStyle(.secondary)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
                .listRowBackground(Color.clear)

                HStack(spacing: 10) {
                    QuickAction(title: "Today", symbol: "sun.max") { app.open(store.todayNote()) }
                    QuickAction(title: "New page", symbol: "square.and.pencil") { app.open(store.newPage()) }
                    QuickAction(title: "Record", symbol: "mic") { showMeeting = true }
                    QuickAction(title: "Ask", symbol: "sparkles") { app.tab = .ask }
                    QuickAction(title: "Find", symbol: "arrow.right.circle") { app.showQuickSwitcher = true }
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
            }

            let recent = ws.recent(limit: 10)
            if !recent.isEmpty {
                Section("Jump back in") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(recent) { page in
                                Button { app.open(page.id) } label: { RecentCard(page: page) }
                                    .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }

            let upcoming = UpcomingItem.collect(ws)
            if !upcoming.isEmpty {
                Section("Upcoming") {
                    ForEach(upcoming.prefix(6)) { item in
                        Button { app.open(item.pageID) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).lineLimit(1)
                                    Text(item.context).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(item.when).font(.caption.weight(.medium)).foregroundStyle(item.overdue ? Color.red : Palette.accent)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            let favorites = ws.favorites
            if !favorites.isEmpty {
                Section("Favorites") {
                    ForEach(favorites) { page in
                        PageTreeRow(page: page, depth: 0, showChildren: false)
                    }
                }
            }

            Section {
                PageTree(parent: nil)
                Button {
                    app.open(store.newPage())
                } label: {
                    Label("Add a page", systemImage: "plus").foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text("Pages")
                    Spacer()
                    Menu {
                        Button { app.open(store.newPage()) } label: { Label("Page", systemImage: "doc") }
                        Button { app.open(store.newDatabase(title: "")) } label: { Label("Database", systemImage: "cylinder.split.1x2") }
                        Button { app.push(.templates(parent: nil)) } label: { Label("From a template", systemImage: "square.grid.2x2") }
                    } label: {
                        Image(systemName: "plus").font(.subheadline.weight(.semibold))
                    }
                }
            }

            Section {
                NavigationLink(value: Route.templates(parent: nil)) { Label("Templates", systemImage: "square.grid.2x2") }
                NavigationLink(value: Route.databases) { Label("Databases", systemImage: "cylinder.split.1x2") }
                NavigationLink(value: Route.tags) { Label("Tags", systemImage: "number") }
                Button { showImporter = true } label: { Label("Import Markdown", systemImage: "square.and.arrow.down") }
                NavigationLink(value: Route.trash) {
                    HStack {
                        Label("Trash", systemImage: "trash")
                        Spacer()
                        let n = ws.trash.count
                        if n > 0 { Text("\(n)").foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(store.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    workspaceName = store.name
                    renamingWorkspace = true
                } label: {
                    Image(systemName: "brain.head.profile")
                }
                .accessibilityLabel("Rename workspace")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { app.open(store.newPage()) } label: { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel("New page")
            }
        }
        .alert("Workspace name", isPresented: $renamingWorkspace) {
            TextField("Name", text: $workspaceName)
            Button("Save") { if !workspaceName.isEmpty { store.rename(workspace: workspaceName) } }
            Button("Cancel", role: .cancel) {}
        }
        .markdownImporter(isPresented: $showImporter, parent: nil)
        .sheet(isPresented: $showMeeting) { MeetingNotesSheet() }
    }
}

private struct QuickAction: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.title3)
                Text(title).font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.accent)
    }
}

private struct RecentCard: View {
    let page: Page

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                if let cover = page.cover {
                    CoverView(cover: cover, height: 54)
                } else {
                    Rectangle().fill(Color(UIColor.tertiarySystemFill)).frame(height: 54)
                }
                PageIconView(page: page, size: 24)
                    .padding(6)
                    .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                    .offset(x: 10, y: 16)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(page.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(page.updatedAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.top, 22)
            .padding(.bottom, 10)
            Spacer(minLength: 0)
        }
        .frame(width: 150, height: 140, alignment: .top)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Database rows with a date in the next week (or overdue and not done).
struct UpcomingItem: Identifiable {
    var id: String { pageID.uuidString + when }
    var pageID: UUID
    var title: String
    var context: String
    var when: String
    var date: Date
    var overdue: Bool

    static func collect(_ ws: Workspace) -> [UpcomingItem] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let horizon = cal.date(byAdding: .day, value: 7, to: today)!
        var out: [UpcomingItem] = []
        for db in ws.databases {
            guard let schema = db.schema else { continue }
            let dateProps = schema.properties.filter { $0.type == .date }
            let status = schema.properties.first { $0.type == .status }
            guard !dateProps.isEmpty else { continue }
            for row in ws.rows(of: db.id) {
                if let status, case .select(let sid)? = row.properties[status.id], status.option(id: sid)?.group == .complete { continue }
                for p in dateProps {
                    guard case .date(let d)? = row.properties[p.id] else { continue }
                    let day = cal.startOfDay(for: d.start)
                    let overdue = day < today
                    guard day < horizon, day >= cal.date(byAdding: .day, value: -14, to: today)! else { continue }
                    let when: String
                    if cal.isDateInToday(day) { when = "Today" }
                    else if cal.isDateInTomorrow(day) { when = "Tomorrow" }
                    else if overdue { when = "Overdue" }
                    else { when = d.start.formatted(.dateTime.weekday(.wide)) }
                    out.append(UpcomingItem(pageID: row.id, title: row.displayTitle, context: "\(db.displayTitle) · \(p.name)",
                                            when: when, date: d.start, overdue: overdue))
                }
            }
        }
        return out.sorted { $0.date < $1.date }
    }
}
