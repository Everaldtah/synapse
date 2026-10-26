import Foundation

/// Plain-text helpers for notes sources. Pure Swift, so they're unit-tested on Linux.
public enum SourceText {
    /// One timed piece of a transcript.
    public struct Segment: Equatable, Sendable {
        public var start: Double
        public var end: Double
        public var text: String

        public init(start: Double, end: Double, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }
    }

    /// Transcript text with a paragraph break at every pause longer than `pause` seconds (or every ~`maxLength`
    /// characters in unbroken speech).
    public static func paragraphs(_ segments: [Segment], pause: Double = 1.5, maxLength: Int = 700) -> String {
        var paragraphs: [String] = []
        var current = ""
        var lastEnd = 0.0
        for s in segments {
            let piece = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            if !current.isEmpty && (s.start - lastEnd > pause || current.count > maxLength) {
                paragraphs.append(current)
                current = ""
            }
            current += current.isEmpty ? piece : " " + piece
            lastEnd = s.end
        }
        if !current.isEmpty { paragraphs.append(current) }
        return paragraphs.joined(separator: "\n")
    }

    /// Text of a Word `word/document.xml`: one line per paragraph, tabs and line breaks kept.
    public static func word(_ xml: String) -> String {
        officeText(xml, paragraph: "w:p", text: "w:t", tab: "w:tab", lineBreak: "w:br")
    }

    /// Text of a PowerPoint `ppt/slides/slideN.xml` (or notes slide): one line per paragraph.
    public static func slide(_ xml: String) -> String {
        officeText(xml, paragraph: "a:p", text: "a:t", tab: "a:tab", lineBreak: "a:br")
    }

    static func officeText(_ xml: String, paragraph: String, text: String, tab: String, lineBreak: String) -> String {
        // Runs of text, tabs and breaks, in document order; paragraphs end at </w:p>.
        let pattern = "<\(text)(?:\\s[^>]*)?>(.*?)</\(text)>|<\(tab)(?:\\s[^>]*)?/>|<\(lineBreak)(?:\\s[^>]*)?/>|</\(paragraph)>"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return "" }
        let ns = xml as NSString
        var lines: [String] = []
        var line = ""
        for m in re.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
            let token = ns.substring(with: m.range)
            if token.hasPrefix("</") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { lines.append(t) }
                line = ""
            } else if token.hasPrefix("<\(tab)") {
                line += "\t"
            } else if token.hasPrefix("<\(lineBreak)") {
                line += "\n"
            } else if m.range(at: 1).location != NSNotFound {
                line += decodeEntities(ns.substring(with: m.range(at: 1)))
            }
        }
        let t = line.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { lines.append(t) }
        return lines.joined(separator: "\n")
    }

    /// Excel `xl/sharedStrings.xml`: the string table cells point into (rich-text runs joined).
    public static func xlsxSharedStrings(_ xml: String) -> [String] {
        guard let si = try? NSRegularExpression(pattern: "<si\\b[^>]*>(.*?)</si>", options: [.dotMatchesLineSeparators]),
              let t = try? NSRegularExpression(pattern: "<t\\b[^>]*>(.*?)</t>", options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = xml as NSString
        return si.matches(in: xml, range: NSRange(location: 0, length: ns.length)).map { m in
            let inner = ns.substring(with: m.range(at: 1))
            let ins = inner as NSString
            return t.matches(in: inner, range: NSRange(location: 0, length: ins.length))
                .map { decodeEntities(ins.substring(with: $0.range(at: 1))) }.joined()
        }
    }

    /// Excel `xl/worksheets/sheetN.xml` as tab-separated rows.
    public static func xlsxSheet(_ xml: String, shared: [String]) -> String {
        guard let rowRE = try? NSRegularExpression(pattern: "<row\\b[^>]*>(.*?)</row>", options: [.dotMatchesLineSeparators]),
              let cellRE = try? NSRegularExpression(pattern: "<c\\b([^>]*?)(?:/>|>(.*?)</c>)", options: [.dotMatchesLineSeparators]) else { return "" }
        let ns = xml as NSString
        var lines: [String] = []
        for row in rowRE.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
            let inner = ns.substring(with: row.range(at: 1))
            let ins = inner as NSString
            var cells: [String] = []
            for c in cellRE.matches(in: inner, range: NSRange(location: 0, length: ins.length)) {
                let attrs = ins.substring(with: c.range(at: 1))
                let body = c.range(at: 2).location == NSNotFound ? "" : ins.substring(with: c.range(at: 2))
                let type = attrs.range(of: "t=\"([a-zA-Z]+)\"", options: .regularExpression).map { String(attrs[$0].dropFirst(3).dropLast()) } ?? ""
                var value = ""
                if type == "inlineStr" {
                    value = body.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                } else if let v = body.range(of: "(?s)<v>(.*?)</v>", options: .regularExpression) {
                    value = String(body[v].dropFirst(3).dropLast(4))
                    if type == "s", let i = Int(value), i >= 0, i < shared.count { value = shared[i] }
                }
                cells.append(decodeEntities(value).replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " "))
            }
            while cells.last == "" { cells.removeLast() }
            if !cells.isEmpty { lines.append(cells.joined(separator: "\t")) }
        }
        return lines.joined(separator: "\n")
    }

    /// OpenDocument `content.xml` (odt, ods, odp): paragraphs and headings on their own lines, table cells tab-separated.
    public static func openDocument(_ xml: String) -> String {
        var s = xml
        s = s.replacingOccurrences(of: "<text:tab/>", with: "\t")
        s = s.replacingOccurrences(of: "<text:line-break/>", with: "\n")
        s = s.replacingOccurrences(of: "<text:s(?: text:c=\"\\d+\")?/>", with: " ", options: .regularExpression)
        // A cell's paragraphs stay on its row: cells are tab-separated, rows end the line.
        if let cellRE = try? NSRegularExpression(pattern: "<table:table-cell\\b[^>]*>(.*?)</table:table-cell>", options: [.dotMatchesLineSeparators]) {
            let ns = s as NSString
            var rebuilt = ""
            var last = 0
            for m in cellRE.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                rebuilt += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                rebuilt += ns.substring(with: m.range(at: 1)).replacingOccurrences(of: "</text:p>", with: " ") + "\t"
                last = m.range.location + m.range.length
            }
            rebuilt += ns.substring(from: last)
            s = rebuilt
        }
        s = s.replacingOccurrences(of: "</(text:p|text:h|table:table-row|draw:page)>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let lines = decodeEntities(s).components(separatedBy: "\n").map {
            $0.replacingOccurrences(of: " +\t", with: "\t", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\t+$", with: "", options: .regularExpression)
        }
        return tidy(lines.joined(separator: "\n"))
    }

    /// Readable runs from a binary file (like `strings -n 6`), for formats nothing else can open.
    public static func printableRuns(_ data: Data, minLength: Int = 6, limit: Int = 200_000) -> String {
        var out = ""
        var run = ""
        for byte in data.prefix(20_000_000) {
            if (32...126).contains(byte) || byte == 9 {
                run.append(Character(Unicode.Scalar(byte)))
            } else {
                if run.count >= minLength { out += run + "\n"; if out.count > limit { break } }
                run = ""
            }
        }
        if run.count >= minLength { out += run }
        return String(out.prefix(limit))
    }

    /// Whether data looks like text (no NUL bytes near the start).
    public static func looksLikeText(_ data: Data) -> Bool {
        !data.prefix(8_192).contains(0)
    }

    /// XML character entities: the five named ones and numeric ones.
    public static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].firstIndex(of: ";"), s.distance(from: i, to: semi) <= 10 {
                let name = String(s[s.index(after: i)..<semi])
                var replacement: String?
                switch name {
                case "amp": replacement = "&"
                case "lt": replacement = "<"
                case "gt": replacement = ">"
                case "quot": replacement = "\""
                case "apos": replacement = "'"
                default:
                    if name.hasPrefix("#x") || name.hasPrefix("#X"), let v = UInt32(name.dropFirst(2), radix: 16), let u = Unicode.Scalar(v) {
                        replacement = String(Character(u))
                    } else if name.hasPrefix("#"), let v = UInt32(name.dropFirst()), let u = Unicode.Scalar(v) {
                        replacement = String(Character(u))
                    }
                }
                if let replacement {
                    out += replacement
                    i = s.index(after: semi)
                    continue
                }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }

    /// Slide files in presentation order ("ppt/slides/slide2.xml" before "slide10.xml").
    public static func sortedSlidePaths(_ paths: [String]) -> [String] {
        func number(_ p: String) -> Int {
            Int(p.split(separator: "/").last?.filter(\.isNumber) ?? "") ?? 0
        }
        return paths.filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }.sorted { number($0) < number($1) }
    }

    /// Collapse runs of blank lines and trailing spaces (PDF and OCR text).
    public static func tidy(_ s: String) -> String {
        var lines: [String] = []
        var blank = false
        for raw in s.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if !blank && !lines.isEmpty { lines.append("") }
                blank = true
            } else {
                lines.append(line)
                blank = false
            }
        }
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}

extension AIRouter {
    /// Whether notes from `characters` of material are better made in the cloud: on device they'd take more than
    /// `maxLocalParts` requests (a long PDF or several hours of audio).
    public static func notesComplexity(characters: Int, budget: LocalBudget, maxLocalParts: Int = 12) -> String? {
        let perPart = max(1_000, budget.prompt - 1_200)
        let parts = (characters + perPart - 1) / perPart
        return parts > maxLocalParts ? "Long material: about \(parts) parts on device" : nil
    }
}
