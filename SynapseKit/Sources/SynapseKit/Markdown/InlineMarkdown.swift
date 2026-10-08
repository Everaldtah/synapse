import Foundation

/// A `[[wiki link]]`: `[[Target]]`, `[[Target|alias]]`, `[[Target#Heading]]`, `[[Target^block]]`, `![[Embed]]`.
public struct WikiLink: Hashable, Sendable {
    public var target: String
    public var heading: String?
    public var blockRef: String?
    public var alias: String?
    public var isEmbed: Bool

    public init(target: String, heading: String? = nil, blockRef: String? = nil, alias: String? = nil, isEmbed: Bool = false) {
        self.target = target
        self.heading = heading
        self.blockRef = blockRef
        self.alias = alias
        self.isEmbed = isEmbed
    }

    /// What the link reads as.
    public var label: String { alias ?? (heading.map { "\(target) › \($0)" } ?? target) }

    /// The Markdown source for this link.
    public var markdown: String {
        var s = (isEmbed ? "!" : "") + "[[" + target
        if let h = heading { s += "#" + h }
        if let b = blockRef { s += "^" + b }
        if let a = alias { s += "|" + a }
        return s + "]]"
    }
}

/// A styled run found in a block's inline Markdown. Ranges are UTF-16 (NSString / UIKit).
public struct InlineToken: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case bold, italic, strike, underline, highlight, code, math
        case link(url: String)
        case wikiLink(WikiLink)
        case tag(String)
        case date(String)
        case url(String)
    }

    public var kind: Kind
    /// The whole token, Markdown markers included.
    public var range: NSRange
    /// The part a reader sees (the markers excluded; for an aliased link, the alias).
    public var contentRange: NSRange

    /// Marker characters around the content (dimmed while editing, removed in plain text).
    public var markerRanges: [NSRange] {
        var out: [NSRange] = []
        if contentRange.location > range.location {
            out.append(NSRange(location: range.location, length: contentRange.location - range.location))
        }
        let end = range.location + range.length
        let contentEnd = contentRange.location + contentRange.length
        if end > contentEnd { out.append(NSRange(location: contentEnd, length: end - contentEnd)) }
        return out
    }
}

/// Tokenizer for the inline Markdown Synapse stores in block text.
public enum InlineMarkdown {
    private struct Rule {
        let regex: NSRegularExpression
        /// Capture group holding the content.
        let content: Int
        let protects: Bool
        let make: (NSTextCheckingResult, NSString) -> InlineToken.Kind
    }

    private static func re(_ pattern: String) -> NSRegularExpression {
        // The patterns are constants; a failure here is a programming error caught by the tests.
        return try! NSRegularExpression(pattern: pattern, options: [])
    }

    /// Rules in precedence order. "Protecting" tokens hide their inside from later rules.
    private static let rules: [Rule] = [
        Rule(regex: re("`([^`\\n]+)`"), content: 1, protects: true) { _, _ in .code },
        Rule(regex: re("(!?)\\[\\[([^\\[\\]\\n]+?)\\]\\]"), content: 2, protects: true) { m, s in
            .wikiLink(parseWikiLink(s.substring(with: m.range(at: 2)), embed: m.range(at: 1).length > 0))
        },
        Rule(regex: re("(?<!\\!)\\[([^\\[\\]\\n]+)\\]\\(([^()\\s]+)\\)"), content: 1, protects: true) { m, s in
            .link(url: s.substring(with: m.range(at: 2)))
        },
        Rule(regex: re("(?<![\\w$])\\$(?=[^\\s$])([^$\\n]*?[^\\s$])\\$(?![\\w$])"), content: 1, protects: true) { _, _ in .math },
        Rule(regex: re("(?<![\\w/])(https?://[^\\s<>()\\[\\]]+[^\\s<>()\\[\\].,;:!?'\"])"), content: 1, protects: true) { m, s in
            .url(s.substring(with: m.range(at: 1)))
        },
        Rule(regex: re("\\*\\*(?=\\S)(.+?)(?<=\\S)\\*\\*"), content: 1, protects: false) { _, _ in .bold },
        Rule(regex: re("(?<![\\w_])__(?=\\S)(.+?)(?<=\\S)__(?![\\w_])"), content: 1, protects: false) { _, _ in .bold },
        Rule(regex: re("(?<![*\\w])\\*(?=[^\\s*])(.+?)(?<=[^\\s*])\\*(?![*\\w])"), content: 1, protects: false) { _, _ in .italic },
        Rule(regex: re("(?<![\\w_])_(?=[^\\s_])(.+?)(?<=[^\\s_])_(?![\\w_])"), content: 1, protects: false) { _, _ in .italic },
        Rule(regex: re("~~(?=\\S)(.+?)(?<=\\S)~~"), content: 1, protects: false) { _, _ in .strike },
        Rule(regex: re("==(?=\\S)(.+?)(?<=\\S)=="), content: 1, protects: false) { _, _ in .highlight },
        Rule(regex: re("<u>(.+?)</u>"), content: 1, protects: false) { _, _ in .underline },
        Rule(regex: re("(?<![\\w#&/])#([A-Za-z\\p{L}][\\w\\p{L}/-]*)"), content: 0, protects: true) { m, s in
            .tag(s.substring(with: m.range(at: 1)))
        },
        Rule(regex: re("(?<![\\w@])@(\\d{4}-\\d{2}-\\d{2}(?: \\d{2}:\\d{2})?)"), content: 0, protects: true) { m, s in
            .date(s.substring(with: m.range(at: 1)))
        },
    ]

    /// Every token in `text`, sorted by position.
    public static func tokens(in text: String) -> [InlineToken] {
        if text.isEmpty { return [] }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var protected: [NSRange] = []
        var tokens: [InlineToken] = []
        for rule in rules {
            for m in rule.regex.matches(in: text, options: [], range: full) {
                let r = m.range
                if protected.contains(where: { NSIntersectionRange($0, r).length > 0 }) { continue }
                var content = m.range(at: rule.content)
                let kind = rule.make(m, ns)
                if case .wikiLink(let link) = kind, let alias = link.alias {
                    // Show only the alias: [[Target|alias]]
                    let aliasStart = r.location + r.length - 2 - (alias as NSString).length
                    content = NSRange(location: aliasStart, length: (alias as NSString).length)
                }
                // Overlapping style runs of the same kind can't nest; keep the first.
                if tokens.contains(where: { $0.kind == kind && NSIntersectionRange($0.range, r).length > 0 }) { continue }
                tokens.append(InlineToken(kind: kind, range: r, contentRange: content))
                if rule.protects { protected.append(r) }
            }
        }
        return tokens.sorted { $0.range.location < $1.range.location }
    }

    public static func parseWikiLink(_ inner: String, embed: Bool = false) -> WikiLink {
        var body = inner
        var alias: String?
        if let bar = body.firstIndex(of: "|") {
            alias = String(body[body.index(after: bar)...]).trimmingCharacters(in: .whitespaces)
            body = String(body[..<bar])
            if alias?.isEmpty == true { alias = nil }
        }
        var blockRef: String?
        if let caret = body.firstIndex(of: "^") {
            blockRef = String(body[body.index(after: caret)...])
            body = String(body[..<caret])
        }
        var heading: String?
        if let hash = body.firstIndex(of: "#") {
            heading = String(body[body.index(after: hash)...]).trimmingCharacters(in: .whitespaces)
            body = String(body[..<hash])
            if heading?.isEmpty == true { heading = nil }
        }
        return WikiLink(target: body.trimmingCharacters(in: .whitespaces), heading: heading, blockRef: blockRef,
                        alias: alias, isEmbed: embed)
    }

    /// The text a reader sees: markers removed, links shown by their label.
    public static func plainText(_ text: String) -> String {
        let toks = tokens(in: text)
        if toks.isEmpty { return text }
        let ns = text as NSString
        var hidden = IndexSet()
        for t in toks {
            switch t.kind {
            case .tag, .date, .url:
                continue
            case .wikiLink(let link) where link.alias == nil:
                // [[Target#Heading]] reads as "Target › Heading"; keep it simple: hide the markers only.
                for m in t.markerRanges { hidden.insert(integersIn: m.location..<(m.location + m.length)) }
            default:
                for m in t.markerRanges { hidden.insert(integersIn: m.location..<(m.location + m.length)) }
            }
        }
        var units: [unichar] = []
        units.reserveCapacity(ns.length)
        for i in 0..<ns.length where !hidden.contains(i) { units.append(ns.character(at: i)) }
        return String(utf16CodeUnits: units, count: units.count)
    }

    /// All wiki links in `text`.
    public static func wikiLinks(in text: String) -> [WikiLink] {
        tokens(in: text).compactMap { if case .wikiLink(let l) = $0.kind { return l } else { return nil } }
    }

    /// All `#tags` in `text`, lowercased.
    public static func tags(in text: String) -> [String] {
        tokens(in: text).compactMap { if case .tag(let t) = $0.kind { return t.lowercased() } else { return nil } }
    }

    /// Wrap `range` of `text` in a marker pair, or remove it if already wrapped. Returns the new text and selection.
    public static func toggleWrap(_ text: String, range: NSRange, open: String, close: String) -> (String, NSRange) {
        let ns = text as NSString
        let o = (open as NSString).length
        let c = (close as NSString).length
        // Already wrapped just outside the selection → unwrap.
        if range.location >= o, range.location + range.length + c <= ns.length,
           ns.substring(with: NSRange(location: range.location - o, length: o)) == open,
           ns.substring(with: NSRange(location: range.location + range.length, length: c)) == close {
            let m = NSMutableString(string: text)
            m.deleteCharacters(in: NSRange(location: range.location + range.length, length: c))
            m.deleteCharacters(in: NSRange(location: range.location - o, length: o))
            return (m as String, NSRange(location: range.location - o, length: range.length))
        }
        // The selection includes the markers → unwrap.
        if range.length >= o + c {
            let inner = ns.substring(with: range)
            if inner.hasPrefix(open) && inner.hasSuffix(close) {
                let stripped = String((inner as NSString).substring(with: NSRange(location: o, length: (inner as NSString).length - o - c)))
                let m = NSMutableString(string: text)
                m.replaceCharacters(in: range, with: stripped)
                return (m as String, NSRange(location: range.location, length: (stripped as NSString).length))
            }
        }
        let m = NSMutableString(string: text)
        m.insert(close, at: range.location + range.length)
        m.insert(open, at: range.location)
        return (m as String, NSRange(location: range.location + o, length: range.length))
    }
}
