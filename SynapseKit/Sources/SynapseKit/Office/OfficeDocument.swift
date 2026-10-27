import Foundation

/// The Office file types Synapse can write on the device.
public enum OfficeKind: String, CaseIterable, Sendable {
    case xlsx, pptx, docx

    public var fileExtension: String { rawValue }

    /// The official OOXML media type.
    public var mimeType: String {
        switch self {
        case .xlsx: return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case .pptx: return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case .docx: return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        }
    }

    public var title: String {
        switch self {
        case .xlsx: return "Excel spreadsheet"
        case .pptx: return "PowerPoint presentation"
        case .docx: return "Word document"
        }
    }
}

/// Why an Office file couldn't be built.
public struct OfficeError: Error, LocalizedError, Sendable {
    public var message: String
    public var errorDescription: String? { message }

    public init(message: String) {
        self.message = message
    }
}

/// Builds real Office files from the text an AI agent writes: CSV or Markdown tables for spreadsheets, Markdown
/// slides for decks, Markdown for documents. Pure Swift, no server.
public enum OfficeDocument {
    /// Build the file bytes from the agent's text. `theme` only matters for pptx (DeckTheme raw value; unknown → .light).
    public static func make(_ kind: OfficeKind, title: String, text: String, theme: String? = nil) throws -> Data {
        let body = OfficeText.unfence(OfficeText.normalize(text))
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OfficeError(message: "Nothing to write: the \(kind.title) text is empty.")
        }
        let title = OfficeText.oneLine(title)
        switch kind {
        case .xlsx:
            var sheets = XLSXWriter.sheets(fromText: body)
            guard sheets.contains(where: { !$0.rows.isEmpty }) else {
                throw OfficeError(message: "Nothing to write: no rows found for the spreadsheet.")
            }
            if let i = sheets.firstIndex(where: { $0.name.isEmpty }), !title.isEmpty { sheets[i].name = title }
            return try XLSXWriter.write(sheets, title: title)
        case .pptx:
            let slides = PPTXWriter.slides(fromText: body)
            guard !slides.isEmpty else { throw OfficeError(message: "Nothing to write: no slides found.") }
            return try PPTXWriter.write(slides, title: title, theme: DeckTheme(named: theme))
        case .docx:
            return try DOCXWriter.write(markdown: body, title: title)
        }
    }

    /// One-line description of what was produced, e.g. "3 sheets, 42 rows" / "8 slides" / "5 headings, 2 tables", for the agent's tool result.
    public static func describe(_ kind: OfficeKind, text: String) -> String {
        let body = OfficeText.unfence(OfficeText.normalize(text))
        switch kind {
        case .xlsx:
            let sheets = XLSXWriter.sheets(fromText: body).filter { !$0.rows.isEmpty }
            let rows = sheets.reduce(0) { $0 + $1.rows.count }
            return "\(OfficeText.count(sheets.count, "sheet")), \(OfficeText.count(rows, "row"))"
        case .pptx:
            let slides = PPTXWriter.slides(fromText: body)
            let notes = slides.filter { !$0.notes.isEmpty }.count
            return OfficeText.count(slides.count, "slide") + (notes > 0 ? ", \(notes) with speaker notes" : "")
        case .docx:
            return DOCXWriter.summary(markdown: body)
        }
    }
}

// MARK: - Shared helpers

/// Text clean-up shared by the writers.
enum OfficeText {
    /// LF line endings, no BOM.
    static func normalize(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if t.hasPrefix("\u{FEFF}") { t.removeFirst() }
        return t
    }

    /// The text inside one code fence wrapping the whole input (models often wrap output in ```csv … ```).
    static func unfence(_ s: String) -> String {
        let lines = s.components(separatedBy: "\n")
        guard let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              let last = lines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }), first < last,
              lines[first].trimmingCharacters(in: .whitespaces).hasPrefix("```"),
              lines[last].trimmingCharacters(in: .whitespaces) == "```" else { return s }
        let inner = lines[(first + 1)..<last]
        // Only when no other fence opens inside (otherwise it's a document that contains code blocks).
        guard !inner.contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }) else { return s }
        return inner.joined(separator: "\n")
    }

    static func oneLine(_ s: String) -> String {
        s.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    /// Display width in "average characters": East Asian wide characters count double.
    static func width(_ s: String) -> Int {
        s.unicodeScalars.reduce(0) { n, u in
            let v = u.value
            let wide = (0x1100...0x115F).contains(v) || (0x2E80...0xA4CF).contains(v) || (0xAC00...0xD7A3).contains(v)
                || (0xF900...0xFAFF).contains(v) || (0xFE30...0xFE4F).contains(v) || (0xFF00...0xFF60).contains(v)
                || (0x1F300...0x1FAFF).contains(v) || (0x20000...0x3FFFD).contains(v)
            return n + (wide ? 2 : (u.properties.generalCategory == .nonspacingMark ? 0 : 1))
        }
    }
}

/// XML 1.0 text helpers.
enum OfficeXML {
    static let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"

    /// Escape `<>&"'` and drop characters XML 1.0 can't carry (C0 controls other than tab/LF/CR, U+FFFE, U+FFFF).
    static func escape(_ s: String) -> String {
        var out = ""
        out.unicodeScalars.reserveCapacity(s.unicodeScalars.count)
        for u in s.unicodeScalars {
            switch u {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default:
                if isLegal(u) { out.unicodeScalars.append(u) }
            }
        }
        return out
    }

    /// Legal in an XML 1.0 document (Swift scalars are never surrogates).
    static func isLegal(_ u: Unicode.Scalar) -> Bool {
        let v = u.value
        if v < 0x20 { return v == 0x9 || v == 0xA || v == 0xD }
        return v != 0xFFFE && v != 0xFFFF
    }

    /// Text with characters XML can't carry removed.
    static func clean(_ s: String) -> String {
        var out = ""
        out.unicodeScalars.append(contentsOf: s.unicodeScalars.filter(isLegal))
        return out
    }

    /// `docProps/core.xml`.
    static func coreProperties(title: String, created: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        let date = f.string(from: created)
        return header + """
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
        xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" \
        xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\
        <dc:title>\(escape(title))</dc:title><dc:creator>Synapse</dc:creator><cp:lastModifiedBy>Synapse</cp:lastModifiedBy>\
        <dcterms:created xsi:type="dcterms:W3CDTF">\(date)</dcterms:created>\
        <dcterms:modified xsi:type="dcterms:W3CDTF">\(date)</dcterms:modified></cp:coreProperties>
        """
    }

    /// `docProps/app.xml`; `extra` is more `<Properties>` children.
    static func appProperties(extra: String = "") -> String {
        header + """
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" \
        xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">\
        <Application>Synapse</Application>\(extra)</Properties>
        """
    }

    /// `_rels/.rels` pointing at the main part and the two docProps parts.
    static func packageRels(main: String) -> String {
        relationships([
            ("http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument", main),
            ("http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties", "docProps/core.xml"),
            ("http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties", "docProps/app.xml"),
        ])
    }

    /// A relationships part; ids are rId1, rId2… in order. A target starting with `http` is external.
    static func relationships(_ rels: [(type: String, target: String)]) -> String {
        let items = rels.enumerated().map { i, r in
            let external = r.target.hasPrefix("http") || r.target.hasPrefix("mailto:") ? " TargetMode=\"External\"" : ""
            return "<Relationship Id=\"rId\(i + 1)\" Type=\"\(r.type)\" Target=\"\(escape(r.target))\"\(external)/>"
        }.joined()
        return header + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(items)</Relationships>"
    }

    /// `[Content_Types].xml` with the rels/xml defaults and one override per part.
    static func contentTypes(_ overrides: [(part: String, type: String)]) -> String {
        let o = overrides.map { "<Override PartName=\"/\($0.part)\" ContentType=\"\($0.type)\"/>" }.joined()
        return header + """
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\(o)</Types>
        """
    }

    static let coreType = "application/vnd.openxmlformats-package.core-properties+xml"
    static let appType = "application/vnd.openxmlformats-officedocument.extended-properties+xml"
}

/// A run of inline Markdown text with its formatting.
struct OfficeRun: Equatable {
    var text: String
    var bold = false
    var italic = false
    var code = false
    var strike = false
    var link: String?
}

/// Inline Markdown (`**bold**`, `*italic*`, `` `code` ``, `~~strike~~`, `[text](url)`) to runs.
enum OfficeInline {
    static func runs(_ s: String) -> [OfficeRun] {
        let c = Array(s)
        var out: [OfficeRun] = []
        var buf = ""
        var bold = false, italic = false, strike = false

        func flush() {
            if !buf.isEmpty { out.append(OfficeRun(text: buf, bold: bold, italic: italic, strike: strike)); buf = "" }
        }
        func occurs(_ delim: [Character], after start: Int) -> Bool {
            guard start < c.count, delim.count <= c.count - start else { return false }
            var j = start
            while j + delim.count <= c.count {
                if Array(c[j..<(j + delim.count)]) == delim, j > 0, !c[j - 1].isWhitespace { return true }
                j += 1
            }
            return false
        }

        var i = 0
        while i < c.count {
            let ch = c[i]
            if ch == "\\", i + 1 < c.count, "\\`*_~[]()#+-.!|>".contains(c[i + 1]) {
                buf.append(c[i + 1]); i += 2; continue
            }
            if ch == "`" {
                var n = 0
                while i + n < c.count, c[i + n] == "`" { n += 1 }
                var j = i + n, close = -1
                while j < c.count {
                    if c[j] == "`" {
                        var m = 0
                        while j + m < c.count, c[j + m] == "`" { m += 1 }
                        if m == n { close = j; break }
                        j += m
                    } else { j += 1 }
                }
                if close >= 0 {
                    flush()
                    var code = String(c[(i + n)..<close])
                    if code.count > 1, code.hasPrefix(" "), code.hasSuffix(" ") { code = String(code.dropFirst().dropLast()) }
                    out.append(OfficeRun(text: code, bold: bold, italic: italic, code: true, strike: strike))
                    i = close + n
                } else {
                    buf += String(repeating: "`", count: n); i += n
                }
                continue
            }
            if ch == "!" || ch == "[", let link = linkAt(c, ch == "!" ? i + 1 : i) {
                flush()
                if ch == "!" {
                    if !link.text.isEmpty { out.append(OfficeRun(text: link.text, italic: true)) }
                } else {
                    for var r in runs(link.text) {
                        r.link = link.url
                        r.bold = r.bold || bold; r.italic = r.italic || italic; r.strike = r.strike || strike
                        out.append(r)
                    }
                }
                i = link.end; continue
            }
            if ch == "*" || ch == "_" {
                var n = 0
                while i + n < c.count, c[i + n] == ch { n += 1 }
                let prev: Character = i > 0 ? c[i - 1] : " "
                let next: Character = i + n < c.count ? c[i + n] : " "
                if ch == "_", prev.isLetter || prev.isNumber, next.isLetter || next.isNumber {
                    buf += String(repeating: "_", count: n); i += n; continue
                }
                let take = min(n, 3)
                let wantsBold = take >= 2, wantsItalic = take != 2
                let closing = (!wantsBold || bold) && (!wantsItalic || italic) && !prev.isWhitespace
                let delim = Array(repeating: ch, count: take)
                if closing {
                    flush()
                    if wantsBold { bold = false }
                    if wantsItalic { italic = false }
                    buf += String(repeating: String(ch), count: n - take)
                } else if !next.isWhitespace, (!wantsBold || !bold), (!wantsItalic || !italic), occurs(delim, after: i + n) {
                    flush()
                    buf += String(repeating: String(ch), count: n - take)
                    if wantsBold { bold = true }
                    if wantsItalic { italic = true }
                } else {
                    buf += String(repeating: String(ch), count: n)
                }
                i += n; continue
            }
            if ch == "~", i + 1 < c.count, c[i + 1] == "~" {
                let prev: Character = i > 0 ? c[i - 1] : " "
                let next: Character = i + 2 < c.count ? c[i + 2] : " "
                if strike, !prev.isWhitespace {
                    flush(); strike = false; i += 2; continue
                } else if !strike, !next.isWhitespace, occurs(["~", "~"], after: i + 2) {
                    flush(); strike = true; i += 2; continue
                }
            }
            if ch == "<", let br = lineBreakTag(c, i) {
                buf.append("\n"); i = br; continue
            }
            buf.append(ch); i += 1
        }
        flush()
        // Merge neighbours with the same formatting.
        var merged: [OfficeRun] = []
        for r in out {
            if var last = merged.last, last.bold == r.bold, last.italic == r.italic, last.code == r.code,
               last.strike == r.strike, last.link == r.link {
                last.text += r.text
                merged[merged.count - 1] = last
            } else {
                merged.append(r)
            }
        }
        return merged
    }

    /// Plain text with the Markdown markup removed.
    static func plain(_ s: String) -> String {
        runs(s).map(\.text).joined()
    }

    /// `[text](url)` starting at `i`.
    private static func linkAt(_ c: [Character], _ i: Int) -> (text: String, url: String, end: Int)? {
        guard i < c.count, c[i] == "[" else { return nil }
        var depth = 0, j = i
        while j < c.count {
            if c[j] == "[" { depth += 1 } else if c[j] == "]" { depth -= 1; if depth == 0 { break } }
            j += 1
        }
        guard j + 1 < c.count, c[j] == "]", c[j + 1] == "(" else { return nil }
        guard let close = c[(j + 2)...].firstIndex(of: ")") else { return nil }
        let text = String(c[(i + 1)..<j])
        var url = String(c[(j + 2)..<close]).trimmingCharacters(in: .whitespaces)
        if let space = url.firstIndex(of: " ") { url = String(url[..<space]) } // drop a "title"
        if url.hasPrefix("<"), url.hasSuffix(">") { url = String(url.dropFirst().dropLast()) }
        return (text, url, close + 1)
    }

    /// `<br>`, `<br/>`, `<br />` at `i`: the index after it.
    private static func lineBreakTag(_ c: [Character], _ i: Int) -> Int? {
        let rest = String(c[i..<min(c.count, i + 6)]).lowercased()
        for tag in ["<br />", "<br/>", "<br>"] where rest.hasPrefix(tag) { return i + tag.count }
        return nil
    }
}
