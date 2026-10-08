import Foundation

/// The AI actions Synapse offers on text (Notion AI's set, run on Claude).
public enum AIAction: String, CaseIterable, Identifiable, Sendable {
    case improve, fixGrammar, shorter, longer, simplify
    case toneProfessional, toneCasual, toneFriendly, toneConfident
    case translate, summarize, explain, actionItems, continueWriting, brainstorm, outline, suggestLinks, custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .improve: return "Improve writing"
        case .fixGrammar: return "Fix spelling & grammar"
        case .shorter: return "Make shorter"
        case .longer: return "Make longer"
        case .simplify: return "Simplify language"
        case .toneProfessional: return "Tone: Professional"
        case .toneCasual: return "Tone: Casual"
        case .toneFriendly: return "Tone: Friendly"
        case .toneConfident: return "Tone: Confident"
        case .translate: return "Translate"
        case .summarize: return "Summarize"
        case .explain: return "Explain this"
        case .actionItems: return "Find action items"
        case .continueWriting: return "Continue writing"
        case .brainstorm: return "Brainstorm ideas"
        case .outline: return "Draft an outline"
        case .suggestLinks: return "Suggest [[links]]"
        case .custom: return "Ask AI…"
        }
    }

    public var symbol: String {
        switch self {
        case .improve: return "wand.and.stars"
        case .fixGrammar: return "checkmark.seal"
        case .shorter: return "arrow.down.right.and.arrow.up.left"
        case .longer: return "arrow.up.left.and.arrow.down.right"
        case .simplify: return "text.badge.minus"
        case .toneProfessional, .toneCasual, .toneFriendly, .toneConfident: return "theatermasks"
        case .translate: return "character.bubble"
        case .summarize: return "text.append"
        case .explain: return "questionmark.bubble"
        case .actionItems: return "checklist"
        case .continueWriting: return "text.cursor"
        case .brainstorm: return "lightbulb"
        case .outline: return "list.bullet.indent"
        case .suggestLinks: return "point.3.connected.trianglepath.dotted"
        case .custom: return "sparkles"
        }
    }

    /// Actions whose result replaces the selection (others insert below).
    public var replacesSelection: Bool {
        switch self {
        case .improve, .fixGrammar, .shorter, .longer, .simplify, .toneProfessional, .toneCasual, .toneFriendly, .toneConfident, .translate:
            return true
        default:
            return false
        }
    }

    /// Grouping for the menu.
    public static let editGroup: [AIAction] = [.improve, .fixGrammar, .shorter, .longer, .simplify]
    public static let toneGroup: [AIAction] = [.toneProfessional, .toneCasual, .toneFriendly, .toneConfident]
    public static let generateGroup: [AIAction] = [.summarize, .explain, .actionItems, .continueWriting, .brainstorm, .outline, .suggestLinks]
}

public struct AIMessage: Codable, Hashable, Sendable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public var role: Role
    public var content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

/// A request for any provider: a system prompt plus a conversation.
public struct AIRequest: Sendable {
    public var system: String
    public var messages: [AIMessage]

    public init(system: String, messages: [AIMessage]) {
        self.system = system
        self.messages = messages
    }
}

public enum AIPrompts {
    public static let baseSystem = """
    You are Synapse AI, the writing and thinking assistant inside Synapse, a notes, docs and databases app.
    Pages use Markdown: headings (#), lists (-, 1.), to-dos (- [ ]), quotes (>), callouts (> [!note]), code fences, \
    **bold**, *italic*, ==highlight==, `code`, [[Page links]] and #tags.
    Write in the same language as the user's text unless asked to translate. Reply with the content only: no preamble \
    such as "Here is", no closing remarks, and no surrounding code fence unless the content is code.
    """

    public static func request(for action: AIAction, text: String, pageTitle: String, pageContext: String,
                               language: String = "English", instruction: String = "", linkCandidates: [String] = []) -> AIRequest {
        let selection = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let ctx = pageContext.isEmpty ? "" : "\n\n<page title=\"\(escape(pageTitle))\">\n\(String(pageContext.prefix(24_000)))\n</page>"
        let task: String
        switch action {
        case .improve: task = "Improve the writing of the text below: clearer, better flow, same meaning and roughly the same length. Keep Markdown and [[links]]."
        case .fixGrammar: task = "Fix spelling and grammar in the text below. Change nothing else. Keep Markdown and [[links]]."
        case .shorter: task = "Make the text below shorter while keeping its key points. Keep Markdown and [[links]]."
        case .longer: task = "Expand the text below with more detail and explanation, in the same voice. Keep Markdown and [[links]]."
        case .simplify: task = "Rewrite the text below in simpler language that anyone can understand."
        case .toneProfessional: task = "Rewrite the text below in a professional tone."
        case .toneCasual: task = "Rewrite the text below in a casual tone."
        case .toneFriendly: task = "Rewrite the text below in a warm, friendly tone."
        case .toneConfident: task = "Rewrite the text below in a confident, direct tone."
        case .translate: task = "Translate the text below into \(language). Keep Markdown and [[links]] (do not translate link targets)."
        case .summarize: task = selection.isEmpty ? "Summarize the page in a few concise bullet points." : "Summarize the text below in a few concise bullet points."
        case .explain: task = "Explain the text below simply, as you would to a curious colleague."
        case .actionItems: task = "List the action items in the \(selection.isEmpty ? "page" : "text below") as a Markdown to-do list (- [ ] item). If there are none, reply with a single line saying so."
        case .continueWriting: task = "Continue writing from where the page ends. Match its style and format. Write one to three paragraphs or list items."
        case .brainstorm: task = "Brainstorm ideas about \(selection.isEmpty ? "the page's topic" : "the text below") as a Markdown bulleted list of 8–12 varied ideas."
        case .outline: task = "Draft a structured Markdown outline (headings and bullets) for \(selection.isEmpty ? "the page's topic" : "the topic below")."
        case .suggestLinks:
            let list = linkCandidates.prefix(400).map { "- \($0)" }.joined(separator: "\n")
            task = """
            These are the titles of other pages in the workspace:
            \(list)

            Which of them are meaningfully related to the page? Reply with up to 8 lines, each exactly "[[Title]] — reason" \
            using titles from the list only. If none are related, reply "None".
            """
        case .custom: task = instruction.isEmpty ? "Help with the text below." : instruction
        }
        var user = task
        if !selection.isEmpty && action != .suggestLinks { user += "\n\n<text>\n\(selection)\n</text>" }
        user += ctx
        return AIRequest(system: baseSystem, messages: [AIMessage(role: .user, content: user)])
    }

    /// Ask a question about the workspace with retrieved pages as sources.
    public static func ask(question: String, sources: [(title: String, text: String)], history: [AIMessage] = []) -> AIRequest {
        var system = baseSystem + """

        Answer questions about the user's workspace using the <source> pages provided. Cite the pages you used inline as \
        [[Page title]]. If the sources don't contain the answer, say so briefly and answer from general knowledge, \
        marking that part as such.
        """
        if !sources.isEmpty {
            system += "\n\n" + sources.map { "<source title=\"\(escape($0.title))\">\n\($0.text)\n</source>" }.joined(separator: "\n")
        }
        return AIRequest(system: system, messages: history + [AIMessage(role: .user, content: question)])
    }

    /// The most relevant pages for a question (keyword retrieval), within a character budget.
    public static func retrieve(_ question: String, in ws: Workspace, limit: Int = 8, budget: Int = 60_000, focus: UUID? = nil) -> [(title: String, text: String)] {
        let stop: Set<String> = ["the", "a", "an", "and", "or", "of", "to", "in", "on", "for", "is", "are", "what", "which", "who",
                                 "how", "my", "me", "i", "do", "does", "did", "with", "about", "from", "this", "that", "it", "be", "was", "were", "when", "where", "why"]
        let words = question.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 1 && !stop.contains($0) }
        var scored: [(Page, Double)] = []
        for p in ws.livePages where !p.isTemplate {
            let title = p.displayTitle.lowercased()
            let body = p.plainText.lowercased()
            var s = 0.0
            for w in words {
                if title.contains(w) { s += 5 }
                s += min(5, Double(body.components(separatedBy: w).count - 1))
            }
            if p.id == focus { s += 50 }
            if s > 0 { scored.append((p, s)) }
        }
        if scored.isEmpty { scored = ws.recent(limit: limit).map { ($0, 1) } }
        var out: [(title: String, text: String)] = []
        var used = 0
        for (p, _) in scored.sorted(by: { $0.1 > $1.1 }).prefix(limit) {
            var text = MarkdownCodec.blocksToMarkdown(p.blocks, workspace: ws)
            if p.kind == .row, let db = p.parentID.flatMap({ ws[$0] }), let schema = db.schema {
                let props = schema.properties.filter { $0.type != .title }.map { prop in
                    "\(prop.name): \(PropertyResolver.displayText(PropertyResolver.resolve(p, prop, schema: schema, in: ws), prop, in: ws))"
                }
                text = props.joined(separator: "\n") + "\n\n" + text
            }
            let room = budget - used
            if room <= 200 { break }
            if text.count > room { text = String(text.prefix(room)) + "…" }
            used += text.count
            out.append((p.displayTitle, text))
        }
        return out
    }

    /// `[[Title]]` lines from a link-suggestion reply.
    public static func parseLinkSuggestions(_ reply: String) -> [(title: String, reason: String)] {
        reply.components(separatedBy: "\n").compactMap { line in
            let links = InlineMarkdown.wikiLinks(in: line)
            guard let l = links.first else { return nil }
            var reason = line
            if let r = line.range(of: "]]") { reason = String(line[r.upperBound...]) }
            reason = reason.trimmingCharacters(in: CharacterSet(charactersIn: " -—–:"))
            return (l.target, reason)
        }
    }

    static func escape(_ s: String) -> String { s.replacingOccurrences(of: "\"", with: "'") }
}
