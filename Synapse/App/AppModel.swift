import Foundation
import Observation
import SynapseKit

enum AppTab: Hashable {
    case home, search, graph, ask, settings
}

enum Route: Hashable {
    case page(UUID)
    case graph(focus: UUID?)
    case trash
    case templates(parent: UUID?)
    case tags
    case tag(String)
    case databases
}

/// Pairing details from a `synapse://pair?...` link or QR code.
struct PairingRequest: Identifiable, Hashable {
    var id: String { url + token }
    var url: String
    var token: String
    var name: String
}

/// Navigation state: the selected tab and each tab's stack.
@MainActor
@Observable
final class AppModel {
    var tab: AppTab = .home
    var homePath: [Route] = []
    var searchPath: [Route] = []
    var graphPath: [Route] = []
    var askPath: [Route] = []
    var settingsPath: [Route] = []

    var pairing: PairingRequest?
    var showQuickSwitcher = false
    var toast: String?

    /// Push a route on the current tab (Settings and Ask open pages on Home).
    func push(_ route: Route) {
        switch tab {
        case .home: homePath.append(route)
        case .search: searchPath.append(route)
        case .graph: graphPath.append(route)
        case .ask, .settings:
            tab = .home
            homePath.append(route)
        }
    }

    func open(_ pageID: UUID) {
        // Don't stack the same page twice in a row.
        if currentPath.last == .page(pageID) { return }
        push(.page(pageID))
    }

    var currentPath: [Route] {
        switch tab {
        case .home: return homePath
        case .search: return searchPath
        case .graph: return graphPath
        case .ask: return askPath
        case .settings: return settingsPath
        }
    }

    func popToRoot() {
        switch tab {
        case .home: homePath = []
        case .search: searchPath = []
        case .graph: graphPath = []
        case .ask: askPath = []
        case .settings: settingsPath = []
        }
    }

    func show(toast text: String) {
        toast = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if self.toast == text { self.toast = nil }
        }
    }

    /// `synapse://page/<uuid>`, `synapse://open?title=…`, `synapse://pair?url=…&token=…&name=…`
    func handle(url: URL, store: WorkspaceStore) {
        guard url.scheme == "synapse" else { return }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = comps?.queryItems ?? []
        func q(_ name: String) -> String? { items.first { $0.name == name }?.value }
        switch url.host {
        case "page":
            if let id = UUID(uuidString: url.lastPathComponent), store.page(id) != nil { tab = .home; open(id) }
        case "open":
            if let title = q("title"), let id = store.pageForLink(title) { open(id) }
        case "pair":
            if let u = q("url"), let t = q("token") {
                pairing = PairingRequest(url: u, token: t, name: q("name") ?? "")
                tab = .settings
            }
        case "new":
            let id = store.newPage()
            tab = .home
            open(id)
        case "today":
            let id = store.todayNote()
            tab = .home
            open(id)
        default:
            break
        }
    }

    static func link(to pageID: UUID) -> URL { URL(string: "synapse://page/\(pageID.uuidString)")! }

    static func openLink(title: String) -> URL? {
        var c = URLComponents()
        c.scheme = "synapse"
        c.host = "open"
        c.queryItems = [URLQueryItem(name: "title", value: title)]
        return c.url
    }
}
