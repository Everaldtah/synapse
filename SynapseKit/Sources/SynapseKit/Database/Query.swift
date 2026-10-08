import Foundation

/// A group of rows on a board or in a grouped view.
public struct RowGroup: Identifiable, Hashable, Sendable {
    /// Option id, "true"/"false" for checkboxes, page id for relations, "" for "No value".
    public var id: String
    public var title: String
    public var color: Tint
    public var rows: [Page]
}

/// Filtering, sorting and grouping database rows for a view.
public enum DatabaseQuery {

    public static func rows(for view: DatabaseView, database: Page, in ws: Workspace, search: String = "", now: Date = Date()) -> [Page] {
        guard let schema = database.schema else { return [] }
        var rows = ws.rows(of: database.id)
        let rules = view.filters.filter { schema.property(id: $0.propertyID) != nil }
        if !rules.isEmpty {
            rows = rows.filter { row in
                let results = rules.map { matches(row, $0, schema: schema, in: ws, now: now) }
                return view.conjunction == .and ? results.allSatisfy { $0 } : results.contains(true)
            }
        }
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            rows = rows.filter { row in
                if row.title.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil { return true }
                for p in schema.properties where p.type != .title {
                    let t = PropertyResolver.displayText(PropertyResolver.resolve(row, p, schema: schema, in: ws), p, in: ws)
                    if t.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil { return true }
                }
                return false
            }
        }
        if !view.sorts.isEmpty {
            let keys = view.sorts.compactMap { s in schema.property(id: s.propertyID).map { (s, $0) } }
            var cache: [UUID: [ResolvedValue]] = [:]
            for row in rows { cache[row.id] = keys.map { PropertyResolver.resolve(row, $0.1, schema: schema, in: ws) } }
            rows.sort { a, b in
                for (i, key) in keys.enumerated() {
                    let c = compare(cache[a.id]![i], cache[b.id]![i], key.1)
                    if c != 0 { return key.0.ascending ? c < 0 : c > 0 }
                }
                return (a.order, a.createdAt) < (b.order, b.createdAt)
            }
        }
        return rows
    }

    // MARK: Filters

    public static func matches(_ row: Page, _ rule: FilterRule, schema: DatabaseSchema, in ws: Workspace, now: Date = Date()) -> Bool {
        guard let prop = schema.property(id: rule.propertyID) else { return true }
        let v = PropertyResolver.resolve(row, prop, schema: schema, in: ws)
        let needle = rule.value.trimmingCharacters(in: .whitespaces)
        let cal = Calendar.current

        switch rule.op {
        case .isEmpty: return v.isEmpty
        case .isNotEmpty: return !v.isEmpty
        case .isChecked: if case .bool(let b) = v { return b }; return false
        case .isNotChecked: if case .bool(let b) = v { return !b }; return true
        default: break
        }
        if needle.isEmpty && !rule.op.isUnary { return true }

        // Dates
        if let d = v.dateValue {
            let day = cal.startOfDay(for: d)
            let today = cal.startOfDay(for: now)
            let target = DateText.parse(needle).map { cal.startOfDay(for: $0) }
            switch rule.op {
            case .equals: return target.map { day == $0 } ?? false
            case .before: return target.map { day < $0 } ?? false
            case .after: return target.map { day > $0 } ?? false
            case .onOrBefore: return target.map { day <= $0 } ?? false
            case .onOrAfter: return target.map { day >= $0 } ?? false
            case .isToday: return day == today
            case .pastWeek: return day <= today && day >= cal.date(byAdding: .day, value: -7, to: today)!
            case .pastMonth: return day <= today && day >= cal.date(byAdding: .month, value: -1, to: today)!
            case .nextWeek: return day >= today && day <= cal.date(byAdding: .day, value: 7, to: today)!
            case .nextMonth: return day >= today && day <= cal.date(byAdding: .month, value: 1, to: today)!
            default: break
            }
        }
        if [.isToday, .pastWeek, .pastMonth, .nextWeek, .nextMonth].contains(rule.op) { return false }

        // Numbers
        if case .number(let n) = v, let x = Double(needle) {
            switch rule.op {
            case .equals: return n == x
            case .notEquals: return n != x
            case .greaterThan: return n > x
            case .lessThan: return n < x
            case .greaterOrEqual: return n >= x
            case .lessOrEqual: return n <= x
            default: break
            }
        }

        // Options: the rule value is an option id or name.
        if case .options(let opts) = v {
            let hit = opts.contains { $0.id == needle || $0.name.compare(needle, options: .caseInsensitive) == .orderedSame }
            switch rule.op {
            case .equals, .contains: return hit
            case .notEquals, .notContains: return !hit
            default: break
            }
        }
        if case .pages(let ids) = v {
            let hit = ids.contains { $0.uuidString == needle || ws[$0]?.title.range(of: needle, options: .caseInsensitive) != nil }
            switch rule.op {
            case .contains, .equals: return hit
            case .notContains, .notEquals: return !hit
            default: break
            }
        }

        let text = PropertyResolver.displayText(v, prop, in: ws)
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        switch rule.op {
        case .equals: return text.compare(needle, options: opts) == .orderedSame
        case .notEquals: return text.compare(needle, options: opts) != .orderedSame
        case .contains: return text.range(of: needle, options: opts) != nil
        case .notContains: return text.range(of: needle, options: opts) == nil
        case .startsWith: return text.range(of: needle, options: opts.union(.anchored)) != nil
        case .endsWith: return text.range(of: needle, options: opts.union([.anchored, .backwards])) != nil
        case .greaterThan: return (v.numberValue ?? .nan) > (Double(needle) ?? .nan)
        case .lessThan: return (v.numberValue ?? .nan) < (Double(needle) ?? .nan)
        case .greaterOrEqual: return (v.numberValue ?? .nan) >= (Double(needle) ?? .nan)
        case .lessOrEqual: return (v.numberValue ?? .nan) <= (Double(needle) ?? .nan)
        default: return true
        }
    }

    // MARK: Sorting

    /// -1, 0, 1. Empty values sort last.
    public static func compare(_ a: ResolvedValue, _ b: ResolvedValue, _ prop: PropertyDefinition) -> Int {
        if a.isEmpty && b.isEmpty { return 0 }
        if a.isEmpty { return 1 }
        if b.isEmpty { return -1 }
        switch (a, b) {
        case (.number(let x), .number(let y)): return x < y ? -1 : (x > y ? 1 : 0)
        case (.date(let x), .date(let y)): return x.start < y.start ? -1 : (x.start > y.start ? 1 : 0)
        case (.bool(let x), .bool(let y)): return x == y ? 0 : (x ? -1 : 1)
        case (.options(let x), .options(let y)):
            // Option order in the schema, like Notion.
            let ix = x.first.flatMap { o in prop.options.firstIndex { $0.id == o.id } } ?? Int.max
            let iy = y.first.flatMap { o in prop.options.firstIndex { $0.id == o.id } } ?? Int.max
            return ix < iy ? -1 : (ix > iy ? 1 : 0)
        default:
            let sx = String(describing: a), sy = String(describing: b)
            if case .text(let tx) = a, case .text(let ty) = b {
                let r = tx.compare(ty, options: [.caseInsensitive, .numeric, .diacriticInsensitive])
                return r == .orderedAscending ? -1 : (r == .orderedDescending ? 1 : 0)
            }
            return sx < sy ? -1 : (sx > sy ? 1 : 0)
        }
    }

    // MARK: Grouping

    /// Properties a view can group by.
    public static func groupable(_ schema: DatabaseSchema) -> [PropertyDefinition] {
        schema.properties.filter { [.select, .status, .multiSelect, .checkbox, .person, .relation].contains($0.type) }
    }

    public static func groups(_ rows: [Page], by prop: PropertyDefinition, schema: DatabaseSchema, in ws: Workspace, hideEmpty: Bool = false) -> [RowGroup] {
        var groups: [RowGroup] = []
        switch prop.type {
        case .select, .status, .multiSelect:
            var order = prop.options
            if prop.type == .status {
                order.sort { (StatusGroup.allCases.firstIndex(of: $0.group ?? .todo) ?? 0) < (StatusGroup.allCases.firstIndex(of: $1.group ?? .todo) ?? 0) }
            }
            groups.append(RowGroup(id: "", title: "No \(prop.name)", color: .none, rows: []))
            groups += order.map { RowGroup(id: $0.id, title: $0.name, color: $0.color, rows: []) }
            for row in rows {
                var ids: [String] = []
                switch row.properties[prop.id] {
                case .select(let id)?: ids = [id]
                case .multiSelect(let m)?: ids = m
                default: break
                }
                ids = ids.filter { id in groups.contains { $0.id == id } }
                if ids.isEmpty { groups[0].rows.append(row) }
                for id in ids { if let gi = groups.firstIndex(where: { $0.id == id }) { groups[gi].rows.append(row) } }
            }
        case .checkbox:
            groups = [RowGroup(id: "false", title: "Unchecked", color: .gray, rows: []),
                      RowGroup(id: "true", title: "Checked", color: .green, rows: [])]
            for row in rows {
                if case .checkbox(true)? = row.properties[prop.id] { groups[1].rows.append(row) } else { groups[0].rows.append(row) }
            }
        case .person:
            var byName: [String: [Page]] = [:]
            var none: [Page] = []
            for row in rows {
                if case .people(let p)? = row.properties[prop.id], !p.isEmpty { for n in p { byName[n, default: []].append(row) } }
                else { none.append(row) }
            }
            groups = [RowGroup(id: "", title: "No \(prop.name)", color: .none, rows: none)]
            groups += byName.keys.sorted().map { RowGroup(id: $0, title: $0, color: Tint.stable(for: $0), rows: byName[$0]!) }
        case .relation:
            var byPage: [UUID: [Page]] = [:]
            var none: [Page] = []
            for row in rows {
                if case .relation(let ids)? = row.properties[prop.id], !ids.isEmpty { for i in ids { byPage[i, default: []].append(row) } }
                else { none.append(row) }
            }
            groups = [RowGroup(id: "", title: "No \(prop.name)", color: .none, rows: none)]
            groups += byPage.keys.compactMap { id in ws[id].map { RowGroup(id: id.uuidString, title: $0.displayTitle, color: .none, rows: byPage[id]!) } }
                .sorted { $0.title < $1.title }
        default:
            groups = [RowGroup(id: "", title: "All", color: .none, rows: rows)]
        }
        if hideEmpty { groups.removeAll { $0.rows.isEmpty } }
        else if let first = groups.first, first.id == "", first.rows.isEmpty, groups.count > 1 { groups.removeFirst() }
        return groups
    }

    /// The value to store when a card is dropped into a group.
    public static func value(forGroup groupID: String, prop: PropertyDefinition, current: PropertyValue?) -> PropertyValue? {
        switch prop.type {
        case .select, .status: return groupID.isEmpty ? nil : .select(groupID)
        case .multiSelect:
            if groupID.isEmpty { return nil }
            var ids: [String] = []
            if case .multiSelect(let m)? = current { ids = m }
            return .multiSelect(ids.contains(groupID) ? ids : [groupID])
        case .checkbox: return .checkbox(groupID == "true")
        case .person: return groupID.isEmpty ? nil : .people([groupID])
        case .relation: return UUID(uuidString: groupID).map { .relation([$0]) }
        default: return current
        }
    }

    /// Row counts per group, for chart views.
    public static func chartData(rows: [Page], by prop: PropertyDefinition?, schema: DatabaseSchema, in ws: Workspace) -> [(label: String, count: Int, color: Tint)] {
        guard let prop else { return [("All", rows.count, .blue)] }
        if prop.type == .date || prop.type == .createdTime || prop.type == .lastEditedTime {
            var counts: [String: Int] = [:]
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM"
            for r in rows {
                if let d = PropertyResolver.resolve(r, prop, schema: schema, in: ws).dateValue { counts[f.string(from: d), default: 0] += 1 }
            }
            return counts.keys.sorted().map { ($0, counts[$0]!, .blue) }
        }
        if groupable(schema).contains(where: { $0.id == prop.id }) {
            return groups(rows, by: prop, schema: schema, in: ws, hideEmpty: true).map { ($0.title, $0.rows.count, $0.color == .none ? .gray : $0.color) }
        }
        var counts: [String: Int] = [:]
        for r in rows {
            let t = PropertyResolver.displayText(PropertyResolver.resolve(r, prop, schema: schema, in: ws), prop, in: ws)
            counts[t.isEmpty ? "Empty" : t, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }.prefix(12).map { ($0.key, $0.value, Tint.stable(for: $0.key)) }
    }
}
