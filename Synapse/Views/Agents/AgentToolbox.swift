import Foundation
import SynapseKit

/// Runs one agent's tool calls: the workspace (through the store, so edits save, snapshot and re-index), the graph
/// view, navigation, files, other agents, and — through `AgentRunner` — the web, the shells and Claude Code.
@MainActor
final class AgentToolbox {
    let agent: AgentProfile
    let ai: AIService
    let store: WorkspaceStore
    let app: AppModel
    unowned let center: AgentCenter
    let session: AgentSession
    /// The model this run uses (sub-agents without a model of their own use it too).
    let choice: ModelChoice
    /// 0 for the agent the user talks to, 1 for an agent it asked.
    let depth: Int
    let runner: AgentRunner
    /// Files made in this run (shown with the answer).
    private(set) var produced: [AgentFile] = []
    private var specs: [String: AgentToolSpec] = [:]

    init(agent: AgentProfile, ai: AIService, store: WorkspaceStore, app: AppModel, center: AgentCenter, session: AgentSession,
         choice: ModelChoice, sources: [NotesSource], files: [URL], depth: Int = 0) {
        self.agent = agent
        self.ai = ai
        self.store = store
        self.app = app
        self.center = center
        self.session = session
        self.choice = choice
        self.depth = depth
        runner = AgentRunner(ai: ai, sources: sources, files: files)
    }

    /// The tools this agent may use right now (its capabilities, and what's set up on this iPhone and the bridge).
    func tools(small: Bool) -> [AgentToolSpec] {
        let caps = agent.capabilities
        var t = AgentToolCatalog.appTools(for: caps, small: small)
        for spec in runner.tools(web: caps.contains(.web)) {
            switch spec.name {
            case "shell":
                guard caps.contains(.shell) else { continue }
                t.append(spec)
                if !small { t.append(.saveFile) }
            case AgentToolSpec.claudeCode.name:
                if caps.contains(.claudeCode) && !small { t.append(spec) }
            default:
                t.append(spec)
            }
        }
        if caps.contains(.delegate), depth == 0, !small {
            let others = center.profiles.filter { $0.id != agent.id }.map(\.name)
            if !others.isEmpty { t.append(.askAgent(others)) }
        }
        specs = Dictionary(t.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        return t
    }

    // MARK: - Running a call

    func execute(_ call: AgentToolCall, limit: Int, progress: @escaping (String) -> Void) async throws -> String {
        if specs[call.name]?.changes == true, agent.confirmChanges, !session.allowAll {
            guard await session.ask(call, agent: agent) else {
                return "The user declined this change. Don't try it again; continue without it or ask them."
            }
        }
        let a = call.attributes
        let input = call.input
        switch call.name {
        // Reading
        case "list_pages":
            return WorkspaceOps.listPages(store.workspace, filter: input)
        case "search_workspace":
            return WorkspaceOps.search(input, in: store.workspace, budget: max(2_000, limit))
        case "read_page":
            return try WorkspaceOps.readPage(input, in: store.workspace, index: LinkIndex(workspace: store.workspace))

        // Changing
        case "create_page":
            let title = a["title"] ?? Self.firstHeading(input) ?? ""
            let (id, report) = try change { try WorkspaceOps.createPage(&$0, title: title, markdown: input, parent: a["parent"], icon: a["icon"]) }
            session.touched.insert(id)
            return report
        case "edit_page":
            return try change { try WorkspaceOps.editPage(&$0, title: a["title"] ?? a["page"] ?? "", markdown: input, mode: a["mode"] ?? "append") }
        case "rename_page":
            return try change { try WorkspaceOps.renamePage(&$0, title: a["title"] ?? "", to: input) }
        case "move_page":
            return try change { try WorkspaceOps.movePage(&$0, title: a["title"] ?? "", to: a["to"] ?? input) }
        case "delete_page":
            return try change { try WorkspaceOps.trashPage(&$0, title: a["title"] ?? input) }
        case "link_pages":
            let from = a["from"] ?? a["title"] ?? ""
            return try change { try WorkspaceOps.linkPages(&$0, from: from, to: WorkspaceOps.titles(in: input), createMissing: a["create"]?.lowercased() != "no") }
        case "tag_page":
            let tags = input.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isNewline }).map(String.init)
            return try change { try WorkspaceOps.tagPage(&$0, title: a["title"] ?? "", tags: tags) }
        case "create_database":
            let (id, report) = try change { try WorkspaceOps.createDatabase(&$0, title: a["title"] ?? "", columns: input, parent: a["parent"], icon: a["icon"]) }
            session.touched.insert(id)
            return report
        case "add_rows":
            let rows = CSV.parse(input)
            return try change { try WorkspaceOps.addRows(&$0, database: a["database"] ?? a["title"] ?? "", rows: rows) }
        case "update_row":
            return try change { try WorkspaceOps.updateRow(&$0, database: a["database"], row: a["row"] ?? a["title"] ?? "", values: input) }
        case "daily_note":
            if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                var ws = store.workspace
                let (id, report) = WorkspaceOps.dailyNote(&ws, append: "")
                if store.workspace[id] == nil { store.mutate { $0 = ws } }
                return report
            }
            return try change { WorkspaceOps.dailyNote(&$0, append: input).report }

        // Graph
        case "graph_overview":
            return WorkspaceOps.graphOverview(store.workspace, index: LinkIndex(workspace: store.workspace))
        case "graph_settings":
            return GraphSettingsStore.shared.settings.summary
        case "set_graph":
            return try setGraph(a, input)
        case "graph_group":
            return try graphGroup(input, color: a["color"] ?? a["colour"] ?? "blue")
        case "show_graph":
            return try showGraph(focus: a["focus"] ?? (input.isEmpty ? nil : input), depth: a["depth"])
        case "open":
            return try open(input)

        // Files
        case "create_spreadsheet":
            return try makeFile(.xlsx, title: a["title"], text: input, theme: nil, page: a["page"])
        case "create_presentation":
            return try makeFile(.pptx, title: a["title"], text: input, theme: a["theme"], page: a["page"])
        case "create_document":
            return try makeFile(.docx, title: a["title"], text: input, theme: nil, page: a["page"])
        case "create_pdf":
            return try makeFile(.pdf, title: a["title"], text: input, theme: nil, page: a["page"])
        case "export_page":
            guard let format = DocumentFormat(rawValue: (a["format"] ?? "pdf").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))) else {
                throw AgentToolError("format must be pdf, docx, pptx, xlsx or md.")
            }
            let page = try WorkspaceOps.require(input, in: store.workspace)
            let text = try DocumentMaker.text(for: page, in: store.workspace, format: format)
            let file = try DocumentMaker.save(format, title: page.displayTitle, text: text, theme: a["theme"])
            produced.append(file)
            return "Saved \"\(page.displayTitle)\" as \(file.name) (\(AgentFileStore.format(file.bytes))). It's attached to your reply."
        case "save_file":
            return try await saveFile(input, where: a["where"])

        // Other agents
        case "ask_agent":
            return try await askAgent(a["agent"] ?? "", task: input, progress: progress)

        default:
            // Web, shell, Claude Code and attached sources.
            return try await runner.execute(call, limit: limit, progress: progress)
        }
    }

    /// Apply a workspace change to a copy and commit it only if it succeeds.
    private func change<T>(_ op: (inout Workspace) throws -> T) throws -> T {
        var ws = store.workspace
        let result = try op(&ws)
        store.mutate { $0 = ws }
        session.changed = true
        return result
    }

    static func firstHeading(_ markdown: String) -> String? {
        markdown.split(separator: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Graph view

    /// `set_graph`: attributes and `key: value` / `key=value` lines.
    private func setGraph(_ attributes: [String: String], _ input: String) throws -> String {
        var pairs = attributes.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        for line in input.split(whereSeparator: { $0.isNewline || $0 == "," || $0 == ";" }) {
            let sep = line.firstIndex(of: ":") ?? line.firstIndex(of: "=")
            guard let sep else { continue }
            pairs.append((line[..<sep].trimmingCharacters(in: .whitespaces), line[line.index(after: sep)...].trimmingCharacters(in: .whitespaces)))
        }
        guard !pairs.isEmpty else { throw AgentToolError("Give settings as attributes, e.g. show_tags=\"true\". Keys: \(GraphViewSettings.keys.joined(separator: ", ")).") }
        var settings = GraphSettingsStore.shared.settings
        var changes: [String] = []
        for (k, v) in pairs { changes.append(try settings.set(k, to: v)) }
        GraphSettingsStore.shared.settings = settings
        return changes.joined(separator: "\n")
    }

    private func graphGroup(_ query: String, color raw: String) throws -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var settings = GraphSettingsStore.shared.settings
        if q.lowercased() == "clear" || q.isEmpty && raw.lowercased() == "none" {
            settings.groups = []
            GraphSettingsStore.shared.settings = settings
            return "Removed all colour groups."
        }
        guard !q.isEmpty else { throw AgentToolError("Give the group's query as the input, e.g. tag:biology.") }
        let name = raw.lowercased().trimmingCharacters(in: .whitespaces)
        if ["none", "remove", "delete", "off"].contains(name) {
            let removed = settings.removeGroup(query: q)
            GraphSettingsStore.shared.settings = settings
            return removed ? "Removed the group \(q)." : "There's no group \(q)."
        }
        guard let tint = Tint(rawValue: name == "grey" ? "gray" : name), tint != .none else {
            throw AgentToolError("Unknown colour \(raw). Use gray, brown, orange, yellow, green, blue, purple, pink or red.")
        }
        settings.addGroup(query: q, color: tint)
        GraphSettingsStore.shared.settings = settings
        let ws = store.workspace
        let data = GraphBuilder.build(ws, index: LinkIndex(workspace: ws), options: settings.options)
        let group = GraphGroup(query: q, color: tint)
        let hits = data.nodes.filter { node in group.matches(node, page: node.pageID.flatMap { ws[$0] }, workspace: ws) }
        return "Nodes matching \(q) are now \(tint.rawValue) (\(hits.count) of \(data.nodes.count) nodes: "
            + hits.prefix(8).map(\.title).joined(separator: ", ") + (hits.count > 8 ? ", …" : "") + ")."
    }

    private func showGraph(focus: String?, depth: String?) throws -> String {
        var note = ""
        if let depth {
            var s = GraphSettingsStore.shared.settings
            note = " " + (try s.set("depth", to: depth))
            GraphSettingsStore.shared.settings = s
        }
        app.tab = .graph
        if let focus, !focus.isEmpty {
            let page = try WorkspaceOps.require(focus, in: store.workspace)
            app.graphPath = [.graph(focus: page.id)]
            GraphSettingsStore.shared.requestFit()
            return "Showing the local graph around \"\(page.displayTitle)\" (\(GraphSettingsStore.shared.settings.depth) links away).\(note)"
        }
        app.graphPath = []
        GraphSettingsStore.shared.requestFit()
        return "Showing the whole graph.\(note)"
    }

    private func open(_ target: String) throws -> String {
        let t = WorkspaceOps.cleanTitle(target)
        switch t.lowercased() {
        case "home": app.tab = .home; app.homePath = []; return "Opened Home."
        case "search": app.tab = .search; return "Opened Search."
        case "graph": app.tab = .graph; app.graphPath = []; return "Opened the graph."
        case "agents", "agent": app.tab = .agents; return "Opened Agents."
        case "settings": app.tab = .settings; return "Opened Settings."
        default:
            let page = try WorkspaceOps.require(t, in: store.workspace)
            app.tab = .home
            app.homePath = [.page(page.id)]
            return "Opened \"\(page.displayTitle)\"."
        }
    }

    // MARK: - Files

    private func makeFile(_ format: DocumentFormat, title: String?, text: String, theme: String?, page: String?) throws -> String {
        let name = title.flatMap { $0.isEmpty ? nil : $0 } ?? Self.firstHeading(text) ?? format.title
        let file = try DocumentMaker.save(format, title: name, text: text, theme: theme)
        produced.append(file)
        var what = ""
        switch format {
        case .xlsx: what = OfficeDocument.describe(.xlsx, text: text)
        case .pptx: what = OfficeDocument.describe(.pptx, text: text)
        case .docx: what = OfficeDocument.describe(.docx, text: text)
        case .pdf, .md: what = ""
        }
        var report = "Made \(file.name) (\(AgentFileStore.format(file.bytes))\(what.isEmpty ? "" : ", " + what)). It's attached to your reply and saved in Agent Files."
        if let page, !page.isEmpty {
            let p = try WorkspaceOps.require(page, in: store.workspace, fuzzy: false)
            AgentFileStore.attach(file, to: p.id, store: store)
            session.changed = true
            report += " Also added it to \"\(p.displayTitle)\"."
        }
        return report
    }

    private func saveFile(_ path: String, where target: String?) async throws -> String {
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { throw AgentToolError("Give the file's path, as the shell sees it.") }
        let onPhone = target?.lowercased() == "iphone" || (runner.phoneShell && !runner.pcShell)
        let file: AgentFile
        if onPhone {
            let share = ai.linux.shareDir.standardizedFileURL
            var rel = p
            for prefix in ["/root/share/", "/mnt/share/", "./"] where rel.hasPrefix(prefix) { rel = String(rel.dropFirst(prefix.count)) }
            let url = share.appendingPathComponent(rel).standardizedFileURL
            guard url.path.hasPrefix(share.path + "/"), FileManager.default.fileExists(atPath: url.path) else {
                throw AgentToolError("No file at \(p) in the iPhone's Linux folder. Write it under the current folder (where files/ is) and give that path.")
            }
            file = try AgentFileStore.importFile(url)
        } else {
            guard let bridge = ai.bridgeEndpoint, runner.pcShell else { throw AgentToolError("No computer sandbox is connected.") }
            file = AgentFileStore.record(for: try await bridge.download(p, into: AgentFileStore.directory))
        }
        produced.append(file)
        return "Saved \(file.name) (\(AgentFileStore.format(file.bytes))) to Synapse. It's attached to your reply."
    }

    // MARK: - Other agents

    private func askAgent(_ name: String, task: String, progress: @escaping (String) -> Void) async throws -> String {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let other = center.profiles.first(where: { $0.name.lowercased() == key })
                ?? center.profiles.first(where: { $0.name.lowercased().contains(key) && !key.isEmpty }) else {
            throw AgentToolError("No agent is called \(name). Agents: \(center.profiles.map(\.name).joined(separator: ", ")).")
        }
        guard other.id != agent.id else { throw AgentToolError("That's you; do the task yourself.") }
        progress("\(other.icon) \(other.name) is working on it")
        let result = try await center.runSubagent(other, task: task, parent: self, progress: progress)
        produced += result.files
        return "\(other.name) answered:\n\(result.answer)"
    }
}
