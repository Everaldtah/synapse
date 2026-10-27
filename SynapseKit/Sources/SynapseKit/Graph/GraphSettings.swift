import Foundation

/// How graph nodes are coloured.
public enum GraphColorMode: String, Codable, CaseIterable, Sendable {
    /// By node kind: page, database, row, daily note, tag, unresolved.
    case type
    /// By the page's first tag.
    case tag
    /// By the first matching colour group (Obsidian's groups).
    case groups

    public var title: String {
        switch self {
        case .type: return "Type"
        case .tag: return "First tag"
        case .groups: return "Groups"
        }
    }
}

/// A colour group: nodes matching `query` are drawn in `color`. The first matching group wins, like Obsidian.
public struct GraphGroup: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    /// What it matches: "tag:idea" (or "#idea"), "path:Projects" (page is, or is under, a page titled Projects),
    /// "kind:database|row|daily|page", "title:meeting", "line:…" (any page text contains), or plain text = title contains.
    public var query: String
    public var color: Tint

    public init(id: UUID = UUID(), query: String, color: Tint) {
        self.id = id
        self.query = query
        self.color = color
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID())
        query = c.value(.query, "")
        color = c.value(.color, .blue)
    }

    /// Whether a node matches (page is nil for tag/unresolved nodes).
    public func matches(_ node: GraphNode, page: Page?, workspace: Workspace) -> Bool {
        let (field, value) = GraphGroup.parse(query)
        guard !value.isEmpty else { return false }
        switch field {
        case .tag:
            // "project" also matches nested tags like "project/alpha".
            let tag = value.lowercased()
            func hit(_ t: String) -> Bool { t == tag || t.hasPrefix(tag + "/") }
            if node.kind != .tag, let page { return page.tags.contains(where: hit) }
            return node.tag.map(hit) ?? false
        case .path:
            guard let page else { return false }
            let parts = value.split(separator: "/").map { Workspace.normalize(String($0)) }.filter { !$0.isEmpty }
            guard !parts.isEmpty else { return false }
            // Titles from the root down to the page; the parts must appear in it as a run.
            var chain = [Workspace.normalize(page.displayTitle)]
            var seen: Set<UUID> = [page.id]
            var cur = page.parentID
            while let c = cur, !seen.contains(c), let p = workspace[c] {
                chain.insert(Workspace.normalize(p.displayTitle), at: 0)
                seen.insert(c)
                cur = p.parentID
            }
            guard chain.count >= parts.count else { return false }
            for start in 0...(chain.count - parts.count) where Array(chain[start..<(start + parts.count)]) == parts {
                return true
            }
            return false
        case .kind:
            let wanted = value.lowercased().split(whereSeparator: { $0 == "|" || $0 == "," || $0 == " " })
                .map { GraphGroup.kindName(String($0)) }
            return wanted.contains(node.kind.rawValue)
        case .title, .text:
            return GraphGroup.contains(node.title, value)
        case .line:
            guard let page else { return false }
            return page.blocks.contains { GraphGroup.contains($0.plainText, value) }
        }
    }

    enum Field: String {
        case tag, path, kind, title, line, text
    }

    /// Split a query into its field and value ("#idea" → tag, idea; "Meeting" → text, Meeting).
    static func parse(_ query: String) -> (field: Field, value: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.hasPrefix("#") { return (.tag, unquote(String(q.dropFirst()))) }
        if let colon = q.firstIndex(of: ":") {
            let name = q[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            var rest = unquote(q[q.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            let field: Field?
            switch name {
            case "tag", "tags":
                field = .tag
                if rest.hasPrefix("#") { rest.removeFirst() }
            case "path": field = .path
            case "kind", "type": field = .kind
            case "title", "file": field = .title
            case "line", "content": field = .line
            default: field = nil
            }
            if let field { return (field, rest) }
        }
        return (.text, unquote(q))
    }

    /// The same query however it is spelled ("#Idea" and "tag:idea" are one group).
    static func canonical(_ query: String) -> String {
        let (field, value) = parse(query)
        return field.rawValue + ":" + value.lowercased()
    }

    static func kindName(_ word: String) -> String {
        switch word {
        case "db", "dbs", "databases": return "database"
        case "rows": return "row"
        case "dailies", "journal": return "daily"
        case "pages", "note", "notes": return "page"
        case "tags": return "tag"
        default: return word
        }
    }

    static func contains(_ text: String, _ needle: String) -> Bool {
        text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

private func unquote(_ s: String) -> String {
    let t = s.trimmingCharacters(in: .whitespaces)
    for (open, close) in [("\"", "\""), ("'", "'"), ("\u{201C}", "\u{201D}")] where t.count >= 2 && t.hasPrefix(open) && t.hasSuffix(close) {
        return String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
    }
    return t
}

/// Everything the graph shows and how (Obsidian's graph settings): filters, colour groups, display and forces.
/// The app persists it as JSON; decoding is tolerant, so adding settings never wipes saved ones.
public struct GraphViewSettings: Codable, Equatable, Sendable {
    // MARK: Filters
    public var showTags = false
    public var showUnresolved = false
    public var showOrphans = true
    public var showRows = true
    public var showDaily = true
    public var showHierarchy = false
    public var showRelations = true
    /// Local graph hops, 1...5.
    public var depth = 1
    /// Persisted filter text.
    public var search = ""

    // MARK: Groups & colour
    public var colorMode: GraphColorMode = .type
    public var groups: [GraphGroup] = []

    // MARK: Display
    /// Node radius multiplier, 0.4...3.
    public var nodeSize = 1.0
    /// Edge width multiplier, 0.3...4.
    public var linkThickness = 1.0
    /// Labels for all nodes above this zoom (Obsidian's "text fade threshold"), 0.1...3.
    public var labelZoom = 0.9
    public var showArrows = false

    // MARK: Forces (map onto ForceLayout)
    /// Gravity to the centre, 0...0.3.
    public var centerForce = 0.045
    /// Repulsion between nodes (|charge|), 0...2000.
    public var repelForce = 260.0
    /// Spring strength along links, 0...1.5.
    public var linkForce = 0.7
    /// Spring rest length, 10...400.
    public var linkDistance = 70.0

    public init() {}

    public static let `default` = GraphViewSettings()

    public static let depthRange: ClosedRange<Int> = 1...5
    public static let nodeSizeRange: ClosedRange<Double> = 0.4...3
    public static let linkThicknessRange: ClosedRange<Double> = 0.3...4
    public static let labelZoomRange: ClosedRange<Double> = 0.1...3
    public static let centerForceRange: ClosedRange<Double> = 0...0.3
    public static let repelForceRange: ClosedRange<Double> = 0...2000
    public static let linkForceRange: ClosedRange<Double> = 0...1.5
    public static let linkDistanceRange: ClosedRange<Double> = 10...400

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GraphViewSettings()
        showTags = c.value(.showTags, d.showTags)
        showUnresolved = c.value(.showUnresolved, d.showUnresolved)
        showOrphans = c.value(.showOrphans, d.showOrphans)
        showRows = c.value(.showRows, d.showRows)
        showDaily = c.value(.showDaily, d.showDaily)
        showHierarchy = c.value(.showHierarchy, d.showHierarchy)
        showRelations = c.value(.showRelations, d.showRelations)
        depth = c.value(.depth, d.depth).clamped(to: Self.depthRange)
        search = c.value(.search, d.search)
        colorMode = c.value(.colorMode, d.colorMode)
        groups = c.value(.groups, d.groups)
        nodeSize = c.value(.nodeSize, d.nodeSize).clamped(to: Self.nodeSizeRange)
        linkThickness = c.value(.linkThickness, d.linkThickness).clamped(to: Self.linkThicknessRange)
        labelZoom = c.value(.labelZoom, d.labelZoom).clamped(to: Self.labelZoomRange)
        showArrows = c.value(.showArrows, d.showArrows)
        centerForce = c.value(.centerForce, d.centerForce).clamped(to: Self.centerForceRange)
        repelForce = c.value(.repelForce, d.repelForce).clamped(to: Self.repelForceRange)
        linkForce = c.value(.linkForce, d.linkForce).clamped(to: Self.linkForceRange)
        linkDistance = c.value(.linkDistance, d.linkDistance).clamped(to: Self.linkDistanceRange)
    }

    /// The builder options (focus nil).
    public var options: GraphOptions {
        var o = GraphOptions()
        o.showTags = showTags
        o.showUnresolved = showUnresolved
        o.showOrphans = showOrphans
        o.showRows = showRows
        o.showDaily = showDaily
        o.showHierarchy = showHierarchy
        o.showRelations = showRelations
        o.depth = depth
        o.search = search
        return o
    }

    /// Push the forces into a layout.
    public func applyForces(to layout: ForceLayout) {
        layout.gravity = centerForce
        layout.charge = -repelForce
        layout.linkStrength = linkForce
        layout.linkDistance = linkDistance
    }

    /// The colour of the first group matching a node, if any (like Obsidian).
    public static func groupColor(for node: GraphNode, page: Page?, workspace: Workspace, groups: [GraphGroup]) -> Tint? {
        groups.first { $0.matches(node, page: page, workspace: workspace) }?.color
    }

    // MARK: Agent access

    /// Every valid key for `set`, in display order.
    public static let keys: [String] = [
        "show_tags", "show_unresolved", "show_orphans", "show_rows", "show_daily", "show_hierarchy", "show_relations",
        "depth", "search", "color_by", "node_size", "link_thickness", "label_zoom", "arrows",
        "center_force", "repel_force", "link_force", "link_distance",
    ]

    /// Other spellings `set` accepts, keyed by the name squashed to lowercase letters and digits.
    private static let aliases: [String: String] = [
        "tags": "show_tags", "unresolved": "show_unresolved", "orphans": "show_orphans", "rows": "show_rows",
        "daily": "show_daily", "dailynotes": "show_daily", "hierarchy": "show_hierarchy", "relations": "show_relations",
        "filter": "search", "colourby": "color_by", "colormode": "color_by", "colourmode": "color_by",
        "color": "color_by", "colour": "color_by", "showarrows": "arrows", "arrow": "arrows",
        "textfade": "label_zoom", "textfadethreshold": "label_zoom", "gravity": "center_force",
        "centreforce": "center_force", "charge": "repel_force", "repel": "repel_force", "repulsion": "repel_force",
        "linkstrength": "link_force", "distance": "link_distance",
    ]

    /// The `keys` entry a spelling means ("Show-Tags", "showTags" and "show tags" all mean show_tags).
    static func canonicalKey(_ key: String) -> String? {
        let squashed = String(key.lowercased().filter { $0.isLetter || $0.isNumber })
        if let k = keys.first(where: { $0.replacingOccurrences(of: "_", with: "") == squashed }) { return k }
        return aliases[squashed]
    }

    /// Agent-friendly setter. Keys are snake_case: show_tags, show_unresolved, show_orphans, show_rows, show_daily,
    /// show_hierarchy, show_relations, depth, search, color_by (type|tag|groups), node_size, link_thickness,
    /// label_zoom, arrows, center_force, repel_force, link_force, link_distance. Values: true/false/yes/no/on/off
    /// (or toggle), numbers (clamped to the ranges above), words; "default" restores a setting's default.
    /// Returns a short description of the change, e.g. "repel_force 260 → 500". Throws GraphSettingsError
    /// (a message listing valid keys/values) for an unknown key or unparseable value.
    public mutating func set(_ key: String, to value: String) throws -> String {
        guard let k = GraphViewSettings.canonicalKey(key) else {
            throw GraphSettingsError("Unknown graph setting \"\(key)\". Valid keys: \(GraphViewSettings.keys.joined(separator: ", ")).")
        }
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch k {
        case "show_tags": return try setBool(\.showTags, k, raw)
        case "show_unresolved": return try setBool(\.showUnresolved, k, raw)
        case "show_orphans": return try setBool(\.showOrphans, k, raw)
        case "show_rows": return try setBool(\.showRows, k, raw)
        case "show_daily": return try setBool(\.showDaily, k, raw)
        case "show_hierarchy": return try setBool(\.showHierarchy, k, raw)
        case "show_relations": return try setBool(\.showRelations, k, raw)
        case "arrows": return try setBool(\.showArrows, k, raw)
        case "node_size": return try setNumber(\.nodeSize, k, raw, Self.nodeSizeRange)
        case "link_thickness": return try setNumber(\.linkThickness, k, raw, Self.linkThicknessRange)
        case "label_zoom": return try setNumber(\.labelZoom, k, raw, Self.labelZoomRange)
        case "center_force": return try setNumber(\.centerForce, k, raw, Self.centerForceRange)
        case "repel_force": return try setNumber(\.repelForce, k, raw, Self.repelForceRange)
        case "link_force": return try setNumber(\.linkForce, k, raw, Self.linkForceRange)
        case "link_distance": return try setNumber(\.linkDistance, k, raw, Self.linkDistanceRange)
        case "depth":
            let range = Self.depthRange
            let wanted: Double
            if Self.isDefaultWord(raw) {
                wanted = Double(Self.default.depth)
            } else if let d = Self.parseNumber(raw) {
                wanted = d
            } else {
                throw GraphSettingsError("depth needs a whole number of links from \(range.lowerBound) to \(range.upperBound), not \"\(raw)\".")
            }
            let old = depth
            depth = Int(wanted.clamped(to: Double(range.lowerBound)...Double(range.upperBound)).rounded())
            return Self.describe(k, String(old), String(depth), note: Self.clampNote(wanted, Double(depth), range: Double(range.lowerBound)...Double(range.upperBound)))
        case "search":
            let old = search
            search = unquote(raw)
            return Self.describe(k, "\"\(old)\"", "\"\(search)\"")
        case "color_by":
            let mode: GraphColorMode
            switch raw.lowercased() {
            case "type", "types", "kind": mode = .type
            case "tag", "tags", "first tag", "first_tag", "firsttag": mode = .tag
            case "groups", "group": mode = .groups
            case "default": mode = Self.default.colorMode
            default:
                throw GraphSettingsError("color_by must be type, tag or groups, not \"\(raw)\".")
            }
            let old = colorMode
            colorMode = mode
            return Self.describe(k, old.rawValue, mode.rawValue)
        default:
            throw GraphSettingsError("Unknown graph setting \"\(key)\". Valid keys: \(GraphViewSettings.keys.joined(separator: ", ")).")
        }
    }

    /// The current value of a `set` key as text (nil for an unknown key).
    public func value(forKey key: String) -> String? {
        guard let k = GraphViewSettings.canonicalKey(key) else { return nil }
        switch k {
        case "show_tags": return String(showTags)
        case "show_unresolved": return String(showUnresolved)
        case "show_orphans": return String(showOrphans)
        case "show_rows": return String(showRows)
        case "show_daily": return String(showDaily)
        case "show_hierarchy": return String(showHierarchy)
        case "show_relations": return String(showRelations)
        case "depth": return String(depth)
        case "search": return "\"\(search)\""
        case "color_by": return colorMode.rawValue
        case "node_size": return Self.format(nodeSize)
        case "link_thickness": return Self.format(linkThickness)
        case "label_zoom": return Self.format(labelZoom)
        case "arrows": return String(showArrows)
        case "center_force": return Self.format(centerForce)
        case "repel_force": return Self.format(repelForce)
        case "link_force": return Self.format(linkForce)
        case "link_distance": return Self.format(linkDistance)
        default: return nil
        }
    }

    /// Add (or replace the colour of) a group with this query; "clear" semantics are handled by the caller.
    /// Also switches `colorMode` to groups so the group shows.
    public mutating func addGroup(query: String, color: Tint) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let key = GraphGroup.canonical(q)
        if let i = groups.firstIndex(where: { GraphGroup.canonical($0.query) == key }) {
            groups[i].color = color
        } else {
            groups.append(GraphGroup(query: q, color: color))
        }
        colorMode = .groups
    }

    /// Remove every group with this query (however it is spelled). Returns whether one was removed.
    @discardableResult
    public mutating func removeGroup(query: String) -> Bool {
        let key = GraphGroup.canonical(query)
        let before = groups.count
        groups.removeAll { GraphGroup.canonical($0.query) == key }
        return groups.count != before
    }

    /// Every setting as "key: value" lines (keys as in `set`), plus the groups — for the agent to read.
    public var summary: String {
        var lines = GraphViewSettings.keys.map { "\($0): \(value(forKey: $0) ?? "")" }
        if groups.isEmpty {
            lines.append("groups: none")
        } else {
            lines.append("groups (first match wins):")
            for (i, g) in groups.enumerated() {
                lines.append("  \(i + 1). \(g.query.isEmpty ? "(empty)" : g.query) → \(g.color.rawValue)")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Parsing helpers

    private mutating func setBool(_ kp: WritableKeyPath<GraphViewSettings, Bool>, _ key: String, _ raw: String) throws -> String {
        let old = self[keyPath: kp]
        let new: Bool
        switch raw.lowercased() {
        case "true", "yes", "on", "1", "y", "show", "enable", "enabled": new = true
        case "false", "no", "off", "0", "n", "hide", "disable", "disabled": new = false
        case "toggle", "flip": new = !old
        case "default": new = Self.default[keyPath: kp]
        default:
            throw GraphSettingsError("\(key) needs true or false (yes/no, on/off, toggle), not \"\(raw)\".")
        }
        self[keyPath: kp] = new
        return Self.describe(key, String(old), String(new))
    }

    private mutating func setNumber(_ kp: WritableKeyPath<GraphViewSettings, Double>, _ key: String, _ raw: String,
                                    _ range: ClosedRange<Double>) throws -> String {
        let wanted: Double
        if Self.isDefaultWord(raw) {
            wanted = Self.default[keyPath: kp]
        } else if let d = Self.parseNumber(raw) {
            wanted = d
        } else {
            throw GraphSettingsError("\(key) needs a number from \(Self.format(range.lowerBound)) to \(Self.format(range.upperBound)), not \"\(raw)\".")
        }
        let old = self[keyPath: kp]
        let new = wanted.clamped(to: range)
        self[keyPath: kp] = new
        return Self.describe(key, Self.format(old), Self.format(new), note: Self.clampNote(wanted, new, range: range))
    }

    private static func isDefaultWord(_ raw: String) -> Bool { raw.lowercased() == "default" }

    private static func parseNumber(_ raw: String) -> Double? {
        guard let d = Double(raw), d.isFinite else { return nil }
        return d
    }

    private static func clampNote(_ wanted: Double, _ got: Double, range: ClosedRange<Double>) -> String? {
        if wanted > range.upperBound && got == range.upperBound { return "max \(format(range.upperBound))" }
        if wanted < range.lowerBound && got == range.lowerBound { return "min \(format(range.lowerBound))" }
        return nil
    }

    private static func describe(_ key: String, _ old: String, _ new: String, note: String? = nil) -> String {
        let base = old == new ? "\(key) already \(new)" : "\(key) \(old) → \(new)"
        return note.map { "\(base) (\($0))" } ?? base
    }

    /// Short number text: 260, 0.7, 0.045.
    static func format(_ d: Double) -> String {
        let r = (d * 1000).rounded() / 1000
        if r == r.rounded(), abs(r) < 1e12 { return String(Int(r)) }
        return String(r)
    }
}

/// A rejected `GraphViewSettings.set` call.
public struct GraphSettingsError: Error, LocalizedError, Sendable {
    public var message: String

    public init(_ message: String) { self.message = message }

    public var errorDescription: String? { message }
}

extension Comparable {
    fileprivate func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
