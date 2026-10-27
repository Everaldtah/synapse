import Foundation

/// Colour themes for generated decks: solid background, title, text and accent colours.
public enum DeckTheme: String, CaseIterable, Sendable {
    case light, dark, ocean, sunset, forest, mono

    /// The theme with this raw value (any case, surrounding spaces ignored), or `.light`.
    public init(named name: String?) {
        let key = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self = DeckTheme(rawValue: key) ?? .light
    }

    struct Palette {
        var background: String
        var title: String
        var text: String
        var subtle: String
        var accent: String
        var onAccent: String
        var band1: String
        var band2: String
        var line: String
        var isDark: Bool
        var accents: [String]
    }

    var palette: Palette {
        switch self {
        case .light:
            return Palette(background: "FFFFFF", title: "1F2937", text: "374151", subtle: "6B7280", accent: "2563EB", onAccent: "FFFFFF",
                           band1: "F3F4F6", band2: "FFFFFF", line: "D1D5DB", isDark: false,
                           accents: ["2563EB", "F59E0B", "10B981", "EF4444", "8B5CF6", "06B6D4"])
        case .dark:
            return Palette(background: "111827", title: "F9FAFB", text: "D1D5DB", subtle: "9CA3AF", accent: "60A5FA", onAccent: "0B1220",
                           band1: "1F2937", band2: "182132", line: "374151", isDark: true,
                           accents: ["60A5FA", "FBBF24", "34D399", "F87171", "A78BFA", "22D3EE"])
        case .ocean:
            return Palette(background: "0B2545", title: "FFFFFF", text: "D6E6F5", subtle: "8DA9C4", accent: "38BDF8", onAccent: "06213A",
                           band1: "13315C", band2: "0F2B50", line: "2A4D78", isDark: true,
                           accents: ["38BDF8", "2DD4BF", "FCD34D", "F472B6", "A5B4FC", "86EFAC"])
        case .sunset:
            return Palette(background: "FFF7ED", title: "7C2D12", text: "431407", subtle: "9A3412", accent: "EA580C", onAccent: "FFFFFF",
                           band1: "FFEDD5", band2: "FFF7ED", line: "FDBA74", isDark: false,
                           accents: ["EA580C", "DB2777", "F59E0B", "7C3AED", "0D9488", "DC2626"])
        case .forest:
            return Palette(background: "F3F7F2", title: "1B4332", text: "2D3B33", subtle: "52796F", accent: "2D6A4F", onAccent: "FFFFFF",
                           band1: "E3EDE4", band2: "F3F7F2", line: "B7CDBE", isDark: false,
                           accents: ["2D6A4F", "B08968", "40916C", "D4A373", "588157", "A3B18A"])
        case .mono:
            return Palette(background: "FFFFFF", title: "111111", text: "2B2B2B", subtle: "6E6E6E", accent: "111111", onAccent: "FFFFFF",
                           band1: "F2F2F2", band2: "FFFFFF", line: "CCCCCC", isDark: false,
                           accents: ["111111", "555555", "888888", "AAAAAA", "333333", "777777"])
        }
    }
}

/// Writes PowerPoint decks (.pptx, 16:9) from Markdown-style slides.
///
/// Input: slides separated by a `---` line. In each slide the first `#`/`##` line is the title; `- `, `* ` and `1. `
/// lines are bullets (indent two spaces or a tab for a sub-bullet); other lines are paragraphs; a `Notes:` line and
/// everything after it are the speaker notes; a Markdown table becomes a slide table. The first slide is a title slide.
public enum PPTXWriter {
    /// One slide.
    public struct Slide: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case text, bullet, number, heading, quote, code
        }

        /// A paragraph of the slide body. `level` is 0 for top-level bullets, 1–2 for sub-bullets.
        public struct Item: Equatable, Sendable {
            public var kind: Kind
            public var level: Int
            public var text: String

            public init(kind: Kind, level: Int = 0, text: String) {
                self.kind = kind
                self.level = level
                self.text = text
            }
        }

        public var title: String
        public var items: [Item]
        /// The slide's first Markdown table, if any.
        public var table: [[String]]?
        public var notes: String

        public init(title: String, items: [Item] = [], table: [[String]]? = nil, notes: String = "") {
            self.title = title
            self.items = items
            self.table = table
            self.notes = notes
        }
    }

    // MARK: Parsing

    /// The slides in `text`. Without any `---` separators, each `#`/`##` heading starts a slide.
    public static func slides(fromText text: String) -> [Slide] {
        let lines = OfficeText.normalize(text).components(separatedBy: "\n")
        var fence = false
        var hasSeparators = false
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { fence.toggle() }
            if !fence, isSeparator(line) { hasSeparators = true; break }
        }
        var chunks: [[String]] = []
        var current: [String] = []
        fence = false
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") { fence.toggle() }
            if !fence, isSeparator(line) {
                chunks.append(current)
                current = []
                continue
            }
            if !fence, !hasSeparators, let h = heading(t), h.level <= 2,
               current.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                chunks.append(current)
                current = []
            }
            current.append(line)
        }
        chunks.append(current)
        return chunks.compactMap(parseSlide)
    }

    static func isSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.count >= 3 && t.allSatisfy { $0 == "-" }
    }

    static func heading(_ t: String) -> (level: Int, text: String)? {
        let hashes = t.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = t.dropFirst(hashes)
        guard let first = rest.first, first == " " || first == "\t" else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        return (hashes, text.trimmingCharacters(in: .whitespaces))
    }

    /// Indent width (tab = 4), kind, number (for `3.`) and text of a list line.
    static func listItem(_ line: String) -> (indent: Int, ordered: Bool, start: Int?, text: String)? {
        var indent = 0
        var rest = Substring(line)
        while let c = rest.first, c == " " || c == "\t" {
            indent += c == "\t" ? 4 : 1
            rest.removeFirst()
        }
        guard let m = rest.range(of: "^([-*+•]|[0-9]{1,3}[.)]|[a-zA-Z][.)])[ \t]+", options: .regularExpression) else { return nil }
        let marker = rest[m].trimmingCharacters(in: .whitespaces)
        let text = String(rest[m.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        // "A. Smith" style initials only count as a list when the letter marker is lowercase.
        if let f = marker.first, f.isLetter, f.isUppercase { return nil }
        return (indent, !"-*+•".contains(marker), Int(marker.dropLast()), text)
    }

    static func notesStart(_ t: String) -> String? {
        guard let r = t.range(of: "^(\\*\\*|__)?(speaker\\s+)?notes?(\\*\\*|__)?\\s*:\\s*(\\*\\*|__)?", options: [.regularExpression, .caseInsensitive])
        else { return nil }
        return String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    static func cleanTitle(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if let r = t.range(of: "^slide\\s+[0-9]+\\s*[:.\\-–—]\\s*", options: [.regularExpression, .caseInsensitive]), r.upperBound < t.endIndex {
            t = String(t[r.upperBound...])
        }
        return t
    }

    static func parseSlide(_ lines: [String]) -> Slide? {
        var slide = Slide(title: "")
        var notes: [String]?
        var stack: [Int] = []
        var fence = false
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)
            i += 1
            if notes != nil { notes?.append(t); continue }
            if fence {
                if t.hasPrefix("```") { fence = false } else { slide.items.append(Slide.Item(kind: .code, text: line)) }
                continue
            }
            if t.hasPrefix("```") { fence = true; stack = []; continue }
            if t.isEmpty { continue }
            if let n = notesStart(t) { notes = [n]; continue }
            if t.contains("|"), i < lines.count, CSV.isTableSeparator(lines[i]) {
                var rows = [CSV.tableCells(t)]
                i += 1
                while i < lines.count, lines[i].contains("|") {
                    rows.append(CSV.tableCells(lines[i]))
                    i += 1
                }
                if slide.table == nil {
                    slide.table = rows
                } else {
                    slide.items += rows.map { Slide.Item(kind: .text, text: $0.joined(separator: "  ·  ")) }
                }
                stack = []
                continue
            }
            if let h = heading(t) {
                if slide.title.isEmpty, h.level <= 3 { slide.title = cleanTitle(h.text) } else { slide.items.append(Slide.Item(kind: .heading, text: h.text)) }
                stack = []
                continue
            }
            if slide.title.isEmpty, slide.items.isEmpty, let r = t.range(of: "^\\**title\\**\\s*:\\s*", options: [.regularExpression, .caseInsensitive]) {
                slide.title = cleanTitle(String(t[r.upperBound...]))
                continue
            }
            if let item = listItem(line) {
                while let last = stack.last, item.indent < last { stack.removeLast() }
                if let last = stack.last {
                    if item.indent >= last + 2 { stack.append(item.indent) }
                } else {
                    stack.append(item.indent)
                }
                var text = item.text
                if text.hasPrefix("[ ] ") { text = "\u{2610} " + text.dropFirst(4) }
                if text.lowercased().hasPrefix("[x] ") { text = "\u{2611} " + text.dropFirst(4) }
                slide.items.append(Slide.Item(kind: item.ordered ? .number : .bullet, level: min(stack.count - 1, 2), text: text))
                continue
            }
            if t.hasPrefix("!["), t.hasSuffix(")") { continue } // images aren't embedded
            var text = t
            var kind = Slide.Kind.text
            if text.hasPrefix(">") {
                text = String(text.drop { $0 == ">" || $0 == " " })
                kind = .quote
            }
            if let r = text.range(of: "^\\**subtitle\\**\\s*:\\s*", options: [.regularExpression, .caseInsensitive]) {
                text = String(text[r.upperBound...])
            }
            let indented = line.first == " " || line.first == "\t"
            if indented, let last = slide.items.last, last.kind == .bullet || last.kind == .number {
                slide.items[slide.items.count - 1].text += " " + text
            } else if kind == .quote, let last = slide.items.last, last.kind == .quote {
                slide.items[slide.items.count - 1].text += " " + text
            } else {
                slide.items.append(Slide.Item(kind: kind, text: text))
                stack = []
            }
        }
        if let notes {
            slide.notes = notes.map { OfficeInline.plain($0) }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if slide.title.isEmpty, slide.items.isEmpty, slide.table == nil, slide.notes.isEmpty { return nil }
        return slide
    }

    // MARK: Geometry (EMU; 914,400 per inch, 12,700 per point)

    static let slideWidth = 12_192_000
    static let slideHeight = 6_858_000
    static let margin = 609_600
    static let contentWidth = slideWidth - 2 * margin
    static let titleBox = (y: 330_000, cy: 1_060_000)
    static let barBox = (y: 1_455_000, cx: 914_400, cy: 54_864)
    static let bodyBox = (y: 1_640_000, cy: 4_620_000)
    static let coverTitle = (x: 914_400, y: 1_500_000, cx: 10_363_200, cy: 2_100_000)
    static let coverBar = (y: 3_745_000, cx: 1_097_280, cy: 64_008)
    static let coverSubtitle = (x: 1_524_000, y: 3_960_000, cx: 9_144_000, cy: 2_000_000)

    static func points(_ emu: Int) -> Double { Double(emu) / 12_700 }

    // MARK: Text fitting

    /// Lines `text` wraps to in a box `width` points wide at `size` points (average glyph ≈ 0.52 em).
    static func lineCount(_ text: String, size: Double, width: Double) -> Int {
        let perLine = max(1, width / (size * 0.52))
        return text.components(separatedBy: "\n").reduce(0) { n, l in
            n + max(1, Int((Double(OfficeText.width(l)) * 1.05 / perLine).rounded(.up)))
        }
    }

    static func itemSize(_ base: Double, _ item: Slide.Item) -> Double {
        switch item.kind {
        case .code: return max(9, base * 0.75)
        case .heading: return base
        default: return max(9, (base * [1, 0.86, 0.76][min(item.level, 2)]).rounded())
        }
    }

    /// Left margin and hanging indent (EMU). Sub-bullets line up with their parent's text.
    static func indent(_ item: Slide.Item) -> (marL: Int, hanging: Int) {
        switch item.kind {
        case .bullet: return ([342_900, 742_950, 1_143_000][min(item.level, 2)], 285_750)
        case .number: return ([457_200, 857_250, 1_257_300][min(item.level, 2)], 400_050)
        case .quote: return (228_600, 0)
        default: return (0, 0)
        }
    }

    /// Largest body size (points) at which `items` fit `width` × `height` points, plus a PowerPoint font scale
    /// (100,000 = none) when even the smallest size overflows.
    static func fit(_ items: [Slide.Item], width: Double, height: Double, sizes: [Double]) -> (size: Double, scale: Int) {
        func needed(_ size: Double) -> Double {
            items.reduce(0) { h, item in
                let s = itemSize(size, item)
                let w = width - points(indent(item).marL)
                return h + Double(lineCount(OfficeInline.plain(item.text), size: s, width: w)) * s * 1.2 + s * 0.5
            }
        }
        for size in sizes where needed(size) <= height { return (size, 100_000) }
        let smallest = sizes.last ?? 10
        let scale = max(25_000, Int(height / needed(smallest) * 100_000) / 2_500 * 2_500)
        return (smallest, scale)
    }

    static func titleSize(_ text: String, width: Double, height: Double, sizes: [Double]) -> Double {
        for size in sizes where Double(lineCount(text, size: size, width: width)) * size * 1.15 <= height { return size }
        return sizes.last ?? 20
    }

    // MARK: XML pieces

    static let namespaces = "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" "
        + "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" "
        + "xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\""

    static let groupProperties = "<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>"
        + "<p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/><a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"0\" cy=\"0\"/></a:xfrm></p:grpSpPr>"

    static func fill(_ color: String) -> String {
        "<a:solidFill><a:srgbClr val=\"\(color)\"/></a:solidFill>"
    }

    static func background(_ color: String) -> String {
        "<p:bg><p:bgPr>\(fill(color))<a:effectLst/></p:bgPr></p:bg>"
    }

    static func xfrm(_ x: Int, _ y: Int, _ cx: Int, _ cy: Int) -> String {
        "<a:xfrm><a:off x=\"\(x)\" y=\"\(y)\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm>"
    }

    /// Runs for inline Markdown `text`.
    static func runs(_ text: String, size: Double, color: String, bold: Bool = false, italic: Bool = false, palette: DeckTheme.Palette) -> String {
        let sz = Int((size * 100).rounded())
        return OfficeInline.runs(text).map { r -> String in
            var attrs = "lang=\"en-US\" sz=\"\(sz)\""
            if bold || r.bold { attrs += " b=\"1\"" }
            if italic || r.italic { attrs += " i=\"1\"" }
            if r.strike { attrs += " strike=\"sngStrike\"" }
            if r.link != nil { attrs += " u=\"sng\"" }
            attrs += " dirty=\"0\""
            let font = r.code ? "<a:latin typeface=\"Courier New\"/><a:cs typeface=\"Courier New\"/>" : ""
            let props = "<a:rPr \(attrs)>\(fill(r.link != nil ? palette.accent : color))\(font)</a:rPr>"
            return r.text.replacingOccurrences(of: "\t", with: "    ").components(separatedBy: "\n").map {
                "<a:r>\(props)<a:t>\(OfficeXML.escape($0))</a:t></a:r>"
            }.joined(separator: "<a:br>\(props)</a:br>")
        }.joined()
    }

    static func paragraph(_ item: Slide.Item, base: Double, palette: DeckTheme.Palette) -> String {
        let size = itemSize(base, item)
        let before = "<a:spcBef><a:spcPts val=\"\(Int(size * 50))\"/></a:spcBef>"
        let (marL, hanging) = indent(item)
        let lvl = item.level > 0 ? " lvl=\"\(min(item.level, 2))\"" : ""
        var pPr: String
        switch item.kind {
        case .bullet:
            let char = ["\u{2022}", "\u{2013}", "\u{2022}"][min(item.level, 2)]
            pPr = "<a:pPr marL=\"\(marL)\" indent=\"-\(hanging)\"\(lvl)>\(before)<a:buClr><a:srgbClr val=\"\(palette.accent)\"/></a:buClr>"
                + "<a:buSzPct val=\"100000\"/><a:buFont typeface=\"Arial\"/><a:buChar char=\"\(char)\"/></a:pPr>"
        case .number:
            let scheme = ["arabicPeriod", "alphaLcPeriod", "romanLcPeriod"][min(item.level, 2)]
            pPr = "<a:pPr marL=\"\(marL)\" indent=\"-\(hanging)\"\(lvl)>\(before)<a:buClr><a:srgbClr val=\"\(palette.accent)\"/></a:buClr>"
                + "<a:buSzPct val=\"100000\"/><a:buFont typeface=\"+mj-lt\"/><a:buAutoNum type=\"\(scheme)\"/></a:pPr>"
        default:
            pPr = "<a:pPr marL=\"\(marL)\" indent=\"0\">\(item.kind == .code ? "<a:spcBef><a:spcPts val=\"0\"/></a:spcBef>" : before)<a:buNone/></a:pPr>"
        }
        let text = item.kind == .code ? "`" + item.text.replacingOccurrences(of: "`", with: "'") + "`" : item.text
        let color = item.kind == .heading ? palette.title : (item.kind == .quote ? palette.subtle : palette.text)
        let content = runs(text, size: size, color: color, bold: item.kind == .heading, italic: item.kind == .quote, palette: palette)
        return "<a:p>\(pPr)\(content)</a:p>"
    }

    static func textShape(id: Int, name: String, placeholder: String?, frame: (Int, Int, Int, Int), anchor: String,
                          autofit: String = "<a:normAutofit/>", paragraphs: String) -> String {
        let locks = placeholder != nil ? "<p:cNvSpPr><a:spLocks noGrp=\"1\"/></p:cNvSpPr>" : "<p:cNvSpPr txBox=\"1\"/>"
        return "<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"\(name)\"/>\(locks)<p:nvPr>\(placeholder ?? "")</p:nvPr></p:nvSpPr>"
            + "<p:spPr>\(xfrm(frame.0, frame.1, frame.2, frame.3))<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom>\(placeholder == nil ? "<a:noFill/>" : "")</p:spPr>"
            + "<p:txBody><a:bodyPr vert=\"horz\" wrap=\"square\" lIns=\"91440\" tIns=\"45720\" rIns=\"91440\" bIns=\"45720\" rtlCol=\"0\" anchor=\"\(anchor)\">\(autofit)</a:bodyPr>"
            + "<a:lstStyle/>\(paragraphs.isEmpty ? "<a:p><a:endParaRPr lang=\"en-US\" dirty=\"0\"/></a:p>" : paragraphs)</p:txBody></p:sp>"
    }

    static func rectangle(id: Int, name: String, frame: (Int, Int, Int, Int), color: String) -> String {
        "<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"\(name)\"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr>\(xfrm(frame.0, frame.1, frame.2, frame.3))"
            + "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom>\(fill(color))<a:ln><a:noFill/></a:ln></p:spPr></p:sp>"
    }

    /// A slide table in `frame`, header row in the accent colour, banded body rows.
    static func table(_ input: [[String]], id: Int, frame: (Int, Int, Int, Int), palette: DeckTheme.Palette) -> String {
        let columns = max(1, input.map(\.count).max() ?? 1)
        let rows = input.map { $0 + Array(repeating: "", count: columns - $0.count) }
        let weights = (0..<columns).map { c in Double(min(40, max(4, rows.map { OfficeText.width(OfficeInline.plain($0[c])) }.max() ?? 4))) }
        let total = weights.reduce(0, +)
        var widths = weights.map { Int(Double(frame.2) * $0 / total) }
        widths[columns - 1] += frame.2 - widths.reduce(0, +)

        func rowHeights(_ size: Double) -> [Double] {
            rows.map { row in
                let lines = row.enumerated().map { c, cell in lineCount(OfficeInline.plain(cell), size: size, width: points(widths[c]) - 14.4) }.max() ?? 1
                return Double(lines) * size * 1.2 + 9
            }
        }
        let available = points(frame.3)
        var size = 9.0
        for s in [24.0, 22, 20, 18, 16, 14, 13, 12, 11, 10, 9] where rowHeights(s).reduce(0, +) <= available {
            size = s
            break
        }
        let heights = rowHeights(size).map { Int($0 * 12_700) }
        let line = { (edge: String) in "<a:\(edge) w=\"6350\" cap=\"flat\" cmpd=\"sng\" algn=\"ctr\">\(fill(palette.line))<a:prstDash val=\"solid\"/></a:\(edge)>" }
        let borders = ["lnL", "lnR", "lnT", "lnB"].map(line).joined()
        var body = ""
        for (r, row) in rows.enumerated() {
            let header = r == 0
            let cellFill = header ? palette.accent : (r % 2 == 1 ? palette.band1 : palette.band2)
            let color = header ? palette.onAccent : palette.text
            let cells = row.map { cell -> String in
                let text = runs(cell, size: size, color: color, bold: header, palette: palette)
                return "<a:tc><a:txBody><a:bodyPr/><a:lstStyle/><a:p>\(text.isEmpty ? "<a:endParaRPr lang=\"en-US\" sz=\"\(Int(size * 100))\" dirty=\"0\"/>" : text)</a:p></a:txBody>"
                    + "<a:tcPr marL=\"91440\" marR=\"91440\" marT=\"45720\" marB=\"45720\" anchor=\"ctr\">\(borders)\(fill(cellFill))</a:tcPr></a:tc>"
            }.joined()
            body += "<a:tr h=\"\(heights[r])\">\(cells)</a:tr>"
        }
        let grid = widths.map { "<a:gridCol w=\"\($0)\"/>" }.joined()
        let height = heights.reduce(0, +)
        return "<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id=\"\(id)\" name=\"Table \(id)\"/><p:cNvGraphicFramePr><a:graphicFrameLocks noGrp=\"1\"/></p:cNvGraphicFramePr><p:nvPr/></p:nvGraphicFramePr>"
            + "<p:xfrm><a:off x=\"\(frame.0)\" y=\"\(frame.1)\"/><a:ext cx=\"\(frame.2)\" cy=\"\(min(height, frame.3))\"/></p:xfrm>"
            + "<a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/table\"><a:tbl><a:tblPr firstRow=\"1\" bandRow=\"1\"/>"
            + "<a:tblGrid>\(grid)</a:tblGrid>\(body)</a:tbl></a:graphicData></a:graphic></p:graphicFrame>"
    }

    // MARK: Slides

    static func titleSlide(_ slide: Slide, deckTitle: String, palette: DeckTheme.Palette) -> String {
        let title = slide.title.isEmpty ? (deckTitle.isEmpty ? "Untitled presentation" : deckTitle) : slide.title
        let tSize = titleSize(OfficeInline.plain(title), width: points(coverTitle.cx) - 14.4, height: points(coverTitle.cy) - 7.2,
                              sizes: [54, 48, 44, 40, 36, 32, 28, 24])
        var shapes = textShape(id: 2, name: "Title 1", placeholder: "<p:ph type=\"ctrTitle\"/>",
                               frame: (coverTitle.x, coverTitle.y, coverTitle.cx, coverTitle.cy), anchor: "b",
                               paragraphs: "<a:p><a:pPr algn=\"ctr\"/>\(runs(title, size: tSize, color: palette.title, bold: true, palette: palette))</a:p>")
        shapes += rectangle(id: 4, name: "Accent", frame: ((slideWidth - coverBar.cx) / 2, coverBar.y, coverBar.cx, coverBar.cy), color: palette.accent)
        var lines = slide.items.map { Slide.Item(kind: .text, text: $0.text) }
        if let table = slide.table { lines += table.map { Slide.Item(kind: .text, text: $0.joined(separator: "  ·  ")) } }
        if !lines.isEmpty {
            let (size, scale) = fit(lines, width: points(coverSubtitle.cx) - 14.4, height: points(coverSubtitle.cy) - 7.2,
                                    sizes: [26, 24, 22, 20, 18, 16, 14, 12])
            let paragraphs = lines.map { item in
                "<a:p><a:pPr marL=\"0\" indent=\"0\" algn=\"ctr\"><a:spcBef><a:spcPts val=\"\(Int(size * 30))\"/></a:spcBef><a:buNone/></a:pPr>"
                    + runs(item.text, size: size, color: palette.subtle, palette: palette) + "</a:p>"
            }.joined()
            shapes += textShape(id: 3, name: "Subtitle 2", placeholder: "<p:ph type=\"subTitle\" idx=\"1\"/>",
                                frame: (coverSubtitle.x, coverSubtitle.y, coverSubtitle.cx, coverSubtitle.cy), anchor: "t",
                                autofit: scale < 100_000 ? "<a:normAutofit fontScale=\"\(scale)\"/>" : "<a:normAutofit/>", paragraphs: paragraphs)
        }
        return slideXML(shapes, palette: palette)
    }

    static func contentSlide(_ slide: Slide, number: Int, palette: DeckTheme.Palette) -> String {
        var shapes = ""
        if !slide.title.isEmpty {
            let size = titleSize(OfficeInline.plain(slide.title), width: points(contentWidth) - 14.4, height: points(titleBox.cy) - 7.2,
                                 sizes: [40, 36, 32, 28, 26, 24, 20])
            shapes += textShape(id: 2, name: "Title 1", placeholder: "<p:ph type=\"title\"/>",
                                frame: (margin, titleBox.y, contentWidth, titleBox.cy), anchor: "b",
                                paragraphs: "<a:p>\(runs(slide.title, size: size, color: palette.title, bold: true, palette: palette))</a:p>")
        }
        shapes += rectangle(id: 4, name: "Accent", frame: (margin, barBox.y, barBox.cx, barBox.cy), color: palette.accent)

        var textHeight = bodyBox.cy
        let gap = 182_880
        if slide.table != nil {
            textHeight = slide.items.isEmpty ? 0 : min(bodyBox.cy * 2 / 5, max(bodyBox.cy / 5, slide.items.count * 420_000))
        }
        if !slide.items.isEmpty {
            let (size, scale) = fit(slide.items, width: points(contentWidth) - 14.4, height: points(textHeight) - 7.2,
                                    sizes: slide.table == nil ? [28, 26, 24, 22, 20, 18, 16, 14, 12, 11, 10] : [20, 18, 16, 14, 12, 11, 10])
            let paragraphs = slide.items.map { paragraph($0, base: size, palette: palette) }.joined()
            shapes += textShape(id: 3, name: "Content 2", placeholder: "<p:ph idx=\"1\"/>",
                                frame: (margin, bodyBox.y, contentWidth, textHeight), anchor: "t",
                                autofit: scale < 100_000 ? "<a:normAutofit fontScale=\"\(scale)\" lnSpcReduction=\"10000\"/>" : "<a:normAutofit/>",
                                paragraphs: paragraphs)
        }
        if let rows = slide.table {
            let top = slide.items.isEmpty ? bodyBox.y : bodyBox.y + textHeight + gap
            shapes += table(rows, id: 6, frame: (margin, top, contentWidth, bodyBox.y + bodyBox.cy - top), palette: palette)
        }
        shapes += textShape(id: 5, name: "Slide Number", placeholder: nil, frame: (slideWidth - margin - 1_219_200, 6_355_080, 1_219_200, 365_760),
                            anchor: "ctr", autofit: "",
                            paragraphs: "<a:p><a:pPr algn=\"r\"/>\(runs(String(number), size: 12, color: palette.subtle, palette: palette))</a:p>")
        return slideXML(shapes, palette: palette)
    }

    static func slideXML(_ shapes: String, palette: DeckTheme.Palette) -> String {
        OfficeXML.header + "<p:sld \(namespaces)><p:cSld>\(background(palette.background))<p:spTree>\(groupProperties)\(shapes)</p:spTree></p:cSld>"
            + "<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>"
    }

    static func notesSlide(_ notes: String) -> String {
        let paragraphs = notes.components(separatedBy: "\n").map {
            $0.isEmpty ? "<a:p><a:endParaRPr lang=\"en-US\" dirty=\"0\"/></a:p>" : "<a:p><a:r><a:rPr lang=\"en-US\" dirty=\"0\"/><a:t>\(OfficeXML.escape($0))</a:t></a:r></a:p>"
        }.joined()
        return OfficeXML.header + "<p:notes \(namespaces)><p:cSld><p:spTree>\(groupProperties)"
            + "<p:sp><p:nvSpPr><p:cNvPr id=\"2\" name=\"Slide Image Placeholder 1\"/><p:cNvSpPr><a:spLocks noGrp=\"1\" noRot=\"1\" noChangeAspect=\"1\"/></p:cNvSpPr>"
            + "<p:nvPr><p:ph type=\"sldImg\"/></p:nvPr></p:nvSpPr><p:spPr/></p:sp>"
            + "<p:sp><p:nvSpPr><p:cNvPr id=\"3\" name=\"Notes Placeholder 2\"/><p:cNvSpPr><a:spLocks noGrp=\"1\"/></p:cNvSpPr>"
            + "<p:nvPr><p:ph type=\"body\" idx=\"1\"/></p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/>\(paragraphs)</p:txBody></p:sp>"
            + "</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:notes>"
    }

    // MARK: Package parts

    static func clrMap(dark: Bool) -> String {
        dark
            ? "<p:clrMap bg1=\"dk1\" tx1=\"lt1\" bg2=\"dk2\" tx2=\"lt2\" accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\"/>"
            : "<p:clrMap bg1=\"lt1\" tx1=\"dk1\" bg2=\"lt2\" tx2=\"dk2\" accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\"/>"
    }

    static func themeXML(_ p: DeckTheme.Palette, name: String) -> String {
        // Dark themes keep dk1 dark and map the background to it (see clrMap).
        let dk1 = p.isDark ? p.background : p.title
        let lt1 = p.isDark ? p.title : p.background
        let dk2 = p.isDark ? p.band1 : p.text
        let lt2 = p.isDark ? p.text : p.band1
        let accents = p.accents.enumerated().map { "<a:accent\($0.offset + 1)><a:srgbClr val=\"\($0.element)\"/></a:accent\($0.offset + 1)>" }.joined()
        func ln(_ w: Int) -> String {
            "<a:ln w=\"\(w)\" cap=\"flat\" cmpd=\"sng\" algn=\"ctr\"><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill><a:prstDash val=\"solid\"/><a:miter lim=\"800000\"/></a:ln>"
        }
        func gs(_ pos: Int, _ mods: String) -> String { "<a:gs pos=\"\(pos)\"><a:schemeClr val=\"phClr\">\(mods)</a:schemeClr></a:gs>" }
        let grad1 = "<a:gradFill rotWithShape=\"1\"><a:gsLst>"
            + gs(0, "<a:lumMod val=\"110000\"/><a:satMod val=\"105000\"/><a:tint val=\"67000\"/>")
            + gs(50_000, "<a:lumMod val=\"105000\"/><a:satMod val=\"103000\"/><a:tint val=\"73000\"/>")
            + gs(100_000, "<a:lumMod val=\"105000\"/><a:satMod val=\"109000\"/><a:tint val=\"81000\"/>")
            + "</a:gsLst><a:lin ang=\"5400000\" scaled=\"0\"/></a:gradFill>"
        let grad2 = "<a:gradFill rotWithShape=\"1\"><a:gsLst>"
            + gs(0, "<a:satMod val=\"103000\"/><a:lumMod val=\"102000\"/><a:tint val=\"94000\"/>")
            + gs(50_000, "<a:satMod val=\"110000\"/><a:lumMod val=\"100000\"/><a:shade val=\"100000\"/>")
            + gs(100_000, "<a:lumMod val=\"99000\"/><a:satMod val=\"120000\"/><a:shade val=\"78000\"/>")
            + "</a:gsLst><a:lin ang=\"5400000\" scaled=\"0\"/></a:gradFill>"
        let solid = "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>"
        return OfficeXML.header + """
        <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="\(name)"><a:themeElements>\
        <a:clrScheme name="\(name)"><a:dk1><a:srgbClr val="\(dk1)"/></a:dk1><a:lt1><a:srgbClr val="\(lt1)"/></a:lt1>\
        <a:dk2><a:srgbClr val="\(dk2)"/></a:dk2><a:lt2><a:srgbClr val="\(lt2)"/></a:lt2>\(accents)\
        <a:hlink><a:srgbClr val="\(p.accent)"/></a:hlink><a:folHlink><a:srgbClr val="\(p.subtle)"/></a:folHlink></a:clrScheme>\
        <a:fontScheme name="\(name)"><a:majorFont><a:latin typeface="Arial" panose="020B0604020202020204"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont>\
        <a:minorFont><a:latin typeface="Arial" panose="020B0604020202020204"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme>\
        <a:fmtScheme name="\(name)"><a:fillStyleLst>\(solid)\(grad1)\(grad2)</a:fillStyleLst>\
        <a:lnStyleLst>\(ln(6350))\(ln(12700))\(ln(19050))</a:lnStyleLst>\
        <a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle>\
        <a:effectStyle><a:effectLst><a:outerShdw blurRad="57150" dist="19050" dir="5400000" algn="ctr" rotWithShape="0">\
        <a:srgbClr val="000000"><a:alpha val="63000"/></a:srgbClr></a:outerShdw></a:effectLst></a:effectStyle></a:effectStyleLst>\
        <a:bgFillStyleLst>\(solid)<a:solidFill><a:schemeClr val="phClr"><a:tint val="95000"/><a:satMod val="170000"/></a:schemeClr></a:solidFill>\(grad2)</a:bgFillStyleLst>\
        </a:fmtScheme></a:themeElements><a:objectDefaults/><a:extraClrSchemeLst/></a:theme>
        """
    }

    static func level(_ n: Int, marL: Int, size: Int, color: String, bullet: String?, accent: String) -> String {
        let bu = bullet.map { "<a:buClr><a:srgbClr val=\"\(accent)\"/></a:buClr><a:buFont typeface=\"Arial\"/><a:buChar char=\"\($0)\"/>" } ?? "<a:buNone/>"
        return "<a:lvl\(n)pPr marL=\"\(marL)\" indent=\"\(bullet == nil ? 0 : -285_750)\" algn=\"l\" defTabSz=\"914400\" rtl=\"0\" eaLnBrk=\"1\" latinLnBrk=\"0\" hangingPunct=\"1\">"
            + "<a:spcBef><a:spcPts val=\"1000\"/></a:spcBef>\(bu)<a:defRPr sz=\"\(size)\" kern=\"1200\">\(fill(color))"
            + "<a:latin typeface=\"+mn-lt\"/><a:ea typeface=\"+mn-ea\"/><a:cs typeface=\"+mn-cs\"/></a:defRPr></a:lvl\(n)pPr>"
    }

    static func masterXML(_ p: DeckTheme.Palette) -> String {
        let title = textShape(id: 2, name: "Title Placeholder 1", placeholder: "<p:ph type=\"title\"/>", frame: (margin, titleBox.y, contentWidth, titleBox.cy),
                              anchor: "b", paragraphs: "<a:p><a:r><a:rPr lang=\"en-US\"/><a:t>Click to edit Master title style</a:t></a:r></a:p>")
        let bodyText = ["Click to edit Master text styles", "Second level", "Third level"].enumerated().map {
            "<a:p><a:pPr lvl=\"\($0.offset)\"/><a:r><a:rPr lang=\"en-US\"/><a:t>\($0.element)</a:t></a:r></a:p>"
        }.joined()
        let body = textShape(id: 3, name: "Text Placeholder 2", placeholder: "<p:ph type=\"body\" idx=\"1\"/>", frame: (margin, bodyBox.y, contentWidth, bodyBox.cy),
                             anchor: "t", paragraphs: bodyText)
        let titleStyle = "<p:titleStyle><a:lvl1pPr algn=\"l\" defTabSz=\"914400\" rtl=\"0\" eaLnBrk=\"1\" latinLnBrk=\"0\" hangingPunct=\"1\">"
            + "<a:lnSpc><a:spcPct val=\"90000\"/></a:lnSpc><a:spcBef><a:spcPct val=\"0\"/></a:spcBef><a:buNone/>"
            + "<a:defRPr sz=\"4000\" b=\"1\" kern=\"1200\">\(fill(p.title))<a:latin typeface=\"+mj-lt\"/><a:ea typeface=\"+mj-ea\"/><a:cs typeface=\"+mj-cs\"/></a:defRPr></a:lvl1pPr></p:titleStyle>"
        let bodyStyle = "<p:bodyStyle>" + level(1, marL: 342_900, size: 2800, color: p.text, bullet: "\u{2022}", accent: p.accent)
            + level(2, marL: 742_950, size: 2400, color: p.text, bullet: "\u{2013}", accent: p.accent)
            + level(3, marL: 1_143_000, size: 2000, color: p.text, bullet: "\u{2022}", accent: p.accent) + "</p:bodyStyle>"
        let otherStyle = "<p:otherStyle><a:defPPr><a:defRPr lang=\"en-US\"/></a:defPPr>" + level(1, marL: 0, size: 1800, color: p.text, bullet: nil, accent: p.accent) + "</p:otherStyle>"
        return OfficeXML.header + "<p:sldMaster \(namespaces)><p:cSld>\(background(p.background))<p:spTree>\(groupProperties)\(title)\(body)</p:spTree></p:cSld>"
            + clrMap(dark: p.isDark)
            + "<p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"rId1\"/><p:sldLayoutId id=\"2147483650\" r:id=\"rId2\"/></p:sldLayoutIdLst>"
            + "<p:txStyles>\(titleStyle)\(bodyStyle)\(otherStyle)</p:txStyles></p:sldMaster>"
    }

    static func layoutXML(cover: Bool, palette p: DeckTheme.Palette) -> String {
        let shapes: String
        if cover {
            shapes = textShape(id: 2, name: "Title 1", placeholder: "<p:ph type=\"ctrTitle\"/>", frame: (coverTitle.x, coverTitle.y, coverTitle.cx, coverTitle.cy),
                               anchor: "b", paragraphs: "<a:p><a:pPr algn=\"ctr\"/><a:r><a:rPr lang=\"en-US\" sz=\"5400\"/><a:t>Click to edit Master title style</a:t></a:r></a:p>")
                + textShape(id: 3, name: "Subtitle 2", placeholder: "<p:ph type=\"subTitle\" idx=\"1\"/>",
                            frame: (coverSubtitle.x, coverSubtitle.y, coverSubtitle.cx, coverSubtitle.cy), anchor: "t",
                            paragraphs: "<a:p><a:pPr marL=\"0\" indent=\"0\" algn=\"ctr\"><a:buNone/></a:pPr><a:r><a:rPr lang=\"en-US\" sz=\"2400\">\(fill(p.subtle))</a:rPr><a:t>Click to edit Master subtitle style</a:t></a:r></a:p>")
        } else {
            shapes = textShape(id: 2, name: "Title 1", placeholder: "<p:ph type=\"title\"/>", frame: (margin, titleBox.y, contentWidth, titleBox.cy),
                               anchor: "b", paragraphs: "<a:p><a:r><a:rPr lang=\"en-US\"/><a:t>Click to edit Master title style</a:t></a:r></a:p>")
                + textShape(id: 3, name: "Content Placeholder 2", placeholder: "<p:ph idx=\"1\"/>", frame: (margin, bodyBox.y, contentWidth, bodyBox.cy),
                            anchor: "t", paragraphs: "<a:p><a:pPr lvl=\"0\"/><a:r><a:rPr lang=\"en-US\"/><a:t>Click to edit Master text styles</a:t></a:r></a:p>")
        }
        return OfficeXML.header + "<p:sldLayout \(namespaces) type=\"\(cover ? "title" : "obj")\" preserve=\"1\"><p:cSld name=\"\(cover ? "Title Slide" : "Title and Content")\">"
            + "<p:spTree>\(groupProperties)\(shapes)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>"
    }

    static func notesMasterXML() -> String {
        OfficeXML.header + "<p:notesMaster \(namespaces)><p:cSld><p:bg><p:bgRef idx=\"1001\"><a:schemeClr val=\"bg1\"/></p:bgRef></p:bg><p:spTree>\(groupProperties)"
            + "<p:sp><p:nvSpPr><p:cNvPr id=\"2\" name=\"Slide Image Placeholder 1\"/><p:cNvSpPr><a:spLocks noGrp=\"1\" noRot=\"1\" noChangeAspect=\"1\"/></p:cNvSpPr>"
            + "<p:nvPr><p:ph type=\"sldImg\" idx=\"2\"/></p:nvPr></p:nvSpPr><p:spPr>\(xfrm(685_800, 1_143_000, 5_486_400, 3_086_100))"
            + "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom><a:noFill/><a:ln w=\"12700\"><a:solidFill><a:prstClr val=\"black\"/></a:solidFill></a:ln></p:spPr></p:sp>"
            + "<p:sp><p:nvSpPr><p:cNvPr id=\"3\" name=\"Notes Placeholder 2\"/><p:cNvSpPr><a:spLocks noGrp=\"1\"/></p:cNvSpPr>"
            + "<p:nvPr><p:ph type=\"body\" sz=\"quarter\" idx=\"3\"/></p:nvPr></p:nvSpPr><p:spPr>\(xfrm(685_800, 4_400_550, 5_486_400, 3_600_450))"
            + "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr><p:txBody><a:bodyPr vert=\"horz\" lIns=\"91440\" tIns=\"45720\" rIns=\"91440\" bIns=\"45720\" rtlCol=\"0\"/>"
            + "<a:lstStyle/><a:p><a:pPr lvl=\"0\"/><a:r><a:rPr lang=\"en-US\"/><a:t>Click to edit Master text styles</a:t></a:r></a:p></p:txBody></p:sp>"
            + "</p:spTree></p:cSld>" + clrMap(dark: false)
            + "<p:notesStyle><a:lvl1pPr marL=\"0\" algn=\"l\" defTabSz=\"914400\" rtl=\"0\" eaLnBrk=\"1\" latinLnBrk=\"0\" hangingPunct=\"1\">"
            + "<a:defRPr sz=\"1200\" kern=\"1200\"><a:solidFill><a:schemeClr val=\"tx1\"/></a:solidFill><a:latin typeface=\"+mn-lt\"/><a:ea typeface=\"+mn-ea\"/><a:cs typeface=\"+mn-cs\"/></a:defRPr>"
            + "</a:lvl1pPr></p:notesStyle></p:notesMaster>"
    }

    // MARK: Output

    /// The .pptx bytes. `title` goes into the document properties, and onto the first slide if it has no title.
    public static func write(_ slides: [Slide], title: String, theme: DeckTheme = .light, created: Date = Date()) throws -> Data {
        guard !slides.isEmpty else { throw OfficeError(message: "Nothing to write: the deck has no slides.") }
        let palette = theme.palette
        let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
        let pml = "application/vnd.openxmlformats-officedocument.presentationml."
        let noted = slides.indices.filter { !slides[$0].notes.isEmpty }
        let docTitle = title.isEmpty ? OfficeInline.plain(slides[0].title) : title

        var overrides: [(part: String, type: String)] = [
            ("ppt/presentation.xml", pml + "presentation.main+xml"),
            ("ppt/slideMasters/slideMaster1.xml", pml + "slideMaster+xml"),
            ("ppt/slideLayouts/slideLayout1.xml", pml + "slideLayout+xml"),
            ("ppt/slideLayouts/slideLayout2.xml", pml + "slideLayout+xml"),
            ("ppt/theme/theme1.xml", "application/vnd.openxmlformats-officedocument.theme+xml"),
        ]
        overrides += slides.indices.map { ("ppt/slides/slide\($0 + 1).xml", pml + "slide+xml") }
        if !noted.isEmpty {
            overrides.append(("ppt/notesMasters/notesMaster1.xml", pml + "notesMaster+xml"))
            overrides.append(("ppt/theme/theme2.xml", "application/vnd.openxmlformats-officedocument.theme+xml"))
            overrides += noted.map { ("ppt/notesSlides/notesSlide\($0 + 1).xml", pml + "notesSlide+xml") }
        }
        overrides += [
            ("ppt/presProps.xml", pml + "presProps+xml"),
            ("ppt/viewProps.xml", pml + "viewProps+xml"),
            ("ppt/tableStyles.xml", pml + "tableStyles+xml"),
            ("docProps/core.xml", OfficeXML.coreType),
            ("docProps/app.xml", OfficeXML.appType),
        ]

        // presentation.xml.rels: master, slides, [notes master], props, theme, table styles.
        var presRels: [(type: String, target: String)] = [(rel + "slideMaster", "slideMasters/slideMaster1.xml")]
        presRels += slides.indices.map { (rel + "slide", "slides/slide\($0 + 1).xml") }
        var notesMasterID = ""
        if !noted.isEmpty {
            presRels.append((rel + "notesMaster", "notesMasters/notesMaster1.xml"))
            notesMasterID = "<p:notesMasterIdLst><p:notesMasterId r:id=\"rId\(presRels.count)\"/></p:notesMasterIdLst>"
        }
        presRels += [(rel + "presProps", "presProps.xml"), (rel + "viewProps", "viewProps.xml"),
                     (rel + "theme", "theme/theme1.xml"), (rel + "tableStyles", "tableStyles.xml")]
        let slideIDs = slides.indices.map { "<p:sldId id=\"\(256 + $0)\" r:id=\"rId\($0 + 2)\"/>" }.joined()
        let presentation = OfficeXML.header + "<p:presentation \(namespaces) saveSubsetFonts=\"1\">"
            + "<p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"rId1\"/></p:sldMasterIdLst>\(notesMasterID)"
            + "<p:sldIdLst>\(slideIDs)</p:sldIdLst><p:sldSz cx=\"\(slideWidth)\" cy=\"\(slideHeight)\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/>"
            + "<p:defaultTextStyle><a:defPPr><a:defRPr lang=\"en-US\"/></a:defPPr>"
            + level(1, marL: 0, size: 1800, color: palette.text, bullet: nil, accent: palette.accent) + "</p:defaultTextStyle></p:presentation>"
        let presProps = OfficeXML.header + "<p:presentationPr \(namespaces)/>"
        let viewProps = OfficeXML.header + "<p:viewPr \(namespaces)><p:normalViewPr><p:restoredLeft sz=\"15620\"/><p:restoredTop sz=\"94660\"/></p:normalViewPr>"
            + "<p:gridSpacing cx=\"76200\" cy=\"76200\"/></p:viewPr>"
        let tableStyles = OfficeXML.header + "<a:tblStyleLst xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" def=\"{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}\"/>"
        let app = OfficeXML.appProperties(extra: "<PresentationFormat>Widescreen</PresentationFormat><Slides>\(slides.count)</Slides><Notes>\(noted.count)</Notes>")

        var zip = ZipWriter()
        zip.add("[Content_Types].xml", text: OfficeXML.contentTypes(overrides))
        zip.add("_rels/.rels", text: OfficeXML.packageRels(main: "ppt/presentation.xml"))
        zip.add("docProps/app.xml", text: app)
        zip.add("docProps/core.xml", text: OfficeXML.coreProperties(title: docTitle, created: created))
        zip.add("ppt/presentation.xml", text: presentation)
        zip.add("ppt/_rels/presentation.xml.rels", text: OfficeXML.relationships(presRels))
        zip.add("ppt/presProps.xml", text: presProps)
        zip.add("ppt/viewProps.xml", text: viewProps)
        zip.add("ppt/tableStyles.xml", text: tableStyles)
        zip.add("ppt/theme/theme1.xml", text: themeXML(palette, name: "Synapse \(theme.rawValue.capitalized)"))
        zip.add("ppt/slideMasters/slideMaster1.xml", text: masterXML(palette))
        zip.add("ppt/slideMasters/_rels/slideMaster1.xml.rels", text: OfficeXML.relationships([
            (rel + "slideLayout", "../slideLayouts/slideLayout1.xml"), (rel + "slideLayout", "../slideLayouts/slideLayout2.xml"),
            (rel + "theme", "../theme/theme1.xml"),
        ]))
        for (i, cover) in [true, false].enumerated() {
            zip.add("ppt/slideLayouts/slideLayout\(i + 1).xml", text: layoutXML(cover: cover, palette: palette))
            zip.add("ppt/slideLayouts/_rels/slideLayout\(i + 1).xml.rels", text: OfficeXML.relationships([(rel + "slideMaster", "../slideMasters/slideMaster1.xml")]))
        }
        for (i, slide) in slides.enumerated() {
            let xml = i == 0 ? titleSlide(slide, deckTitle: title, palette: palette) : contentSlide(slide, number: i + 1, palette: palette)
            zip.add("ppt/slides/slide\(i + 1).xml", text: xml)
            var rels: [(type: String, target: String)] = [(rel + "slideLayout", "../slideLayouts/slideLayout\(i == 0 ? 1 : 2).xml")]
            if !slide.notes.isEmpty { rels.append((rel + "notesSlide", "../notesSlides/notesSlide\(i + 1).xml")) }
            zip.add("ppt/slides/_rels/slide\(i + 1).xml.rels", text: OfficeXML.relationships(rels))
        }
        if !noted.isEmpty {
            zip.add("ppt/notesMasters/notesMaster1.xml", text: notesMasterXML())
            zip.add("ppt/notesMasters/_rels/notesMaster1.xml.rels", text: OfficeXML.relationships([(rel + "theme", "../theme/theme2.xml")]))
            zip.add("ppt/theme/theme2.xml", text: themeXML(DeckTheme.light.palette, name: "Synapse Notes"))
            for i in noted {
                zip.add("ppt/notesSlides/notesSlide\(i + 1).xml", text: notesSlide(slides[i].notes))
                zip.add("ppt/notesSlides/_rels/notesSlide\(i + 1).xml.rels", text: OfficeXML.relationships([
                    (rel + "notesMaster", "../notesMasters/notesMaster1.xml"), (rel + "slide", "../slides/slide\(i + 1).xml"),
                ]))
            }
        }
        return try zip.finish()
    }
}
