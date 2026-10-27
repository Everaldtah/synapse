import Foundation

/// What an agent is allowed to do. Each maps to a group of tools (`AgentToolCatalog`).
public enum AgentCapability: String, Codable, CaseIterable, Identifiable, Sendable {
    /// List, search and read pages and databases.
    case readWorkspace
    /// Create, edit, link, tag, move and trash pages; build databases and rows.
    case editWorkspace
    /// Inspect the graph and change the graph view (filters, groups, colours, forces).
    case graph
    /// Open pages and tabs in the app.
    case navigate
    /// Make spreadsheets, presentations, Word documents and PDFs.
    case documents
    /// Search and read the web.
    case web
    /// Run commands in a Linux shell (on the iPhone or the bridge computer's sandbox).
    case shell
    /// Hand hard tasks to Claude Code on the bridge computer.
    case claudeCode
    /// Give sub-tasks to other agents.
    case delegate

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .readWorkspace: return "Read the workspace"
        case .editWorkspace: return "Change pages and databases"
        case .graph: return "Graph view"
        case .navigate: return "Open pages and tabs"
        case .documents: return "Make files (Excel, PowerPoint, Word, PDF)"
        case .web: return "Search and read the web"
        case .shell: return "Linux terminal"
        case .claudeCode: return "Claude Code (bridge)"
        case .delegate: return "Ask other agents"
        }
    }

    public var symbol: String {
        switch self {
        case .readWorkspace: return "doc.text.magnifyingglass"
        case .editWorkspace: return "square.and.pencil"
        case .graph: return "point.3.filled.connected.trianglepath.dotted"
        case .navigate: return "arrow.up.forward.app"
        case .documents: return "doc.richtext"
        case .web: return "globe"
        case .shell: return "terminal"
        case .claudeCode: return "sparkles.rectangle.stack"
        case .delegate: return "person.2"
        }
    }
}

/// An agent: a persona with instructions, the tools it may use and the model it runs on.
public struct AgentProfile: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Emoji.
    public var icon: String
    /// One line for lists.
    public var summary: String
    /// Added to the system prompt.
    public var instructions: String
    public var capabilities: Set<AgentCapability>
    /// A model key (see `AgentModelKey`); "" = Auto.
    public var model: String
    /// Tool calls allowed in one run.
    public var maxSteps: Int
    /// Ask before each change to the workspace.
    public var confirmChanges: Bool
    /// Shipped with the app (can be edited or reset, not deleted).
    public var builtIn: Bool
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, icon: String = "🤖", summary: String = "", instructions: String = "",
                capabilities: Set<AgentCapability> = Set(AgentCapability.allCases), model: String = "", maxSteps: Int = 24,
                confirmChanges: Bool = false, builtIn: Bool = false, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.icon = icon
        self.summary = summary
        self.instructions = instructions
        self.capabilities = capabilities
        self.model = model
        self.maxSteps = maxSteps
        self.confirmChanges = confirmChanges
        self.builtIn = builtIn
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID())
        name = c.value(.name, "Agent")
        icon = c.value(.icon, "🤖")
        summary = c.value(.summary, "")
        instructions = c.value(.instructions, "")
        // Unknown capability names from a newer version are skipped rather than failing the whole profile.
        let raw: [String] = c.value(.capabilities, [])
        capabilities = Set(raw.compactMap(AgentCapability.init(rawValue:)))
        model = c.value(.model, "")
        maxSteps = c.value(.maxSteps, 24)
        confirmChanges = c.value(.confirmChanges, false)
        builtIn = c.value(.builtIn, false)
        createdAt = c.value(.createdAt, Date())
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(icon, forKey: .icon)
        try c.encode(summary, forKey: .summary)
        try c.encode(instructions, forKey: .instructions)
        try c.encode(capabilities.map(\.rawValue).sorted(), forKey: .capabilities)
        try c.encode(model, forKey: .model)
        try c.encode(maxSteps, forKey: .maxSteps)
        try c.encode(confirmChanges, forKey: .confirmChanges)
        try c.encode(builtIn, forKey: .builtIn)
        try c.encode(createdAt, forKey: .createdAt)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, icon, summary, instructions, capabilities, model, maxSteps, confirmChanges, builtIn, createdAt
    }
}

/// The agents Synapse ships with. Their ids are fixed so edits survive updates and "Reset" can find the original.
public enum AgentPresets {
    public static let synapse = AgentProfile(
        id: UUID(uuidString: "5E0A6E47-0000-4000-8000-000000000001")!, name: "Synapse Agent", icon: "⚡️",
        summary: "Does anything in the app: pages, databases, links, the graph, files, web and terminal",
        instructions: """
        You operate the Synapse app for the user. You can read and change their pages and databases, connect notes \
        with [[links]] and #tags, shape the graph view, open pages, make Excel/PowerPoint/Word/PDF files, research \
        the web and run code. Plan briefly, then act with tools; check your work by reading back what you changed. \
        Never delete or replace content unless the user asked for it.
        """,
        capabilities: Set(AgentCapability.allCases), maxSteps: 40, builtIn: true)

    public static let researcher = AgentProfile(
        id: UUID(uuidString: "5E0A6E47-0000-4000-8000-000000000002")!, name: "Researcher", icon: "🔎",
        summary: "Researches on the web and writes sourced notes into your workspace",
        instructions: """
        You are a careful researcher. Search the web several times with different queries, read the best primary \
        sources (not just snippets), compare them, and note where they disagree. Cite every factual claim with a \
        Markdown link. When the user wants a write-up, save it as a page (create_page) with a ## Sources section, link \
        it to related pages already in the workspace, and tell the user which page you made.
        """,
        capabilities: [.web, .readWorkspace, .editWorkspace, .documents, .shell, .claudeCode, .navigate],
        maxSteps: 30, builtIn: true)

    public static let graphArchitect = AgentProfile(
        id: UUID(uuidString: "5E0A6E47-0000-4000-8000-000000000003")!, name: "Graph Architect", icon: "🕸️",
        summary: "Turns notes into a connected knowledge graph and styles the graph view",
        instructions: """
        You organise the user's notes as an Obsidian-style knowledge graph. Use graph_overview to find hubs, orphans \
        and unlinked mentions; connect related pages with link_pages, add #tags, and create hub pages (maps of \
        content) that link to each topic's notes. Then shape the view: colour groups (graph_group), filters and \
        forces (set_graph), and show it (show_graph). Prefer adding links over rewriting text.
        """,
        capabilities: [.readWorkspace, .editWorkspace, .graph, .navigate], maxSteps: 40, builtIn: true)

    public static let analyst = AgentProfile(
        id: UUID(uuidString: "5E0A6E47-0000-4000-8000-000000000004")!, name: "Analyst", icon: "📊",
        summary: "Works with data: spreadsheets, databases, calculations and charts",
        instructions: """
        You are a data analyst. Read attached files and databases, compute with the shell (python3) rather than in \
        your head, and present results as tables. Make Excel files with create_spreadsheet (use formulas for totals \
        so they stay live), and put structured results in Synapse databases when that helps the user track them.
        """,
        capabilities: [.readWorkspace, .editWorkspace, .documents, .shell, .web, .navigate], maxSteps: 30, builtIn: true)

    public static let presenter = AgentProfile(
        id: UUID(uuidString: "5E0A6E47-0000-4000-8000-000000000005")!, name: "Presenter", icon: "🎞️",
        summary: "Makes slide decks, reports, Word documents and PDFs",
        instructions: """
        You make polished documents. For decks: one idea per slide, a clear title, 3–5 short bullets, speaker notes \
        with what to say; open with a title slide and end with a summary. For reports: headings, short paragraphs, \
        tables where they help. Gather the content from the user's pages or the web first, then make the file.
        """,
        capabilities: [.readWorkspace, .documents, .web, .editWorkspace, .navigate], maxSteps: 24, builtIn: true)

    public static let coder = AgentProfile(
        id: UUID(uuidString: "5E0A6E47-0000-4000-8000-000000000006")!, name: "Coder", icon: "💻",
        summary: "Writes and runs code in Linux, converts and edits files",
        instructions: """
        You are a software engineer with a Linux shell. Write small scripts, run them, read the errors and fix them \
        until they work. Attached files are in files/. When you produce a file the user wants, bring it into Synapse \
        with save_file. Show the important commands and results in your answer.
        """,
        capabilities: [.shell, .claudeCode, .web, .readWorkspace, .editWorkspace, .documents], maxSteps: 30, builtIn: true)

    public static let all: [AgentProfile] = [synapse, researcher, graphArchitect, analyst, presenter, coder]
}

/// A file attached to a message (by the user) or made by an agent.
public struct AgentFile: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case document, image, audio, video, spreadsheet, presentation, pdf, other }

    public var id: UUID
    /// Shown to the user and the model ("Budget.xlsx").
    public var name: String
    /// The stored copy, relative to the agent files folder.
    public var path: String
    public var kind: Kind
    public var bytes: Int64

    public init(id: UUID = UUID(), name: String, path: String, kind: Kind, bytes: Int64 = 0) {
        self.id = id
        self.name = name
        self.path = path
        self.kind = kind
        self.bytes = bytes
    }

    /// The kind for a file name.
    public static func kind(forExtension ext: String) -> Kind {
        switch ext.lowercased() {
        case "xlsx", "xls", "csv", "tsv", "numbers", "ods": return .spreadsheet
        case "pptx", "ppt", "key", "odp": return .presentation
        case "pdf": return .pdf
        case "png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tiff", "bmp": return .image
        case "m4a", "mp3", "wav", "aac", "caf", "aif", "aiff", "flac", "ogg", "opus": return .audio
        case "mp4", "mov", "m4v", "webm", "mkv", "avi": return .video
        case "docx", "doc", "txt", "md", "rtf", "odt", "pages", "html", "htm", "epub", "json", "xml": return .document
        default: return .other
        }
    }

    public var symbol: String {
        switch kind {
        case .document: return "doc.text"
        case .image: return "photo"
        case .audio: return "waveform"
        case .video: return "film"
        case .spreadsheet: return "tablecells"
        case .presentation: return "rectangle.on.rectangle.angled"
        case .pdf: return "doc.richtext"
        case .other: return "doc"
        }
    }
}

/// One step an agent took, kept with the message.
public struct AgentStepRecord: Codable, Hashable, Sendable {
    public var tool: String
    public var input: String
    public var attributes: [String: String]
    public var output: String
    public var failed: Bool
    /// Progress lines (e.g. steps Claude Code took).
    public var inner: [String]

    public init(tool: String, input: String, attributes: [String: String] = [:], output: String = "", failed: Bool = false, inner: [String] = []) {
        self.tool = tool
        self.input = input
        self.attributes = attributes
        self.output = output
        self.failed = failed
        self.inner = inner
    }

    public var call: AgentToolCall { AgentToolCall(name: tool, input: input, attributes: attributes) }
}

public struct AgentChatMessage: Identifiable, Codable, Hashable, Sendable {
    public enum Role: String, Codable, Sendable { case user, assistant }

    public var id: UUID
    public var role: Role
    public var text: String
    /// Files the user attached (user messages) or the agent made (answers).
    public var files: [AgentFile]
    /// Text extracted from attachments, as the model saw it (user messages).
    public var attachmentText: String
    public var steps: [AgentStepRecord]
    /// The model that wrote an answer.
    public var model: String?
    public var failed: Bool
    /// The run changed the workspace (offers "Undo changes").
    public var changedWorkspace: Bool
    public var createdAt: Date

    public init(id: UUID = UUID(), role: Role, text: String, files: [AgentFile] = [], attachmentText: String = "",
                steps: [AgentStepRecord] = [], model: String? = nil, failed: Bool = false, changedWorkspace: Bool = false,
                createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.files = files
        self.attachmentText = attachmentText
        self.steps = steps
        self.model = model
        self.failed = failed
        self.changedWorkspace = changedWorkspace
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID())
        role = c.value(.role, .user)
        text = c.value(.text, "")
        files = c.value(.files, [])
        attachmentText = c.value(.attachmentText, "")
        steps = c.value(.steps, [])
        model = c.value(.model, nil)
        failed = c.value(.failed, false)
        changedWorkspace = c.value(.changedWorkspace, false)
        createdAt = c.value(.createdAt, Date())
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, text, files, attachmentText, steps, model, failed, changedWorkspace, createdAt
    }

    /// What the model sees for this message in later turns.
    public var promptText: String {
        guard role == .user, !attachmentText.isEmpty else { return text }
        return text + "\n\n" + attachmentText
    }
}

/// A chat with one agent.
public struct AgentConversation: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var agentID: UUID
    public var title: String
    public var messages: [AgentChatMessage]
    /// A model key for this chat (nil = the agent's model).
    public var model: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), agentID: UUID, title: String = "", messages: [AgentChatMessage] = [], model: String? = nil,
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.agentID = agentID
        self.title = title
        self.messages = messages
        self.model = model
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID())
        agentID = c.value(.agentID, AgentPresets.synapse.id)
        title = c.value(.title, "")
        messages = c.value(.messages, [])
        model = c.value(.model, nil)
        createdAt = c.value(.createdAt, Date())
        updatedAt = c.value(.updatedAt, Date())
    }

    private enum CodingKeys: String, CodingKey {
        case id, agentID, title, messages, model, createdAt, updatedAt
    }

    public var displayTitle: String { title.isEmpty ? "New chat" : title }

    /// A title from the first request ("Make a reading list database…").
    public static func title(from text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.count > 60 ? String(t.prefix(57)) + "…" : t
    }
}
