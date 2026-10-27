import Foundation

/// A tool the agent can call.
public struct AgentToolSpec: Equatable, Sendable {
    public var name: String
    /// When to use it, for the model.
    public var summary: String
    /// One example call, exactly as the model should write it.
    public var example: String
    /// The call may have no input (`<tool name="list_pages"/>`).
    public var inputOptional: Bool
    /// Changes the workspace or the app (asked for approval when an agent checks before changes).
    public var changes: Bool

    public init(name: String, summary: String, example: String, inputOptional: Bool = false, changes: Bool = false) {
        self.name = name
        self.summary = summary
        self.example = example
        self.inputOptional = inputOptional
        self.changes = changes
    }

    public static let webSearch = AgentToolSpec(
        name: "web_search",
        summary: "Search the web. Use it when you need current facts, references, or to check something you're unsure of.",
        example: "<tool name=\"web_search\">boiling point of water at altitude</tool>")

    public static let fetchURL = AgentToolSpec(
        name: "fetch_url",
        summary: "Read a web page as text (after web_search, or for a link the user gave).",
        example: "<tool name=\"fetch_url\">https://en.wikipedia.org/wiki/Photosynthesis</tool>")

    /// Linux shell. `targets` are where it can run ("iphone", "pc").
    public static func shell(targets: [String]) -> AgentToolSpec {
        let whereText = targets.count > 1
            ? " Add where=\"iphone\" (Alpine Linux on this phone, offline, slower) or where=\"pc\" (Ubuntu on the user's computer, fast, has python3, pandas, pandoc, LibreOffice, ffmpeg)."
            : (targets.first == "pc" ? " It runs on Ubuntu on the user's computer (python3, pandas, pandoc, LibreOffice, ffmpeg)." : " It runs on Alpine Linux on this phone.")
        let attr = targets.count > 1 ? " where=\"\(targets.last ?? "pc")\"" : ""
        return AgentToolSpec(
            name: "shell",
            summary: "Run a bash command in a sandboxed Linux machine for calculations, data processing, converting files, or anything that needs code. Attached files are in files/." + whereText,
            example: "<tool name=\"shell\"\(attr)>python3 -c \"print(sum([12.5, 7.25, 3]))\"</tool>")
    }

    /// Hand a whole task to Claude Code (the user's Claude subscription) in the Linux sandbox.
    public static let claudeCode = AgentToolSpec(
        name: "claude_code",
        summary: "Hand a hard, multi-step task to Claude Code (a much stronger model on the user's Claude subscription) running in the Linux sandbox. It can search the web, read pages, run code and use the attached files in files/. Describe the whole task and what to return.",
        example: "<tool name=\"claude_code\">Find the latest figures for Lagos's population with sources, and compute the growth since 2020.</tool>")

    public static let readSource = AgentToolSpec(
        name: "read_source",
        summary: "Read more of an attached file or recording by name, when the excerpt you were given isn't enough.",
        example: "<tool name=\"read_source\">Lecture 3.pdf</tool>")
}

/// A call the model made.
public struct AgentToolCall: Equatable, Sendable {
    public var name: String
    public var input: String
    public var attributes: [String: String]

    public init(name: String, input: String, attributes: [String: String] = [:]) {
        self.name = name
        self.input = input
        self.attributes = attributes
    }

    /// The call written back in canonical form (kept in the conversation instead of the model's raw reply).
    public var markup: String {
        let attrs = attributes.keys.sorted().map { " \($0)=\"\(attributes[$0] ?? "")\"" }.joined()
        return "<tool name=\"\(name)\"\(attrs)>\(input)</tool>"
    }
}

/// What happened during a run, for the steps list in the UI.
public enum AgentEvent: Equatable, Sendable {
    /// What the model said alongside its tool calls ("I'll create the hub page first.").
    case note(String)
    case calling(AgentToolCall)
    case result(AgentToolCall, output: String, failed: Bool)
    case answer(String)
}

/// A tool-using loop that works with any model, through a plain-text protocol: the model replies with one
/// `<tool name="…">input</tool>` to use a tool, gets `<result>…</result>` back, and finishes with a normal answer.
/// Small on-device models follow it as well as cloud ones, and every step is visible.
public enum Agent {
    public static func instructions(tools: [AgentToolSpec], maxCalls: Int, callsPerReply: Int = 1, compact: Bool = false) -> String {
        let list = tools.map { compact ? "- \($0.name): \($0.summary)" : "- \($0.name): \($0.summary)\n  Example: \($0.example)" }
            .joined(separator: "\n")
        let form = callsPerReply > 1
            ? "To use tools, reply with ONLY tool calls in exactly the form shown (up to \(callsPerReply) in one reply; they run in order), and nothing else."
            : "To use a tool, reply with ONLY one tool call in exactly the form shown, and nothing else."
        let syntax = compact
            ? "\nCall syntax: <tool name=\"read_page\">Weekly review</tool>; with attributes: <tool name=\"create_page\" title=\"Ideas\" parent=\"Projects\">Markdown</tool>; no input: <tool name=\"list_pages\"/>\n"
            : ""
        return """
        TOOLS
        You can use these tools:
        \(list)
        \(syntax)
        \(form) Write each call as plain text in exactly that XML form — not as a function call, JSON or any other \
        syntax. You'll get the output back as <result>…</result>. Use at most \(maxCalls) tool calls, and only when they help. When you have what you \
        need, write your final answer normally, with no <tool> tags. When you used web pages, cite them as Markdown links.
        """
    }

    /// The first tool call in a reply, if any (tolerates code fences, single quotes and a missing closing tag).
    public static func parseCall(_ reply: String, known: Set<String>) -> AgentToolCall? {
        parseCalls(reply, known: known).first
    }

    /// Every tool call in a reply, in order. Calls to tools outside `known` are dropped, and so are calls with no
    /// input unless the tool is in `inputOptional`.
    public static func parseCalls(_ reply: String, known: Set<String>, inputOptional: Set<String> = []) -> [AgentToolCall] {
        rawCalls(reply).filter { known.contains($0.name) && (!$0.input.isEmpty || inputOptional.contains($0.name)) }
    }

    /// Names of tools a reply tried to call that don't exist (so the model can be told).
    public static func unknownCalls(_ reply: String, known: Set<String>) -> [String] {
        rawCalls(reply).map(\.name).filter { !known.contains($0) }
    }

    /// `key="…"` (may contain apostrophes) or `key='…'` (may contain double quotes).
    private static let attributePattern = try? NSRegularExpression(pattern: "(\\w+)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')")

    private static let junkTag = "^</(?:[a-z]+:)?(?:parameter|function|invoke|tool_call|tool|arg|args|arguments)>(?:tool>|function>)?$"

    private static func rawCalls(_ reply: String) -> [AgentToolCall] {
        // Models that slip into their own function-calling syntax (gpt-oss "harmony") get it translated.
        let reply = reply.range(of: "<tool") == nil ? (NativeToolCalls.fromHarmony(reply) ?? reply) : reply
        var calls: [AgentToolCall] = []
        var from = reply.startIndex
        while let open = reply.range(of: "<tool(?:\\s+[^>]*)?>", options: .regularExpression, range: from..<reply.endIndex) {
            let tag = String(reply[open])
            var attributes: [String: String] = [:]
            if let re = attributePattern {
                let ns = tag as NSString
                for m in re.matches(in: tag, range: NSRange(location: 0, length: ns.length)) {
                    let value = m.range(at: 2).location != NSNotFound ? m.range(at: 2) : m.range(at: 3)
                    attributes[ns.substring(with: m.range(at: 1))] = value.location != NSNotFound ? ns.substring(with: value) : ""
                }
            }
            let rest = reply[open.upperBound...]
            var input = ""
            let close = rest.range(of: "</tool>")
            let next = rest.range(of: "<tool(?:\\s+[^>]*)?>", options: .regularExpression)
            if tag.hasSuffix("/>") {
                from = open.upperBound
            } else if let close, next.map({ close.lowerBound < $0.lowerBound }) ?? true {
                input = String(rest[..<close.lowerBound])
                from = close.upperBound
            } else if let next {
                // No closing tag before the next call: this one ends there.
                input = String(rest[..<next.lowerBound])
                from = next.lowerBound
            } else {
                input = String(rest)
                from = reply.endIndex
            }
            var name = attributes.removeValue(forKey: "name") ?? ""
            input = input.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty {
                // Small models sometimes write <tool>graph_overview</tool> or <tool>read_page Home</tool>.
                let parts = input.split(maxSplits: 1, whereSeparator: { $0 == " " || $0.isNewline })
                guard let first = parts.first, first.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { continue }
                name = String(first)
                input = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
            }
            if input.hasPrefix("```") {
                input = input.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
                if input.hasSuffix("```") { input = String(input.dropLast(3)) }
                input = input.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            // Stray closing tags some models leave after an argument ("</parameter>", "</rfl:parameter>tool>").
            var lines = input.components(separatedBy: "\n")
            while let last = lines.last?.trimmingCharacters(in: .whitespaces), last.range(of: junkTag, options: .regularExpression) != nil {
                lines.removeLast()
            }
            input = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            calls.append(AgentToolCall(name: name, input: input, attributes: attributes))
        }
        return calls
    }

    /// Remove any stray tool markup from a final answer.
    public static func cleanAnswer(_ reply: String) -> String {
        var reply = reply
        // Harmony leftovers: keep only the final channel's message.
        if let final = reply.range(of: "<|channel|>final<|message|>") { reply = String(reply[final.upperBound...]) }
        reply = reply.replacingOccurrences(of: "<\\|[a-z_]+\\|>", with: "", options: .regularExpression)
        return reply.replacingOccurrences(of: "<tool\\s+[^>]*/>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "(?s)<tool(?:\\s+[^>]*)?>.*?(</tool>|$)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "(?s)<result[^>]*>.*?</result>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Shorten tool output to fit the model's window, keeping the start and the end.
    public static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit, limit > 200 else { return text }
        let head = text.prefix(limit * 3 / 4)
        let tail = text.suffix(limit / 4 - 40)
        return "\(head)\n…[\(text.count - head.count - tail.count) characters cut]…\n\(tail)"
    }

    /// Keep a long run inside the model's window: past `limit` characters, older tool results (not the last
    /// `keepLast` messages) are cut to their first lines. The question and the calls themselves stay.
    public static func compact(_ messages: [AIMessage], limit: Int, keepLast: Int = 4) -> [AIMessage] {
        var out = messages
        var total = out.reduce(0) { $0 + $1.content.count }
        guard total > limit else { return out }
        for i in out.indices.dropLast(keepLast) where i > 0 && out[i].role == .user && out[i].content.hasPrefix("<result") {
            let old = out[i].content
            guard old.count > 500 else { continue }
            let short = String(old.prefix(360)) + "\n…[older result shortened]…\n</result>"
            out[i].content = short
            total -= old.count - short.count
            if total <= limit { break }
        }
        return out
    }

    /// Run the loop.
    /// - Parameters:
    ///   - maxCalls: tool calls allowed before the model must answer.
    ///   - resultLimit: characters of each tool output the model sees.
    ///   - callsPerReply: tool calls the model may batch in one reply (run in order).
    ///   - contextLimit: characters of conversation kept before older results are shortened.
    ///   - compactTools: list tools without examples (small windows).
    ///   - complete: one model request → the whole reply.
    ///   - execute: runs a tool call; a thrown error is shown to the model as the result.
    public static func run(_ request: AIRequest, tools: [AgentToolSpec], maxCalls: Int, resultLimit: Int,
                           callsPerReply: Int = 1, contextLimit: Int = .max, compactTools: Bool = false,
                           complete: (AIRequest) async throws -> String,
                           execute: (AgentToolCall) async throws -> String,
                           event: (AgentEvent) -> Void = { _ in },
                           isolation: isolated (any Actor)? = #isolation) async throws -> String {
        let system = request.system + "\n\n" + instructions(tools: tools, maxCalls: maxCalls, callsPerReply: callsPerReply, compact: compactTools)
        let known = Set(tools.map(\.name))
        let optional = Set(tools.filter(\.inputOptional).map(\.name))
        var messages = request.messages
        var calls = 0
        var nudged = false
        while true {
            try Task.checkCancellation()
            let reply = try await complete(AIRequest(system: system, messages: compact(messages, limit: contextLimit)))
            let parsed = Array(parseCalls(reply, known: known, inputOptional: optional).prefix(max(1, callsPerReply)))
            if parsed.isEmpty, let missing = unknownCalls(reply, known: known).first, calls < maxCalls {
                // A call to a tool that doesn't exist: say so rather than treating the markup as the answer.
                calls += 1
                messages.append(AIMessage(role: .assistant, content: reply))
                messages.append(AIMessage(role: .user, content: """
                <result tool="\(missing)">
                Error: there is no tool called \(missing). The tools are: \(tools.map(\.name).joined(separator: ", ")).
                </result>
                """))
                continue
            }
            if parsed.isEmpty && cleanAnswer(reply).isEmpty && !nudged {
                // Some models "decide" to use a tool in hidden reasoning and send nothing; ask once more.
                nudged = true
                messages.append(AIMessage(role: .assistant, content: "(no reply)"))
                messages.append(AIMessage(role: .user, content: "Your reply was empty. Write the tool call itself as text in the <tool name=\"…\">…</tool> form, or write your answer."))
                continue
            }
            guard !parsed.isEmpty else {
                let answer = cleanAnswer(reply)
                event(.answer(answer))
                return answer
            }
            if calls >= maxCalls {
                messages.append(AIMessage(role: .assistant, content: parsed.map(\.markup).joined(separator: "\n")))
                messages.append(AIMessage(role: .user, content: "You've used all your tool calls. Write the final answer now, with no <tool> tags."))
                let final = cleanAnswer(try await complete(AIRequest(system: system, messages: compact(messages, limit: contextLimit))))
                event(.answer(final))
                return final
            }
            let note = cleanAnswer(reply)
            if !note.isEmpty && note.count < 600 { event(.note(note)) }
            var made: [AgentToolCall] = []
            var results: [String] = []
            for call in parsed where calls < maxCalls {
                try Task.checkCancellation()
                calls += 1
                made.append(call)
                event(.calling(call))
                var output: String
                var failed = false
                do {
                    output = try await execute(call)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    output = "Error: \(error.localizedDescription)"
                    failed = true
                }
                output = truncate(output.isEmpty ? "(no output)" : output, limit: resultLimit)
                event(.result(call, output: output, failed: failed))
                results.append("<result tool=\"\(call.name)\">\n\(output)\n</result>")
            }
            messages.append(AIMessage(role: .assistant, content: made.map(\.markup).joined(separator: "\n")))
            messages.append(AIMessage(role: .user, content: """
            \(results.joined(separator: "\n"))
            \(calls < maxCalls ? "Use another tool only if you still need one; otherwise write the final answer." : "Now write the final answer, with no <tool> tags.")
            """))
        }
    }

    /// The request that checks notes against the web and adds references (run with `webSearch` + `fetchURL`).
    public static func referencesRequest(notes: String, title: String, limit: Int) -> AIRequest {
        AIRequest(system: MeetingNotes.system, messages: [AIMessage(role: .user, content: """
        These are notes on "\(AIPrompts.escape(title))". Check the most important facts in them (names, dates, numbers, \
        definitions and claims) against reliable sources on the web: search, and read a page when the snippet isn't enough. \
        Then reply with only these Markdown sections:

        ## References
        - [Page title](https://link) — what it confirms or adds

        ## Corrections
        - Anything in the notes that's wrong or out of date, with the correct fact and its source. Leave this section \
        out if everything checks out.

        <notes>
        \(String(notes.prefix(limit)))
        </notes>
        """)])
    }
}
