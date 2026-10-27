import Foundation

/// Turns a page's Markdown into the slide text `OfficeDocument` makes decks from: a title slide, then one slide per
/// `#`/`##` heading, with long slides split.
public enum SlideOutline {
    public static func slides(title: String, markdown: String, maxLines: Int = 7) -> String {
        var slides: [(title: String, lines: [String])] = []
        var intro: [String] = []
        var current: (title: String, lines: [String])?
        var inCode = false
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inCode.toggle(); continue }
            if inCode || line.isEmpty || line == "---" || line.hasPrefix("|---") || line.hasPrefix("| ---") { continue }
            if line.hasPrefix("# ") || line.hasPrefix("## ") {
                if let c = current { slides.append(c) }
                current = (String(line.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces), [])
                continue
            }
            var item = line
            if item.hasPrefix("### ") { item = "- **" + item.dropFirst(4) + "**" }
            else if item.hasPrefix("> ") { item = String(item.dropFirst(2)) }
            else if item.hasPrefix("- [ ] ") || item.hasPrefix("- [x] ") { item = "- " + item.dropFirst(6) }
            else if item.hasPrefix("|") { item = "- " + item.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " · ") }
            // Keep the source indentation of sub-bullets.
            if raw.hasPrefix("  ") || raw.hasPrefix("\t"), item.hasPrefix("- ") || item.hasPrefix("* ") { item = "  " + item }
            if item.count > 220 { item = String(item.prefix(217)) + "…" }
            if current == nil { intro.append(item) } else { current?.lines.append(item) }
        }
        if let c = current { slides.append(c) }
        if slides.isEmpty && intro.count > 2 {
            // No headings: chunk the text.
            let chunks = stride(from: 2, to: intro.count, by: maxLines).map { Array(intro[$0..<min(intro.count, $0 + maxLines)]) }
            slides = chunks.enumerated().map { (chunks.count > 1 ? "\(title) (\($0.offset + 1))" : title, $0.element) }
            intro = Array(intro.prefix(2))
        }
        var out = ["# \(title)\n" + intro.prefix(2).map { $0.hasPrefix("- ") ? String($0.dropFirst(2)) : $0 }.joined(separator: "\n")]
        for s in slides {
            let parts = s.lines.isEmpty ? [[]] : stride(from: 0, to: s.lines.count, by: maxLines).map { Array(s.lines[$0..<min(s.lines.count, $0 + maxLines)]) }
            for (i, part) in parts.enumerated() {
                out.append("# \(s.title)\(i > 0 ? " (cont.)" : "")\n" + part.joined(separator: "\n"))
            }
        }
        return out.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n---\n")
    }
}

public extension WorkspaceOps {
    /// A database as rows of display text, header first (for spreadsheets).
    static func databaseTable(_ id: UUID, in ws: Workspace) -> [[String]] {
        guard let db = ws[id], let schema = db.schema else { return [] }
        let props = schema.properties
        var rows = [props.map(\.name)]
        for r in ws.rows(of: id).sorted(by: { $0.order < $1.order }) {
            rows.append(props.map { p in
                p.type == .title ? r.title : PropertyResolver.displayText(PropertyResolver.resolve(r, p, schema: schema, in: ws), p, in: ws)
            })
        }
        return rows
    }
}
