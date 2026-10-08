import Foundation

/// Markdown in and out — Obsidian-compatible (frontmatter, callouts, `[[links]]`, `$$` math).
public enum MarkdownCodec {

    // MARK: - Export

    /// A page as Markdown with YAML frontmatter.
    public static func export(_ page: Page, in workspace: Workspace? = nil, includeTitle: Bool = false) -> String {
        var out = ""
        let fm = frontmatter(page, workspace: workspace)
        if !fm.isEmpty { out += "---\n" + fm + "---\n\n" }
        if includeTitle { out += "# \(page.displayTitle)\n\n" }
        out += blocksToMarkdown(page.blocks, workspace: workspace)
        if page.kind == .database, let ws = workspace {
            out += (out.hasSuffix("\n\n") || out.isEmpty ? "" : "\n") + databaseTable(page, workspace: ws)
        }
        return out
    }

    static func frontmatter(_ page: Page, workspace: Workspace?) -> String {
        var lines: [String] = []
        lines.append("id: \(page.id.uuidString)")
        if !page.icon.isEmpty { lines.append("icon: \(yaml(page.icon))") }
        if !page.aliases.isEmpty { lines.append("aliases: [\(page.aliases.map(yaml).joined(separator: ", "))]") }
        let tags = page.tags.sorted()
        if !tags.isEmpty { lines.append("tags: [\(tags.map(yaml).joined(separator: ", "))]") }
        lines.append("created: \(DateText.iso(page.createdAt, includeTime: true))")
        lines.append("updated: \(DateText.iso(page.updatedAt, includeTime: true))")
        if let d = page.dailyDate { lines.append("daily: \(d)") }
        if page.kind == .row, let ws = workspace, let dbID = page.parentID, let db = ws[dbID], let schema = db.schema {
            for prop in schema.properties where prop.type != .title {
                let v = PropertyResolver.displayText(PropertyResolver.resolve(page, prop, schema: schema, in: ws), prop, in: ws)
                if !v.isEmpty { lines.append("\(yamlKey(prop.name)): \(yaml(v))") }
            }
        }
        return lines.map { $0 + "\n" }.joined()
    }

    static func yaml(_ s: String) -> String {
        let needsQuotes = s.isEmpty || s.contains(where: { ":#[]{},&*!|>'\"%@`".contains($0) }) || s.hasPrefix(" ") || s.hasSuffix(" ")
        return needsQuotes ? "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" : s
    }

    static func yamlKey(_ s: String) -> String {
        s.contains(where: { ":#[]{}\"'".contains($0) }) ? "\"\(s)\"" : s
    }

    public static func blocksToMarkdown(_ blocks: [Block], workspace: Workspace? = nil) -> String {
        var lines: [String] = []
        var numberCounters: [Int: Int] = [:]
        var previousType: BlockType?
        var calloutDepth: [Int] = []   // indent levels of open toggles/callouts

        for block in blocks {
            // Close callouts/toggles this block isn't inside of.
            while let last = calloutDepth.last, block.indent <= last { calloutDepth.removeLast() }
            let quotePrefix = String(repeating: "> ", count: calloutDepth.count)
            let listIndent = String(repeating: "    ", count: max(0, block.indent - calloutDepth.count))

            if block.type != .numbered { numberCounters[block.indent] = nil }
            for k in numberCounters.keys where k > block.indent { numberCounters[k] = nil }

            // Blank line between block groups (not inside lists).
            if let prev = previousType, !(prev.isListItem && block.type.isListItem), !lines.isEmpty, calloutDepth.isEmpty {
                lines.append("")
            }
            previousType = block.type

            func add(_ s: String) { lines.append(quotePrefix + s) }

            switch block.type {
            case .paragraph:
                add(listIndent + block.text)
            case .heading1: add("# " + block.text)
            case .heading2: add("## " + block.text)
            case .heading3: add("### " + block.text)
            case .bulleted: add(listIndent + "- " + block.text)
            case .numbered:
                let n = (numberCounters[block.indent] ?? 0) + 1
                numberCounters[block.indent] = n
                add(listIndent + "\(n). " + block.text)
            case .todo: add(listIndent + (block.checked ? "- [x] " : "- [ ] ") + block.text)
            case .toggle:
                add("> [!toggle]" + (block.collapsed ? "- " : "+ ") + block.text)
                calloutDepth.append(block.indent)
            case .quote:
                for l in block.text.components(separatedBy: "\n") { add("> " + l) }
            case .callout:
                let kind = calloutKind(for: block.icon)
                add("> [!\(kind)] " + (block.icon.isEmpty ? "" : block.icon + " ") + block.text)
            case .divider: add("---")
            case .code:
                add("```" + block.language)
                for l in block.text.components(separatedBy: "\n") { add(l) }
                add("```")
            case .equation:
                add("$$")
                for l in block.text.components(separatedBy: "\n") { add(l) }
                add("$$")
            case .image:
                let path = block.url.hasPrefix("asset:") ? "assets/" + block.url.dropFirst(6) : block.url
                add("![\(block.caption)](\(path.replacingOccurrences(of: " ", with: "%20")))")
            case .bookmark, .embed, .file:
                add("[\(block.caption.isEmpty ? block.url : block.caption)](\(block.url))")
            case .table:
                lines.append(contentsOf: tableMarkdown(block).map { quotePrefix + $0 })
            case .pageLink, .childPage:
                let title = block.pageID.flatMap { workspace?[$0]?.displayTitle } ?? block.text
                add(listIndent + "[[\(title)]]")
            case .childDatabase:
                let title = block.pageID.flatMap { workspace?[$0]?.displayTitle } ?? "Database"
                add("![[\(title)]]")
            case .tableOfContents:
                add("<!-- table of contents -->")
            case .breadcrumb:
                add("<!-- breadcrumb -->")
            }
        }
        return lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }

    static func calloutKind(for icon: String) -> String {
        switch icon {
        case "⚠️", "❗", "🚧": return "warning"
        case "❌", "🛑", "⛔": return "danger"
        case "✅", "✔️": return "success"
        case "❓": return "question"
        case "📝", "✏️": return "note"
        case "🔥": return "important"
        default: return "info"
        }
    }

    static func tableMarkdown(_ block: Block) -> [String] {
        guard let first = block.table.first, !first.isEmpty else { return [] }
        let cols = block.table.map(\.count).max() ?? first.count
        func row(_ r: [String]) -> String {
            "| " + (0..<cols).map { i in i < r.count ? r[i].replacingOccurrences(of: "|", with: "\\|") : "" }.joined(separator: " | ") + " |"
        }
        var out: [String] = []
        if block.headerRow {
            out.append(row(first))
            out.append("|" + String(repeating: " --- |", count: cols))
            for r in block.table.dropFirst() { out.append(row(r)) }
        } else {
            out.append("|" + String(repeating: "  |", count: cols))
            out.append("|" + String(repeating: " --- |", count: cols))
            for r in block.table { out.append(row(r)) }
        }
        return out
    }

    /// A database's rows as a Markdown table.
    static func databaseTable(_ db: Page, workspace: Workspace) -> String {
        guard let schema = db.schema else { return "" }
        let props = schema.properties
        var lines = ["| " + props.map(\.name).joined(separator: " | ") + " |",
                     "|" + String(repeating: " --- |", count: props.count)]
        for row in workspace.rows(of: db.id) {
            let cells = props.map { p -> String in
                if p.type == .title { return "[[\(row.displayTitle)]]" }
                return PropertyResolver.displayText(PropertyResolver.resolve(row, p, schema: schema, in: workspace), p, in: workspace)
                    .replacingOccurrences(of: "|", with: "\\|")
            }
            lines.append("| " + cells.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Import

    public struct Imported {
        public var title: String
        public var blocks: [Block]
        public var frontmatter: [String: String]
        public var tags: [String]
        public var aliases: [String]
    }

    /// Parse a Markdown document. `fallbackTitle` is used when there is no leading `# Title` (e.g. the file name).
    public static func parse(_ markdown: String, fallbackTitle: String = "") -> Imported {
        var text = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        var fm: [String: String] = [:]
        var tags: [String] = []
        var aliases: [String] = []
        if text.hasPrefix("---\n"), let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex) {
            let body = String(text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound])
            var listKey: String?
            for line in body.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("- "), let key = listKey {
                    let v = unquote(String(trimmed.dropFirst(2)))
                    if key == "tags" { tags.append(v) } else if key == "aliases" { aliases.append(v) }
                    else { fm[key] = (fm[key].map { $0 + ", " } ?? "") + v }
                    continue
                }
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = unquote(String(line[..<colon]).trimmingCharacters(in: .whitespaces))
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                listKey = value.isEmpty ? key.lowercased() : nil
                let list = parseYamlList(value)
                switch key.lowercased() {
                case "tags": tags.append(contentsOf: list)
                case "aliases", "alias": aliases.append(contentsOf: list)
                default: fm[key] = unquote(value)
                }
            }
            var after = end.upperBound
            if let nl = text[after...].firstIndex(of: "\n") { after = text.index(after: nl) } else { after = text.endIndex }
            text = String(text[after...])
        }

        var blocks = parseBlocks(text)
        var title = fallbackTitle
        // A leading "# Title" names the page (it wins over the file name).
        if let first = blocks.first, first.type == .heading1, !first.text.isEmpty {
            title = InlineMarkdown.plainText(first.text)
            blocks.removeFirst()
        }
        if blocks.first?.type == .paragraph && blocks.first?.text.isEmpty == true { blocks.removeFirst() }
        return Imported(title: title, blocks: blocks.isEmpty ? [Block()] : blocks, frontmatter: fm,
                        tags: tags.map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }, aliases: aliases)
    }

    static func unquote(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.count >= 2, (t.hasPrefix("\"") && t.hasSuffix("\"")) || (t.hasPrefix("'") && t.hasSuffix("'")) {
            t = String(t.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
        }
        return t
    }

    static func parseYamlList(_ value: String) -> [String] {
        let v = value.trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("[") && v.hasSuffix("]") {
            return v.dropFirst().dropLast().split(separator: ",").map { unquote(String($0)) }.filter { !$0.isEmpty }
        }
        if v.isEmpty { return [] }
        return v.split(separator: v.contains(",") ? "," : " ").map { unquote(String($0)) }.filter { !$0.isEmpty }
    }

    /// Markdown body → blocks. Also used for AI output.
    public static func parseBlocks(_ markdown: String, baseIndent: Int = 0) -> [Block] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [Block] = []
        var i = 0

        func spaces(_ line: String) -> Int {
            var n = 0
            for ch in line { if ch == " " { n += 1 } else if ch == "\t" { n += 4 } else { break } }
            return n
        }
        // Nesting unit: the smallest indentation used in the document (2 or 4 spaces, or a tab).
        let used = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(spaces).filter { $0 > 0 }
        let unit = max(2, min(4, used.min() ?? 4))

        func leadingIndent(_ line: String) -> (level: Int, rest: String) {
            let n = spaces(line)
            let rest = String(line.drop(while: { $0 == " " || $0 == "\t" }))
            return (n / unit, rest)
        }

        while i < lines.count {
            let raw = lines[i]
            let (lvl, line) = leadingIndent(raw)
            let level = lvl + baseIndent
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty { i += 1; continue }

            // Fenced code
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fence = String(trimmed.prefix(3))
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    body.append(lines[i])
                    i += 1
                }
                i += 1
                blocks.append(Block(type: .code, text: body.joined(separator: "\n"), indent: level, language: lang))
                continue
            }
            // Block math
            if trimmed.hasPrefix("$$") {
                let rest = String(trimmed.dropFirst(2))
                if rest.hasSuffix("$$") && rest.count >= 2 {
                    blocks.append(Block(type: .equation, text: String(rest.dropLast(2)).trimmingCharacters(in: .whitespaces), indent: level))
                    i += 1
                    continue
                }
                var body: [String] = rest.isEmpty ? [] : [rest]
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("$$") {
                    body.append(lines[i])
                    i += 1
                }
                i += 1
                blocks.append(Block(type: .equation, text: body.joined(separator: "\n"), indent: level))
                continue
            }
            // Table
            if trimmed.hasPrefix("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                var rows: [[String]] = [splitTableRow(trimmed)]
                i += 2
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(splitTableRow(lines[i].trimmingCharacters(in: .whitespaces)))
                    i += 1
                }
                let headerEmpty = rows.first?.allSatisfy { $0.isEmpty } ?? false
                if headerEmpty { rows.removeFirst() }
                let width = rows.map(\.count).max() ?? 0
                rows = rows.map { $0 + Array(repeating: "", count: max(0, width - $0.count)) }
                blocks.append(Block(type: .table, indent: level, table: rows, headerRow: !headerEmpty))
                continue
            }
            // Callout / toggle / quote
            if trimmed.hasPrefix(">") {
                var quoted: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    var content = String(t.dropFirst())
                    if content.hasPrefix(" ") { content.removeFirst() }
                    quoted.append(content)
                    i += 1
                }
                let head = quoted.first ?? ""
                if head.hasPrefix("[!"), let close = head.firstIndex(of: "]") {
                    let kind = head[head.index(head.startIndex, offsetBy: 2)..<close].lowercased()
                    var rest = String(head[head.index(after: close)...])
                    var folded: Bool?
                    if rest.hasPrefix("-") { folded = true; rest.removeFirst() } else if rest.hasPrefix("+") { folded = false; rest.removeFirst() }
                    rest = rest.trimmingCharacters(in: .whitespaces)
                    let inner = parseBlocks(quoted.dropFirst().joined(separator: "\n"), baseIndent: level + 1)
                    if kind == "toggle" || folded != nil {
                        blocks.append(Block(type: .toggle, text: rest.isEmpty ? kind.capitalized : rest, indent: level, collapsed: folded ?? false))
                        blocks.append(contentsOf: inner)
                    } else {
                        var icon = calloutIcon(for: kind)
                        if let first = rest.first, isEmoji(first) {
                            icon = String(first)
                            rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
                        }
                        let body = ([rest] + inner.filter { $0.type == .paragraph }.map(\.text)).filter { !$0.isEmpty }
                        blocks.append(Block(type: .callout, text: body.joined(separator: "\n"), indent: level, icon: icon))
                        blocks.append(contentsOf: inner.filter { $0.type != .paragraph })
                    }
                } else {
                    blocks.append(Block(type: .quote, text: quoted.joined(separator: "\n"), indent: level))
                }
                continue
            }
            i += 1
            // Headings
            if let h = headingLevel(trimmed) {
                let type: BlockType = h == 1 ? .heading1 : h == 2 ? .heading2 : .heading3
                blocks.append(Block(type: type, text: String(trimmed.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces), indent: level))
                continue
            }
            // Divider
            if trimmed == "---" || trimmed == "***" || trimmed == "___" || trimmed == "* * *" {
                blocks.append(Block(type: .divider, indent: level))
                continue
            }
            // To-do
            if let todo = matchPrefix(trimmed, ["- [ ] ", "* [ ] ", "- [x] ", "- [X] ", "* [x] ", "+ [ ] ", "- [ ]", "- [x]"]) {
                let checked = todo.prefix.lowercased().contains("x")
                blocks.append(Block(type: .todo, text: todo.rest, indent: level, checked: checked))
                continue
            }
            // Bullets
            if let b = matchPrefix(trimmed, ["- ", "* ", "+ ", "• "]) {
                blocks.append(Block(type: .bulleted, text: b.rest, indent: level))
                continue
            }
            // Numbered
            if let n = numberedItem(trimmed) {
                blocks.append(Block(type: .numbered, text: n, indent: level))
                continue
            }
            // Image on its own line
            if let img = standaloneImage(trimmed) {
                var url = img.url.replacingOccurrences(of: "%20", with: " ")
                if url.hasPrefix("assets/") { url = "asset:" + url.dropFirst(7) }
                blocks.append(Block(type: .image, indent: level, url: url, caption: img.alt))
                continue
            }
            if trimmed.hasPrefix("![["), trimmed.hasSuffix("]]") {
                let inner = String(trimmed.dropFirst(3).dropLast(2))
                let lower = inner.lowercased()
                if [".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic"].contains(where: { lower.hasSuffix($0) }) {
                    blocks.append(Block(type: .image, indent: level, url: "asset:" + (inner as NSString).lastPathComponent))
                } else {
                    blocks.append(Block(type: .paragraph, text: trimmed, indent: level))
                }
                continue
            }
            if trimmed == "<!-- table of contents -->" || trimmed.lowercased() == "[toc]" {
                blocks.append(Block(type: .tableOfContents, indent: level))
                continue
            }
            if trimmed == "<!-- breadcrumb -->" {
                blocks.append(Block(type: .breadcrumb, indent: level))
                continue
            }
            // A bare link on its own line → bookmark
            if let link = standaloneLink(trimmed), link.url.hasPrefix("http") {
                blocks.append(Block(type: .bookmark, indent: level, url: link.url, caption: link.text == link.url ? "" : link.text))
                continue
            }
            blocks.append(Block(type: .paragraph, text: line.trimmingCharacters(in: .whitespaces), indent: level))
        }
        return blocks
    }

    static func isEmoji(_ ch: Character) -> Bool {
        guard let s = ch.unicodeScalars.first else { return false }
        return s.properties.isEmoji && (s.value >= 0x2190 || ch.unicodeScalars.count > 1)
    }

    static func calloutIcon(for kind: String) -> String {
        switch kind {
        case "warning", "caution", "attention": return "⚠️"
        case "danger", "error", "bug", "failure", "fail", "missing": return "❌"
        case "success", "check", "done": return "✅"
        case "question", "help", "faq": return "❓"
        case "note": return "📝"
        case "tip", "hint", "important": return "🔥"
        case "quote", "cite": return "💬"
        case "example": return "📋"
        case "abstract", "summary", "tldr": return "📄"
        case "todo": return "☑️"
        default: return "💡"
        }
    }

    static func headingLevel(_ s: String) -> Int? {
        var n = 0
        for ch in s { if ch == "#" { n += 1 } else { break } }
        guard n >= 1, n <= 6, s.count > n, s[s.index(s.startIndex, offsetBy: n)] == " " else { return nil }
        return min(n, 3)
    }

    static func matchPrefix(_ s: String, _ prefixes: [String]) -> (prefix: String, rest: String)? {
        for p in prefixes where s.hasPrefix(p) {
            return (p, String(s.dropFirst(p.count)).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    static func numberedItem(_ s: String) -> String? {
        var digits = 0
        for ch in s { if ch.isASCII && ch.isNumber { digits += 1 } else { break } }
        guard digits > 0, digits < 5 else { return nil }
        let rest = s.dropFirst(digits)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return String(rest.dropFirst(2))
    }

    static func standaloneImage(_ s: String) -> (alt: String, url: String)? {
        guard s.hasPrefix("!["), s.hasSuffix(")"), let mid = s.range(of: "](") else { return nil }
        let alt = String(s[s.index(s.startIndex, offsetBy: 2)..<mid.lowerBound])
        let url = String(s[mid.upperBound..<s.index(before: s.endIndex)])
        guard !url.contains(" ") || url.contains("%20") || !url.contains("](") else { return nil }
        return (alt, url)
    }

    static func standaloneLink(_ s: String) -> (text: String, url: String)? {
        if (s.hasPrefix("http://") || s.hasPrefix("https://")) && !s.contains(" ") { return (s, s) }
        if s.hasPrefix("<http") && s.hasSuffix(">") { let u = String(s.dropFirst().dropLast()); return (u, u) }
        guard s.hasPrefix("["), s.hasSuffix(")"), let mid = s.range(of: "](") else { return nil }
        let text = String(s[s.index(after: s.startIndex)..<mid.lowerBound])
        let url = String(s[mid.upperBound..<s.index(before: s.endIndex)])
        guard !text.contains("]("), !url.contains(" ") else { return nil }
        return (text, url)
    }

    static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("|") || t.hasPrefix(":") || t.hasPrefix("-") else { return false }
        return t.contains("-") && t.allSatisfy { "|:- ".contains($0) }
    }

    static func splitTableRow(_ line: String) -> [String] {
        var t = line
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        var cells: [String] = []
        var cur = ""
        var escape = false
        for ch in t {
            if escape { cur.append(ch); escape = false; continue }
            if ch == "\\" { escape = true; continue }
            if ch == "|" { cells.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""; continue }
            cur.append(ch)
        }
        cells.append(cur.trimmingCharacters(in: .whitespaces))
        return cells
    }

    /// A file-name-safe version of a title (for vault export).
    public static func fileName(for title: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|#^[]").union(.newlines).union(.controlCharacters)
        let cleaned = title.unicodeScalars.map { bad.contains($0) ? "-" : String($0) }.joined()
        let t = cleaned.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "Untitled" : String(t.prefix(120))
    }
}
