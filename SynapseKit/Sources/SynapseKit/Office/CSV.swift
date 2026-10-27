import Foundation

/// Table text to rows: RFC 4180 CSV/TSV (delimiter detected) or a Markdown pipe table.
public enum CSV {
    /// Column alignment from a Markdown table's separator row.
    public enum Alignment: Sendable {
        case none, left, center, right
    }

    /// Rows of cells. Detects a Markdown pipe table (a `|---|` separator row) or else the delimiter (comma, semicolon,
    /// tab or pipe). Quoted fields may hold delimiters, `""` and line breaks. Empty cells are kept; blank rows at the
    /// start and end are dropped.
    public static func parse(_ text: String) -> [[String]] {
        let text = OfficeText.normalize(text)
        if let table = markdownTable(text) { return table.rows }
        return parse(text, delimiter: detectDelimiter(text))
    }

    /// Rows of delimited text with a known delimiter.
    public static func parse(_ text: String, delimiter: Character) -> [[String]] {
        let d = delimiter.unicodeScalars.first ?? ","
        var rows: [[String]] = []
        var row: [String] = []
        var field = String.UnicodeScalarView()
        var quoted = false      // inside quotes
        var wasQuoted = false   // this field was quoted (so trailing spaces after the quote are dropped)
        let scalars = Array(OfficeText.normalize(text).unicodeScalars)
        var i = 0

        func endField() {
            var s = String(field)
            if !wasQuoted { s = s.trimmingCharacters(in: .whitespaces) }
            row.append(s)
            field = String.UnicodeScalarView()
            wasQuoted = false
        }
        func endRow() {
            endField()
            rows.append(row)
            row = []
        }

        while i < scalars.count {
            let u = scalars[i]
            if quoted {
                if u == "\"" {
                    if i + 1 < scalars.count, scalars[i + 1] == "\"" {
                        field.append("\""); i += 2; continue
                    }
                    quoted = false
                } else {
                    field.append(u)
                }
                i += 1
                continue
            }
            if u == "\"", String(field).trimmingCharacters(in: .whitespaces).isEmpty, !wasQuoted {
                // Opening quote (spaces before it, as in `a, "b, c"`, are allowed).
                field = String.UnicodeScalarView()
                quoted = true
                wasQuoted = true
            } else if u == d {
                endField()
            } else if u == "\n" {
                endRow()
            } else if wasQuoted, u == " " || u == "\t", d != u {
                // Spaces after a closing quote.
            } else {
                field.append(u)
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty || wasQuoted { endRow() }
        return trimBlankRows(rows)
    }

    /// The most consistent delimiter among comma, semicolon, tab and pipe over the first lines (comma if none).
    public static func detectDelimiter(_ text: String) -> Character {
        let lines = OfficeText.normalize(text).components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.prefix(20)
        guard !lines.isEmpty else { return "," }
        var best: (delimiter: Character, consistent: Int, columns: Int) = (",", 0, 0)
        for d in [",", "\t", ";", "|"] as [Character] {
            let counts = lines.map { countOutsideQuotes($0, d) }
            // The most common non-zero count, and how many lines have it.
            var tally: [Int: Int] = [:]
            for n in counts where n > 0 { tally[n, default: 0] += 1 }
            guard let mode = tally.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key < $1.key }) else { continue }
            if mode.value > best.consistent || (mode.value == best.consistent && mode.key > best.columns) {
                best = (d, mode.value, mode.key)
            }
        }
        return best.delimiter
    }

    // MARK: Markdown tables

    /// A Markdown pipe table anywhere in `text` (header row, `|---|` separator, body rows); text around it is ignored.
    public static func markdownTable(_ text: String) -> (rows: [[String]], alignments: [Alignment])? {
        let lines = OfficeText.normalize(text).components(separatedBy: "\n")
        guard lines.count >= 2 else { return nil }
        for i in 1..<lines.count where isTableSeparator(lines[i]) && lines[i - 1].contains("|") {
            var rows = [tableCells(lines[i - 1])]
            var j = i + 1
            while j < lines.count, lines[j].contains("|"), !lines[j].trimmingCharacters(in: .whitespaces).isEmpty {
                rows.append(tableCells(lines[j]))
                j += 1
            }
            let withBreaks = rows.map { $0.map { $0.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive]) } }
            return (withBreaks, alignments(lines[i]))
        }
        return nil
    }

    /// A Markdown table separator row such as `|---|:--:|` or `--- | ---`.
    public static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("|"), t.contains("-") else { return false }
        return tableCells(t).allSatisfy { c in
            let core = c.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return !core.isEmpty && core.allSatisfy { $0 == "-" }
        }
    }

    /// The cells of a Markdown table row: outer pipes optional, `\|` is a literal pipe, cells trimmed.
    public static func tableCells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|"), !t.hasSuffix("\\|") { t.removeLast() }
        var cells: [String] = []
        var cell = ""
        var escaped = false
        var inCode = false
        for ch in t {
            if escaped {
                if ch != "|" { cell.append("\\") }
                cell.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "`" {
                inCode.toggle(); cell.append(ch)
            } else if ch == "|", !inCode {
                cells.append(cell.trimmingCharacters(in: .whitespaces)); cell = ""
            } else {
                cell.append(ch)
            }
        }
        if escaped { cell.append("\\") }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        return cells
    }

    static func alignments(_ separator: String) -> [Alignment] {
        tableCells(separator).map { c in
            switch (c.hasPrefix(":"), c.hasSuffix(":")) {
            case (true, true): return .center
            case (false, true): return .right
            case (true, false): return .left
            default: return .none
            }
        }
    }

    // MARK: Helpers

    static func countOutsideQuotes(_ line: String, _ d: Character) -> Int {
        var n = 0
        var quoted = false
        for ch in line {
            if ch == "\"" { quoted.toggle() } else if ch == d, !quoted { n += 1 }
        }
        return n
    }

    static func trimBlankRows(_ rows: [[String]]) -> [[String]] {
        func blank(_ r: [String]) -> Bool { r.allSatisfy { $0.isEmpty } }
        var rows = rows
        while let last = rows.last, blank(last) { rows.removeLast() }
        while let first = rows.first, blank(first) { rows.removeFirst() }
        return rows
    }
}
