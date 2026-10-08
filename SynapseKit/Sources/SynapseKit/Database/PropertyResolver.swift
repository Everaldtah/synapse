import Foundation

/// A property's value after computing formulas, rollups and timestamps.
public enum ResolvedValue: Hashable, Sendable {
    case empty
    case text(String)
    case number(Double)
    case bool(Bool)
    case date(DateValue)
    case options([SelectOption])
    case pages([UUID])
    case strings([String])
    case list([ResolvedValue])

    public var isEmpty: Bool {
        switch self {
        case .empty: return true
        case .text(let s): return s.isEmpty
        case .options(let o): return o.isEmpty
        case .pages(let p): return p.isEmpty
        case .strings(let s): return s.isEmpty
        case .list(let l): return l.isEmpty || l.allSatisfy(\.isEmpty)
        case .number(let n): return n.isNaN
        default: return false
        }
    }

    public var numberValue: Double? {
        switch self {
        case .number(let n): return n
        case .bool(let b): return b ? 1 : 0
        case .text(let s): return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    public var dateValue: Date? {
        if case .date(let d) = self { return d.start }
        return nil
    }
}

/// Reads a row's properties, computing formulas and rollups.
public enum PropertyResolver {

    public static func resolve(_ row: Page, _ prop: PropertyDefinition, schema: DatabaseSchema, in ws: Workspace, depth: Int = 0) -> ResolvedValue {
        switch prop.type {
        case .title:
            return .text(row.title)
        case .createdTime:
            return .date(DateValue(start: row.createdAt, includeTime: true))
        case .lastEditedTime:
            return .date(DateValue(start: row.updatedAt, includeTime: true))
        case .uniqueID:
            if case .number(let n)? = row.properties[prop.id] {
                return .text((prop.idPrefix.isEmpty ? "" : prop.idPrefix + "-") + String(Int(n)))
            }
            return .empty
        case .formula:
            guard depth < 8, !prop.formula.trimmingCharacters(in: .whitespaces).isEmpty else { return .empty }
            do {
                let expr = try FormulaParser.parse(prop.formula)
                let ctx = FormulaContext(lookup: { name in
                    guard let p = schema.property(named: name) ?? schema.property(id: name) else {
                        throw FormulaError("No property named \"\(name)\"")
                    }
                    return FormulaValue(resolve(row, p, schema: schema, in: ws, depth: depth + 1), property: p)
                })
                return try FormulaEvaluator.evaluate(expr, ctx).resolved
            } catch let e as FormulaError {
                return .text("⚠︎ " + e.message)
            } catch {
                return .text("⚠︎ Error")
            }
        case .rollup:
            return rollup(row, prop, schema: schema, in: ws, depth: depth)
        default:
            guard let v = row.properties[prop.id] else { return prop.type == .checkbox ? .bool(false) : .empty }
            switch v {
            case .text(let s), .url(let s), .email(let s), .phone(let s): return s.isEmpty ? .empty : .text(s)
            case .number(let n): return .number(n)
            case .select(let id): return prop.option(id: id).map { .options([$0]) } ?? .empty
            case .multiSelect(let ids): return .options(ids.compactMap { prop.option(id: $0) })
            case .date(let d): return .date(d)
            case .checkbox(let b): return .bool(b)
            case .relation(let ids): return .pages(ids.filter { ws[$0]?.isTrashed == false })
            case .people(let p), .files(let p): return .strings(p)
            }
        }
    }

    static func rollup(_ row: Page, _ prop: PropertyDefinition, schema: DatabaseSchema, in ws: Workspace, depth: Int) -> ResolvedValue {
        guard depth < 8, let cfg = prop.rollup, let relProp = schema.property(id: cfg.relationPropertyID),
              let targetDB = relProp.relation.flatMap({ ws[$0.databaseID] }), let targetSchema = targetDB.schema,
              let target = targetSchema.property(id: cfg.targetPropertyID) else { return .empty }
        var ids: [UUID] = []
        if case .relation(let r)? = row.properties[relProp.id] { ids = r }
        let related = ids.compactMap { ws[$0] }.filter { !$0.isTrashed }
        let values = related.map { resolve($0, target, schema: targetSchema, in: ws, depth: depth + 1) }
        let flat: [ResolvedValue] = values.flatMap { v -> [ResolvedValue] in
            switch v {
            case .options(let o): return o.map { .options([$0]) }
            case .list(let l): return l
            default: return [v]
            }
        }
        let total = Double(related.count)
        let nonEmpty = flat.filter { !$0.isEmpty }
        let numbers = flat.compactMap(\.numberValue)
        let dates = flat.compactMap(\.dateValue)
        let checks = values.map { if case .bool(true) = $0 { return true } else { return false } }
        switch cfg.function {
        case .showOriginal: return .list(values)
        case .count: return .number(total)
        case .countValues: return .number(Double(nonEmpty.count))
        case .countUnique: return .number(Double(Set(nonEmpty.map { displayText($0, target, in: ws) }).count))
        case .countEmpty: return .number(Double(values.filter(\.isEmpty).count))
        case .countNotEmpty: return .number(Double(values.filter { !$0.isEmpty }.count))
        case .percentEmpty: return total == 0 ? .empty : .text(percent(Double(values.filter(\.isEmpty).count) / total))
        case .percentNotEmpty: return total == 0 ? .empty : .text(percent(Double(values.filter { !$0.isEmpty }.count) / total))
        case .sum: return .number(numbers.reduce(0, +))
        case .average: return numbers.isEmpty ? .empty : .number(numbers.reduce(0, +) / Double(numbers.count))
        case .median:
            guard !numbers.isEmpty else { return .empty }
            let s = numbers.sorted()
            return .number(s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2)
        case .min: return numbers.min().map { .number($0) } ?? .empty
        case .max: return numbers.max().map { .number($0) } ?? .empty
        case .range: return numbers.isEmpty ? .empty : .number(numbers.max()! - numbers.min()!)
        case .earliest: return dates.min().map { .date(DateValue(start: $0)) } ?? .empty
        case .latest: return dates.max().map { .date(DateValue(start: $0)) } ?? .empty
        case .checked: return .number(Double(checks.filter { $0 }.count))
        case .unchecked: return .number(Double(checks.filter { !$0 }.count))
        case .percentChecked: return total == 0 ? .empty : .text(percent(Double(checks.filter { $0 }.count) / total))
        }
    }

    static func percent(_ x: Double) -> String {
        let v = (x * 1000).rounded() / 10
        return (v == v.rounded() ? String(Int(v)) : String(v)) + "%"
    }

    // MARK: - Display

    public static func formatNumber(_ n: Double, _ format: NumberFormat) -> String {
        if n.isNaN { return "" }
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 0
        switch format {
        case .number:
            f.usesGroupingSeparator = false
            f.maximumFractionDigits = 6
            return f.string(from: NSNumber(value: n)) ?? String(n)
        case .commas:
            f.numberStyle = .decimal
            return f.string(from: NSNumber(value: n)) ?? String(n)
        case .percent:
            f.numberStyle = .decimal
            return (f.string(from: NSNumber(value: n * 100)) ?? String(n * 100)) + "%"
        default:
            f.numberStyle = .decimal
            f.minimumFractionDigits = n == n.rounded() ? 0 : 2
            let symbol: String
            switch format {
            case .dollar: symbol = "$"
            case .euro: symbol = "€"
            case .pound: symbol = "£"
            case .yen: symbol = "¥"
            case .rupee: symbol = "₹"
            case .won: symbol = "₩"
            case .franc: symbol = "CHF "
            default: symbol = ""
            }
            let body = f.string(from: NSNumber(value: abs(n))) ?? String(abs(n))
            return (n < 0 ? "-" : "") + symbol + body
        }
    }

    public static func formatDate(_ d: DateValue) -> String {
        var s = DateText.short(d.start, includeTime: d.includeTime)
        if let e = d.end { s += " → " + DateText.short(e, includeTime: d.includeTime) }
        return s
    }

    /// One-line text for a value (tables, exports, search).
    public static func displayText(_ v: ResolvedValue, _ prop: PropertyDefinition, in ws: Workspace) -> String {
        switch v {
        case .empty: return ""
        case .text(let s): return s
        case .number(let n): return formatNumber(n, prop.type == .number ? prop.numberFormat : .number)
        case .bool(let b): return prop.type == .checkbox ? (b ? "Yes" : "No") : (b ? "true" : "false")
        case .date(let d): return formatDate(d)
        case .options(let o): return o.map(\.name).joined(separator: ", ")
        case .pages(let ids): return ids.compactMap { ws[$0]?.displayTitle }.joined(separator: ", ")
        case .strings(let s): return s.joined(separator: ", ")
        case .list(let l): return l.map { displayText($0, prop, in: ws) }.filter { !$0.isEmpty }.joined(separator: ", ")
        }
    }
}
