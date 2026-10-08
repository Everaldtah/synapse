import SwiftUI
import SynapseKit

struct SearchView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var scope = SearchScope.all
    @AppStorage("recentSearches") private var recentRaw = ""

    enum SearchScope: String, CaseIterable {
        case all, pages, databases, rows

        var title: String {
            switch self {
            case .all: return "All"
            case .pages: return "Pages"
            case .databases: return "Databases"
            case .rows: return "Rows"
            }
        }

        var kinds: Set<PageKind> {
            switch self {
            case .all: return [.page, .database, .row]
            case .pages: return [.page]
            case .databases: return [.database]
            case .rows: return [.row]
            }
        }
    }

    private var recents: [String] { recentRaw.split(separator: "\u{1F}").map(String.init) }

    private func remember(_ q: String) {
        let t = q.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        recentRaw = ([t] + recents.filter { $0 != t }).prefix(8).joined(separator: "\u{1F}")
    }

    var body: some View {
        List {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                if !recents.isEmpty {
                    Section("Recent searches") {
                        ForEach(recents, id: \.self) { r in
                            Button { query = r } label: { Label(r, systemImage: "clock.arrow.circlepath") }
                                .foregroundStyle(.primary)
                        }
                        Button("Clear", role: .destructive) { recentRaw = "" }.font(.footnote)
                    }
                }
                Section("Recently opened") {
                    ForEach(store.workspace.recent(limit: 8)) { page in
                        Button { app.open(page.id) } label: { PageRowLabel(page: page, showPath: true) }
                            .buttonStyle(.plain)
                    }
                }
                let tags = store.linkIndex.tagCounts.prefix(16)
                if !tags.isEmpty {
                    Section("Tags") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(Array(tags), id: \.tag) { t in
                                    Button { app.push(.tag(t.tag)) } label: {
                                        Text("#\(t.tag)  \(t.count)").font(.footnote)
                                            .padding(.horizontal, 10).padding(.vertical, 5)
                                            .background(Palette.accent.opacity(0.12), in: Capsule())
                                            .foregroundStyle(Palette.accent)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            } else {
                let hits = Search.run(query, in: store.workspace, kinds: scope.kinds)
                if hits.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    Section("\(hits.count) result\(hits.count == 1 ? "" : "s")") {
                        ForEach(hits) { hit in
                            if let page = store.page(hit.pageID) {
                                Button {
                                    remember(query)
                                    app.open(hit.pageID)
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        PageRowLabel(page: page, showPath: true)
                                        if !hit.snippet.isEmpty {
                                            Text(highlight(hit.snippet, query)).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                                                .padding(.leading, 36)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                Section {
                    Button {
                        remember(query)
                        let id = store.newPage(title: query.trimmingCharacters(in: .whitespaces))
                        app.open(id)
                    } label: { Label("New page “\(query)”", systemImage: "plus") }
                }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search pages, text and properties")
        .searchScopes($scope) {
            ForEach(SearchScope.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .onSubmit(of: .search) { remember(query) }
        .navigationTitle("Search")
    }

    private func highlight(_ text: String, _ query: String) -> AttributedString {
        var s = AttributedString(text)
        for word in query.split(separator: " ") where word.count > 1 {
            var searchRange = s.startIndex..<s.endIndex
            while let r = s[searchRange].range(of: String(word), options: [.caseInsensitive, .diacriticInsensitive]) {
                s[r].foregroundColor = Palette.accent
                s[r].inlinePresentationIntent = .stronglyEmphasized
                searchRange = r.upperBound..<s.endIndex
            }
        }
        return s
    }
}
