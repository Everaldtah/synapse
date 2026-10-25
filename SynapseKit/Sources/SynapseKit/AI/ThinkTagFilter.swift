import Foundation

/// Drops a leading `<think>…</think>` block from a streamed reply. Reasoning models (Qwen3) can open with one even
/// when thinking is switched off; notes and rewrites should only show the answer.
public struct ThinkTagFilter: Sendable {
    private var buffer = ""
    private var passing = false

    public init() {}

    /// Feed the next chunk; returns the text to show now (possibly empty while undecided).
    public mutating func feed(_ chunk: String) -> String {
        if passing { return chunk }
        buffer += chunk
        let head = buffer.drop(while: \.isWhitespace)
        if head.isEmpty { return "" }
        // Still could turn into "<think>".
        if head.count < 7 && "<think>".hasPrefix(head) { return "" }
        if head.hasPrefix("<think>") {
            guard let end = buffer.range(of: "</think>") else { return "" }
            passing = true
            let rest = buffer[end.upperBound...].drop(while: \.isWhitespace)
            buffer = ""
            return String(rest)
        }
        passing = true
        buffer = ""
        return String(head)
    }

    /// Call at the end: returns anything still held back (never an unfinished think block).
    public mutating func finish() -> String {
        defer { buffer = "" }
        if passing { return "" }
        let head = buffer.drop(while: \.isWhitespace)
        return head.hasPrefix("<think>") ? "" : String(head)
    }
}
