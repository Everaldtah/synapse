import Foundation

/// A tool the agent can call.
public struct AgentToolSpec: Equatable, Sendable {
    public var name: String
    /// When to use it, for the model.
    public var summary: String
    /// One example call, exactly as the model should write it.
    public var example: String

    public init(name: String, summary: String, example: String) {
        self.name = name
        self.summary = summary
        self.example = example
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
    case calling(AgentToolCall)
    case result(AgentToolCall, output: String, failed: Bool)
    case answer(String)
}

/// A tool-using loop that works with any model, through a plain-text protocol: the model replies with one
/// `<tool name="…">input</tool>` to use a tool, gets `<result>…</result>` back, and finishes with a normal answer.
/// Small on-device models follow it as well as cloud ones, and every step is visible.
public enum Agent {
    public static func instructions(tools: [AgentToolSpec], maxCalls: Int) -> String {
        let list = tools.map { "- \($0.name): \($0.summary)\n  Example: \($0.example)" }.joined(separator: "\n")
        return """
        TOOLS
        You can use these tools:
        \(list)

        To use a tool, reply with ONLY one tool call in exactly the form shown, and nothing else. You'll get the output \
        back as <result>…</result>. Use at most \(maxCalls) tool calls, and only when they help. When you have what you \
        need, write your final answer normally, with no <tool> tags. When you used web pages, cite them as Markdown links.
        """
    }

    /// The first tool call in a reply, if any (tolerates code fences, single quotes and a missing closing tag).
    public static func parseCall(_ reply: String, known: Set<String>) -> AgentToolCall? {
        guard let open = reply.range(of: "<tool\\s+[^>]*>", options: .regularExpression) else { return nil }
        let tag = String(reply[open])
        var attributes: [String: String] = [:]
        if let re = try? NSRegularExpression(pattern: "(\\w+)\\s*=\\s*[\"']([^\"']*)[\"']") {
            let ns = tag as NSString
            for m in re.matches(in: tag, range: NSRange(location: 0, length: ns.length)) {
                attributes[ns.substring(with: m.range(at: 1))] = ns.substring(with: m.range(at: 2))
            }
        }
        guard let name = attributes.removeValue(forKey: "name"), known.contains(name) else { return nil }
        let rest = reply[open.upperBound...]
        var input = rest.range(of: "</tool>").map { String(rest[..<$0.lowerBound]) } ?? String(rest)
        input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.hasPrefix("```") {
            input = input.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            if input.hasSuffix("```") { input = String(input.dropLast(3)) }
            input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !input.isEmpty else { return nil }
        return AgentToolCall(name: name, input: input, attributes: attributes)
    }

    /// Remove any stray tool markup from a final answer.
    public static func cleanAnswer(_ reply: String) -> String {
        reply.replacingOccurrences(of: "(?s)<tool\\s+[^>]*>.*?(</tool>|$)", with: "", options: .regularExpression)
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

    /// Run the loop.
    /// - Parameters:
    ///   - maxCalls: tool calls allowed before the model must answer.
    ///   - resultLimit: characters of each tool output the model sees.
    ///   - complete: one model request → the whole reply.
    ///   - execute: runs a tool call; a thrown error is shown to the model as the result.
    public static func run(_ request: AIRequest, tools: [AgentToolSpec], maxCalls: Int, resultLimit: Int,
                           complete: (AIRequest) async throws -> String,
                           execute: (AgentToolCall) async throws -> String,
                           event: (AgentEvent) -> Void = { _ in },
                           isolation: isolated (any Actor)? = #isolation) async throws -> String {
        let system = request.system + "\n\n" + instructions(tools: tools, maxCalls: maxCalls)
        let known = Set(tools.map(\.name))
        var messages = request.messages
        var calls = 0
        while true {
            try Task.checkCancellation()
            let reply = try await complete(AIRequest(system: system, messages: messages))
            guard let call = parseCall(reply, known: known) else {
                let answer = cleanAnswer(reply)
                event(.answer(answer))
                return answer
            }
            if calls >= maxCalls {
                messages.append(AIMessage(role: .assistant, content: call.markup))
                messages.append(AIMessage(role: .user, content: "You've used all your tool calls. Write the final answer now, with no <tool> tags."))
                let final = cleanAnswer(try await complete(AIRequest(system: system, messages: messages)))
                event(.answer(final))
                return final
            }
            calls += 1
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
            messages.append(AIMessage(role: .assistant, content: call.markup))
            messages.append(AIMessage(role: .user, content: """
            <result tool="\(call.name)">
            \(output)
            </result>
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
