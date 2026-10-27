import Foundation

/// A tool failed in a way the model can fix (shown to it as the result).
public struct AgentToolError: LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// What the agent's workspace tools do, as plain operations on a `Workspace` (the app applies them through its store,
/// which saves, snapshots and re-indexes). Every operation returns a short report for the model.
public enum WorkspaceOps {
    // MARK: - Finding pages

    /// A live page by exact title, alias or id; with `fuzzy`, otherwise the best title match.
    public static func find(_ title: String, in ws: Workspace, fuzzy: Bool = false) -> Page? {
        let t = cleanTitle(title)
        guard !t.isEmpty else { return nil }
        if let p = ws.resolve(t), !p.isTrashed { return p }
        guard fuzzy else { return nil }
        let key = Workspace.normalize(t)
        let live = ws.livePages.filter { !$0.isTemplate }
        return live.first { Workspace.normalize($0.title).hasPrefix(key) }
            ?? Search.quickSwitch(t, in: ws, limit: 1).first
    }

    /// Like `find`, but explains what exists when nothing matches.
    public static func require(_ title: String, in ws: Workspace, fuzzy: Bool = true) throws -> Page {
        if let p = find(title, in: ws, fuzzy: fuzzy) { return p }
        let close = Search.quickSwitch(cleanTitle(title), in: ws, limit: 5).map { "\"\($0.displayTitle)\"" }
        throw AgentToolError("No page is called \"\(cleanTitle(title))\"." + (close.isEmpty ? " Use list_pages to see the titles." : " Close matches: \(close.joined(separator: ", "))."))
    }

    /// Titles as models write them: without [[ ]], quotes or a leading #.
    public static func cleanTitle(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("[["), t.hasSuffix("]]") { t = String(t.dropFirst(2).dropLast(2)) }
        if let bar = t.firstIndex(of: "|"), t.contains("]]") == false { t = String(t[..<bar]) }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’`"))
        if t.hasPrefix("# ") { t = String(t.dropFirst(2)) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "Title, [[Other, with comma]]; Third" → titles (separators inside [[ ]] don't split).
    public static func titles(in list: String) -> [String] {
        var out: [String] = [], cur = "", depth = 0
        var chars = Array(list)[...]
        while let ch = chars.popFirst() {
            if ch == "[" && chars.first == "[" { depth += 1; cur += "[["; chars = chars.dropFirst(); continue }
            if ch == "]" && chars.first == "]" { depth = max(0, depth - 1); cur += "]]"; chars = chars.dropFirst(); continue }
            if depth == 0 && (ch == "," || ch == ";" || ch.isNewline) { out.append(cur); cur = ""; continue }
            cur.append(ch)
        }
        out.append(cur)
        return out.map { cleanTitle($0.trimmingCharacters(in: CharacterSet(charactersIn: "-•*").union(.whitespaces))) }.filter { !$0.isEmpty }
    }

    private static func kindText(_ p: Page, in ws: Workspace) -> String {
        if p.dailyDate != nil { return "daily note" }
        switch p.kind {
        case .page: return "page"
        case .database: return "database, \(ws.rows(of: p.id).count) rows"
        case .row: return "row of \(p.parentID.flatMap { ws[$0]?.displayTitle } ?? "a database")"
        }
    }

    // MARK: - Reading

    public static func listPages(_ ws: Workspace, filter: String = "", limit: Int = 150) -> String {
        let words = filter.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        let pages = ws.livePages.filter { p in
            guard !p.isTemplate else { return false }
            if words.isEmpty { return p.kind != .row }
            let t = p.displayTitle.lowercased()
            return words.allSatisfy { t.contains($0) }
        }.sorted { a, b in
            let pa = ws.ancestors(of: a.id).map(\.displayTitle) + [a.displayTitle]
            let pb = ws.ancestors(of: b.id).map(\.displayTitle) + [b.displayTitle]
            return pa.joined(separator: "/").localizedCaseInsensitiveCompare(pb.joined(separator: "/")) == .orderedAscending
        }
        guard !pages.isEmpty else { return words.isEmpty ? "The workspace is empty." : "No page titles contain \"\(filter)\"." }
        var lines = pages.prefix(limit).map { p -> String in
            var line = "- \(p.icon.isEmpty ? "" : p.icon + " ")\(p.displayTitle) (\(kindText(p, in: ws)))"
            if let parent = p.parentID.flatMap({ ws[$0] }), p.kind != .row { line += " — in \(parent.displayTitle)" }
            let tags = p.tags.sorted()
            if !tags.isEmpty { line += " — " + tags.map { "#" + $0 }.joined(separator: " ") }
            return line
        }
        if pages.count > limit { lines.append("…and \(pages.count - limit) more (filter by words to narrow it down).") }
        let rows = words.isEmpty ? ws.livePages.filter { $0.kind == .row }.count : 0
        return "\(pages.count) \(words.isEmpty ? "pages and databases" : "matches")\(rows > 0 ? " (plus \(rows) database rows)" : ""):\n" + lines.joined(separator: "\n")
    }

    public static func search(_ query: String, in ws: Workspace, limit: Int = 6, budget: Int = 6_000) -> String {
        let hits = AIPrompts.retrieve(query, in: ws, limit: limit, budget: budget)
        guard !hits.isEmpty else { return "Nothing in the workspace matches \"\(query)\"." }
        let per = max(200, budget / max(1, hits.count))
        return hits.map { "## \($0.title)\n\(Agent.truncate($0.text, limit: per))" }.joined(separator: "\n\n")
    }

    public static func readPage(_ title: String, in ws: Workspace, index: LinkIndex? = nil, rowLimit: Int = 100) throws -> String {
        let p = try require(title, in: ws)
        var head = "# \(p.icon.isEmpty ? "" : p.icon + " ")\(p.displayTitle)\n"
        var facts: [String] = [kindText(p, in: ws)]
        if let parent = p.parentID.flatMap({ ws[$0] }), p.kind != .row { facts.append("in \(parent.displayTitle)") }
        let kids = ws.children(of: p.id).filter { !$0.isTemplate }
        if !kids.isEmpty && p.kind != .database { facts.append("sub-pages: " + kids.map(\.displayTitle).joined(separator: ", ")) }
        if let index {
            let out = (index.outgoing[p.id] ?? []).compactMap { ws[$0]?.displayTitle }.sorted()
            let back = Set((index.backlinks[p.id] ?? []).map(\.sourceID)).compactMap { ws[$0]?.displayTitle }.sorted()
            if !out.isEmpty { facts.append("links to: " + out.joined(separator: ", ")) }
            if !back.isEmpty { facts.append("linked from: " + back.joined(separator: ", ")) }
        }
        head += "(" + facts.joined(separator: " · ") + ")\n\n"

        switch p.kind {
        case .database:
            guard let schema = p.schema else { return head }
            let props = schema.properties
            var s = head + "Columns:\n" + props.map { "- \($0.name): \(columnType($0))" }.joined(separator: "\n")
            let rows = ws.rows(of: p.id).sorted { $0.order < $1.order }
            if rows.isEmpty { return s + "\n\nNo rows yet." }
            s += "\n\n| " + props.map(\.name).joined(separator: " | ") + " |\n|" + props.map { _ in "---" }.joined(separator: "|") + "|\n"
            for r in rows.prefix(rowLimit) {
                s += "| " + props.map { cell(r, $0, schema, ws) }.joined(separator: " | ") + " |\n"
            }
            if rows.count > rowLimit { s += "…and \(rows.count - rowLimit) more rows.\n" }
            return s
        case .row:
            var s = head
            if let db = p.parentID.flatMap({ ws[$0] }), let schema = db.schema {
                s += schema.properties.filter { $0.type != .title }.map { "\($0.name): \(cell(p, $0, schema, ws))" }.joined(separator: "\n") + "\n\n"
            }
            return s + MarkdownCodec.blocksToMarkdown(p.blocks, workspace: ws)
        case .page:
            let body = MarkdownCodec.blocksToMarkdown(p.blocks, workspace: ws).trimmingCharacters(in: .whitespacesAndNewlines)
            return head + (body.isEmpty ? "(empty page)" : body)
        }
    }

    private static func cell(_ row: Page, _ prop: PropertyDefinition, _ schema: DatabaseSchema, _ ws: Workspace) -> String {
        if prop.type == .title { return row.displayTitle }
        return PropertyResolver.displayText(PropertyResolver.resolve(row, prop, schema: schema, in: ws), prop, in: ws)
            .replacingOccurrences(of: "|", with: "/").replacingOccurrences(of: "\n", with: " ")
    }

    private static func columnType(_ p: PropertyDefinition) -> String {
        switch p.type {
        case .select, .multiSelect, .status:
            let name = p.type == .multiSelect ? "multi_select" : p.type.rawValue
            return p.options.isEmpty ? name : "\(name)(\(p.options.map(\.name).joined(separator: ", ")))"
        default:
            return p.type.rawValue
        }
    }

    // MARK: - Pages

    /// Markdown → blocks, dropping a leading `# Title` that repeats the page title.
    static func blocks(_ markdown: String, title: String) -> [Block] {
        var md = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = md.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first,
           first.hasPrefix("# "), Workspace.normalize(String(first.dropFirst(2))) == Workspace.normalize(title) {
            md = String(md.dropFirst(first.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return md.isEmpty ? [] : MarkdownCodec.parseBlocks(md)
    }

    @discardableResult
    public static func createPage(_ ws: inout Workspace, title rawTitle: String, markdown: String, parent: String? = nil,
                                  icon: String? = nil) throws -> (id: UUID, report: String) {
        let title = cleanTitle(rawTitle)
        guard !title.isEmpty else { throw AgentToolError("create_page needs a title=\"…\".") }
        if let existing = find(title, in: ws), existing.kind != .row {
            // A page the agent created empty earlier (e.g. as a link target) is filled in instead of duplicated.
            if existing.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, existing.kind == .page {
                ws.pages[existing.id]?.blocks = blocks(markdown, title: title).nonEmpty
                if let icon, !icon.isEmpty { ws.pages[existing.id]?.icon = icon }
                ws.touch(existing.id)
                return (existing.id, "Filled in the existing empty page \"\(existing.displayTitle)\".")
            }
            throw AgentToolError("A page called \"\(existing.displayTitle)\" already exists. Use edit_page to change it, or pick another title.")
        }
        var note = ""
        var parentID: UUID?
        if let parent = parent.map(cleanTitle), !parent.isEmpty, parent.lowercased() != "top" {
            if let p = find(parent, in: ws) {
                guard p.kind == .page else { throw AgentToolError("\"\(p.displayTitle)\" is a \(p.kind == .database ? "database — use add_rows" : "database row"); pages go under pages.") }
                parentID = p.id
            } else {
                parentID = ws.createPage(title: parent)
                note = " (made the parent page \"\(parent)\" too)"
            }
        }
        let id = ws.createPage(title: title, icon: icon ?? "", parentID: parentID, blocks: blocks(markdown, title: title))
        let links = InlineMarkdown.wikiLinks(in: markdown).map(\.target).filter { find($0, in: ws) == nil }
        var report = "Created \"\(title)\"\(parentID.flatMap { ws[$0] }.map { " in \($0.displayTitle)" } ?? "")\(note)."
        if !links.isEmpty { report += " Links to pages that don't exist yet: \(Set(links).sorted().joined(separator: ", ")) (use link_pages or create_page to make them)." }
        return (id, report)
    }

    public static func editPage(_ ws: inout Workspace, title: String, markdown: String, mode rawMode: String = "append") throws -> String {
        let p = try require(title, in: ws, fuzzy: false)
        guard p.kind != .database else { throw AgentToolError("\"\(p.displayTitle)\" is a database: use add_rows or update_row.") }
        guard !p.locked else { throw AgentToolError("\"\(p.displayTitle)\" is locked. Ask the user to unlock it first.") }
        let new = blocks(markdown, title: p.title)
        let mode = rawMode.lowercased()
        var b = p.blocks.filter { !($0.type == .paragraph && $0.text.isEmpty && $0.pageID == nil) }
        switch mode {
        case "replace", "rewrite", "overwrite":
            b = new
        case "prepend", "top", "start":
            b = new + b
        default:
            b += new
        }
        ws.pages[p.id]?.blocks = b.nonEmpty
        ws.touch(p.id)
        let verb = mode == "replace" || mode == "rewrite" || mode == "overwrite" ? "Replaced the content of" : (mode.hasPrefix("pre") || mode == "top" || mode == "start" ? "Added \(new.count) blocks to the top of" : "Added \(new.count) blocks to")
        return "\(verb) \"\(p.displayTitle)\" (now \(b.count) blocks)."
    }

    public static func renamePage(_ ws: inout Workspace, title: String, to newTitle: String) throws -> String {
        let p = try require(title, in: ws, fuzzy: false)
        let t = cleanTitle(newTitle)
        guard !t.isEmpty else { throw AgentToolError("Give the new title as the input.") }
        if let other = find(t, in: ws), other.id != p.id { throw AgentToolError("\"\(other.displayTitle)\" already exists.") }
        let old = p.title
        ws.rename(p.id, to: t)
        let n = old.trimmingCharacters(in: .whitespaces).isEmpty ? 0 : ws.updateLinks(from: old, to: t)
        return "Renamed \"\(p.displayTitle)\" to \"\(t)\"" + (n > 0 ? " and updated \(n) link\(n == 1 ? "" : "s")." : ".")
    }

    public static func movePage(_ ws: inout Workspace, title: String, to parent: String) throws -> String {
        let p = try require(title, in: ws, fuzzy: false)
        let target = cleanTitle(parent)
        if target.isEmpty || ["top", "root", "none", "top level"].contains(target.lowercased()) {
            ws.move(p.id, to: nil)
            return "Moved \"\(p.displayTitle)\" to the top level."
        }
        let dest = try require(target, in: ws, fuzzy: false)
        guard dest.kind == .page else { throw AgentToolError("Pages can only go under pages, and \"\(dest.displayTitle)\" is a \(dest.kind.rawValue).") }
        guard ws.move(p.id, to: dest.id) else { throw AgentToolError("Can't move \"\(p.displayTitle)\" into itself or one of its own sub-pages.") }
        return "Moved \"\(p.displayTitle)\" into \"\(dest.displayTitle)\"."
    }

    public static func trashPage(_ ws: inout Workspace, title: String) throws -> String {
        let p = try require(title, in: ws, fuzzy: false)
        ws.trash(p.id)
        return "Moved \"\(p.displayTitle)\" to the Trash (the user can restore it)."
    }

    /// The `[[targets]]` a page already links to (normalized).
    static func linkedTargets(_ p: Page) -> Set<String> {
        var out = Set<String>()
        for b in p.blocks { for s in b.markdownSources { for l in InlineMarkdown.wikiLinks(in: s) { out.insert(Workspace.normalize(l.target)) } } }
        return out
    }

    public static func linkPages(_ ws: inout Workspace, from: String, to list: [String], createMissing: Bool = true) throws -> String {
        let source = try require(from, in: ws, fuzzy: false)
        guard !list.isEmpty else { throw AgentToolError("List the pages to link to, separated by commas.") }
        let already = linkedTargets(source)
        var added: [String] = [], skipped: [String] = [], created: [String] = []
        for raw in list {
            let t = cleanTitle(raw)
            guard !t.isEmpty, Workspace.normalize(t) != Workspace.normalize(source.title) else { continue }
            let target = find(t, in: ws)
            let name = target?.displayTitle ?? t
            if already.contains(Workspace.normalize(name)) || already.contains(Workspace.normalize(t)) { skipped.append(name); continue }
            if target == nil && createMissing {
                ws.createPage(title: t)
                created.append(t)
            }
            added.append(name)
        }
        guard !added.isEmpty else {
            return skipped.isEmpty ? "Nothing to link." : "\"\(source.displayTitle)\" already links to \(skipped.joined(separator: ", "))."
        }
        let links = added.map { "[[\($0)]]" }
        var blocks = ws.pages[source.id]?.blocks ?? []
        if let i = blocks.lastIndex(where: { $0.type == .paragraph && $0.text.hasPrefix("Related: ") }) {
            blocks[i].text += " · " + links.joined(separator: " · ")
        } else {
            blocks = blocks.filter { !($0.type == .paragraph && $0.text.isEmpty && $0.pageID == nil) }
            blocks.append(Block(type: .paragraph, text: "Related: " + links.joined(separator: " · ")))
        }
        ws.pages[source.id]?.blocks = blocks
        ws.touch(source.id)
        var report = "Linked \"\(source.displayTitle)\" → \(added.joined(separator: ", "))."
        if !created.isEmpty { report += " Created empty pages: \(created.joined(separator: ", "))." }
        if !skipped.isEmpty { report += " Already linked: \(skipped.joined(separator: ", "))." }
        return report
    }

    /// "Machine Learning" → "machine-learning"; nil when nothing usable is left.
    public static func tagName(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasPrefix("#") { t.removeFirst() }
        t = t.replacingOccurrences(of: " ", with: "-")
        t = String(t.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" || $0 == "/" }.map(Character.init))
        while let f = t.unicodeScalars.first, !CharacterSet.letters.contains(f) { t.removeFirst() }
        return t.isEmpty ? nil : t.lowercased()
    }

    public static func tagPage(_ ws: inout Workspace, title: String, tags raw: [String]) throws -> String {
        let p = try require(title, in: ws, fuzzy: false)
        let have = p.tags
        // "a, b" or "#a #b": hashes separate tags; otherwise spaces join words ("machine learning" → machine-learning).
        let tags = raw.flatMap { piece -> [String] in
            piece.contains("#") ? piece.split(separator: "#").map(String.init) : [piece]
        }.compactMap(tagName)
        let new = tags.filter { !have.contains($0) }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        guard !new.isEmpty else { return tags.isEmpty ? "No valid tags given." : "\"\(p.displayTitle)\" already has those tags." }
        let text = new.map { "#" + $0 }.joined(separator: " ")
        var blocks = ws.pages[p.id]?.blocks ?? []
        if let i = blocks.lastIndex(where: { $0.type == .paragraph && $0.text.hasPrefix("Tags: ") }) {
            blocks[i].text += " " + text
        } else {
            blocks = blocks.filter { !($0.type == .paragraph && $0.text.isEmpty && $0.pageID == nil) }
            blocks.append(Block(type: .paragraph, text: "Tags: " + text))
        }
        ws.pages[p.id]?.blocks = blocks
        ws.touch(p.id)
        return "Tagged \"\(p.displayTitle)\" with \(text)."
    }

    // MARK: - Databases

    /// "Name: type" lines (or comma-separated) → columns. The first title column (or the first column) is the title.
    public static func parseColumns(_ spec: String) throws -> [PropertyDefinition] {
        var pieces: [String] = []
        for line in spec.split(whereSeparator: \.isNewline) {
            // "A: text, B: number(…)" on one line: split on commas outside parentheses.
            let named = line.contains(":")
            var depth = 0, cur = ""
            for ch in line {
                if ch == "(" { depth += 1 } else if ch == ")" { depth = max(0, depth - 1) }
                if ch == "," && depth == 0 && (!named || cur.contains(":")) { pieces.append(cur); cur = "" } else { cur.append(ch) }
            }
            if !cur.trimmingCharacters(in: .whitespaces).isEmpty { pieces.append(cur) }
        }
        var props: [PropertyDefinition] = []
        for piece in pieces {
            var s = piece.trimmingCharacters(in: .whitespaces)
            while s.hasPrefix("-") || s.hasPrefix("*") || s.hasPrefix("•") { s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces) }
            guard !s.isEmpty else { continue }
            var name = s, typeText = "text"
            if let colon = s.firstIndex(of: ":") {
                name = String(s[..<colon]); typeText = String(s[s.index(after: colon)...])
            } else if let open = s.firstIndex(of: "("), s.hasSuffix(")") {
                name = String(s[..<open]); typeText = String(s[s.index(after: open)..<s.index(before: s.endIndex)])
            }
            name = name.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'`*")))
            guard !name.isEmpty else { continue }
            guard !props.contains(where: { $0.name.lowercased() == name.lowercased() }) else { continue }
            props.append(try column(name: name, type: typeText.trimmingCharacters(in: .whitespaces)))
        }
        guard !props.isEmpty else { throw AgentToolError("Give the columns one per line as Name: type.") }
        if let i = props.firstIndex(where: { $0.type == .title }) {
            props[i].id = PropertyDefinition.titleID
            props.insert(props.remove(at: i), at: 0)
            for j in props.indices.dropFirst() where props[j].type == .title { props[j].type = .text }
        } else {
            props[0].type = .title
            props[0].id = PropertyDefinition.titleID
            props[0].options = []
        }
        return props
    }

    static func column(name: String, type raw: String) throws -> PropertyDefinition {
        var t = raw
        var options: [String] = []
        if let open = raw.firstIndex(of: "("), let close = raw.lastIndex(of: ")"), open < close {
            options = raw[raw.index(after: open)..<close].split(whereSeparator: { $0 == "," || $0 == "|" || $0 == "/" })
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            t = String(raw[..<open])
        }
        t = t.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
        let type: PropertyType
        switch t {
        case "title", "name", "primary": type = .title
        case "text", "rich_text", "string", "note", "notes", "long_text", "": type = .text
        case "number", "num", "int", "integer", "float", "decimal", "currency", "money", "price", "percent", "rating": type = .number
        case "select", "single_select", "option", "category", "choice": type = .select
        case "multi_select", "multiselect", "tags", "multi", "labels": type = .multiSelect
        case "status", "state": type = .status
        case "date", "datetime", "time", "deadline", "due": type = .date
        case "checkbox", "check", "bool", "boolean", "done", "yes/no", "yes_no": type = .checkbox
        case "url", "link", "website": type = .url
        case "email", "mail", "e_mail": type = .email
        case "phone", "tel", "telephone": type = .phone
        case "person", "people", "user": type = .person
        case "files", "file", "attachment": type = .files
        default: throw AgentToolError("Unknown column type \"\(raw)\" for \(name). Use title, text, number, select(…), multi_select(…), status, date, checkbox, url, email or phone.")
        }
        var def = PropertyDefinition(name: name, type: type)
        if type == .number {
            if t == "currency" || t == "money" || t == "price" { def.numberFormat = .dollar }
            if t == "percent" { def.numberFormat = .percent }
        }
        if type == .status {
            def.options = options.isEmpty ? PropertyDefinition.defaultStatusOptions() : options.enumerated().map { i, o in
                SelectOption(name: o, color: Tint.stable(for: o), group: i == 0 ? .todo : (i == options.count - 1 ? .complete : .inProgress))
            }
        } else if type == .select || type == .multiSelect {
            def.options = options.map { SelectOption(name: $0, color: Tint.stable(for: $0)) }
        }
        return def
    }

    @discardableResult
    public static func createDatabase(_ ws: inout Workspace, title rawTitle: String, columns: String, parent: String? = nil,
                                      icon: String? = nil) throws -> (id: UUID, report: String) {
        let title = cleanTitle(rawTitle)
        guard !title.isEmpty else { throw AgentToolError("create_database needs a title=\"…\".") }
        if let existing = find(title, in: ws) { throw AgentToolError("\"\(existing.displayTitle)\" already exists.") }
        let props = try parseColumns(columns)
        var parentID: UUID?
        if let parent = parent.map(cleanTitle), !parent.isEmpty, parent.lowercased() != "top" {
            let p = try require(parent, in: ws, fuzzy: false)
            guard p.kind == .page else { throw AgentToolError("Databases go under pages, and \"\(p.displayTitle)\" is a \(p.kind.rawValue).") }
            parentID = p.id
        }
        let views: [DatabaseView] = props.contains { $0.type == .status }
            ? [DatabaseView(name: "Table", type: .table), DatabaseView(name: "Board", type: .board)]
            : [DatabaseView(name: "Table", type: .table)]
        let id = ws.createDatabase(title: title, parentID: parentID, schema: DatabaseSchema(properties: props), views: views, icon: icon ?? "")
        return (id, "Created the database \"\(title)\" with columns " + props.map { "\($0.name) (\(columnType($0)))" }.joined(separator: ", ") + ".")
    }

    /// Text → a property value, adding select options that don't exist yet.
    public static func value(_ raw: String, for prop: inout PropertyDefinition) -> PropertyValue? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        switch prop.type {
        case .title, .formula, .rollup, .createdTime, .lastEditedTime, .uniqueID, .relation:
            return nil
        case .text: return .text(s)
        case .url: return .url(s)
        case .email: return .email(s)
        case .phone: return .phone(s)
        case .number:
            var t = s.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: " ", with: "")
            let percent = t.hasSuffix("%")
            t = t.trimmingCharacters(in: CharacterSet(charactersIn: "$€£¥₹₩%+"))
            guard let n = Double(t) else { return nil }
            return .number(percent ? n / 100 : n)
        case .checkbox:
            return .checkbox(["yes", "y", "true", "1", "x", "✓", "✔", "done", "checked", "on"].contains(s.lowercased()))
        case .date:
            return DateText.parse(s).map { .date(DateValue(start: $0)) }
        case .select, .status:
            return .select(optionID(s, in: &prop))
        case .multiSelect:
            let names = s.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "|" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return names.isEmpty ? nil : .multiSelect(names.map { optionID($0, in: &prop) })
        case .person:
            return .people(s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        case .files:
            return .files(s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        }
    }

    private static func optionID(_ name: String, in prop: inout PropertyDefinition) -> String {
        if let o = prop.option(named: name) { return o.id }
        let o = SelectOption(name: name, color: Tint.stable(for: name), group: prop.type == .status ? .todo : nil)
        prop.options.append(o)
        return o.id
    }

    public static func addRows(_ ws: inout Workspace, database: String, rows table: [[String]]) throws -> String {
        let db = try require(database, in: ws, fuzzy: false)
        guard db.kind == .database, var schema = db.schema else { throw AgentToolError("\"\(db.displayTitle)\" isn't a database. Use create_database first.") }
        let table = table.filter { $0.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
        guard table.count >= 2 else { throw AgentToolError("Give a header row of column names and at least one row.") }
        let header = table[0].map { $0.trimmingCharacters(in: .whitespaces) }
        var added: [String] = []
        var columnIDs: [String?] = []
        for name in header {
            if let p = schema.property(named: name) { columnIDs.append(p.id); continue }
            if Workspace.normalize(name) == Workspace.normalize(schema.titleProperty.name) || ["title", "name"].contains(name.lowercased()) {
                columnIDs.append(schema.titleProperty.id); continue
            }
            guard !name.isEmpty else { columnIDs.append(nil); continue }
            let p = PropertyDefinition(name: name, type: .text)
            schema.properties.append(p)
            added.append(name)
            columnIDs.append(p.id)
        }
        var titleIndex = columnIDs.firstIndex { $0 == schema.titleProperty.id }
        if titleIndex == nil { titleIndex = 0; columnIDs[0] = schema.titleProperty.id }
        var count = 0
        for row in table.dropFirst() {
            let title = titleIndex.flatMap { $0 < row.count ? row[$0] : nil }?.trimmingCharacters(in: .whitespaces) ?? ""
            var values: [String: PropertyValue] = [:]
            for (i, id) in columnIDs.enumerated() where i < row.count && i != titleIndex {
                guard let id, var prop = schema.property(id: id) else { continue }
                if let v = value(row[i], for: &prop) { values[id] = v }
                schema.update(prop)
            }
            ws.pages[db.id]?.schema = schema
            if ws.createRow(in: db.id, title: title, properties: values) != nil { count += 1 }
            schema = ws.pages[db.id]?.schema ?? schema
        }
        ws.pages[db.id]?.schema = schema
        ws.touch(db.id)
        return "Added \(count) row\(count == 1 ? "" : "s") to \"\(db.displayTitle)\"" + (added.isEmpty ? "." : " and new text columns \(added.joined(separator: ", ")).")
    }

    public static func updateRow(_ ws: inout Workspace, database: String?, row: String, values text: String) throws -> String {
        var candidates = ws.livePages.filter { $0.kind == .row && Workspace.normalize($0.title) == Workspace.normalize(cleanTitle(row)) }
        if let database, !database.isEmpty {
            let db = try require(database, in: ws, fuzzy: false)
            candidates = candidates.filter { $0.parentID == db.id }
        }
        guard let r = candidates.first, let dbID = r.parentID, var schema = ws[dbID]?.schema else {
            throw AgentToolError("No database row is called \"\(cleanTitle(row))\"\(database.map { " in \($0)" } ?? ""). Use read_page on the database to see its rows.")
        }
        var changed: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-*•")))
            let raw = String(line[line.index(after: colon)...])
            if Workspace.normalize(name) == Workspace.normalize(schema.titleProperty.name) {
                ws.rename(r.id, to: raw.trimmingCharacters(in: .whitespaces)); changed.append(name); continue
            }
            guard var prop = schema.property(named: name) else { throw AgentToolError("\"\(ws[dbID]?.displayTitle ?? "")\" has no column \(name). Columns: \(schema.properties.map(\.name).joined(separator: ", ")).") }
            let v = value(raw, for: &prop)
            schema.update(prop)
            ws.pages[dbID]?.schema = schema
            ws.setProperty(r.id, prop.id, v)
            changed.append(name)
        }
        guard !changed.isEmpty else { throw AgentToolError("Give one Column: value per line.") }
        return "Updated \(changed.joined(separator: ", ")) of \"\(r.displayTitle)\"."
    }

    // MARK: - Daily note

    public static func dailyNote(_ ws: inout Workspace, append markdown: String, date: Date = Date()) -> (id: UUID, report: String) {
        let id = ws.dailyNote(for: date)
        let new = blocks(markdown, title: ws[id]?.title ?? "")
        if !new.isEmpty {
            var b = (ws.pages[id]?.blocks ?? []).filter { !($0.type == .paragraph && $0.text.isEmpty && $0.pageID == nil) }
            b += new
            ws.pages[id]?.blocks = b
            ws.touch(id)
        }
        let body = ws[id].map { MarkdownCodec.blocksToMarkdown($0.blocks, workspace: ws) } ?? ""
        return (id, "\(new.isEmpty ? "" : "Added to today's note. ")Today's note \"\(ws[id]?.displayTitle ?? "")\":\n\(Agent.truncate(body, limit: 3_000))")
    }

    // MARK: - Graph

    public static func graphOverview(_ ws: Workspace, index: LinkIndex, limit: Int = 12) -> String {
        let pages = ws.livePages.filter { !$0.isTemplate && $0.kind != .row }
        var degree: [UUID: Int] = [:]
        var edges = 0
        for (src, targets) in index.outgoing {
            for t in targets where ws[t] != nil {
                edges += 1
                degree[src, default: 0] += 1
                degree[t, default: 0] += 1
            }
        }
        let hubs = pages.filter { (degree[$0.id] ?? 0) > 0 }.sorted { (degree[$0.id] ?? 0) > (degree[$1.id] ?? 0) }.prefix(limit)
        let orphans = pages.filter { (degree[$0.id] ?? 0) == 0 && $0.dailyDate == nil }
        let unresolved = Set(index.unresolved.values.flatMap { $0 })
        var s = "\(pages.count) pages, \(edges) links, \(index.tags.count) tags, \(orphans.count) orphans (no links in or out)."
        if !hubs.isEmpty { s += "\n\nMost connected:\n" + hubs.map { "- \($0.displayTitle) (\(degree[$0.id] ?? 0))" }.joined(separator: "\n") }
        if !orphans.isEmpty {
            s += "\n\nOrphans:\n" + orphans.prefix(limit * 2).map { "- \($0.displayTitle)" }.joined(separator: "\n")
            if orphans.count > limit * 2 { s += "\n…and \(orphans.count - limit * 2) more" }
        }
        let tags = index.tags.map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }.prefix(limit)
        if !tags.isEmpty { s += "\n\nTags: " + tags.map { "#\($0.0) (\($0.1))" }.joined(separator: ", ") }
        if !unresolved.isEmpty { s += "\n\nLinks to pages that don't exist yet: " + unresolved.sorted().prefix(limit * 2).joined(separator: ", ") }
        // Pages whose title appears in another page's text without a link: ready-made edges.
        var mentions: [String] = []
        for p in pages where p.title.trimmingCharacters(in: .whitespaces).count >= 3 {
            for m in LinkIndex.unlinkedMentions(of: p, in: ws, limit: 3) {
                if let src = ws[m.sourceID] { mentions.append("\(src.displayTitle) mentions \(p.displayTitle)") }
            }
            if mentions.count >= limit * 2 { break }
        }
        if !mentions.isEmpty { s += "\n\nUnlinked mentions (could be links):\n" + mentions.prefix(limit * 2).map { "- " + $0 }.joined(separator: "\n") }
        return s
    }
}

private extension Array where Element == Block {
    /// Pages always keep at least one (empty) block to type into.
    var nonEmpty: [Block] { isEmpty ? [Block()] : self }
}
