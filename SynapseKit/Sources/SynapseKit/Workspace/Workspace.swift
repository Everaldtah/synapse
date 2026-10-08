import Foundation

/// All pages of a workspace and the operations on them. A value type: the app's store owns one.
public struct Workspace: Codable, Sendable {
    public var pages: [UUID: Page]
    public var name: String

    public init(pages: [UUID: Page] = [:], name: String = "My Workspace") {
        self.pages = pages
        self.name = name
    }

    public subscript(id: UUID) -> Page? {
        get { pages[id] }
        set { pages[id] = newValue }
    }

    // MARK: - Queries

    public var livePages: [Page] { pages.values.filter { !$0.isTrashed } }

    /// Children shown in the page tree (pages and databases, not rows).
    public func children(of parentID: UUID?, includeRows: Bool = false) -> [Page] {
        pages.values
            .filter { $0.parentID == parentID && !$0.isTrashed && !$0.isTemplate && (includeRows || $0.kind != .row) }
            .sorted { ($0.order, $0.createdAt) < ($1.order, $1.createdAt) }
    }

    public func hasChildren(_ id: UUID) -> Bool {
        pages.values.contains { $0.parentID == id && !$0.isTrashed && !$0.isTemplate && $0.kind != .row }
    }

    /// Rows of a database, in creation order.
    public func rows(of databaseID: UUID) -> [Page] {
        pages.values
            .filter { $0.parentID == databaseID && $0.kind == .row && !$0.isTrashed && !$0.isTemplate }
            .sorted { ($0.order, $0.createdAt) < ($1.order, $1.createdAt) }
    }

    public func templates(of databaseID: UUID) -> [Page] {
        pages.values.filter { $0.parentID == databaseID && $0.isTemplate && !$0.isTrashed }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public var databases: [Page] {
        livePages.filter { $0.kind == .database }.sorted { $0.displayTitle.lowercased() < $1.displayTitle.lowercased() }
    }

    public var favorites: [Page] {
        livePages.filter(\.isFavorite).sorted { $0.displayTitle.lowercased() < $1.displayTitle.lowercased() }
    }

    public func recent(limit: Int = 12) -> [Page] {
        livePages.filter { !$0.isTemplate }
            .sorted { ($0.lastOpenedAt ?? $0.updatedAt) > ($1.lastOpenedAt ?? $1.updatedAt) }
            .prefix(limit).map { $0 }
    }

    public var trash: [Page] {
        // Only the top of each trashed subtree.
        pages.values.filter { p in
            guard let t = p.trashedAt else { return false }
            if let parent = p.parentID, let pp = pages[parent], pp.trashedAt == t { return false }
            return true
        }.sorted { ($0.trashedAt ?? .distantPast) > ($1.trashedAt ?? .distantPast) }
    }

    /// Ancestors from the root down to (excluding) the page.
    public func ancestors(of id: UUID) -> [Page] {
        var out: [Page] = []
        var seen = Set<UUID>()
        var cur = pages[id]?.parentID
        while let c = cur, let p = pages[c], !seen.contains(c) {
            out.insert(p, at: 0)
            seen.insert(c)
            cur = p.parentID
        }
        return out
    }

    public func descendants(of id: UUID) -> [Page] {
        var out: [Page] = []
        var stack = [id]
        var byParent: [UUID: [Page]] = [:]
        for p in pages.values { if let pid = p.parentID { byParent[pid, default: []].append(p) } }
        while let cur = stack.popLast() {
            for child in byParent[cur] ?? [] {
                out.append(child)
                stack.append(child.id)
            }
        }
        return out
    }

    public func isDescendant(_ id: UUID, of ancestor: UUID) -> Bool {
        ancestors(of: id).contains { $0.id == ancestor }
    }

    // MARK: - Creating

    private func nextOrder(in parentID: UUID?) -> Double {
        (pages.values.filter { $0.parentID == parentID }.map(\.order).max() ?? 0) + 1
    }

    @discardableResult
    public mutating func createPage(title: String = "", icon: String = "", parentID: UUID? = nil,
                                    blocks: [Block] = [], kind: PageKind = .page) -> UUID {
        let page = Page(kind: kind, title: title, icon: icon, parentID: parentID, order: nextOrder(in: parentID),
                        blocks: blocks.isEmpty ? [Block()] : blocks)
        pages[page.id] = page
        return page.id
    }

    /// A new database with Notion's starter properties and a table view.
    @discardableResult
    public mutating func createDatabase(title: String = "", parentID: UUID? = nil, inline: Bool = false,
                                        schema: DatabaseSchema? = nil, views: [DatabaseView]? = nil, icon: String = "") -> UUID {
        let s = schema ?? DatabaseSchema(properties: [
            PropertyDefinition(id: PropertyDefinition.titleID, name: "Name", type: .title),
            PropertyDefinition(name: "Status", type: .status, options: PropertyDefinition.defaultStatusOptions()),
            PropertyDefinition(name: "Tags", type: .multiSelect),
        ])
        let page = Page(kind: .database, title: title, icon: icon, parentID: parentID, order: nextOrder(in: parentID),
                        blocks: [], schema: s, views: views ?? [DatabaseView(name: "Table", type: .table)], isInline: inline)
        pages[page.id] = page
        return page.id
    }

    /// A new row in a database (optionally from one of its templates).
    @discardableResult
    public mutating func createRow(in databaseID: UUID, title: String = "", properties: [String: PropertyValue] = [:],
                                   template: UUID? = nil) -> UUID? {
        guard var db = pages[databaseID], db.kind == .database else { return nil }
        var row = Page(kind: .row, title: title, parentID: databaseID, order: nextOrder(in: databaseID),
                       blocks: [Block()], properties: properties)
        if let tid = template, let t = pages[tid] {
            row.blocks = t.blocks.map { var b = $0; b.id = UUID(); return b }
            row.icon = t.icon
            for (k, v) in t.properties where row.properties[k] == nil { row.properties[k] = v }
            if row.title.isEmpty { row.title = t.title == "New template" ? "" : t.title }
        }
        if var schema = db.schema {
            for p in schema.properties where p.type == .uniqueID && row.properties[p.id] == nil {
                row.properties[p.id] = .number(Double(schema.nextUniqueNumber))
                schema.nextUniqueNumber += 1
            }
            db.schema = schema
            pages[databaseID] = db
        }
        pages[row.id] = row
        return row.id
    }

    // MARK: - Changing

    public mutating func touch(_ id: UUID) { pages[id]?.updatedAt = Date() }

    public mutating func rename(_ id: UUID, to title: String) {
        pages[id]?.title = title
        touch(id)
    }

    /// Move a page under a new parent (nil = top level). Refuses to move a page into itself.
    @discardableResult
    public mutating func move(_ id: UUID, to parentID: UUID?, before sibling: UUID? = nil) -> Bool {
        guard pages[id] != nil else { return false }
        if let p = parentID, p == id || isDescendant(p, of: id) { return false }
        if let p = parentID, pages[p]?.kind == .row, pages[id]?.kind == .row { return false }
        var order = nextOrder(in: parentID)
        if let s = sibling, let sp = pages[s], sp.parentID == parentID {
            let before = children(of: parentID).filter { $0.order < sp.order }.map(\.order).max() ?? (sp.order - 1)
            order = (before + sp.order) / 2
        }
        pages[id]?.parentID = parentID
        pages[id]?.order = order
        if pages[id]?.kind == .row, let p = parentID, pages[p]?.kind != .database { pages[id]?.kind = .page }
        touch(id)
        return true
    }

    /// Put `id` directly after `afterID` among its siblings.
    public mutating func reorder(_ id: UUID, after afterID: UUID) {
        guard let target = pages[afterID] else { return }
        let siblings = children(of: target.parentID, includeRows: target.kind == .row)
        let next = siblings.first { $0.order > target.order && $0.id != id }
        pages[id]?.parentID = target.parentID
        pages[id]?.order = next.map { (target.order + $0.order) / 2 } ?? target.order + 1
    }

    /// Move a page and its sub-pages to the trash.
    public mutating func trash(_ id: UUID) {
        let now = Date()
        for d in descendants(of: id) where pages[d.id]?.trashedAt == nil { pages[d.id]?.trashedAt = now }
        pages[id]?.trashedAt = now
        pages[id]?.isFavorite = false
    }

    /// Bring a page (and what was trashed with it) back. If its parent is gone, it returns to the top level.
    public mutating func restore(_ id: UUID) {
        guard let t = pages[id]?.trashedAt else { return }
        for d in descendants(of: id) where pages[d.id]?.trashedAt == t { pages[d.id]?.trashedAt = nil }
        pages[id]?.trashedAt = nil
        if let parent = pages[id]?.parentID, pages[parent] == nil || pages[parent]?.isTrashed == true {
            pages[id]?.parentID = nil
            if pages[id]?.kind == .row { pages[id]?.kind = .page }
        }
    }

    /// Delete a page and its sub-pages for good. Returns the removed ids.
    @discardableResult
    public mutating func deletePermanently(_ id: UUID) -> [UUID] {
        let ids = [id] + descendants(of: id).map(\.id)
        for i in ids { pages[i] = nil }
        return ids
    }

    @discardableResult
    public mutating func emptyTrash() -> [UUID] {
        let ids = pages.values.filter(\.isTrashed).map(\.id)
        for i in ids { pages[i] = nil }
        return ids
    }

    /// Deep copy of a page with its sub-pages and rows. Links between copied pages point at the copies.
    @discardableResult
    public mutating func duplicate(_ id: UUID) -> UUID? {
        guard let original = pages[id] else { return nil }
        let tree = [original] + descendants(of: id)
        var map: [UUID: UUID] = [:]
        for p in tree { map[p.id] = UUID() }
        let now = Date()
        for p in tree {
            var copy = p
            copy.id = map[p.id]!
            if let parent = p.parentID { copy.parentID = map[parent] ?? parent }
            copy.createdAt = now
            copy.updatedAt = now
            copy.isFavorite = false
            copy.lastOpenedAt = nil
            copy.blocks = p.blocks.map { b in
                var nb = b
                nb.id = UUID()
                if let target = b.pageID, let m = map[target] { nb.pageID = m }
                return nb
            }
            for (k, v) in p.properties {
                if case .relation(let ids) = v { copy.properties[k] = .relation(ids.map { map[$0] ?? $0 }) }
            }
            if p.id == id {
                copy.title = p.title.isEmpty ? "" : p.title + " (copy)"
                copy.order = p.order + 0.5
            }
            pages[copy.id] = copy
        }
        return map[id]
    }

    // MARK: - Database helpers

    public mutating func setProperty(_ rowID: UUID, _ propertyID: String, _ value: PropertyValue?) {
        guard var row = pages[rowID] else { return }
        let old = row.properties[propertyID]
        row.properties[propertyID] = value
        row.updatedAt = Date()
        pages[rowID] = row
        syncReverseRelation(rowID: rowID, propertyID: propertyID, old: old, new: value)
    }

    /// Keep two-way relations in step: adding B to A's relation adds A to B's reverse property.
    private mutating func syncReverseRelation(rowID: UUID, propertyID: String, old: PropertyValue?, new: PropertyValue?) {
        guard let row = pages[rowID], let dbID = row.parentID, let db = pages[dbID],
              let prop = db.schema?.property(id: propertyID), prop.type == .relation,
              let reverse = prop.relation?.reversePropertyID else { return }
        var oldIDs: Set<UUID> = []
        var newIDs: Set<UUID> = []
        if case .relation(let a)? = old { oldIDs = Set(a) }
        if case .relation(let b)? = new { newIDs = Set(b) }
        for added in newIDs.subtracting(oldIDs) {
            var ids: [UUID] = []
            if case .relation(let cur)? = pages[added]?.properties[reverse] { ids = cur }
            if !ids.contains(rowID) { ids.append(rowID) }
            pages[added]?.properties[reverse] = .relation(ids)
        }
        for removed in oldIDs.subtracting(newIDs) {
            if case .relation(let cur)? = pages[removed]?.properties[reverse] {
                pages[removed]?.properties[reverse] = .relation(cur.filter { $0 != rowID })
            }
        }
    }

    /// Add a relation property, optionally with its mirror on the other database.
    @discardableResult
    public mutating func addRelation(in databaseID: UUID, name: String, to targetID: UUID, twoWay: Bool) -> String? {
        guard pages[databaseID]?.schema != nil, pages[targetID]?.schema != nil else { return nil }
        var prop = PropertyDefinition(name: name, type: .relation, relation: RelationConfig(databaseID: targetID))
        if twoWay && targetID != databaseID {
            let back = PropertyDefinition(name: pages[databaseID]?.displayTitle ?? "Related", type: .relation,
                                          relation: RelationConfig(databaseID: databaseID, reversePropertyID: prop.id))
            prop.relation?.reversePropertyID = back.id
            pages[targetID]?.schema?.properties.append(back)
        }
        pages[databaseID]?.schema?.properties.append(prop)
        return prop.id
    }

    /// Delete a property from a database (and its values from the rows).
    public mutating func removeProperty(_ propertyID: String, from databaseID: UUID) {
        guard propertyID != PropertyDefinition.titleID else { return }
        pages[databaseID]?.schema?.properties.removeAll { $0.id == propertyID }
        for r in rows(of: databaseID) { pages[r.id]?.properties[propertyID] = nil }
        if var views = pages[databaseID]?.views {
            for i in views.indices {
                views[i].filters.removeAll { $0.propertyID == propertyID }
                views[i].sorts.removeAll { $0.propertyID == propertyID }
                if views[i].groupBy == propertyID { views[i].groupBy = nil }
                if views[i].dateProperty == propertyID { views[i].dateProperty = nil }
            }
            pages[databaseID]?.views = views
        }
    }

    /// Change a property's type, converting the values that can be converted (text ⇄ options, numbers, dates, checkboxes).
    public mutating func changePropertyType(_ propertyID: String, in databaseID: UUID, to type: PropertyType) {
        guard var schema = pages[databaseID]?.schema, var prop = schema.property(id: propertyID),
              prop.type != type, prop.type != .title, type != .title else { return }
        let old = prop
        prop.type = type
        if type == .status && prop.options.isEmpty { prop.options = PropertyDefinition.defaultStatusOptions() }
        if type == .status { for i in prop.options.indices where prop.options[i].group == nil { prop.options[i].group = .todo } }
        let rowIDs = rows(of: databaseID).map(\.id)
        // Build options from the existing text values first.
        if type.hasOptions {
            for id in rowIDs {
                for name in Workspace.texts(of: pages[id]?.properties[propertyID], old) where prop.option(named: name) == nil {
                    prop.options.append(SelectOption(name: name, group: type == .status ? .todo : nil))
                }
            }
        }
        for id in rowIDs {
            guard let v = pages[id]?.properties[propertyID] else { continue }
            let texts = Workspace.texts(of: v, old)
            var nv: PropertyValue?
            switch type {
            case .text: nv = texts.isEmpty ? nil : .text(texts.joined(separator: ", "))
            case .url: nv = texts.first.map { .url($0) }
            case .email: nv = texts.first.map { .email($0) }
            case .phone: nv = texts.first.map { .phone($0) }
            case .number:
                if case .number(let n) = v { nv = .number(n) } else { nv = texts.first.flatMap { Double($0.replacingOccurrences(of: ",", with: "")) }.map { .number($0) } }
            case .checkbox:
                if case .checkbox(let b) = v { nv = .checkbox(b) }
                else { nv = .checkbox(texts.first.map { ["yes", "true", "1", "x", "✓", "checked"].contains($0.lowercased()) } ?? false) }
            case .date:
                if case .date(let d) = v { nv = .date(d) } else { nv = texts.first.flatMap(DateText.parse).map { .date(DateValue(start: $0)) } }
            case .select, .status:
                nv = texts.first.flatMap { prop.option(named: $0) }.map { .select($0.id) }
            case .multiSelect:
                let ids = texts.compactMap { prop.option(named: $0)?.id }
                nv = ids.isEmpty ? nil : .multiSelect(ids)
            case .person: nv = texts.isEmpty ? nil : .people(texts)
            case .files: nv = texts.isEmpty ? nil : .files(texts)
            case .relation:
                if case .relation(let r) = v { nv = .relation(r) }
            default: nv = nil
            }
            pages[id]?.properties[propertyID] = nv
        }
        if type == .uniqueID {
            for id in rowIDs {
                pages[id]?.properties[propertyID] = .number(Double(schema.nextUniqueNumber))
                schema.nextUniqueNumber += 1
            }
        }
        schema.update(prop)
        pages[databaseID]?.schema = schema
    }

    /// The text form of a stored value, for type conversion.
    static func texts(of value: PropertyValue?, _ prop: PropertyDefinition) -> [String] {
        guard let value else { return [] }
        switch value {
        case .text(let s), .url(let s), .email(let s), .phone(let s):
            let parts = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return prop.type == .text && parts.count <= 1 ? (s.isEmpty ? [] : [s]) : parts
        case .number(let n): return [n == n.rounded() ? String(Int(n)) : String(n)]
        case .select(let id): return prop.option(id: id).map { [$0.name] } ?? []
        case .multiSelect(let ids): return ids.compactMap { prop.option(id: $0)?.name }
        case .date(let d): return [DateText.iso(d.start, includeTime: d.includeTime)]
        case .checkbox(let b): return [b ? "Yes" : "No"]
        case .people(let p), .files(let p): return p
        case .relation: return []
        }
    }

    // MARK: - Daily notes

    public static let dailyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// The daily note for a date, created (under a "Daily Notes" page) if missing.
    public mutating func dailyNote(for date: Date, template: [Block] = []) -> UUID {
        let key = Workspace.dailyFormatter.string(from: date)
        if let existing = livePages.first(where: { $0.dailyDate == key }) { return existing.id }
        let folderID: UUID
        if let folder = livePages.first(where: { $0.title == "Daily Notes" && $0.parentID == nil && $0.kind == .page }) {
            folderID = folder.id
        } else {
            folderID = createPage(title: "Daily Notes", icon: "🗓️", blocks: [Block(text: "One page per day. Tap **Today** on Home to open today's note.")])
        }
        let title = DateText.long(date)
        let id = createPage(title: title, icon: "📝", parentID: folderID,
                            blocks: template.isEmpty ? [Block(type: .heading3, text: "Notes"), Block()] : template)
        pages[id]?.dailyDate = key
        return id
    }

    // MARK: - Links

    /// Find the page a `[[link]]` target names: title or alias, case-insensitive.
    public func resolve(_ target: String) -> Page? {
        let key = Workspace.normalize(target)
        if key.isEmpty { return nil }
        if let id = UUID(uuidString: target), let p = pages[id] { return p }
        let live = livePages.filter { !$0.isTemplate }
        return live.first { Workspace.normalize($0.title) == key }
            ?? live.first { $0.aliases.contains { Workspace.normalize($0) == key } }
    }

    public static func normalize(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Rewrite `[[Old]]` links everywhere after a rename, keeping aliases, headings and embeds.
    public mutating func updateLinks(from oldTitle: String, to newTitle: String) -> Int {
        let old = Workspace.normalize(oldTitle)
        guard !old.isEmpty, !newTitle.isEmpty, old != Workspace.normalize(newTitle) else { return 0 }
        var changed = 0
        for (id, page) in pages {
            var p = page
            var touched = false
            for i in p.blocks.indices {
                let (t, n) = Workspace.relink(p.blocks[i].text, old: old, new: newTitle)
                if n > 0 { p.blocks[i].text = t; touched = true; changed += n }
                for r in p.blocks[i].table.indices {
                    for c in p.blocks[i].table[r].indices {
                        let (ct, cn) = Workspace.relink(p.blocks[i].table[r][c], old: old, new: newTitle)
                        if cn > 0 { p.blocks[i].table[r][c] = ct; touched = true; changed += cn }
                    }
                }
            }
            if touched { pages[id] = p }
        }
        return changed
    }

    static func relink(_ text: String, old: String, new: String) -> (String, Int) {
        guard text.contains("[[") else { return (text, 0) }
        var result = text as NSString
        var count = 0
        for t in InlineMarkdown.tokens(in: text).reversed() {
            guard case .wikiLink(var link) = t.kind, Workspace.normalize(link.target) == old else { continue }
            link.target = new
            result = result.replacingCharacters(in: t.range, with: link.markdown) as NSString
            count += 1
        }
        return (result as String, count)
    }
}

/// Human date strings shared by the app and the Markdown codec.
public enum DateText {
    public static func long(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE, d MMMM yyyy"
        return f.string(from: date)
    }

    public static func short(_ date: Date, includeTime: Bool = false) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = includeTime ? "d MMM yyyy HH:mm" : "d MMM yyyy"
        return f.string(from: date)
    }

    public static func iso(_ date: Date, includeTime: Bool = false) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = includeTime ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd"
        return f.string(from: date)
    }

    public static func parse(_ text: String) -> Date? {
        let s = text.trimmingCharacters(in: .whitespaces)
        for format in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd", "d MMM yyyy", "MMMM d, yyyy", "d MMMM yyyy"] {
            let f = DateFormatter()
            f.calendar = Calendar(identifier: .gregorian)
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}
