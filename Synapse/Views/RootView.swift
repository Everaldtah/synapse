import SwiftUI
import SynapseKit

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(WorkspaceStore.self) private var store

    var body: some View {
        @Bindable var app = app
        TabView(selection: $app.tab) {
            NavigationStack(path: $app.homePath) {
                HomeView().withRoutes()
            }
            .tabItem { Label("Home", systemImage: "house") }
            .tag(AppTab.home)

            NavigationStack(path: $app.searchPath) {
                SearchView().withRoutes()
            }
            .tabItem { Label("Search", systemImage: "magnifyingglass") }
            .tag(AppTab.search)

            NavigationStack(path: $app.graphPath) {
                GraphScreen(focus: nil).withRoutes()
            }
            .tabItem { Label("Graph", systemImage: "point.3.filled.connected.trianglepath.dotted") }
            .tag(AppTab.graph)

            NavigationStack(path: $app.agentsPath) {
                AgentsHomeView().withRoutes()
            }
            .tabItem { Label("Agents", systemImage: "sparkles") }
            .tag(AppTab.agents)

            NavigationStack(path: $app.settingsPath) {
                SettingsView().withRoutes()
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(AppTab.settings)
        }
        .overlay(alignment: .top) {
            if let toast = app.toast {
                Text(toast)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 6, y: 2)
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: app.toast)
        .sheet(isPresented: $app.showQuickSwitcher) {
            QuickSwitcher()
        }
    }
}

extension View {
    /// The destinations every tab's stack can show.
    func withRoutes() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .page(let id): PageScreen(pageID: id)
            case .graph(let focus): GraphScreen(focus: focus)
            case .trash: TrashView()
            case .templates(let parent): TemplateGallery(parent: parent)
            case .tags: TagsView()
            case .tag(let t): TagPagesView(tag: t)
            case .databases: DatabasesListView()
            case .ask: AskView()
            case .agentChat(let id): AgentChatView(conversationID: id)
            case .agentEditor(let id): AgentEditorView(agentID: id)
            case .agentFiles: AgentFilesView()
            case .terminal: TerminalView()
            case .computer: ComputerView()
            case .apiProviders: APIProvidersView()
            }
        }
    }
}

/// Jump to any page by name (fuzzy).
struct QuickSwitcher: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                let results = Search.quickSwitch(query, in: store.workspace)
                ForEach(results) { page in
                    Button {
                        dismiss()
                        app.open(page.id)
                    } label: {
                        PageRowLabel(page: page, showPath: true)
                    }
                    .buttonStyle(.plain)
                }
                if !query.trimmingCharacters(in: .whitespaces).isEmpty && store.workspace.resolve(query) == nil {
                    Button {
                        let id = store.newPage(title: query.trimmingCharacters(in: .whitespaces))
                        dismiss()
                        app.open(id)
                    } label: {
                        Label("Create “\(query)”", systemImage: "plus")
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Jump to a page")
            .navigationTitle("Go to page")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .presentationDetents([.large])
    }
}

/// Icon + title (+ optional breadcrumb path) for page lists.
struct PageRowLabel: View {
    @Environment(WorkspaceStore.self) private var store
    let page: Page
    var showPath = false
    var subtitle: String?

    var body: some View {
        HStack(spacing: 10) {
            PageIconView(page: page, size: 18).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(page.displayTitle)
                    .foregroundStyle(page.title.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                } else if showPath {
                    let path = store.workspace.ancestors(of: page.id).map(\.displayTitle)
                    if !path.isEmpty {
                        Text(path.joined(separator: " / ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}
