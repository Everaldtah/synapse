import Foundation

/// Some models answer with their own function-calling format instead of Synapse's `<tool>` text protocol: OpenAI-style
/// `tool_calls` from the server, or gpt-oss "harmony" text (`to=functions.name … <|call|>`). These turn both into
/// `<tool name="…">…</tool>` markup, so the agent loop treats every model the same.
public enum NativeToolCalls {
    /// Argument keys that hold the tool's main input (the text between the tags).
    static let bodyKeys = ["input", "content", "markdown", "text", "body", "query", "command", "code", "csv", "columns",
                           "rows", "task", "prompt", "url", "path", "values", "slides", "tags", "titles", "to", "q"]

    /// `{"title":"X","markdown":"…"}` → `<tool name="create_page" title="X">…</tool>`.
    public static func markup(name: String, arguments: String) -> String {
        var attrs: [(String, String)] = []
        var body = ""
        let json = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any]
        if let json {
            var values: [String: String] = [:]
            for (k, v) in json {
                switch v {
                case let s as String: values[k] = s
                case let n as NSNumber:
                    // JSON booleans are NSNumbers of type "c" (on Darwin and Linux alike).
                    values[k] = String(cString: n.objCType) == "c" ? (n.boolValue ? "true" : "false") : n.stringValue
                case let a as [Any]: values[k] = a.map { "\($0)" }.joined(separator: k == "rows" ? "\n" : ", ")
                default: continue
                }
            }
            let bodyKey = bodyKeys.first { values[$0] != nil } ?? (values.count == 1 ? values.keys.first : nil)
            if let bodyKey { body = values.removeValue(forKey: bodyKey) ?? "" }
            values.removeValue(forKey: "name")
            attrs = values.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        } else {
            body = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let a = attrs.map { k, v -> String in
            v.contains("\"") ? (v.contains("'") ? " \(k)=\"\(v.replacingOccurrences(of: "\"", with: "'"))\"" : " \(k)='\(v)'") : " \(k)=\"\(v)\""
        }.joined()
        let tool = name.hasPrefix("functions.") ? String(name.dropFirst(10)) : name
        return "<tool name=\"\(tool)\"\(a)>\(body)</tool>"
    }

    /// Rewrite harmony-style calls in a reply as `<tool>` markup (nil when there are none).
    ///   `<|channel|>commentary to=functions.web_search <|constrain|>json<|message|>{"query":"…"}<|call|>`
    ///   `commentary to=tool{"name":"create_page","title":"X"}---\n# Body…<|call|>`
    public static func fromHarmony(_ reply: String) -> String? {
        guard reply.contains("to=") && (reply.contains("<|call|>") || reply.contains("<|message|>") || reply.contains("<|channel|>")) else { return nil }
        var out: [String] = []
        var rest = reply[...]
        while let to = rest.range(of: "to=") {
            var after = rest[to.upperBound...]
            var name = ""
            if after.hasPrefix("functions.") {
                after = after.dropFirst(10)
                name = String(after.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
                after = after.dropFirst(name.count)
            } else if after.hasPrefix("tool") {
                after = after.dropFirst(4)
            } else {
                name = String(after.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
                after = after.dropFirst(name.count)
            }
            let end = after.range(of: "<|call|>")?.lowerBound ?? after.range(of: "<|end|>")?.lowerBound ?? after.endIndex
            var segment = String(after[..<end])
            if let m = segment.range(of: "<|message|>") { segment = String(segment[m.upperBound...]) }
            segment = segment.replacingOccurrences(of: "<|constrain|>json", with: "").replacingOccurrences(of: "<|constrain|>", with: "")
            // A JSON object first, then (optionally) free text that is the body.
            var json = ""
            var trailing = ""
            if let open = segment.firstIndex(of: "{"), segment[..<open].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let close = matchingBrace(segment, from: open) {
                json = String(segment[open...close])
                trailing = String(segment[segment.index(after: close)...])
            } else {
                trailing = segment
            }
            trailing = trailing.trimmingCharacters(in: .whitespacesAndNewlines)
            if trailing.hasPrefix("---") { trailing = String(trailing.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines) }
            var args = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
            if name.isEmpty, let n = args.removeValue(forKey: "name") as? String { name = n }
            if !trailing.isEmpty && !bodyKeys.contains(where: { args[$0] != nil }) { args["input"] = trailing }
            if !name.isEmpty, let data = try? JSONSerialization.data(withJSONObject: args) {
                out.append(markup(name: name, arguments: String(decoding: data, as: UTF8.self)))
            }
            rest = end < after.endIndex ? after[end...].dropFirst(min(8, after[end...].count)) : after[after.endIndex...]
        }
        return out.isEmpty ? nil : out.joined(separator: "\n")
    }

    private static func matchingBrace(_ s: String, from open: String.Index) -> String.Index? {
        var depth = 0
        var inString = false
        var escaped = false
        var i = open
        while i < s.endIndex {
            let c = s[i]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == "{" {
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth == 0 { return i }
            }
            i = s.index(after: i)
        }
        return nil
    }

    /// OpenAI-style function definitions for tools, for models that call functions better than they follow the text
    /// protocol (gpt-oss). Each tool takes `input` (the text between the tags) plus the attributes its example uses.
    public static func schemas(for tools: [AgentToolSpec]) -> [[String: Any]] {
        tools.map { spec in
            let example = Agent.parseCalls(spec.example, known: [spec.name], inputOptional: [spec.name]).first
            var properties: [String: Any] = [
                "input": ["type": "string", "description": "The main input: what goes between the tags in the example."],
            ]
            for key in (example?.attributes.keys.sorted() ?? []) {
                properties[key] = ["type": "string", "description": "As in: \(spec.example.prefix(160))"]
            }
            return ["type": "function", "function": [
                "name": spec.name,
                "description": spec.summary,
                "parameters": ["type": "object", "properties": properties, "required": spec.inputOptional ? [] : ["input"]] as [String: Any],
            ] as [String: Any]]
        }
    }

    /// One piece of a `tool_calls` entry (streamed replies send the name once and the arguments in pieces).
    public struct Delta: Equatable, Sendable {
        public var index: Int
        public var name: String
        public var arguments: String
    }

    /// `tool_calls` JSON → deltas.
    public static func deltas(_ raw: Any?) -> [Delta] {
        guard let list = raw as? [[String: Any]] else { return [] }
        return list.enumerated().compactMap { n, d in
            guard let f = d["function"] as? [String: Any] else { return nil }
            var args = f["arguments"] as? String ?? ""
            if args.isEmpty, let o = f["arguments"], JSONSerialization.isValidJSONObject(o),
               let data = try? JSONSerialization.data(withJSONObject: o) { args = String(decoding: data, as: UTF8.self) }
            return Delta(index: d["index"] as? Int ?? n, name: f["name"] as? String ?? "", arguments: args)
        }
    }

    /// Collects streamed `tool_calls` deltas (name and argument pieces by index).
    public struct Accumulator: Sendable {
        private var names: [Int: String] = [:]
        private var arguments: [Int: String] = [:]
        public init() {}

        public var isEmpty: Bool { names.isEmpty }

        public mutating func add(_ deltas: [Delta]) {
            for d in deltas {
                if !d.name.isEmpty { names[d.index, default: ""] += d.name }
                if !d.arguments.isEmpty { arguments[d.index, default: ""] += d.arguments }
            }
        }

        /// The calls as `<tool>` markup, in order.
        public var markup: String {
            names.keys.sorted().compactMap { i in names[i].map { NativeToolCalls.markup(name: $0, arguments: arguments[i] ?? "") } }
                .joined(separator: "\n")
        }
    }
}
