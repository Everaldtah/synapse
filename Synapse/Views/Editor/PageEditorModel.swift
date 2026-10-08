import Foundation
import Observation
import SynapseKit

/// One block in the editor. `text` is kept apart from the rest so typing only re-renders its own row.
@MainActor
@Observable
final class BlockItem: Identifiable {
    let id: UUID
    /// Everything except the text (type, indent, colours…). `block.text` is stale; use `text`.
    var block: Block
    var text: String

    init(_ b: Block) {
        id = b.id
        block = b
        text = b.text
    }

    var full: Block {
        var b = block
        b.text = text
        return b
    }
}

struct FocusRequest: Equatable {
    var blockID: UUID
    var location: Int
    var length: Int = 0
    var token = UUID()
}

/// The "/" menu while it's open: the slash sits at `start` in the block's text.
struct SlashState: Equatable {
    var blockID: UUID
    var start: Int
    var query: String
}

/// The "[[" link picker while it's open: the query starts at `start` (just after "[[").
struct LinkState: Equatable {
    var blockID: UUID
    var start: Int
    var query: String
}

struct EditorAIRequest: Identifiable, Equatable {
    var id = UUID()
    var blockIDs: [UUID]
    var selectedText: String
    /// Set when the request is about a selection inside one block.
    var range: NSRange?
    var action: AIAction?
}

struct VisibleBlock: Identifiable {
    var id: UUID { item.id }
    let item: BlockItem
    let number: Int?
}

/// Editing state for one open page.
@MainActor
@Observable
final class PageEditorModel {
    let pageID: UUID
    private(set) var items: [BlockItem] = []
    var focusedID: UUID?
    var focusRequest: FocusRequest?
    var slash: SlashState?
    var link: LinkState?
    var actionsFor: UUID?
    var pagePickerFor: UUID?
    var aiRequest: EditorAIRequest?
    var commentsBlock: UUID?
    var showComments = false
    var scrollTarget: UUID?
    var readOnly = false

    @ObservationIgnored weak var store: WorkspaceStore?
    @ObservationIgnored var openPage: (UUID) -> Void = { _ in }
    @ObservationIgnored var selection = NSRange(location: 0, length: 0)
    @ObservationIgnored private var commitTask: Task<Void, Never>?
    @ObservationIgnored private var pendingCommit = false

    init(pageID: UUID, store: WorkspaceStore) {
        self.pageID = pageID
        self.store = store
        reload()
    }

    /// Re-read the page's blocks from the store (after an outside change).
    func reload() {
        // Never drop edits that haven't been saved yet.
        if pendingCommit { commit() }
        guard let page = store?.page(pageID) else { return }
        var blocks = page.blocks
        if blocks.isEmpty { blocks = [Block()] }
        let current = items.map(\.full)
        guard current != blocks else { return }
        // Keep existing items (and their text views) where ids match.
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        items = blocks.map { b in
            if let existing = byID[b.id] {
                if existing.block != b { existing.block = b }
                if existing.text != b.text { existing.text = b.text }
                return existing
            }
            return BlockItem(b)
        }
        readOnly = page.locked
    }

    func index(of id: UUID) -> Int? { items.firstIndex { $0.id == id } }
    func item(_ id: UUID) -> BlockItem? { items.first { $0.id == id } }

    // MARK: - Visible rows

    /// Blocks not hidden inside collapsed toggles/headings, with list numbers.
    var visible: [VisibleBlock] {
        var out: [VisibleBlock] = []
        var hideBelowIndent: Int?
        var hideHeadingLevel: Int?
        var counters: [Int: Int] = [:]
        for item in items {
            let b = item.block
            if let h = hideHeadingLevel {
                if b.type.isHeading, headingLevel(b.type) <= h { hideHeadingLevel = nil } else { continue }
            }
            if let t = hideBelowIndent {
                if b.indent > t { continue }
                hideBelowIndent = nil
            }
            var number: Int?
            if b.type == .numbered {
                let n = (counters[b.indent] ?? 0) + 1
                counters[b.indent] = n
                number = n
            } else {
                counters[b.indent] = nil
            }
            for k in counters.keys where k > b.indent && b.type != .numbered { counters[k] = nil }
            out.append(VisibleBlock(item: item, number: number))
            if b.collapsed {
                if b.type == .toggle { hideBelowIndent = b.indent }
                if b.type.isHeading { hideHeadingLevel = headingLevel(b.type) }
            }
        }
        return out
    }

    private func headingLevel(_ t: BlockType) -> Int {
        switch t {
        case .heading1: return 1
        case .heading2: return 2
        default: return 3
        }
    }

    // MARK: - Saving

    func scheduleCommit() {
        pendingCommit = true
        commitTask?.cancel()
        commitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            self?.commit()
        }
    }

    func commit() {
        commitTask?.cancel()
        pendingCommit = false
        let blocks = items.map(\.full)
        store?.update(pageID) { $0.blocks = blocks }
    }

    // MARK: - Text

    func setText(_ id: UUID, _ text: String) {
        guard let item = item(id), item.text != text else { return }
        item.text = text
        scheduleCommit()
    }

    func focus(_ id: UUID, at location: Int, length: Int = 0) {
        focusRequest = FocusRequest(blockID: id, location: location, length: length)
        focusedID = id
    }

    func focusEnd(_ id: UUID) {
        guard let item = item(id) else { return }
        focus(id, at: (item.text as NSString).length)
    }

    // MARK: - Structure

    @discardableResult
    func insert(_ block: Block, after id: UUID?, focus: Bool = true) -> UUID {
        let item = BlockItem(block)
        if let id, let i = index(of: id) {
            items.insert(item, at: i + 1)
        } else {
            items.append(item)
        }
        if focus && block.type.isTextual { self.focus(item.id, at: 0) }
        scheduleCommit()
        return item.id
    }

    /// Return pressed at `location` in a block.
    func split(_ id: UUID, at location: Int) {
        guard let i = index(of: id) else { return }
        let item = items[i]
        let ns = item.text as NSString
        let loc = min(max(0, location), ns.length)
        // Return on an empty list item ends the list (outdent first, like Notion).
        if ns.length == 0 && item.block.type.isListItem {
            if item.block.indent > 0 {
                item.block.indent -= 1
            } else {
                item.block.type = .paragraph
            }
            scheduleCommit()
            return
        }
        if ns.length == 0 && (item.block.type.isHeading || item.block.type == .quote || item.block.type == .callout) {
            item.block.type = .paragraph
            scheduleCommit()
            return
        }
        let before = ns.substring(to: loc)
        let after = ns.substring(from: loc)
        // Return at the very start of a non-empty block inserts an empty block above.
        if loc == 0 && ns.length > 0 {
            var above = Block(type: item.block.type.continuesOnReturn ? item.block.type : .paragraph, indent: item.block.indent)
            above.checked = false
            let newItem = BlockItem(above)
            items.insert(newItem, at: i)
            focus(id, at: 0)
            scheduleCommit()
            return
        }
        item.text = before
        var next = item.block.continuation(text: after)
        if item.block.type.isHeading { next.type = .paragraph }
        insert(next, after: id)
    }

    /// Backspace at the start of a block.
    func backspaceAtStart(_ id: UUID) {
        guard let i = index(of: id) else { return }
        let item = items[i]
        if item.block.type == .code || item.block.type == .equation {
            if item.text.isEmpty { item.block.type = .paragraph; scheduleCommit() }
            return
        }
        // First turn a styled block back into text, then outdent, then merge into the block above.
        if item.block.type != .paragraph {
            item.block.type = .paragraph
            scheduleCommit()
            return
        }
        if item.block.indent > 0 {
            item.block.indent -= 1
            scheduleCommit()
            return
        }
        guard i > 0 else { return }
        // Find the previous visible textual block.
        let visibleIDs = Set(visible.map(\.id))
        var j = i - 1
        while j >= 0 && !visibleIDs.contains(items[j].id) { j -= 1 }
        guard j >= 0 else { return }
        let prev = items[j]
        if !prev.block.type.isTextual {
            if item.text.isEmpty {
                items.remove(at: i)
                focusRequest = nil
                focusedID = nil
                scheduleCommit()
            }
            return
        }
        let joinAt = (prev.text as NSString).length
        prev.text += item.text
        focus(prev.id, at: joinAt)
        items.remove(at: i)
        scheduleCommit()
    }

    /// The block and the blocks nested under it.
    func subtreeRange(_ id: UUID) -> Range<Int>? {
        guard let i = index(of: id) else { return nil }
        let indent = items[i].block.indent
        var end = i + 1
        while end < items.count && items[end].block.indent > indent { end += 1 }
        // Collapsed headings own everything until the next heading of the same or higher level.
        if items[i].block.type.isHeading && items[i].block.collapsed {
            let level = headingLevel(items[i].block.type)
            end = i + 1
            while end < items.count && !(items[end].block.type.isHeading && headingLevel(items[end].block.type) <= level) { end += 1 }
        }
        return i..<end
    }

    func moveUp(_ id: UUID) {
        guard let r = subtreeRange(id), r.lowerBound > 0 else { return }
        let indent = items[r.lowerBound].block.indent
        // The previous sibling's start.
        var p = r.lowerBound - 1
        while p > 0 && items[p].block.indent > indent { p -= 1 }
        let moving = Array(items[r])
        items.removeSubrange(r)
        items.insert(contentsOf: moving, at: p)
        scheduleCommit()
    }

    func moveDown(_ id: UUID) {
        guard let r = subtreeRange(id), r.upperBound < items.count else { return }
        guard let nextRange = subtreeRange(items[r.upperBound].id) else { return }
        let moving = Array(items[r])
        let insertAt = nextRange.upperBound - moving.count
        items.removeSubrange(r)
        items.insert(contentsOf: moving, at: insertAt)
        scheduleCommit()
    }

    /// Drag & drop: put `id` (with its children) right after `targetID`.
    func move(_ id: UUID, after targetID: UUID) {
        guard id != targetID, let r = subtreeRange(id), let t = index(of: targetID), !r.contains(t) else { return }
        let moving = Array(items[r])
        items.removeSubrange(r)
        guard let newT = index(of: targetID) else { return }
        let target = items[newT]
        let delta = target.block.indent - moving[0].block.indent
        for m in moving { m.block.indent = max(0, m.block.indent + delta) }
        items.insert(contentsOf: moving, at: newT + 1)
        scheduleCommit()
    }

    func indent(_ id: UUID) {
        guard let i = index(of: id), i > 0 else { return }
        let maxIndent = items[i - 1].block.indent + 1
        guard items[i].block.indent < maxIndent, let r = subtreeRange(id) else { return }
        for k in r { items[k].block.indent += 1 }
        scheduleCommit()
    }

    func outdent(_ id: UUID) {
        guard let r = subtreeRange(id), items[r.lowerBound].block.indent > 0 else { return }
        for k in r { items[k].block.indent = max(0, items[k].block.indent - 1) }
        scheduleCommit()
    }

    func turnInto(_ id: UUID, _ type: BlockType) {
        guard let item = item(id) else { return }
        if type == .childPage || type == .childDatabase || type == .pageLink || !type.isTextual {
            // Non-text targets: insert a new block after instead of converting the text.
            add(type, after: id, replacingEmpty: item.text.isEmpty)
            return
        }
        item.block.type = type
        if type == .callout && item.block.icon.isEmpty { item.block.icon = "💡" }
        if type == .code { item.text = InlineMarkdown.plainText(item.text) }
        scheduleCommit()
        focusEnd(id)
    }

    /// Add a block of `type` after `id` (or replace `id` if it's an empty paragraph), doing the extra work
    /// some types need: a sub-page or database is created, a link opens the page picker.
    func add(_ type: BlockType, after id: UUID?, replacingEmpty: Bool = false) {
        var block = Block(type: type)
        if let id, let cur = item(id) { block.indent = cur.block.indent }
        switch type {
        case .callout: block.icon = "💡"
        case .table: block.table = [["", "", ""], ["", "", ""], ["", "", ""]]
        case .childPage:
            guard let s = store else { return }
            let child = s.newPage(parent: pageID)
            block.pageID = child
        case .childDatabase:
            guard let s = store else { return }
            let db = s.newDatabase(parent: pageID, title: "", inline: true)
            block.pageID = db
        default: break
        }
        let newID: UUID
        if replacingEmpty, let id, let i = index(of: id), items[i].text.isEmpty, items[i].block.type.isTextual {
            let item = BlockItem(block)
            items[i] = item
            newID = item.id
            if type.isTextual { focus(newID, at: 0) }
            scheduleCommit()
        } else {
            newID = insert(block, after: id, focus: type.isTextual)
        }
        if !type.isTextual {
            // Keep writing below the new block.
            let after = insert(Block(indent: block.indent), after: newID, focus: false)
            if type != .childPage && type != .pageLink { focus(after, at: 0) }
        }
        if type == .pageLink { pagePickerFor = newID }
        if type == .childPage, let child = block.pageID {
            commit()
            openPage(child)
        }
    }

    func delete(_ id: UUID) {
        guard let i = index(of: id) else { return }
        let removed = items.remove(at: i)
        if items.isEmpty { items = [BlockItem(Block())] }
        if focusedID == removed.id {
            let target = items[max(0, i - 1)]
            if target.block.type.isTextual { focusEnd(target.id) } else { focusedID = nil }
        }
        scheduleCommit()
    }

    func duplicate(_ id: UUID) {
        guard let r = subtreeRange(id) else { return }
        let copies = items[r].map { item -> BlockItem in
            var b = item.full
            b.id = UUID()
            return BlockItem(b)
        }
        items.insert(contentsOf: copies, at: r.upperBound)
        scheduleCommit()
    }

    func update(_ id: UUID, _ change: (inout Block) -> Void) {
        guard let item = item(id) else { return }
        var b = item.full
        change(&b)
        let newText = b.text
        b.text = ""
        var old = item.block
        old.text = ""
        if b != old { item.block = b }
        if newText != item.text { item.text = newText }
        scheduleCommit()
    }

    func toggleChecked(_ id: UUID) {
        update(id) { $0.checked.toggle() }
        Haptics.tap()
    }

    func toggleCollapsed(_ id: UUID) { update(id) { $0.collapsed.toggle() } }

    // MARK: - Slash menu

    func applySlash(_ type: BlockType) {
        guard let s = slash, let item = item(s.blockID) else { slash = nil; return }
        // Remove "/query" from the text.
        let ns = item.text as NSString
        let len = min(ns.length - s.start, 1 + (s.query as NSString).length)
        if s.start >= 0, len > 0, s.start + len <= ns.length {
            item.text = ns.replacingCharacters(in: NSRange(location: s.start, length: len), with: "")
        }
        slash = nil
        if type.isTextual && type != .childPage {
            if item.text.isEmpty || item.block.type == .paragraph {
                turnInto(item.id, type)
            } else {
                add(type, after: item.id)
            }
        } else {
            add(type, after: item.id, replacingEmpty: item.text.isEmpty)
        }
    }

    // MARK: - Links

    /// Finish a `[[` link with a page title.
    func applyLink(title: String) {
        guard let l = link, let item = item(l.blockID) else { link = nil; return }
        let ns = item.text as NSString
        var end = l.start + (l.query as NSString).length
        end = min(end, ns.length)
        let hasClose = end + 2 <= ns.length && ns.substring(with: NSRange(location: end, length: 2)) == "]]"
        let replaceRange = NSRange(location: l.start, length: end - l.start + (hasClose ? 2 : 0))
        item.text = ns.replacingCharacters(in: replaceRange, with: title + "]]")
        link = nil
        focus(item.id, at: l.start + (title as NSString).length + 2)
        scheduleCommit()
    }

    // MARK: - AI results

    /// Insert Markdown (AI output) as blocks after `id`.
    func insertMarkdown(_ markdown: String, after id: UUID?) {
        let blocks = MarkdownCodec.parseBlocks(markdown)
        guard !blocks.isEmpty else { return }
        var anchor = id ?? items.last?.id
        let base = anchor.flatMap { item($0)?.block.indent } ?? 0
        for var b in blocks {
            b.indent += base
            anchor = insert(b, after: anchor, focus: false)
        }
        scheduleCommit()
    }

    /// Replace blocks with Markdown (AI rewrite).
    func replace(_ ids: [UUID], with markdown: String) {
        let blocks = MarkdownCodec.parseBlocks(markdown)
        guard let first = ids.first, let i = index(of: first) else { return }
        if ids.count == 1, blocks.count == 1, let item = item(first), item.block.type.isTextual {
            item.text = blocks[0].text
            if item.block.type == .paragraph && blocks[0].type != .paragraph { item.block.type = blocks[0].type }
            scheduleCommit()
            return
        }
        let indent = items[i].block.indent
        items.removeAll { ids.contains($0.id) }
        let newItems = blocks.map { b -> BlockItem in
            var nb = b
            nb.indent += indent
            return BlockItem(nb)
        }
        items.insert(contentsOf: newItems, at: min(i, items.count))
        if items.isEmpty { items = [BlockItem(Block())] }
        scheduleCommit()
    }

    /// Replace a text range inside one block (AI on a selection).
    func replaceText(in id: UUID, range: NSRange, with text: String) {
        guard let item = item(id) else { return }
        let ns = item.text as NSString
        guard range.location + range.length <= ns.length else { return }
        item.text = ns.replacingCharacters(in: range, with: text.trimmingCharacters(in: .whitespacesAndNewlines))
        scheduleCommit()
    }

    /// The page as Markdown (AI context).
    var markdown: String { MarkdownCodec.blocksToMarkdown(items.map(\.full), workspace: store?.workspace) }

    func markdown(of ids: [UUID]) -> String {
        MarkdownCodec.blocksToMarkdown(items.filter { ids.contains($0.id) }.map(\.full), workspace: store?.workspace)
    }

    /// A tap below the last block: focus the last empty paragraph or add one.
    func tapBelowContent() {
        guard !readOnly else { return }
        if let last = items.last, last.block.type == .paragraph, last.text.isEmpty {
            focus(last.id, at: 0)
        } else {
            insert(Block(), after: items.last?.id)
        }
    }
}
