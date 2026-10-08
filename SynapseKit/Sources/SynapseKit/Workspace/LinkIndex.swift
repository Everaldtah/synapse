import Foundation

/// A mention of one page inside another.
public struct Backlink: Identifiable, Hashable, Sendable {
    public var id: String { "\(sourceID)-\(blockID?.uuidString ?? "p")-\(snippet.hashValue)" }
    public var sourceID: UUID
    public var blockID: UUID?
    /// The sentence around the mention.
    public var snippet: String
}

/// Who links to whom. Rebuilt in the background whenever pages change.
public struct LinkIndex: Sendable {
    /// page → pages it links to
    public private(set) var outgoing: [UUID: Set<UUID>] = [:]
    /// page → link targets that match no page
    public private(set) var unresolved: [UUID: Set<String>] = [:]
    /// page → mentions of it elsewhere
    public private(set) var backlinks: [UUID: [Backlink]] = [:]
    /// tag → pages that use it
    public private(set) var tags: [String: Set<UUID>] = [:]
    /// row → related rows (database relation properties)
    public private(set) var relations: [UUID: Set<UUID>] = [:]

    public init() {}

    public init(workspace: Workspace) {
        var titles: [String: UUID] = [:]
        for p in workspace.livePages where !p.isTemplate {
            let k = Workspace.normalize(p.title)
            if !k.isEmpty, titles[k] == nil { titles[k] = p.id }
        }
        for p in workspace.livePages where !p.isTemplate {
            for a in p.aliases {
                let k = Workspace.normalize(a)
                if !k.isEmpty, titles[k] == nil { titles[k] = p.id }
            }
        }

        for page in workspace.livePages where !page.isTemplate {
            for block in page.blocks {
                // Link blocks
                if let target = block.pageID, block.type == .pageLink || block.type == .childPage || block.type == .childDatabase,
                   workspace[target]?.isTrashed == false, target != page.id {
                    outgoing[page.id, default: []].insert(target)
                    backlinks[target, default: []].append(Backlink(sourceID: page.id, blockID: block.id,
                                                                   snippet: block.type == .pageLink ? "Linked page" : "Sub-page"))
                }
                for source in block.markdownSources {
                    for token in InlineMarkdown.tokens(in: source) {
                        switch token.kind {
                        case .wikiLink(let link):
                            if let id = titles[Workspace.normalize(link.target)] {
                                guard id != page.id else { continue }
                                outgoing[page.id, default: []].insert(id)
                                backlinks[id, default: []].append(Backlink(sourceID: page.id, blockID: block.id,
                                                                           snippet: LinkIndex.snippet(source, around: token.range)))
                            } else if !link.target.isEmpty {
                                unresolved[page.id, default: []].insert(link.target)
                            }
                        case .tag(let t):
                            tags[t.lowercased(), default: []].insert(page.id)
                        default:
                            break
                        }
                    }
                }
            }
            for (_, value) in page.properties {
                switch value {
                case .relation(let ids):
                    for r in ids where workspace[r]?.isTrashed == false && r != page.id {
                        relations[page.id, default: []].insert(r)
                        relations[r, default: []].insert(page.id)
                    }
                case .text(let s):
                    for link in InlineMarkdown.wikiLinks(in: s) {
                        if let id = titles[Workspace.normalize(link.target)], id != page.id {
                            outgoing[page.id, default: []].insert(id)
                            backlinks[id, default: []].append(Backlink(sourceID: page.id, blockID: nil, snippet: s))
                        }
                    }
                default:
                    break
                }
            }
        }
    }

    /// Pages linking to `id`, one entry per page (the first mention's snippet).
    public func linkedMentions(of id: UUID) -> [Backlink] { backlinks[id] ?? [] }

    public func degree(of id: UUID) -> Int {
        (outgoing[id]?.count ?? 0) + (backlinks[id].map { Set($0.map(\.sourceID)).count } ?? 0) + (relations[id]?.count ?? 0)
    }

    /// All tags with how many pages use them, most used first.
    public var tagCounts: [(tag: String, count: Int)] {
        tags.map { ($0.key, $0.value.count) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.tag < $1.tag }
    }

    /// Plain-text mentions of a page's title that aren't links yet (Obsidian's "unlinked mentions").
    public static func unlinkedMentions(of page: Page, in workspace: Workspace, limit: Int = 50) -> [Backlink] {
        let names = ([page.title] + page.aliases).map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 3 }
        guard !names.isEmpty else { return [] }
        var out: [Backlink] = []
        for other in workspace.livePages where other.id != page.id && !other.isTemplate {
            for block in other.blocks where block.type.isTextual && block.type != .code {
                let text = block.text
                for name in names {
                    guard let r = LinkIndex.findUnlinked(name, in: text) else { continue }
                    out.append(Backlink(sourceID: other.id, blockID: block.id, snippet: snippet(text, around: r)))
                    break
                }
                if out.count >= limit { return out }
            }
        }
        return out
    }

    /// The first whole-word, case-insensitive occurrence of `name` outside existing links.
    public static func findUnlinked(_ name: String, in text: String) -> NSRange? {
        let ns = text as NSString
        let escaped = NSRegularExpression.escapedPattern(for: name)
        guard let re = try? NSRegularExpression(pattern: "(?<![\\w\\[|#])" + escaped + "(?![\\w\\]])", options: [.caseInsensitive]) else { return nil }
        let linked = InlineMarkdown.tokens(in: text).filter {
            if case .wikiLink = $0.kind { return true }
            if case .link = $0.kind { return true }
            if case .url = $0.kind { return true }
            return false
        }.map(\.range)
        for m in re.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) {
            if !linked.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) { return m.range }
        }
        return nil
    }

    /// Turn the first unlinked mention of `name` in `text` into a `[[link]]`.
    public static func linkFirstMention(of name: String, in text: String, target: String) -> String? {
        guard let r = findUnlinked(name, in: text) else { return nil }
        let ns = text as NSString
        let found = ns.substring(with: r)
        let link = found == target ? "[[\(target)]]" : "[[\(target)|\(found)]]"
        return ns.replacingCharacters(in: r, with: link)
    }

    static func snippet(_ text: String, around range: NSRange, radius: Int = 70) -> String {
        let plain = text as NSString
        let start = max(0, range.location - radius)
        let end = min(plain.length, range.location + range.length + radius)
        var s = plain.substring(with: NSRange(location: start, length: end - start))
        s = s.replacingOccurrences(of: "\n", with: " ")
        if start > 0 { s = "…" + s }
        if end < plain.length { s += "…" }
        return s
    }
}
