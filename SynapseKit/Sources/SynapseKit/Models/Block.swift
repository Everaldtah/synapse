import Foundation

/// The kinds of block a page is made of (Notion's block set).
public enum BlockType: String, Codable, CaseIterable, Sendable {
    case paragraph, heading1, heading2, heading3
    case bulleted, numbered, todo, toggle
    case quote, callout, divider, code
    case image, bookmark, embed, file
    case equation, table
    case pageLink, childPage, childDatabase
    case tableOfContents, breadcrumb

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = BlockType(rawValue: raw) ?? .paragraph
    }

    /// Blocks whose content is edited as inline-Markdown text.
    public var isTextual: Bool {
        switch self {
        case .paragraph, .heading1, .heading2, .heading3, .bulleted, .numbered, .todo, .toggle,
             .quote, .callout, .code, .equation:
            return true
        default:
            return false
        }
    }

    public var isHeading: Bool { self == .heading1 || self == .heading2 || self == .heading3 }

    public var isListItem: Bool { self == .bulleted || self == .numbered || self == .todo || self == .toggle }

    /// Pressing Return in one of these keeps the same type for the new block (Notion behaviour).
    public var continuesOnReturn: Bool { isListItem }

    /// Can hide the blocks indented below it (toggles and toggle headings).
    public var canCollapse: Bool { self == .toggle || isHeading }

    public var title: String {
        switch self {
        case .paragraph: return "Text"
        case .heading1: return "Heading 1"
        case .heading2: return "Heading 2"
        case .heading3: return "Heading 3"
        case .bulleted: return "Bulleted list"
        case .numbered: return "Numbered list"
        case .todo: return "To-do list"
        case .toggle: return "Toggle list"
        case .quote: return "Quote"
        case .callout: return "Callout"
        case .divider: return "Divider"
        case .code: return "Code"
        case .image: return "Image"
        case .bookmark: return "Web bookmark"
        case .embed: return "Embed"
        case .file: return "File"
        case .equation: return "Block equation"
        case .table: return "Table"
        case .pageLink: return "Link to page"
        case .childPage: return "Page"
        case .childDatabase: return "Database"
        case .tableOfContents: return "Table of contents"
        case .breadcrumb: return "Breadcrumb"
        }
    }

    public var summary: String {
        switch self {
        case .paragraph: return "Just start writing with plain text."
        case .heading1: return "Big section heading."
        case .heading2: return "Medium section heading."
        case .heading3: return "Small section heading."
        case .bulleted: return "Create a simple bulleted list."
        case .numbered: return "Create a list with numbering."
        case .todo: return "Track tasks with a to-do list."
        case .toggle: return "Toggles can hide and show content inside."
        case .quote: return "Capture a quote."
        case .callout: return "Make writing stand out."
        case .divider: return "Visually divide blocks."
        case .code: return "Capture a code snippet."
        case .image: return "Upload or embed with a link."
        case .bookmark: return "Save a link as a visual bookmark."
        case .embed: return "Embed a web page or video."
        case .file: return "Link to a file."
        case .equation: return "Display a standalone math equation."
        case .table: return "Add a simple table."
        case .pageLink: return "Link to an existing page."
        case .childPage: return "Embed a sub-page inside this page."
        case .childDatabase: return "Add an inline database."
        case .tableOfContents: return "Show an outline of the page."
        case .breadcrumb: return "Show where this page lives."
        }
    }

    /// SF Symbol shown in menus.
    public var symbol: String {
        switch self {
        case .paragraph: return "textformat"
        case .heading1: return "textformat.size.larger"
        case .heading2: return "textformat.size"
        case .heading3: return "textformat.size.smaller"
        case .bulleted: return "list.bullet"
        case .numbered: return "list.number"
        case .todo: return "checklist"
        case .toggle: return "chevron.right.circle"
        case .quote: return "text.quote"
        case .callout: return "lightbulb"
        case .divider: return "minus"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .image: return "photo"
        case .bookmark: return "bookmark"
        case .embed: return "globe"
        case .file: return "paperclip"
        case .equation: return "function"
        case .table: return "tablecells"
        case .pageLink: return "arrow.up.right.square"
        case .childPage: return "doc"
        case .childDatabase: return "cylinder.split.1x2"
        case .tableOfContents: return "list.bullet.indent"
        case .breadcrumb: return "chevron.right.2"
        }
    }

    /// Extra words the slash menu matches on.
    public var keywords: [String] {
        switch self {
        case .paragraph: return ["text", "plain", "p"]
        case .heading1: return ["h1", "title", "#"]
        case .heading2: return ["h2", "subtitle", "##"]
        case .heading3: return ["h3", "###"]
        case .bulleted: return ["bullet", "ul", "list", "-"]
        case .numbered: return ["number", "ol", "ordered", "1."]
        case .todo: return ["todo", "task", "check", "checkbox", "[]"]
        case .toggle: return ["toggle", "collapse", "details", "fold"]
        case .quote: return ["quote", "blockquote", ">"]
        case .callout: return ["callout", "note", "info", "tip", "warning"]
        case .divider: return ["divider", "hr", "line", "---"]
        case .code: return ["code", "snippet", "```"]
        case .image: return ["image", "photo", "picture", "img"]
        case .bookmark: return ["bookmark", "link", "url", "web"]
        case .embed: return ["embed", "video", "youtube", "iframe"]
        case .file: return ["file", "attachment", "pdf"]
        case .equation: return ["equation", "math", "latex", "tex", "katex"]
        case .table: return ["table", "grid", "simple table"]
        case .pageLink: return ["link", "page", "mention", "[["]
        case .childPage: return ["page", "subpage", "new page"]
        case .childDatabase: return ["database", "db", "table", "board", "kanban", "inline"]
        case .tableOfContents: return ["toc", "contents", "outline"]
        case .breadcrumb: return ["breadcrumb", "path"]
        }
    }
}

/// Notion's ten colours, used for text, backgrounds, select options and tags.
public enum Tint: String, Codable, CaseIterable, Sendable {
    case none, gray, brown, orange, yellow, green, blue, purple, pink, red

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Tint(rawValue: raw) ?? .none
    }

    public var title: String { self == .none ? "Default" : rawValue.capitalized }

    /// A stable colour for a string (used for new select options and tags).
    public static func stable(for text: String) -> Tint {
        let palette: [Tint] = [.gray, .brown, .orange, .yellow, .green, .blue, .purple, .pink, .red]
        return palette[Int(StableHash.of(text.lowercased()) % UInt64(palette.count))]
    }
}

/// One block of a page. Pages are a flat list of blocks; nesting is the `indent` level.
public struct Block: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var type: BlockType
    /// Inline Markdown (`**bold**`, `[[Link]]`, `#tag` …). Code blocks hold raw code.
    public var text: String
    public var indent: Int
    public var checked: Bool
    public var collapsed: Bool
    public var textColor: Tint
    public var background: Tint
    /// Code block language.
    public var language: String
    /// Image / bookmark / embed / file target: an `https://` URL or `asset:<file name>`.
    public var url: String
    public var caption: String
    /// Callout emoji.
    public var icon: String
    /// Target page for link / sub-page / database blocks.
    public var pageID: UUID?
    /// Database view shown by a `childDatabase` block (nil = the database's first view).
    public var viewID: UUID?
    /// Simple table cells, row-major. Cells hold inline Markdown.
    public var table: [[String]]
    public var headerRow: Bool
    public var headerColumn: Bool

    public init(id: UUID = UUID(), type: BlockType = .paragraph, text: String = "", indent: Int = 0,
                checked: Bool = false, collapsed: Bool = false, textColor: Tint = .none, background: Tint = .none,
                language: String = "", url: String = "", caption: String = "", icon: String = "",
                pageID: UUID? = nil, viewID: UUID? = nil, table: [[String]] = [], headerRow: Bool = true,
                headerColumn: Bool = false) {
        self.id = id
        self.type = type
        self.text = text
        self.indent = indent
        self.checked = checked
        self.collapsed = collapsed
        self.textColor = textColor
        self.background = background
        self.language = language
        self.url = url
        self.caption = caption
        self.icon = icon
        self.pageID = pageID
        self.viewID = viewID
        self.table = table
        self.headerRow = headerRow
        self.headerColumn = headerColumn
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID())
        type = c.value(.type, .paragraph)
        text = c.value(.text, "")
        indent = c.value(.indent, 0)
        checked = c.value(.checked, false)
        collapsed = c.value(.collapsed, false)
        textColor = c.value(.textColor, .none)
        background = c.value(.background, .none)
        language = c.value(.language, "")
        url = c.value(.url, "")
        caption = c.value(.caption, "")
        icon = c.value(.icon, "")
        pageID = c.value(.pageID, nil)
        viewID = c.value(.viewID, nil)
        table = c.value(.table, [])
        headerRow = c.value(.headerRow, true)
        headerColumn = c.value(.headerColumn, false)
    }

    /// A new block that continues this one when Return is pressed.
    public func continuation(text: String = "") -> Block {
        var next = Block(type: type.continuesOnReturn ? type : .paragraph, text: text, indent: indent)
        // Return on an open toggle starts its first child (Notion behaviour).
        if type == .toggle && !collapsed { next.indent = indent + 1; next.type = .paragraph }
        return next
    }

    /// Plain text with Markdown markers removed (search, titles, previews).
    public var plainText: String {
        switch type {
        case .code, .equation: return text
        case .table: return table.map { $0.map(InlineMarkdown.plainText).joined(separator: " ") }.joined(separator: "\n")
        case .image, .bookmark, .embed, .file: return caption.isEmpty ? url : caption
        default: return InlineMarkdown.plainText(text)
        }
    }

    /// Every inline-Markdown string in the block (text and table cells).
    public var markdownSources: [String] {
        switch type {
        case .code, .equation, .divider: return []
        case .table: return table.flatMap { $0 }
        case .image, .bookmark, .embed, .file: return caption.isEmpty ? [] : [caption]
        default: return text.isEmpty ? [] : [text]
        }
    }
}

extension KeyedDecodingContainer {
    /// Decode a value if present and well-formed, else fall back. Keeps old and future files loading.
    func value<T: Decodable>(_ key: Key, _ fallback: @autoclosure () -> T) -> T {
        if let v = try? decodeIfPresent(T.self, forKey: key) { return v }
        return fallback()
    }
}

/// FNV-1a: a hash that is the same on every launch and platform (Swift's Hasher is seeded per process).
public enum StableHash {
    public static func of(_ text: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in text.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return h
    }
}
