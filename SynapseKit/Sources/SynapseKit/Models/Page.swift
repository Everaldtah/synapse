import Foundation

public enum PageKind: String, Codable, Sendable {
    /// An ordinary document.
    case page
    /// A database: its rows are pages whose parent is this page.
    case database
    /// A database row. Opens as a page with a property header.
    case row

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PageKind(rawValue: raw) ?? .page
    }
}

public enum PageFont: String, Codable, CaseIterable, Sendable {
    case standard, serif, mono

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PageFont(rawValue: raw) ?? .standard
    }

    public var title: String {
        switch self {
        case .standard: return "Default"
        case .serif: return "Serif"
        case .mono: return "Mono"
        }
    }
}

public struct Cover: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case gradient, color, image }

    public var kind: Kind
    /// Gradient index, tint name, or image `asset:<name>` / `https://` URL.
    public var value: String
    /// Vertical focus of an image cover, 0 (top) … 1 (bottom).
    public var offset: Double

    public init(kind: Kind, value: String, offset: Double = 0.5) {
        self.kind = kind
        self.value = value
        self.offset = offset
    }

    public static let gradientCount = 8

    public static func randomGradient() -> Cover {
        Cover(kind: .gradient, value: String(Int.random(in: 0..<gradientCount)))
    }
}

public struct Comment: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    /// The block the comment is attached to (nil = the whole page).
    public var blockID: UUID?
    /// The comment this one replies to.
    public var parentID: UUID?
    public var author: String
    public var text: String
    public var createdAt: Date
    public var resolved: Bool

    public init(id: UUID = UUID(), blockID: UUID? = nil, parentID: UUID? = nil, author: String = "You",
                text: String, createdAt: Date = Date(), resolved: Bool = false) {
        self.id = id
        self.blockID = blockID
        self.parentID = parentID
        self.author = author
        self.text = text
        self.createdAt = createdAt
        self.resolved = resolved
    }
}

/// A page, a database, or a database row.
public struct Page: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var kind: PageKind
    public var title: String
    /// Emoji ("" = none).
    public var icon: String
    public var cover: Cover?
    public var parentID: UUID?
    /// Position among siblings.
    public var order: Double
    public var blocks: [Block]
    /// Row values keyed by property id.
    public var properties: [String: PropertyValue]
    /// Databases only.
    public var schema: DatabaseSchema?
    public var views: [DatabaseView]
    public var createdAt: Date
    public var updatedAt: Date
    public var lastOpenedAt: Date?
    public var isFavorite: Bool
    public var trashedAt: Date?
    public var fullWidth: Bool
    public var smallText: Bool
    public var font: PageFont
    public var locked: Bool
    /// Other names `[[links]]` resolve to this page by.
    public var aliases: [String]
    public var comments: [Comment]
    /// `yyyy-MM-dd` for daily notes.
    public var dailyDate: String?
    /// A template inside a database (used for new rows) or the template gallery.
    public var isTemplate: Bool
    /// A database shown inline inside its parent page rather than as a full page.
    public var isInline: Bool

    public init(id: UUID = UUID(), kind: PageKind = .page, title: String = "", icon: String = "",
                cover: Cover? = nil, parentID: UUID? = nil, order: Double = 0, blocks: [Block] = [],
                properties: [String: PropertyValue] = [:], schema: DatabaseSchema? = nil, views: [DatabaseView] = [],
                createdAt: Date = Date(), updatedAt: Date = Date(), isFavorite: Bool = false,
                dailyDate: String? = nil, isInline: Bool = false) {
        self.id = id
        self.kind = kind
        self.title = title
        self.icon = icon
        self.cover = cover
        self.parentID = parentID
        self.order = order
        self.blocks = blocks
        self.properties = properties
        self.schema = schema
        self.views = views
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastOpenedAt = nil
        self.isFavorite = isFavorite
        self.trashedAt = nil
        self.fullWidth = false
        self.smallText = false
        self.font = .standard
        self.locked = false
        self.aliases = []
        self.comments = []
        self.dailyDate = dailyDate
        self.isTemplate = false
        self.isInline = isInline
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID())
        kind = c.value(.kind, .page)
        title = c.value(.title, "")
        icon = c.value(.icon, "")
        cover = c.value(.cover, nil)
        parentID = c.value(.parentID, nil)
        order = c.value(.order, 0)
        blocks = c.value(.blocks, [])
        properties = c.value(.properties, [:])
        schema = c.value(.schema, nil)
        views = c.value(.views, [])
        createdAt = c.value(.createdAt, Date())
        updatedAt = c.value(.updatedAt, createdAt)
        lastOpenedAt = c.value(.lastOpenedAt, nil)
        isFavorite = c.value(.isFavorite, false)
        trashedAt = c.value(.trashedAt, nil)
        fullWidth = c.value(.fullWidth, false)
        smallText = c.value(.smallText, false)
        font = c.value(.font, .standard)
        locked = c.value(.locked, false)
        aliases = c.value(.aliases, [])
        comments = c.value(.comments, [])
        dailyDate = c.value(.dailyDate, nil)
        isTemplate = c.value(.isTemplate, false)
        isInline = c.value(.isInline, false)
    }

    public var isTrashed: Bool { trashedAt != nil }

    public var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Untitled" : t
    }

    /// The icon to show: the page's emoji, or a default by kind.
    public var displayIcon: String { icon }

    /// Text of the whole page, for search and AI context.
    public var plainText: String {
        blocks.map(\.plainText).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// A short preview of the first lines.
    public func excerpt(maxLength: Int = 160) -> String {
        var out = ""
        for b in blocks where b.type != .divider {
            let t = b.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { continue }
            if !out.isEmpty { out += " · " }
            out += t
            if out.count >= maxLength { break }
        }
        return out.count > maxLength ? String(out.prefix(maxLength)) + "…" : out
    }

    /// Headings, for the table of contents and `[[Page#Heading]]` links.
    public var headings: [Block] { blocks.filter { $0.type.isHeading && !$0.text.isEmpty } }

    /// The first image in the page (gallery card previews).
    public var firstImageURL: String? { blocks.first { $0.type == .image && !$0.url.isEmpty }?.url }

    public var tags: Set<String> {
        var tags = Set<String>()
        for b in blocks {
            for s in b.markdownSources {
                for t in InlineMarkdown.tokens(in: s) {
                    if case .tag(let name) = t.kind { tags.insert(name.lowercased()) }
                }
            }
        }
        return tags
    }
}
