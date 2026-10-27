import Foundation

/// Writes Excel workbooks (.xlsx) from rows of text. Numbers, percentages and currency become numbers with a
/// matching format, `=…` cells become formulas (with cached values for the common functions, so viewers that don't
/// recalculate still show results), everything else is text. The first row is a bold, frozen header.
public enum XLSXWriter {
    /// One worksheet.
    public struct Sheet: Equatable, Sendable {
        public var name: String
        public var rows: [[String]]

        public init(name: String, rows: [[String]]) {
            self.name = name
            self.rows = rows
        }
    }

    // MARK: Input

    /// Split multi-sheet text into sheets. A `### Sheet: Budget` line (or a plain `## Budget` heading) starts a sheet;
    /// each sheet's body is CSV/TSV or a Markdown table. Text before the first heading is an unnamed sheet.
    public static func sheets(fromText text: String) -> [Sheet] {
        var out: [Sheet] = []
        var name = ""
        var body: [String] = []
        func flush() {
            let rows = parseBody(body)
            if !rows.isEmpty { out.append(Sheet(name: name, rows: rows)) }
            body = []
        }
        for line in OfficeText.normalize(text).components(separatedBy: "\n") {
            if let heading = sheetHeading(line) {
                flush()
                name = heading
            } else {
                body.append(line)
            }
        }
        flush()
        // A line or two of prose before the first named sheet ("Here's the workbook:") isn't a sheet.
        if out.count > 1, out[0].name.isEmpty, out[0].rows.count <= 2, out[0].rows.allSatisfy({ $0.count == 1 }) {
            out.removeFirst()
        }
        return out
    }

    /// The sheet name if `line` starts a new sheet.
    static func sheetHeading(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        var heading: String
        if t.hasPrefix("#") {
            let hashes = t.prefix { $0 == "#" }
            guard hashes.count <= 6 else { return nil }
            let rest = t.dropFirst(hashes.count)
            guard let first = rest.first, first == " " || first == "\t" else { return nil }
            heading = String(rest).trimmingCharacters(in: .whitespaces)
            while heading.hasSuffix("#") { heading.removeLast() }
            heading = heading.trimmingCharacters(in: .whitespaces)
        } else if t.range(of: "^\\**sheet\\s*:", options: [.regularExpression, .caseInsensitive]) != nil {
            heading = t
        } else {
            return nil
        }
        heading = OfficeInline.plain(heading).trimmingCharacters(in: .whitespaces)
        if let r = heading.range(of: "^sheet(\\s*\\d+)?\\s*[:\\-–—]\\s*", options: [.regularExpression, .caseInsensitive]) {
            let named = heading[r.upperBound...].trimmingCharacters(in: .whitespaces)
            return named.isEmpty ? nil : named
        }
        // A plain heading, unless it looks like a CSV row (`# of units,Cost`).
        guard !heading.isEmpty, !heading.contains(where: { ",;\t|".contains($0) }) else { return nil }
        return heading
    }

    static func parseBody(_ lines: [String]) -> [[String]] {
        let kept = lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
        return CSV.parse(kept.joined(separator: "\n"))
    }

    /// Sheet names made legal for Excel: at most 31 characters, none of `[]:*?/\`, no leading or trailing
    /// apostrophe, not "History", unique ignoring case. Empty names become "Sheet1", "Sheet2"…
    public static func sanitizedSheetNames(_ names: [String]) -> [String] {
        var used = Set<String>()
        var out: [String] = []
        for (i, raw) in names.enumerated() {
            var name = ""
            for ch in OfficeXML.clean(raw) {
                switch ch {
                case "/", "\\", ":": name.append("-")
                case "[", "]", "*", "?": continue
                default: name.append(ch.isNewline ? " " : ch)
                }
            }
            name = name.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: "' "))
            if name.lowercased() == "history" { name += " (1)" }
            if name.isEmpty { name = "Sheet\(i + 1)" }
            name = truncate(name, utf16: 31)
            var candidate = name
            var n = 2
            while used.contains(candidate.lowercased()) {
                let suffix = " (\(n))"
                candidate = truncate(name, utf16: 31 - suffix.utf16.count) + suffix
                n += 1
            }
            used.insert(candidate.lowercased())
            out.append(candidate)
        }
        return out
    }

    static func truncate(_ s: String, utf16 limit: Int) -> String {
        guard s.utf16.count > limit else { return s }
        var out = ""
        for ch in s {
            if out.utf16.count + String(ch).utf16.count > limit { break }
            out.append(ch)
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Cells

    /// What a cell holds.
    enum Kind: Equatable {
        case empty
        case text(String)
        case number(Double)
        case formula(String)
    }

    struct Cell: Equatable {
        var kind: Kind
        /// Excel number format code ("General" unless the input showed one).
        var format = "General"
        var bold = false
        /// How the input looked, for column widths.
        var display = ""
    }

    /// Classify one input cell.
    static func cell(_ raw: String) -> Cell {
        var s = raw.trimmingCharacters(in: .whitespaces)
        var bold = false
        for wrap in ["**", "__"] where s.count > 2 * wrap.count && s.hasPrefix(wrap) && s.hasSuffix(wrap) {
            bold = true
            s = String(s.dropFirst(wrap.count).dropLast(wrap.count)).trimmingCharacters(in: .whitespaces)
        }
        if s.count > 2, s.hasPrefix("`"), s.hasSuffix("`") { s = String(s.dropFirst().dropLast()) }
        guard !s.isEmpty else { return Cell(kind: .empty, bold: bold) }
        if s.hasPrefix("'"), s.count > 1 {
            // Excel's "keep as text" apostrophe, before something that would otherwise become a number or formula.
            let rest = String(s.dropFirst())
            if rest.hasPrefix("=") || (rest.contains(where: \.isNumber) && !rest.contains(where: { $0.isLetter || $0.isWhitespace })) {
                return Cell(kind: .text(rest), bold: bold, display: rest)
            }
        }
        if s.hasPrefix("="), s.count > 1 {
            return Cell(kind: .formula(normalizeFormula(String(s.dropFirst()))), bold: bold, display: s)
        }
        if let n = parseNumber(s) {
            return Cell(kind: .number(n.value), format: n.format, bold: bold, display: s)
        }
        return Cell(kind: .text(s), bold: bold, display: s)
    }

    static let currencySymbols: Set<Character> = ["$", "£", "€", "¥", "₹", "₩", "₦", "₽", "₺", "₱"]

    /// A number as written by a person: `-1,234.5`, `12%`, `$12.50`, `£3`, `4 €`, `(1,200)`, `1.5e3`.
    /// Leading zeros (`007`, zip codes) and more than 15 significant digits (IDs, card numbers) stay text.
    static func parseNumber(_ input: String) -> (value: Double, format: String)? {
        var s = Substring(input.trimmingCharacters(in: .whitespaces))
        var negative = false
        var parens = false
        if s.hasPrefix("("), s.hasSuffix(")"), s.count > 2 {
            parens = true
            negative = true
            s = s.dropFirst().dropLast()
        }
        func takeSign() -> Bool {
            if s.first == "-" || s.first == "\u{2212}" { negative.toggle(); s.removeFirst(); return true }
            if s.first == "+" { s.removeFirst(); return true }
            return false
        }
        let signed = takeSign()
        var currency: Character?
        var suffix = false
        if let c = s.first, currencySymbols.contains(c) {
            currency = c
            s.removeFirst()
            s = s.drop { $0 == " " }
            if !signed && !parens { _ = takeSign() }
        }
        var percent = false
        if s.hasSuffix("%") {
            percent = true
            s.removeLast()
            while s.last == " " { s.removeLast() }
        } else if currency == nil, let c = s.last, currencySymbols.contains(c) {
            currency = c
            suffix = true
            s.removeLast()
            while s.last == " " { s.removeLast() }
        }
        if currency != nil && percent { return nil }

        let core = String(s)
        guard let m = core.range(of: "^([0-9]{1,3}(,[0-9]{3})+|[0-9]+)?(\\.[0-9]+)?([eE][+-]?[0-9]+)?$", options: .regularExpression),
              m.lowerBound == core.startIndex, m.upperBound == core.endIndex, core.contains(where: \.isNumber) else { return nil }
        var intPart = core, frac = "", exponent = ""
        if let e = intPart.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            exponent = String(intPart[e...])
            intPart = String(intPart[..<e])
        }
        if let dot = intPart.firstIndex(of: ".") {
            frac = String(intPart[intPart.index(after: dot)...])
            intPart = String(intPart[..<dot])
        }
        guard !intPart.isEmpty || !frac.isEmpty else { return nil }
        let thousands = intPart.contains(",")
        let digits = intPart.replacingOccurrences(of: ",", with: "")
        if digits.count > 1, digits.hasPrefix("0") { return nil }
        let significant = (digits + frac).drop { $0 == "0" }
        if significant.count > 15 { return nil }
        if !exponent.isEmpty && (thousands || currency != nil || percent) { return nil }

        let plain = (negative ? "-" : "") + (digits.isEmpty ? "0" : digits) + (frac.isEmpty ? "" : "." + frac) + exponent
        guard var value = Double(plain), value.isFinite else { return nil }
        if percent {
            // Shift the decimal point exactly (12.3% is 0.123, not 0.12299999…).
            if let d = Decimal(string: plain, locale: Locale(identifier: "en_US_POSIX")) {
                value = Double("\(d / 100)") ?? value / 100
            } else {
                value /= 100
            }
        }

        let places = min(frac.count, 10)
        let decimals = places > 0 ? "." + String(repeating: "0", count: places) : ""
        var format: String
        if percent {
            format = "0" + decimals + "%"
        } else if let c = currency {
            let base = "#,##0" + decimals
            format = suffix ? base + (input.contains(" \(c)") ? "\" \(c)\"" : "\"\(c)\"") : "\"\(c)\"" + base
        } else if thousands || parens {
            format = "#,##0" + decimals
        } else {
            format = "General"
        }
        if parens, !percent { format = format + ";(" + format + ")" }
        return (value, format)
    }

    /// Formula text as Excel stores it: `;` argument separators become `,`, and functions newer than Excel 2007
    /// get their `_xlfn.` prefix (without it Excel shows #NAME?).
    static func normalizeFormula(_ f: String) -> String {
        var out = ""
        var inString = false, braces = 0
        var word = ""
        func flushWord(_ next: Character?) {
            if next == "(", let prefix = futureFunctions[word.uppercased()], !out.hasSuffix("_xlfn."), !out.hasSuffix("_xlws.") {
                out += prefix
            }
            out += word
            word = ""
        }
        for ch in f {
            if inString {
                out.append(ch)
                if ch == "\"" { inString = false }
                continue
            }
            if ch.isLetter || ch.isNumber || ch == "." || ch == "_" {
                word.append(ch)
                continue
            }
            flushWord(ch)
            switch ch {
            case "\"": inString = true; out.append(ch)
            case "{": braces += 1; out.append(ch)
            case "}": braces = max(0, braces - 1); out.append(ch)
            case ";": out.append(braces > 0 ? ";" : ",")
            default: out.append(ch)
            }
        }
        flushWord(nil)
        return out.trimmingCharacters(in: .whitespaces)
    }

    static let futureFunctions: [String: String] = {
        var map: [String: String] = [:]
        for name in ["CONCAT", "TEXTJOIN", "IFS", "SWITCH", "MAXIFS", "MINIFS", "XLOOKUP", "XMATCH", "UNIQUE", "SEQUENCE",
                     "RANDARRAY", "LET", "LAMBDA", "IFNA", "DAYS", "ISOWEEKNUM", "STDEV.S", "STDEV.P", "VAR.S", "VAR.P",
                     "MODE.SNGL", "PERCENTILE.INC", "PERCENTILE.EXC", "QUARTILE.INC", "QUARTILE.EXC", "RANK.EQ",
                     "RANK.AVG", "NORM.DIST", "NORM.INV", "NORM.S.DIST", "CEILING.MATH", "FLOOR.MATH", "FORECAST.LINEAR",
                     "TEXTBEFORE", "TEXTAFTER", "TEXTSPLIT", "VSTACK", "HSTACK", "TAKE", "DROP", "CHOOSECOLS", "CHOOSEROWS"] {
            map[name] = "_xlfn."
        }
        for name in ["FILTER", "SORT", "SORTBY"] { map[name] = "_xlfn._xlws." }
        return map
    }()

    // MARK: Output

    /// The .xlsx bytes. `title` goes into the document properties.
    public static func write(_ sheets: [Sheet], title: String, created: Date = Date()) throws -> Data {
        let sheets = sheets.filter { !$0.rows.isEmpty }
        guard !sheets.isEmpty else { throw OfficeError(message: "Nothing to write: the spreadsheet has no rows.") }
        let names = sanitizedSheetNames(sheets.map(\.name))
        let maxRows = 1_048_576, maxColumns = 16_384

        var grids: [[[Cell]]] = sheets.map { sheet in
            sheet.rows.prefix(maxRows).map { row in row.prefix(maxColumns).map { cell($0) } }
        }
        for g in grids.indices where !grids[g].isEmpty {
            for c in grids[g][0].indices { grids[g][0][c].bold = true }
        }
        var lookup: [String: Int] = [:]
        for (i, s) in sheets.enumerated() {
            lookup[s.name.lowercased()] = i
            lookup[names[i].lowercased()] = i
        }
        var engine = FormulaEngine(grids: grids, sheetIndex: lookup)
        engine.prepare()
        grids = engine.grids

        var styles = StyleTable()
        var zip = ZipWriter()
        var overrides: [(part: String, type: String)] = [
            ("xl/workbook.xml", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"),
            ("xl/styles.xml", "application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"),
        ]
        var sheetXML: [String] = []
        for g in grids.indices {
            sheetXML.append(worksheet(grids[g], sheet: g, selected: g == 0, engine: &engine, styles: &styles))
            overrides.append(("xl/worksheets/sheet\(g + 1).xml", "application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"))
        }
        overrides += [("docProps/core.xml", OfficeXML.coreType), ("docProps/app.xml", OfficeXML.appType)]

        let sheetList = names.enumerated().map { i, n in
            "<sheet name=\"\(OfficeXML.escape(n))\" sheetId=\"\(i + 1)\" r:id=\"rId\(i + 1)\"/>"
        }.joined()
        let workbook = OfficeXML.header + """
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
        <workbookPr/><bookViews><workbookView xWindow="0" yWindow="0" windowWidth="28800" windowHeight="17000" activeTab="0"/></bookViews>\
        <sheets>\(sheetList)</sheets><calcPr calcId="191029" fullCalcOnLoad="1"/></workbook>
        """
        var rels: [(type: String, target: String)] = names.indices.map {
            ("http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet", "worksheets/sheet\($0 + 1).xml")
        }
        rels.append(("http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles", "styles.xml"))
        let titles = names.map { "<vt:lpstr>\(OfficeXML.escape($0))</vt:lpstr>" }.joined()
        let app = OfficeXML.appProperties(extra: "<HeadingPairs><vt:vector size=\"2\" baseType=\"variant\"><vt:variant><vt:lpstr>Worksheets</vt:lpstr></vt:variant>"
            + "<vt:variant><vt:i4>\(names.count)</vt:i4></vt:variant></vt:vector></HeadingPairs>"
            + "<TitlesOfParts><vt:vector size=\"\(names.count)\" baseType=\"lpstr\">\(titles)</vt:vector></TitlesOfParts>")

        zip.add("[Content_Types].xml", text: OfficeXML.contentTypes(overrides))
        zip.add("_rels/.rels", text: OfficeXML.packageRels(main: "xl/workbook.xml"))
        zip.add("docProps/app.xml", text: app)
        zip.add("docProps/core.xml", text: OfficeXML.coreProperties(title: title, created: created))
        zip.add("xl/workbook.xml", text: workbook)
        zip.add("xl/_rels/workbook.xml.rels", text: OfficeXML.relationships(rels))
        zip.add("xl/styles.xml", text: styles.xml())
        for (i, xml) in sheetXML.enumerated() { zip.add("xl/worksheets/sheet\(i + 1).xml", text: xml) }
        return try zip.finish()
    }

    static func worksheet(_ grid: [[Cell]], sheet: Int, selected: Bool, engine: inout FormulaEngine, styles: inout StyleTable) -> String {
        let columns = grid.map(\.count).max() ?? 0
        var widths = [Int](repeating: 0, count: columns)
        var rowsXML = ""
        for (r, row) in grid.enumerated() {
            var cells = ""
            for (c, cell) in row.enumerated() {
                let ref = cellName(row: r, column: c)
                var display = cell.display
                var key = StyleTable.Key(format: cell.format, bold: cell.bold, header: r == 0, wrap: false)
                switch cell.kind {
                case .empty:
                    if cell.bold || r == 0, c < columns { cells += "<c r=\"\(ref)\" s=\"\(styles.index(key))\"/>" }
                    continue
                case .text(let s):
                    let text = excelText(s)
                    key.wrap = text.contains("\n")
                    display = text.components(separatedBy: "\n").max { OfficeText.width($0) < OfficeText.width($1) } ?? text
                    cells += "<c r=\"\(ref)\" s=\"\(styles.index(key))\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(OfficeXML.escape(text))</t></is></c>"
                case .number(let v):
                    cells += "<c r=\"\(ref)\" s=\"\(styles.index(key))\"><v>\(numberText(v))</v></c>"
                case .formula(let f):
                    key.format = engine.format(sheet: sheet, row: r, column: c)
                    let style = styles.index(key)
                    let formula = "<f>\(OfficeXML.escape(f))</f>"
                    switch engine.cached(sheet: sheet, row: r, column: c) {
                    case .number(let v)?:
                        cells += "<c r=\"\(ref)\" s=\"\(style)\">\(formula)<v>\(numberText(v))</v></c>"
                        display = shown(v, format: key.format)
                    case .text(let s)?:
                        cells += "<c r=\"\(ref)\" s=\"\(style)\" t=\"str\">\(formula)<v>\(OfficeXML.escape(excelText(s)))</v></c>"
                        display = s
                    case .bool(let b)?:
                        cells += "<c r=\"\(ref)\" s=\"\(style)\" t=\"b\">\(formula)<v>\(b ? 1 : 0)</v></c>"
                        display = b ? "TRUE" : "FALSE"
                    case .error(let e)?:
                        cells += "<c r=\"\(ref)\" s=\"\(style)\" t=\"e\">\(formula)<v>\(OfficeXML.escape(e))</v></c>"
                        display = e
                    case .empty?:
                        cells += "<c r=\"\(ref)\" s=\"\(style)\">\(formula)<v>0</v></c>"
                    case nil:
                        cells += "<c r=\"\(ref)\" s=\"\(style)\">\(formula)</c>"
                        display = "0000000000"
                    }
                }
                widths[c] = max(widths[c], OfficeText.width(display) + (r == 0 ? 2 : 0))
            }
            rowsXML += "<row r=\"\(r + 1)\">\(cells)</row>"
        }
        let last = columns > 0 ? cellName(row: max(grid.count - 1, 0), column: columns - 1) : "A1"
        let pane = grid.count > 1
            ? "<pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/><selection pane=\"bottomLeft\" activeCell=\"A2\" sqref=\"A2\"/>"
            : ""
        let cols = widths.isEmpty ? "" : "<cols>" + widths.enumerated().map { i, w in
            let width = Double(min(60, max(8, w + 2))) + 0.7
            return "<col min=\"\(i + 1)\" max=\"\(i + 1)\" width=\"\(width)\" customWidth=\"1\"/>"
        }.joined() + "</cols>"
        return OfficeXML.header + """
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
        <dimension ref="A1:\(last)"/><sheetViews><sheetView workbookViewId="0"\(selected ? " tabSelected=\"1\"" : "")>\(pane)</sheetView></sheetViews>\
        <sheetFormatPr defaultRowHeight="15"/>\(cols)<sheetData>\(rowsXML)</sheetData>\
        <pageMargins left="0.7" right="0.7" top="0.75" bottom="0.75" header="0.3" footer="0.3"/></worksheet>
        """
    }

    /// Text as an Excel cell holds it: at most 32,767 characters, and a literal `_x0041_` kept literal.
    static func excelText(_ s: String) -> String {
        var t = s
        if t.count > 32_767 { t = String(t.prefix(32_767)) }
        if t.contains("_x") {
            t = t.replacingOccurrences(of: "_(x[0-9A-Fa-f]{4}_)", with: "_x005F_$1", options: .regularExpression)
        }
        return t
    }

    /// `A1`-style name of a zero-based cell.
    static func cellName(row: Int, column: Int) -> String {
        columnName(column) + String(row + 1)
    }

    static func columnName(_ index: Int) -> String {
        var n = index + 1
        var s = ""
        while n > 0 {
            let r = (n - 1) % 26
            s = String(UnicodeScalar(UInt8(65 + r))) + s
            n = (n - 1) / 26
        }
        return s
    }

    /// Roughly how a number looks in `format`, for column widths.
    static func shown(_ v: Double, format: String) -> String {
        let section = format.components(separatedBy: ";")[0]
        let decimals = section.split(separator: ".").dropFirst().first.map { $0.prefix { $0 == "0" }.count } ?? 0
        if section.hasSuffix("%") { return String(format: "%.\(decimals)f%%", v * 100) }
        if format == "General" { return String(format: "%.10g", v) }
        let plain = String(format: "%.\(decimals)f", abs(v))
        let integer = plain.prefix { $0 != "." }
        let groups = section.contains(",") ? (integer.count - 1) / 3 : 0
        let symbols = section.filter { !"#0.,\"_)( ".contains($0) }.count
        return String(repeating: "0", count: plain.count + groups + symbols + (v < 0 ? 1 : 0))
    }

    /// A number as `<v>` text: integers without ".0", otherwise the shortest round-trip form.
    static func numberText(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        return "\(v)"
    }
}

// MARK: - Styles

/// The cell formats a workbook uses, as `styles.xml`.
struct StyleTable {
    struct Key: Hashable {
        var format: String
        var bold: Bool
        var header: Bool
        var wrap: Bool
    }

    private(set) var keys: [Key] = [Key(format: "General", bold: false, header: false, wrap: false)]
    private var indexes: [Key: Int] = [Key(format: "General", bold: false, header: false, wrap: false): 0]
    private var customFormats: [String] = []

    static let builtIn: [String: Int] = ["General": 0, "0": 1, "0.00": 2, "#,##0": 3, "#,##0.00": 4, "0%": 9, "0.00%": 10]

    mutating func index(_ key: Key) -> Int {
        if let i = indexes[key] { return i }
        if Self.builtIn[key.format] == nil, !customFormats.contains(key.format) { customFormats.append(key.format) }
        keys.append(key)
        indexes[key] = keys.count - 1
        return keys.count - 1
    }

    func formatID(_ code: String) -> Int {
        Self.builtIn[code] ?? 164 + (customFormats.firstIndex(of: code) ?? 0)
    }

    func xml() -> String {
        let numFmts = customFormats.isEmpty ? "" : "<numFmts count=\"\(customFormats.count)\">" + customFormats.enumerated().map {
            "<numFmt numFmtId=\"\(164 + $0.offset)\" formatCode=\"\(OfficeXML.escape($0.element))\"/>"
        }.joined() + "</numFmts>"
        let xfs = keys.map { k -> String in
            let fmt = formatID(k.format)
            var attrs = "numFmtId=\"\(fmt)\" fontId=\"\(k.bold || k.header ? 1 : 0)\" fillId=\"\(k.header ? 2 : 0)\" borderId=\"\(k.header ? 1 : 0)\" xfId=\"0\""
            if fmt != 0 { attrs += " applyNumberFormat=\"1\"" }
            if k.bold || k.header { attrs += " applyFont=\"1\"" }
            if k.header { attrs += " applyFill=\"1\" applyBorder=\"1\"" }
            if k.wrap { return "<xf \(attrs) applyAlignment=\"1\"><alignment vertical=\"top\" wrapText=\"1\"/></xf>" }
            return "<xf \(attrs)/>"
        }.joined()
        return OfficeXML.header + """
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\(numFmts)\
        <fonts count="2"><font><sz val="11"/><color rgb="FF000000"/><name val="Calibri"/><family val="2"/></font>\
        <font><b/><sz val="11"/><color rgb="FF000000"/><name val="Calibri"/><family val="2"/></font></fonts>\
        <fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill>\
        <fill><patternFill patternType="solid"><fgColor rgb="FFE8EEF7"/><bgColor indexed="64"/></patternFill></fill></fills>\
        <borders count="2"><border><left/><right/><top/><bottom/><diagonal/></border>\
        <border><left/><right/><top/><bottom style="thin"><color rgb="FF8EA3C2"/></bottom><diagonal/></border></borders>\
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
        <cellXfs count="\(keys.count)">\(xfs)</cellXfs>\
        <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>\
        <dxfs count="0"/><tableStyles count="0" defaultTableStyle="TableStyleMedium2" defaultPivotStyle="PivotStyleLight16"/></styleSheet>
        """
    }
}

// MARK: - Formulas

/// Evaluates the everyday subset of Excel formulas (arithmetic, comparisons, `&`, cell and range references across
/// sheets, SUM/AVERAGE/MIN/MAX/COUNT/ROUND/IF and friends) to give each formula cell a cached value. Anything it
/// doesn't know is left uncached; the workbook asks Excel/LibreOffice/Numbers to recalculate on open anyway.
/// A formula that can't be parsed at all (unbalanced parentheses, unterminated string) becomes text, because Excel
/// would otherwise refuse the file.
struct FormulaEngine {
    enum Value: Equatable {
        case number(Double), text(String), bool(Bool), error(String), empty
    }

    indirect enum Node {
        case number(Double), text(String), bool(Bool)
        case ref(sheet: Int?, row: Int, column: Int)
        case range(sheet: Int?, row1: Int, column1: Int, row2: Int, column2: Int)
        case unary(Character, Node)
        case percent(Node)
        case binary(String, Node, Node)
        case call(String, [Node])
        case missing
        case unsupported
    }

    struct SyntaxError: Error {}
    struct Unsupported: Error {}
    struct ExcelError: Error { var code: String }

    struct Key: Hashable {
        var sheet: Int, row: Int, column: Int
    }

    var grids: [[[XLSXWriter.Cell]]]
    let sheetIndex: [String: Int]
    private var nodes: [Key: Node] = [:]
    private var values: [Key: Value?] = [:]
    private var formats: [Key: String] = [:]
    private var visiting: Set<Key> = []

    init(grids: [[[XLSXWriter.Cell]]], sheetIndex: [String: Int]) {
        self.grids = grids
        self.sheetIndex = sheetIndex
    }

    /// Parse every formula; unparseable ones become text.
    mutating func prepare() {
        for s in grids.indices {
            for r in grids[s].indices {
                for c in grids[s][r].indices {
                    guard case .formula(let f) = grids[s][r][c].kind else { continue }
                    var p = Parser(chars: Array(f), sheetIndex: sheetIndex)
                    if let node = try? p.parse() {
                        nodes[Key(sheet: s, row: r, column: c)] = node
                    } else {
                        grids[s][r][c].kind = .text("=" + f)
                    }
                }
            }
        }
    }

    /// The cached value of a formula cell, or nil when it can't be computed here.
    mutating func cached(sheet: Int, row: Int, column: Int) -> Value? {
        let key = Key(sheet: sheet, row: row, column: column)
        if let v = values[key] { return v }
        guard let node = nodes[key], !visiting.contains(key) else { return nil }
        visiting.insert(key)
        defer { visiting.remove(key) }
        var result: Value?
        do {
            let v = try eval(node, sheet: sheet)
            if case .number(let d) = v, !d.isFinite { result = .error("#NUM!") } else { result = v }
        } catch let e as ExcelError {
            result = .error(e.code)
        } catch {
            result = nil
        }
        values[key] = result
        return result
    }

    /// Number format for a formula cell: the format of the first cell it refers to, as Excel does when you type one
    /// (not for counts, text results, comparisons or ratios).
    mutating func format(sheet: Int, row: Int, column: Int) -> String {
        let key = Key(sheet: sheet, row: row, column: column)
        if let f = formats[key] { return f }
        formats[key] = "General" // guards against cycles
        guard let node = nodes[key], !Self.isPlainNumber(node) else { return "General" }
        var result = "General"
        if let target = firstReference(node, sheet: sheet), target.sheet < grids.count, target.row < grids[target.sheet].count,
           target.column < grids[target.sheet][target.row].count {
            let cell = grids[target.sheet][target.row][target.column]
            switch cell.kind {
            case .number: result = cell.format
            case .formula: result = format(sheet: target.sheet, row: target.row, column: target.column)
            default: break
            }
        }
        formats[key] = result
        return result
    }

    /// A result that shouldn't take its inputs' format: a ratio, a count, text or a comparison.
    static func isPlainNumber(_ node: Node) -> Bool {
        switch node {
        case .binary(let op, _, _): return !["+", "-", "*", "^"].contains(op)
        case .unary(_, let n): return isPlainNumber(n)
        case .call(let name, let args):
            if ["COUNT", "COUNTA", "COUNTIF", "LEN", "ROWS", "COLUMNS"].contains(name) { return true }
            if ["ROUND", "ROUNDUP", "ROUNDDOWN", "ABS", "INT", "IFERROR"].contains(name), let first = args.first { return isPlainNumber(first) }
            return false
        default: return false
        }
    }

    private func firstReference(_ node: Node, sheet: Int) -> Key? {
        switch node {
        case .ref(let s, let r, let c): return Key(sheet: s ?? sheet, row: r, column: c)
        case .range(let s, let r, let c, _, _): return Key(sheet: s ?? sheet, row: r, column: c)
        case .unary(_, let n), .percent(let n): return firstReference(n, sheet: sheet)
        case .binary(_, let a, let b): return firstReference(a, sheet: sheet) ?? firstReference(b, sheet: sheet)
        case .call(let name, let args):
            if name == "IF" || name == "IFERROR" { return args.dropFirst(name == "IF" ? 1 : 0).lazy.compactMap { firstReference($0, sheet: sheet) }.first }
            return args.lazy.compactMap { firstReference($0, sheet: sheet) }.first
        default: return nil
        }
    }

    // MARK: Evaluation

    private mutating func cellValue(_ key: Key) throws -> Value {
        guard key.sheet < grids.count, key.row < grids[key.sheet].count, key.column < grids[key.sheet][key.row].count else { return .empty }
        switch grids[key.sheet][key.row][key.column].kind {
        case .empty: return .empty
        case .text(let s): return .text(s)
        case .number(let d): return .number(d)
        case .formula:
            guard let v = cached(sheet: key.sheet, row: key.row, column: key.column) else { throw Unsupported() }
            return v
        }
    }

    private mutating func rangeValues(_ node: Node, sheet: Int) throws -> [Value] {
        guard case .range(let s, let r1, let c1, let r2, let c2) = node else { return [] }
        let target = s ?? sheet
        guard target < grids.count else { throw ExcelError(code: "#REF!") }
        let lastRow = min(max(r1, r2), grids[target].count - 1)
        var out: [Value] = []
        if lastRow < min(r1, r2) { return out }
        for r in min(r1, r2)...lastRow {
            let lastColumn = min(max(c1, c2), grids[target][r].count - 1)
            if lastColumn < min(c1, c2) { continue }
            for c in min(c1, c2)...lastColumn { out.append(try cellValue(Key(sheet: target, row: r, column: c))) }
        }
        return out
    }

    private mutating func eval(_ node: Node, sheet: Int) throws -> Value {
        switch node {
        case .number(let d): return .number(d)
        case .text(let s): return .text(s)
        case .bool(let b): return .bool(b)
        case .missing: return .empty
        case .unsupported: throw Unsupported()
        case .ref(let s, let r, let c):
            let v = try cellValue(Key(sheet: s ?? sheet, row: r, column: c))
            if case .error(let e) = v { throw ExcelError(code: e) }
            return v
        case .range: throw Unsupported() // implicit intersection
        case .unary(let op, let n):
            let v = try Self.number(eval(n, sheet: sheet))
            return .number(op == "-" ? -v : v)
        case .percent(let n):
            return .number(try Self.number(eval(n, sheet: sheet)) / 100)
        case .binary(let op, let a, let b):
            let x = try eval(a, sheet: sheet), y = try eval(b, sheet: sheet)
            switch op {
            case "&": return .text(try Self.text(x) + Self.text(y))
            case "+": return .number(try Self.number(x) + Self.number(y))
            case "-": return .number(try Self.number(x) - Self.number(y))
            case "*": return .number(try Self.number(x) * Self.number(y))
            case "/":
                let d = try Self.number(y)
                guard d != 0 else { throw ExcelError(code: "#DIV/0!") }
                return .number(try Self.number(x) / d)
            case "^": return .number(pow(try Self.number(x), try Self.number(y)))
            default: return .bool(Self.compare(x, y, op))
            }
        case .call(let name, let args):
            return try call(name, args, sheet: sheet)
        }
    }

    /// Argument values for aggregate functions: ranges give their numbers only, direct arguments are converted.
    private mutating func numbers(_ args: [Node], sheet: Int) throws -> [Double] {
        var out: [Double] = []
        for a in args {
            if case .range = a {
                for v in try rangeValues(a, sheet: sheet) {
                    if case .number(let d) = v { out.append(d) }
                    if case .error(let e) = v { throw ExcelError(code: e) }
                }
            } else if case .ref = a {
                let v = try eval(a, sheet: sheet)
                if case .number(let d) = v { out.append(d) }
            } else {
                out.append(try Self.number(eval(a, sheet: sheet)))
            }
        }
        return out
    }

    private mutating func call(_ name: String, _ args: [Node], sheet: Int) throws -> Value {
        func arg(_ i: Int) throws -> Value {
            guard i < args.count else { throw ExcelError(code: "#N/A") }
            return try eval(args[i], sheet: sheet)
        }
        func num(_ i: Int) throws -> Double { try Self.number(arg(i)) }
        func round(_ mode: FloatingPointRoundingRule) throws -> Value {
            let x = try num(0), digits = args.count > 1 ? try num(1) : 0
            let f = pow(10, digits.rounded(.towardZero))
            // Excel rounds the decimal it shows: 2.675 → 2.68, not the binary 2.67499999…
            let scaled = Double(String(format: "%.15g", x * f)) ?? x * f
            return .number(scaled.rounded(mode) / f)
        }
        switch name {
        case "SUM": return .number(try numbers(args, sheet: sheet).reduce(0, +))
        case "PRODUCT": return .number(try numbers(args, sheet: sheet).reduce(1, *))
        case "AVERAGE":
            let n = try numbers(args, sheet: sheet)
            guard !n.isEmpty else { throw ExcelError(code: "#DIV/0!") }
            return .number(n.reduce(0, +) / Double(n.count))
        case "MIN": return .number(try numbers(args, sheet: sheet).min() ?? 0)
        case "MAX": return .number(try numbers(args, sheet: sheet).max() ?? 0)
        case "MEDIAN":
            let n = try numbers(args, sheet: sheet).sorted()
            guard !n.isEmpty else { throw ExcelError(code: "#NUM!") }
            return .number(n.count % 2 == 1 ? n[n.count / 2] : (n[n.count / 2 - 1] + n[n.count / 2]) / 2)
        case "COUNT", "COUNTA":
            var count = 0
            for a in args {
                var vals: [Value]
                if case .range = a {
                    vals = try rangeValues(a, sheet: sheet)
                } else {
                    vals = [(try? eval(a, sheet: sheet)) ?? .error("#VALUE!")]
                }
                for v in vals {
                    switch v {
                    case .number: count += 1
                    case .empty: break
                    default: if name == "COUNTA" { count += 1 }
                    }
                }
            }
            return .number(Double(count))
        case "ROUND": return try round(.toNearestOrAwayFromZero)
        case "ROUNDUP": return try round(.awayFromZero)
        case "ROUNDDOWN": return try round(.towardZero)
        case "ABS": return .number(abs(try num(0)))
        case "INT": return .number(try num(0).rounded(.down))
        case "SQRT":
            let x = try num(0)
            guard x >= 0 else { throw ExcelError(code: "#NUM!") }
            return .number(x.squareRoot())
        case "POWER": return .number(pow(try num(0), try num(1)))
        case "MOD":
            let a = try num(0), b = try num(1)
            guard b != 0 else { throw ExcelError(code: "#DIV/0!") }
            return .number(a - b * (a / b).rounded(.down))
        case "IF":
            let condition = try Self.truth(arg(0))
            if condition { return args.count > 1 ? try orZero(arg(1)) : .bool(true) }
            return args.count > 2 ? try orZero(arg(2)) : .bool(false)
        case "IFERROR":
            do { return try arg(0) } catch is ExcelError { return try arg(1) }
        case "AND", "OR":
            let t = try args.indices.map { try Self.truth(arg($0)) }
            return .bool(name == "AND" ? !t.contains(false) : t.contains(true))
        case "NOT": return .bool(!(try Self.truth(arg(0))))
        case "CONCAT", "CONCATENATE":
            return .text(try args.indices.map { try Self.text(arg($0)) }.joined())
        case "LEN": return .number(Double(try Self.text(arg(0)).count))
        case "UPPER": return .text(try Self.text(arg(0)).uppercased())
        case "LOWER": return .text(try Self.text(arg(0)).lowercased())
        case "TRIM":
            return .text(try Self.text(arg(0)).split(separator: " ").joined(separator: " "))
        default:
            throw Unsupported()
        }
    }

    /// A function result that is a blank cell shows as 0.
    private func orZero(_ v: Value) -> Value {
        v == .empty ? .number(0) : v
    }

    static func number(_ v: Value) throws -> Double {
        switch v {
        case .number(let d): return d
        case .empty: return 0
        case .bool(let b): return b ? 1 : 0
        case .text(let s):
            if let d = Double(s.trimmingCharacters(in: .whitespaces)) { return d }
            if let n = XLSXWriter.parseNumber(s) { return n.value }
            throw ExcelError(code: "#VALUE!")
        case .error(let e): throw ExcelError(code: e)
        }
    }

    static func text(_ v: Value) throws -> String {
        switch v {
        case .number(let d): return XLSXWriter.numberText(d)
        case .text(let s): return s
        case .bool(let b): return b ? "TRUE" : "FALSE"
        case .empty: return ""
        case .error(let e): throw ExcelError(code: e)
        }
    }

    static func truth(_ v: Value) throws -> Bool {
        switch v {
        case .bool(let b): return b
        case .number(let d): return d != 0
        case .empty: return false
        case .text(let s):
            if s.uppercased() == "TRUE" { return true }
            if s.uppercased() == "FALSE" { return false }
            throw ExcelError(code: "#VALUE!")
        case .error(let e): throw ExcelError(code: e)
        }
    }

    /// Excel ordering: numbers < text < booleans; text compares without case; a blank takes the other side's type.
    static func compare(_ a: Value, _ b: Value, _ op: String) -> Bool {
        func rank(_ v: Value) -> Int {
            switch v {
            case .number: return 0
            case .text: return 1
            case .bool: return 2
            default: return -1
            }
        }
        var x = a, y = b
        if x == .empty { x = y == .empty ? .number(0) : (rank(y) == 1 ? .text("") : rank(y) == 2 ? .bool(false) : .number(0)) }
        if y == .empty { y = rank(x) == 1 ? .text("") : rank(x) == 2 ? .bool(false) : .number(0) }
        var order: Int
        switch (x, y) {
        case (.number(let p), .number(let q)): order = p < q ? -1 : (p > q ? 1 : 0)
        case (.text(let p), .text(let q)):
            let l = p.lowercased(), r = q.lowercased()
            order = l < r ? -1 : (l > r ? 1 : 0)
        case (.bool(let p), .bool(let q)): order = p == q ? 0 : (p ? 1 : -1)
        default: order = rank(x) < rank(y) ? -1 : (rank(x) > rank(y) ? 1 : 0)
        }
        switch op {
        case "=": return order == 0
        case "<>": return order != 0
        case "<": return order < 0
        case ">": return order > 0
        case "<=": return order <= 0
        default: return order >= 0
        }
    }

    // MARK: Parsing

    struct Parser {
        let chars: [Character]
        let sheetIndex: [String: Int]
        var i = 0

        init(chars: [Character], sheetIndex: [String: Int]) {
            self.chars = chars
            self.sheetIndex = sheetIndex
        }

        mutating func parse() throws -> Node {
            let n = try comparison()
            skip()
            guard i == chars.count else { throw SyntaxError() }
            return n
        }

        private mutating func skip() {
            while i < chars.count, chars[i] == " " || chars[i] == "\n" || chars[i] == "\t" { i += 1 }
        }

        private mutating func take(_ s: String) -> Bool {
            skip()
            let t = Array(s)
            guard i + t.count <= chars.count, Array(chars[i..<(i + t.count)]) == t else { return false }
            i += t.count
            return true
        }

        private mutating func comparison() throws -> Node {
            var n = try concat()
            while true {
                var matched: String?
                for op in ["<>", "<=", ">=", "=", "<", ">"] where take(op) {
                    matched = op
                    break
                }
                guard let op = matched else { return n }
                n = .binary(op, n, try concat())
            }
        }

        private mutating func concat() throws -> Node {
            var n = try additive()
            while take("&") { n = .binary("&", n, try additive()) }
            return n
        }

        private mutating func additive() throws -> Node {
            var n = try term()
            while true {
                if take("+") { n = .binary("+", n, try term()) } else if take("-") { n = .binary("-", n, try term()) } else { return n }
            }
        }

        private mutating func term() throws -> Node {
            var n = try power()
            while true {
                if take("*") { n = .binary("*", n, try power()) } else if take("/") { n = .binary("/", n, try power()) } else { return n }
            }
        }

        private mutating func power() throws -> Node {
            var n = try unary()
            while take("^") { n = .binary("^", n, try unary()) }
            return n
        }

        private mutating func unary() throws -> Node {
            if take("-") { return .unary("-", try unary()) }
            if take("+") { return .unary("+", try unary()) }
            var n = try primary()
            while take("%") { n = .percent(n) }
            return n
        }

        private mutating func primary() throws -> Node {
            skip()
            guard i < chars.count else { throw SyntaxError() }
            let ch = chars[i]
            if ch == "(" {
                i += 1
                let n = try comparison()
                guard take(")") else { throw SyntaxError() }
                return n
            }
            if ch == "\"" {
                i += 1
                var s = ""
                while true {
                    guard i < chars.count else { throw SyntaxError() }
                    if chars[i] == "\"" {
                        if i + 1 < chars.count, chars[i + 1] == "\"" { s.append("\""); i += 2; continue }
                        i += 1
                        return .text(s)
                    }
                    s.append(chars[i]); i += 1
                }
            }
            if ch.isNumber || ch == "." {
                let start = i
                while i < chars.count, chars[i].isNumber || chars[i] == "." { i += 1 }
                if i < chars.count, chars[i] == "e" || chars[i] == "E" {
                    var j = i + 1
                    if j < chars.count, chars[j] == "+" || chars[j] == "-" { j += 1 }
                    if j < chars.count, chars[j].isNumber {
                        i = j
                        while i < chars.count, chars[i].isNumber { i += 1 }
                    }
                }
                let text = String(chars[start..<i])
                if i < chars.count, chars[i] == ":" { // a row range like 2:2
                    i += 1
                    while i < chars.count, chars[i].isNumber || chars[i] == "$" { i += 1 }
                    return .unsupported
                }
                guard let d = Double(text) else { throw SyntaxError() }
                return .number(d)
            }
            if ch == "'" {
                i += 1
                var name = ""
                while true {
                    guard i < chars.count else { throw SyntaxError() }
                    if chars[i] == "'" {
                        if i + 1 < chars.count, chars[i + 1] == "'" { name.append("'"); i += 2; continue }
                        i += 1
                        break
                    }
                    name.append(chars[i]); i += 1
                }
                guard i < chars.count, chars[i] == "!" else { throw SyntaxError() }
                i += 1
                return try reference(sheet: name)
            }
            if ch == "#" { // an error literal such as #N/A
                i += 1
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || "/!?".contains(chars[i]) { i += 1 }
                return .unsupported
            }
            if ch == "{" || ch == "[" { // array constant, structured reference
                guard let end = chars[i...].firstIndex(of: ch == "{" ? "}" : "]") else { throw SyntaxError() }
                i = end + 1
                return .unsupported
            }
            if ch.isLetter || ch == "_" || ch == "$" || ch == "\\" {
                let word = identifier()
                if i < chars.count, chars[i] == "!" {
                    i += 1
                    return try reference(sheet: word)
                }
                skip()
                if i < chars.count, chars[i] == "(" {
                    i += 1
                    return .call(Self.functionName(word), try arguments())
                }
                if let n = try referenceNode(word, sheet: nil) { return n }
                switch word.uppercased() {
                case "TRUE": return .bool(true)
                case "FALSE": return .bool(false)
                default:
                    if i < chars.count, chars[i] == "[" { // structured reference: Table1[Column]
                        var depth = 0
                        while i < chars.count {
                            if chars[i] == "[" { depth += 1 } else if chars[i] == "]" { depth -= 1; if depth == 0 { i += 1; break } }
                            i += 1
                        }
                    }
                    return .unsupported // a defined name
                }
            }
            throw SyntaxError()
        }

        private mutating func identifier() -> String {
            let start = i
            while i < chars.count, chars[i].isLetter || chars[i].isNumber || "_.$\\".contains(chars[i]) { i += 1 }
            return String(chars[start..<i])
        }

        private mutating func arguments() throws -> [Node] {
            var args: [Node] = []
            if take(")") { return args }
            while true {
                skip()
                if i < chars.count, chars[i] == "," || chars[i] == ")" {
                    args.append(.missing)
                } else {
                    args.append(try comparison())
                }
                if take(",") { continue }
                guard take(")") else { throw SyntaxError() }
                return args
            }
        }

        private mutating func reference(sheet: String) throws -> Node {
            let word = identifier()
            guard let n = try referenceNode(word, sheet: sheet) else { throw SyntaxError() }
            return n
        }

        /// A cell (`B2`, `$B$2`), a range (`B2:C9`) or a column range (`B:B`), with `sheet` if one was named.
        private mutating func referenceNode(_ word: String, sheet: String?) throws -> Node? {
            // An unknown sheet still has its reference consumed, then can't be evaluated.
            var sheetNumber: Int?
            var known = true
            if let sheet {
                sheetNumber = sheetIndex[sheet.lowercased()]
                known = sheetNumber != nil
            }
            var node: Node?
            if let (r, c) = Self.cell(word) {
                node = .ref(sheet: sheetNumber, row: r, column: c)
                if i < chars.count, chars[i] == ":" {
                    i += 1
                    let second = identifier()
                    guard let (r2, c2) = Self.cell(second) else { throw SyntaxError() }
                    node = .range(sheet: sheetNumber, row1: r, column1: c, row2: r2, column2: c2)
                }
            } else if let c = Self.column(word), i < chars.count, chars[i] == ":" {
                i += 1
                let second = identifier()
                guard let c2 = Self.column(second) else { throw SyntaxError() }
                node = .range(sheet: sheetNumber, row1: 0, column1: c, row2: 1_048_575, column2: c2)
            }
            guard let node else { return sheet == nil ? nil : .unsupported }
            return known ? node : .unsupported
        }

        static func functionName(_ word: String) -> String {
            var name = word.uppercased()
            for prefix in ["_XLFN.", "_XLWS."] where name.hasPrefix(prefix) { name.removeFirst(prefix.count) }
            return name
        }

        /// Zero-based row and column of `A1` / `$A$1`.
        static func cell(_ word: String) -> (Int, Int)? {
            let w = word.replacingOccurrences(of: "$", with: "").uppercased()
            let letters = w.prefix { $0.isASCII && $0.isLetter }
            let digits = w.dropFirst(letters.count)
            guard (1...3).contains(letters.count), !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let row = Int(digits), row >= 1, row <= 1_048_576, let col = column(String(letters)) else { return nil }
            return (row - 1, col)
        }

        /// Zero-based column of `B` / `$B`.
        static func column(_ word: String) -> Int? {
            let w = word.replacingOccurrences(of: "$", with: "").uppercased()
            guard (1...3).contains(w.count), w.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
            var n = 0
            for u in w.unicodeScalars { n = n * 26 + Int(u.value - 64) }
            return n <= 16_384 ? n - 1 : nil
        }
    }
}
