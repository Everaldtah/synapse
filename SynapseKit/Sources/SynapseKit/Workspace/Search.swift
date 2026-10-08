import Foundation

public struct SearchHit: Identifiable, Hashable, Sendable {
    public var id: UUID { pageID }
    public var pageID: UUID
    public var score: Double
    public var snippet: String
    public var blockID: UUID?
    public var titleMatch: Bool
}

public enum Search {
    /// Full-text search: every word must appear in the title or the content. Title hits rank first.
    public static func run(_ query: String, in ws: Workspace, limit: Int = 60, kinds: Set<PageKind> = [.page, .database, .row]) -> [SearchHit] {
        let words = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var hits: [SearchHit] = []
        let now = Date()
        for page in ws.livePages where kinds.contains(page.kind) && !page.isTemplate {
            let title = page.displayTitle
            var score = 0.0
            var snippet = ""
            var blockID: UUID?
            var titleMatch = false
            var allFound = true
            for w in words {
                if title.range(of: w, options: opts) != nil {
                    titleMatch = true
                    score += title.lowercased().hasPrefix(w) ? 12 : 8
                    continue
                }
                if page.aliases.contains(where: { $0.range(of: w, options: opts) != nil }) { score += 6; continue }
                var found = false
                for b in page.blocks {
                    let t = b.plainText
                    if let r = t.range(of: w, options: opts) {
                        found = true
                        score += b.type.isHeading ? 3 : 1
                        if snippet.isEmpty {
                            snippet = LinkIndex.snippet(t, around: NSRange(r, in: t), radius: 60)
                            blockID = b.id
                        }
                        break
                    }
                }
                if !found {
                    for (_, v) in page.properties {
                        if let s = v.textValue, s.range(of: w, options: opts) != nil { found = true; score += 1; break }
                    }
                }
                if !found { allFound = false; break }
            }
            guard allFound else { continue }
            if Workspace.normalize(title) == words.joined(separator: " ") { score += 20 }
            // Recently edited pages rank a little higher.
            let days = now.timeIntervalSince(page.lastOpenedAt ?? page.updatedAt) / 86_400
            score += max(0, 3 - days / 10)
            if snippet.isEmpty { snippet = page.excerpt(maxLength: 120) }
            hits.append(SearchHit(pageID: page.id, score: score, snippet: snippet, blockID: blockID, titleMatch: titleMatch))
        }
        return Array(hits.sorted { $0.score > $1.score }.prefix(limit))
    }

    /// Quick-switcher fuzzy score: characters of the query in order inside the title. nil = no match.
    public static func fuzzyScore(_ query: String, _ title: String) -> Double? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        if q.isEmpty { return 0 }
        let t = Array(title.lowercased())
        var qi = 0
        var score = 0.0
        var last = -1
        for (i, ch) in t.enumerated() where qi < q.count && ch == q[qi] {
            score += (last == i - 1) ? 3 : 1
            if i == 0 || t[i - 1] == " " { score += 2 }
            last = i
            qi += 1
        }
        guard qi == q.count else { return nil }
        if title.lowercased().hasPrefix(query.lowercased()) { score += 10 }
        return score - Double(t.count) * 0.02
    }

    /// Pages for a `[[` link picker or quick switcher.
    public static func quickSwitch(_ query: String, in ws: Workspace, limit: Int = 20) -> [Page] {
        let pages = ws.livePages.filter { !$0.isTemplate }
        if query.trimmingCharacters(in: .whitespaces).isEmpty { return ws.recent(limit: limit) }
        return pages.compactMap { p -> (Page, Double)? in
            let best = ([p.displayTitle] + p.aliases).compactMap { fuzzyScore(query, $0) }.max()
            return best.map { (p, $0) }
        }
        .sorted { $0.1 > $1.1 }
        .prefix(limit)
        .map(\.0)
    }
}
