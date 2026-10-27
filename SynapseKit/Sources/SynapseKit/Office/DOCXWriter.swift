import Foundation

/// Writes Word documents (.docx, A4) from Markdown: `#`–`###` headings, paragraphs, bullet and numbered lists
/// (nested by indent), `**bold**`, `*italic*`, `` `code` ``, links, `>` quotes, fenced code, pipe tables and `---`
/// horizontal rules. A lone `#` heading at the top becomes the document title.
public enum DOCXWriter {
    enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case item(ordered: Bool, level: Int, text: String, numID: Int)
        case quote(String)
        case code([String])
        case rule
        case table(rows: [[String]], alignments: [CSV.Alignment])
    }

    // MARK: Parsing

    /// The blocks of `markdown`, plus the start number of each ordered list (by numbering id).
    static func parse(_ markdown: String) -> (blocks: [Block], starts: [Int: Int]) {
        let lines = OfficeText.normalize(markdown).components(separatedBy: "\n")
        var out: [Block] = []
        var starts: [Int: Int] = [:]
        var paragraph: [String] = []
        var quote: [String] = []
        var stack: [(indent: Int, ordered: Bool, numID: Int)] = []
        var nextNumID = 2   // 1 is the shared bullet list
        var inList = false
        var blankSinceItem = false

        func joined(_ lines: [String]) -> String {
            var s = ""
            for (i, raw) in lines.enumerated() {
                var line = raw
                let hardBreak = line.hasSuffix("  ") || line.hasSuffix("\\")
                if line.hasSuffix("\\") { line.removeLast() }
                s += line.trimmingCharacters(in: .whitespaces)
                if i < lines.count - 1 { s += hardBreak ? "\n" : " " }
            }
            return s
        }
        func flush() {
            if !paragraph.isEmpty { out.append(.paragraph(joined(paragraph))); paragraph = [] }
            if !quote.isEmpty { out.append(.quote(joined(quote))); quote = [] }
        }
        func endList() {
            stack = []
            inList = false
            blankSinceItem = false
        }

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") || t.hasPrefix("~~~") {
                flush(); endList()
                let fence = String(t.prefix(3))
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i])
                    i += 1
                }
                i += 1
                out.append(.code(code))
                continue
            }
            i += 1
            if t.isEmpty {
                flush()
                if inList { blankSinceItem = true }
                continue
            }
            if isRule(t) {
                flush(); endList()
                out.append(.rule)
                continue
            }
            if let h = PPTXWriter.heading(t) {
                flush(); endList()
                out.append(.heading(level: h.level, text: h.text))
                continue
            }
            if t.contains("|"), i < lines.count, CSV.isTableSeparator(lines[i]) {
                flush(); endList()
                var rows = [CSV.tableCells(t)]
                let alignments = CSV.alignments(lines[i])
                i += 1
                while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(CSV.tableCells(lines[i]))
                    i += 1
                }
                out.append(.table(rows: rows, alignments: alignments))
                continue
            }
            if t.hasPrefix(">") {
                if !paragraph.isEmpty { out.append(.paragraph(joined(paragraph))); paragraph = [] }
                endList()
                quote.append(String(t.drop { $0 == ">" || $0 == " " }))
                continue
            }
            if let item = PPTXWriter.listItem(line) {
                flush()
                while let last = stack.last, item.indent < last.indent { stack.removeLast() }
                func open() -> (indent: Int, ordered: Bool, numID: Int) {
                    guard item.ordered else { return (item.indent, false, 1) }
                    let id = nextNumID
                    nextNumID += 1
                    starts[id] = item.start ?? 1
                    return (item.indent, true, id)
                }
                if let last = stack.last {
                    if item.indent >= last.indent + 2 {
                        stack.append(open())
                    } else if last.ordered != item.ordered {
                        stack[stack.count - 1] = open()
                    }
                } else {
                    stack.append(open())
                }
                var text = item.text
                if text.hasPrefix("[ ] ") { text = "\u{2610} " + text.dropFirst(4) }
                if text.lowercased().hasPrefix("[x] ") { text = "\u{2611} " + text.dropFirst(4) }
                out.append(.item(ordered: item.ordered, level: min(stack.count - 1, 8), text: text, numID: stack[stack.count - 1].numID))
                inList = true
                blankSinceItem = false
                continue
            }
            // A line under a list item continues it (indented, or straight after it).
            if inList, line.first == " " || line.first == "\t" || !blankSinceItem,
               case .item(let ordered, let level, let text, let numID)? = out.last {
                out[out.count - 1] = .item(ordered: ordered, level: level, text: text + " " + t, numID: numID)
                continue
            }
            if !quote.isEmpty { out.append(.quote(joined(quote))); quote = [] }
            endList()
            paragraph.append(line)
        }
        flush()
        return (out, starts)
    }

    static func isRule(_ t: String) -> Bool {
        let s = t.replacingOccurrences(of: " ", with: "")
        guard s.count >= 3, let c = s.first, "-*_".contains(c) else { return false }
        return s.allSatisfy { $0 == c }
    }

    /// "5 headings, 12 paragraphs, 2 lists, 1 table" (zero counts left out).
    static func summary(markdown: String) -> String {
        let blocks = parse(markdown).blocks
        var headings = 0, paragraphs = 0, lists = 0, tables = 0, code = 0
        var listID: Int? // numbering of the current list's top level
        for b in blocks {
            switch b {
            case .heading: headings += 1
            case .paragraph, .quote: paragraphs += 1
            case .item(_, let level, _, let id):
                if listID == nil || (level == 0 && id != listID) { lists += 1 }
                if level == 0 || listID == nil { listID = id }
            case .table: tables += 1
            case .code: code += 1
            case .rule: break
            }
            if case .item = b {} else { listID = nil }
        }
        let parts = [(headings, "heading"), (paragraphs, "paragraph"), (lists, "list"), (tables, "table"), (code, "code block")]
            .filter { $0.0 > 0 }.map { OfficeText.count($0.0, $0.1) }
        return parts.isEmpty ? "empty document" : parts.joined(separator: ", ")
    }

    // MARK: Output

    /// Text width of an A4 page with 1-inch margins, in twentieths of a point.
    static let textWidth = 11_906 - 2 * 1_440

    /// The .docx bytes. `title` goes into the document properties.
    public static func write(markdown: String, title: String, created: Date = Date()) throws -> Data {
        let (blocks, starts) = parse(markdown)
        guard !blocks.isEmpty else { throw OfficeError(message: "Nothing to write: the document is empty.") }
        var links: [String] = []
        let topLevel = blocks.filter { if case .heading(1, _) = $0 { return true }; return false }.count
        var body = ""
        for (i, block) in blocks.enumerated() {
            switch block {
            case .heading(let level, let text):
                let style = i == 0 && level == 1 && topLevel == 1 ? "Title" : "Heading\(min(level, 3))"
                body += paragraph(text, style: style, links: &links)
            case .paragraph(let text):
                body += paragraph(text, style: nil, links: &links)
            case .quote(let text):
                body += paragraph(text, style: "Quote", links: &links)
            case .item(_, let level, let text, let numID):
                body += paragraph(text, style: "ListParagraph", properties: "<w:numPr><w:ilvl w:val=\"\(level)\"/><w:numId w:val=\"\(numID)\"/></w:numPr>", links: &links)
            case .code(let lines):
                let lines = lines.isEmpty ? [""] : lines
                for (n, line) in lines.enumerated() {
                    let spacing = n == lines.count - 1 ? "<w:spacing w:after=\"160\"/>" : ""
                    body += "<w:p><w:pPr><w:pStyle w:val=\"Code\"/>\(spacing)</w:pPr>\(line.isEmpty ? "" : run(OfficeRun(text: line)))</w:p>"
                }
            case .rule:
                body += "<w:p><w:pPr><w:pBdr><w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"1\" w:color=\"A6A6A6\"/></w:pBdr></w:pPr></w:p>"
            case .table(let rows, let alignments):
                body += table(rows, alignments: alignments, links: &links)
                if i == blocks.count - 1 { body += "<w:p/>" }
            }
        }
        let w = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\""
        let document = OfficeXML.header + "<w:document \(w) xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><w:body>\(body)"
            + "<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/><w:pgMar w:top=\"1440\" w:right=\"1440\" w:bottom=\"1440\" w:left=\"1440\" w:header=\"708\" w:footer=\"708\" w:gutter=\"0\"/>"
            + "<w:cols w:space=\"708\"/></w:sectPr></w:body></w:document>"

        let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
        var rels: [(type: String, target: String)] = [(rel + "styles", "styles.xml"), (rel + "numbering", "numbering.xml"), (rel + "settings", "settings.xml")]
        rels += links.map { (rel + "hyperlink", $0) }
        let wml = "application/vnd.openxmlformats-officedocument.wordprocessingml."
        let settings = OfficeXML.header + "<w:settings \(w)><w:zoom w:percent=\"100\"/><w:defaultTabStop w:val=\"720\"/><w:characterSpacingControl w:val=\"doNotCompress\"/>"
            + "<w:compat><w:compatSetting w:name=\"compatibilityMode\" w:uri=\"http://schemas.microsoft.com/office/word\" w:val=\"15\"/></w:compat></w:settings>"

        var zip = ZipWriter()
        zip.add("[Content_Types].xml", text: OfficeXML.contentTypes([
            ("word/document.xml", wml + "document.main+xml"), ("word/styles.xml", wml + "styles+xml"),
            ("word/numbering.xml", wml + "numbering+xml"), ("word/settings.xml", wml + "settings+xml"),
            ("docProps/core.xml", OfficeXML.coreType), ("docProps/app.xml", OfficeXML.appType),
        ]))
        zip.add("_rels/.rels", text: OfficeXML.packageRels(main: "word/document.xml"))
        zip.add("docProps/app.xml", text: OfficeXML.appProperties())
        zip.add("docProps/core.xml", text: OfficeXML.coreProperties(title: title, created: created))
        zip.add("word/document.xml", text: document)
        zip.add("word/_rels/document.xml.rels", text: OfficeXML.relationships(rels))
        zip.add("word/styles.xml", text: styles)
        zip.add("word/numbering.xml", text: numbering(starts))
        zip.add("word/settings.xml", text: settings)
        return try zip.finish()
    }

    /// A paragraph of inline Markdown. `links` collects hyperlink targets (relationship ids follow the 3 fixed ones).
    static func paragraph(_ text: String, style: String?, properties: String = "", alignment: String? = nil, bold: Bool = false, links: inout [String]) -> String {
        var pPr = style.map { "<w:pStyle w:val=\"\($0)\"/>" } ?? ""
        pPr += properties
        if let alignment { pPr += "<w:jc w:val=\"\(alignment)\"/>" }
        var runs = ""
        for var r in OfficeInline.runs(text) {
            r.bold = r.bold || bold
            if let url = r.link, url.hasPrefix("http://") || url.hasPrefix("https://") || url.hasPrefix("mailto:") {
                if !links.contains(url) { links.append(url) }
                let id = (links.firstIndex(of: url) ?? 0) + 4
                runs += "<w:hyperlink r:id=\"rId\(id)\" w:history=\"1\">\(run(r))</w:hyperlink>"
            } else {
                r.link = nil
                runs += run(r)
            }
        }
        return "<w:p>\(pPr.isEmpty ? "" : "<w:pPr>\(pPr)</w:pPr>")\(runs)</w:p>"
    }

    static func run(_ r: OfficeRun) -> String {
        var rPr = ""
        if r.link != nil { rPr += "<w:rStyle w:val=\"Hyperlink\"/>" }
        if r.code { rPr += "<w:rFonts w:ascii=\"Consolas\" w:hAnsi=\"Consolas\" w:cs=\"Consolas\"/>" }
        if r.bold { rPr += "<w:b/><w:bCs/>" }
        if r.italic { rPr += "<w:i/><w:iCs/>" }
        if r.strike { rPr += "<w:strike/>" }
        if r.code { rPr += "<w:sz w:val=\"20\"/><w:szCs w:val=\"20\"/><w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F2F2F2\"/>" }
        var content = ""
        for (i, line) in r.text.components(separatedBy: "\n").enumerated() {
            if i > 0 { content += "<w:br/>" }
            for (j, piece) in line.components(separatedBy: "\t").enumerated() {
                if j > 0 { content += "<w:tab/>" }
                if !piece.isEmpty { content += "<w:t xml:space=\"preserve\">\(OfficeXML.escape(piece))</w:t>" }
            }
        }
        return "<w:r>\(rPr.isEmpty ? "" : "<w:rPr>\(rPr)</w:rPr>")\(content)</w:r>"
    }

    static func table(_ input: [[String]], alignments: [CSV.Alignment], links: inout [String]) -> String {
        let columns = max(1, input.map(\.count).max() ?? 1)
        let rows = input.map { $0 + Array(repeating: "", count: columns - $0.count) }
        let weights = (0..<columns).map { c in Double(min(40, max(3, rows.map { OfficeText.width(OfficeInline.plain($0[c])) }.max() ?? 3))) }
        let total = weights.reduce(0, +)
        var widths = weights.map { Int(Double(textWidth) * $0 / total) }
        widths[columns - 1] += textWidth - widths.reduce(0, +)

        let edge = { (name: String) in "<w:\(name) w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"A6A6A6\"/>" }
        var xml = "<w:tbl><w:tblPr><w:tblW w:w=\"5000\" w:type=\"pct\"/><w:tblBorders>"
            + ["top", "left", "bottom", "right", "insideH", "insideV"].map(edge).joined()
            + "</w:tblBorders><w:tblLayout w:type=\"fixed\"/><w:tblCellMar><w:left w:w=\"108\" w:type=\"dxa\"/><w:right w:w=\"108\" w:type=\"dxa\"/></w:tblCellMar>"
            + "<w:tblLook w:val=\"04A0\"/></w:tblPr><w:tblGrid>" + widths.map { "<w:gridCol w:w=\"\($0)\"/>" }.joined() + "</w:tblGrid>"
        for (r, row) in rows.enumerated() {
            xml += "<w:tr>" + (r == 0 ? "<w:trPr><w:tblHeader/></w:trPr>" : "")
            for (c, cell) in row.enumerated() {
                let shade = r == 0 ? "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"DCE6F2\"/>" : ""
                var align: String?
                switch c < alignments.count ? alignments[c] : .none {
                case .center: align = "center"
                case .right: align = "right"
                default: align = nil
                }
                xml += "<w:tc><w:tcPr><w:tcW w:w=\"\(widths[c])\" w:type=\"dxa\"/>\(shade)</w:tcPr>"
                    + paragraph(cell, style: nil, properties: "<w:spacing w:before=\"40\" w:after=\"40\"/>", alignment: align, bold: r == 0, links: &links)
                    + "</w:tc>"
            }
            xml += "</w:tr>"
        }
        return xml + "</w:tbl>"
    }

    static func numbering(_ starts: [Int: Int]) -> String {
        let bullets = ["\u{2022}", "\u{25E6}", "\u{25AA}"]
        let formats = [("decimal", "."), ("lowerLetter", "."), ("lowerRoman", ".")]
        func levels(ordered: Bool) -> String {
            (0..<9).map { l in
                let fmt = ordered ? formats[l % 3].0 : "bullet"
                let text = ordered ? "%\(l + 1)\(formats[l % 3].1)" : bullets[l % 3]
                return "<w:lvl w:ilvl=\"\(l)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"\(fmt)\"/><w:lvlText w:val=\"\(text)\"/><w:lvlJc w:val=\"left\"/>"
                    + "<w:pPr><w:ind w:left=\"\(720 + 360 * l)\" w:hanging=\"360\"/></w:pPr></w:lvl>"
            }.joined()
        }
        var xml = OfficeXML.header + "<w:numbering xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">"
            + "<w:abstractNum w:abstractNumId=\"0\"><w:multiLevelType w:val=\"hybridMultilevel\"/>\(levels(ordered: false))</w:abstractNum>"
            + "<w:abstractNum w:abstractNumId=\"1\"><w:multiLevelType w:val=\"hybridMultilevel\"/>\(levels(ordered: true))</w:abstractNum>"
            + "<w:num w:numId=\"1\"><w:abstractNumId w:val=\"0\"/></w:num>"
        // Each ordered list is its own w:num restarting every level, so lists don't continue each other's numbering.
        for id in starts.keys.sorted() {
            let overrides = (0..<9).map { l in
                "<w:lvlOverride w:ilvl=\"\(l)\"><w:startOverride w:val=\"\(l == 0 ? max(0, starts[id] ?? 1) : 1)\"/></w:lvlOverride>"
            }.joined()
            xml += "<w:num w:numId=\"\(id)\"><w:abstractNumId w:val=\"1\"/>\(overrides)</w:num>"
        }
        return xml + "</w:numbering>"
    }

    static let styles: String = {
        func heading(_ n: Int, size: Int, before: Int, after: Int, color: String) -> String {
            "<w:style w:type=\"paragraph\" w:styleId=\"Heading\(n)\"><w:name w:val=\"heading \(n)\"/><w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/>"
                + "<w:uiPriority w:val=\"9\"/><w:qFormat/><w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before=\"\(before)\" w:after=\"\(after)\"/><w:outlineLvl w:val=\"\(n - 1)\"/></w:pPr>"
                + "<w:rPr><w:rFonts w:ascii=\"Calibri Light\" w:hAnsi=\"Calibri Light\" w:cs=\"Calibri Light\"/><w:b/><w:bCs/><w:color w:val=\"\(color)\"/><w:sz w:val=\"\(size)\"/><w:szCs w:val=\"\(size)\"/></w:rPr></w:style>"
        }
        return OfficeXML.header + "<w:styles xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">"
            + "<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii=\"Calibri\" w:eastAsia=\"Calibri\" w:hAnsi=\"Calibri\" w:cs=\"Calibri\"/>"
            + "<w:sz w:val=\"22\"/><w:szCs w:val=\"22\"/><w:lang w:val=\"en-US\" w:eastAsia=\"en-US\" w:bidi=\"ar-SA\"/></w:rPr></w:rPrDefault>"
            + "<w:pPrDefault><w:pPr><w:spacing w:after=\"160\" w:line=\"276\" w:lineRule=\"auto\"/></w:pPr></w:pPrDefault></w:docDefaults>"
            + "<w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/><w:qFormat/></w:style>"
            + "<w:style w:type=\"character\" w:default=\"1\" w:styleId=\"DefaultParagraphFont\"><w:name w:val=\"Default Paragraph Font\"/><w:uiPriority w:val=\"1\"/><w:semiHidden/><w:unhideWhenUsed/></w:style>"
            + "<w:style w:type=\"table\" w:default=\"1\" w:styleId=\"TableNormal\"><w:name w:val=\"Normal Table\"/><w:uiPriority w:val=\"99\"/><w:semiHidden/><w:unhideWhenUsed/>"
            + "<w:tblPr><w:tblInd w:w=\"0\" w:type=\"dxa\"/><w:tblCellMar><w:top w:w=\"0\" w:type=\"dxa\"/><w:left w:w=\"108\" w:type=\"dxa\"/><w:bottom w:w=\"0\" w:type=\"dxa\"/><w:right w:w=\"108\" w:type=\"dxa\"/></w:tblCellMar></w:tblPr></w:style>"
            + "<w:style w:type=\"numbering\" w:default=\"1\" w:styleId=\"NoList\"><w:name w:val=\"No List\"/><w:uiPriority w:val=\"99\"/><w:semiHidden/><w:unhideWhenUsed/></w:style>"
            + "<w:style w:type=\"paragraph\" w:styleId=\"Title\"><w:name w:val=\"Title\"/><w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:uiPriority w:val=\"10\"/><w:qFormat/>"
            + "<w:pPr><w:spacing w:after=\"240\" w:line=\"240\" w:lineRule=\"auto\"/><w:contextualSpacing/></w:pPr>"
            + "<w:rPr><w:rFonts w:ascii=\"Calibri Light\" w:hAnsi=\"Calibri Light\" w:cs=\"Calibri Light\"/><w:spacing w:val=\"-10\"/><w:kern w:val=\"28\"/><w:sz w:val=\"56\"/><w:szCs w:val=\"56\"/></w:rPr></w:style>"
            + heading(1, size: 32, before: 360, after: 120, color: "2F5496")
            + heading(2, size: 26, before: 240, after: 80, color: "2F5496")
            + heading(3, size: 24, before: 200, after: 60, color: "1F3763")
            + "<w:style w:type=\"paragraph\" w:styleId=\"ListParagraph\"><w:name w:val=\"List Paragraph\"/><w:basedOn w:val=\"Normal\"/><w:uiPriority w:val=\"34\"/><w:qFormat/>"
            + "<w:pPr><w:spacing w:after=\"80\"/><w:ind w:left=\"720\"/><w:contextualSpacing/></w:pPr></w:style>"
            + "<w:style w:type=\"paragraph\" w:styleId=\"Quote\"><w:name w:val=\"Quote\"/><w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:uiPriority w:val=\"29\"/><w:qFormat/>"
            + "<w:pPr><w:pBdr><w:left w:val=\"single\" w:sz=\"18\" w:space=\"8\" w:color=\"BFBFBF\"/></w:pBdr><w:spacing w:before=\"120\" w:after=\"160\"/><w:ind w:left=\"720\" w:right=\"720\"/></w:pPr>"
            + "<w:rPr><w:i/><w:iCs/><w:color w:val=\"595959\"/></w:rPr></w:style>"
            + "<w:style w:type=\"paragraph\" w:customStyle=\"1\" w:styleId=\"Code\"><w:name w:val=\"Code\"/><w:basedOn w:val=\"Normal\"/><w:qFormat/>"
            + "<w:pPr><w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F2F2F2\"/><w:spacing w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/><w:ind w:left=\"144\" w:right=\"144\"/></w:pPr>"
            + "<w:rPr><w:rFonts w:ascii=\"Consolas\" w:hAnsi=\"Consolas\" w:cs=\"Consolas\"/><w:sz w:val=\"20\"/><w:szCs w:val=\"20\"/></w:rPr></w:style>"
            + "<w:style w:type=\"character\" w:styleId=\"Hyperlink\"><w:name w:val=\"Hyperlink\"/><w:basedOn w:val=\"DefaultParagraphFont\"/><w:uiPriority w:val=\"99\"/><w:unhideWhenUsed/>"
            + "<w:rPr><w:color w:val=\"0563C1\"/><w:u w:val=\"single\"/></w:rPr></w:style>"
            + "</w:styles>"
    }()
}
