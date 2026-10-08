import Foundation

/// Database property types (Notion's set, minus the multi-user ones).
public enum PropertyType: String, Codable, CaseIterable, Sendable {
    case title, text, number, select, multiSelect, status, date, person, files, checkbox
    case url, email, phone, formula, relation, rollup, createdTime, lastEditedTime, uniqueID

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PropertyType(rawValue: raw) ?? .text
    }

    public var title: String {
        switch self {
        case .title: return "Title"
        case .text: return "Text"
        case .number: return "Number"
        case .select: return "Select"
        case .multiSelect: return "Multi-select"
        case .status: return "Status"
        case .date: return "Date"
        case .person: return "Person"
        case .files: return "Files & media"
        case .checkbox: return "Checkbox"
        case .url: return "URL"
        case .email: return "Email"
        case .phone: return "Phone"
        case .formula: return "Formula"
        case .relation: return "Relation"
        case .rollup: return "Rollup"
        case .createdTime: return "Created time"
        case .lastEditedTime: return "Last edited time"
        case .uniqueID: return "ID"
        }
    }

    public var symbol: String {
        switch self {
        case .title: return "textformat"
        case .text: return "text.alignleft"
        case .number: return "number"
        case .select: return "chevron.down.circle"
        case .multiSelect: return "list.bullet.circle"
        case .status: return "circle.dashed"
        case .date: return "calendar"
        case .person: return "person"
        case .files: return "paperclip"
        case .checkbox: return "checkmark.square"
        case .url: return "link"
        case .email: return "at"
        case .phone: return "phone"
        case .formula: return "function"
        case .relation: return "arrow.up.right"
        case .rollup: return "magnifyingglass"
        case .createdTime: return "clock"
        case .lastEditedTime: return "clock.arrow.circlepath"
        case .uniqueID: return "number.square"
        }
    }

    /// Values computed by Synapse rather than typed by you.
    public var isComputed: Bool {
        switch self {
        case .formula, .rollup, .createdTime, .lastEditedTime, .uniqueID: return true
        default: return false
        }
    }

    /// Types the user can pick when adding a property.
    public static var creatable: [PropertyType] { allCases.filter { $0 != .title } }

    public var hasOptions: Bool { self == .select || self == .multiSelect || self == .status }
}

public enum NumberFormat: String, Codable, CaseIterable, Sendable {
    case number, commas, percent, dollar, euro, pound, yen, rupee, won, franc

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = NumberFormat(rawValue: raw) ?? .number
    }

    public var title: String {
        switch self {
        case .number: return "Number"
        case .commas: return "Number with commas"
        case .percent: return "Percent"
        case .dollar: return "US dollar"
        case .euro: return "Euro"
        case .pound: return "Pound"
        case .yen: return "Yen"
        case .rupee: return "Rupee"
        case .won: return "Won"
        case .franc: return "Franc"
        }
    }
}

public enum StatusGroup: String, Codable, CaseIterable, Sendable {
    case todo, inProgress, complete

    public var title: String {
        switch self {
        case .todo: return "To-do"
        case .inProgress: return "In progress"
        case .complete: return "Complete"
        }
    }
}

public struct SelectOption: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var color: Tint
    /// Status options belong to a group.
    public var group: StatusGroup?

    public init(id: String = ShortID.make(), name: String, color: Tint? = nil, group: StatusGroup? = nil) {
        self.id = id
        self.name = name
        self.color = color ?? Tint.stable(for: name)
        self.group = group
    }
}

public struct RelationConfig: Codable, Hashable, Sendable {
    public var databaseID: UUID
    /// The property on the other database that mirrors this one (two-way relation).
    public var reversePropertyID: String?

    public init(databaseID: UUID, reversePropertyID: String? = nil) {
        self.databaseID = databaseID
        self.reversePropertyID = reversePropertyID
    }
}

public enum RollupFunction: String, Codable, CaseIterable, Sendable {
    case showOriginal, count, countValues, countUnique, countEmpty, countNotEmpty
    case percentEmpty, percentNotEmpty, sum, average, median, min, max, range
    case earliest, latest, checked, unchecked, percentChecked

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RollupFunction(rawValue: raw) ?? .showOriginal
    }

    public var title: String {
        switch self {
        case .showOriginal: return "Show original"
        case .count: return "Count all"
        case .countValues: return "Count values"
        case .countUnique: return "Count unique values"
        case .countEmpty: return "Count empty"
        case .countNotEmpty: return "Count not empty"
        case .percentEmpty: return "Percent empty"
        case .percentNotEmpty: return "Percent not empty"
        case .sum: return "Sum"
        case .average: return "Average"
        case .median: return "Median"
        case .min: return "Min"
        case .max: return "Max"
        case .range: return "Range"
        case .earliest: return "Earliest date"
        case .latest: return "Latest date"
        case .checked: return "Checked"
        case .unchecked: return "Unchecked"
        case .percentChecked: return "Percent checked"
        }
    }
}

public struct RollupConfig: Codable, Hashable, Sendable {
    public var relationPropertyID: String
    public var targetPropertyID: String
    public var function: RollupFunction

    public init(relationPropertyID: String, targetPropertyID: String, function: RollupFunction = .showOriginal) {
        self.relationPropertyID = relationPropertyID
        self.targetPropertyID = targetPropertyID
        self.function = function
    }
}

/// One column of a database.
public struct PropertyDefinition: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var type: PropertyType
    public var options: [SelectOption]
    public var numberFormat: NumberFormat
    public var formula: String
    public var relation: RelationConfig?
    public var rollup: RollupConfig?
    public var includeTime: Bool
    public var idPrefix: String

    public static let titleID = "title"

    public init(id: String = ShortID.make(), name: String, type: PropertyType, options: [SelectOption] = [],
                numberFormat: NumberFormat = .number, formula: String = "", relation: RelationConfig? = nil,
                rollup: RollupConfig? = nil, includeTime: Bool = false, idPrefix: String = "") {
        self.id = id
        self.name = name
        self.type = type
        self.options = options
        self.numberFormat = numberFormat
        self.formula = formula
        self.relation = relation
        self.rollup = rollup
        self.includeTime = includeTime
        self.idPrefix = idPrefix
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, ShortID.make())
        name = c.value(.name, "Property")
        type = c.value(.type, .text)
        options = c.value(.options, [])
        numberFormat = c.value(.numberFormat, .number)
        formula = c.value(.formula, "")
        relation = c.value(.relation, nil)
        rollup = c.value(.rollup, nil)
        includeTime = c.value(.includeTime, false)
        idPrefix = c.value(.idPrefix, "")
    }

    public func option(id optionID: String) -> SelectOption? { options.first { $0.id == optionID } }

    public func option(named name: String) -> SelectOption? {
        options.first { $0.name.compare(name, options: [.caseInsensitive]) == .orderedSame }
    }

    /// Notion's default status options.
    public static func defaultStatusOptions() -> [SelectOption] {
        [SelectOption(name: "Not started", color: .gray, group: .todo),
         SelectOption(name: "In progress", color: .blue, group: .inProgress),
         SelectOption(name: "Done", color: .green, group: .complete)]
    }
}

public struct DatabaseSchema: Codable, Hashable, Sendable {
    public var properties: [PropertyDefinition]
    /// Next number handed out by `uniqueID` properties.
    public var nextUniqueNumber: Int

    public init(properties: [PropertyDefinition] = [], nextUniqueNumber: Int = 1) {
        var props = properties
        if !props.contains(where: { $0.type == .title }) {
            props.insert(PropertyDefinition(id: PropertyDefinition.titleID, name: "Name", type: .title), at: 0)
        }
        self.properties = props
        self.nextUniqueNumber = nextUniqueNumber
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(properties: c.value(.properties, []), nextUniqueNumber: c.value(.nextUniqueNumber, 1))
    }

    public var titleProperty: PropertyDefinition {
        properties.first { $0.type == .title } ?? PropertyDefinition(id: PropertyDefinition.titleID, name: "Name", type: .title)
    }

    public func property(id: String) -> PropertyDefinition? { properties.first { $0.id == id } }

    public func property(named name: String) -> PropertyDefinition? {
        properties.first { $0.name.compare(name, options: [.caseInsensitive]) == .orderedSame }
    }

    public mutating func update(_ property: PropertyDefinition) {
        if let i = properties.firstIndex(where: { $0.id == property.id }) { properties[i] = property }
    }
}

// MARK: - Views

public enum ViewType: String, Codable, CaseIterable, Sendable {
    case table, board, list, gallery, calendar, timeline, chart

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ViewType(rawValue: raw) ?? .table
    }

    public var title: String { rawValue.capitalized }

    public var symbol: String {
        switch self {
        case .table: return "tablecells"
        case .board: return "rectangle.split.3x1"
        case .list: return "list.bullet"
        case .gallery: return "square.grid.2x2"
        case .calendar: return "calendar"
        case .timeline: return "chart.bar.xaxis"
        case .chart: return "chart.pie"
        }
    }
}

public enum FilterOperator: String, Codable, CaseIterable, Sendable {
    case equals, notEquals, contains, notContains, startsWith, endsWith, isEmpty, isNotEmpty
    case greaterThan, lessThan, greaterOrEqual, lessOrEqual
    case before, after, onOrBefore, onOrAfter, isToday, pastWeek, pastMonth, nextWeek, nextMonth
    case isChecked, isNotChecked

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = FilterOperator(rawValue: raw) ?? .contains
    }

    public var title: String {
        switch self {
        case .equals: return "Is"
        case .notEquals: return "Is not"
        case .contains: return "Contains"
        case .notContains: return "Does not contain"
        case .startsWith: return "Starts with"
        case .endsWith: return "Ends with"
        case .isEmpty: return "Is empty"
        case .isNotEmpty: return "Is not empty"
        case .greaterThan: return ">"
        case .lessThan: return "<"
        case .greaterOrEqual: return "≥"
        case .lessOrEqual: return "≤"
        case .before: return "Is before"
        case .after: return "Is after"
        case .onOrBefore: return "Is on or before"
        case .onOrAfter: return "Is on or after"
        case .isToday: return "Is today"
        case .pastWeek: return "Within the past week"
        case .pastMonth: return "Within the past month"
        case .nextWeek: return "Within the next week"
        case .nextMonth: return "Within the next month"
        case .isChecked: return "Is checked"
        case .isNotChecked: return "Is not checked"
        }
    }

    /// Operators that need no value.
    public var isUnary: Bool {
        switch self {
        case .isEmpty, .isNotEmpty, .isToday, .pastWeek, .pastMonth, .nextWeek, .nextMonth, .isChecked, .isNotChecked:
            return true
        default:
            return false
        }
    }

    public static func operators(for type: PropertyType) -> [FilterOperator] {
        switch type {
        case .title, .text, .url, .email, .phone, .person, .files, .uniqueID:
            return [.contains, .notContains, .equals, .notEquals, .startsWith, .endsWith, .isEmpty, .isNotEmpty]
        case .number:
            return [.equals, .notEquals, .greaterThan, .lessThan, .greaterOrEqual, .lessOrEqual, .isEmpty, .isNotEmpty]
        case .select, .status:
            return [.equals, .notEquals, .isEmpty, .isNotEmpty]
        case .multiSelect, .relation:
            return [.contains, .notContains, .isEmpty, .isNotEmpty]
        case .date, .createdTime, .lastEditedTime:
            return [.equals, .before, .after, .onOrBefore, .onOrAfter, .isToday, .pastWeek, .pastMonth, .nextWeek, .nextMonth, .isEmpty, .isNotEmpty]
        case .checkbox:
            return [.isChecked, .isNotChecked]
        case .formula, .rollup:
            return [.contains, .notContains, .equals, .notEquals, .greaterThan, .lessThan, .isEmpty, .isNotEmpty, .isChecked, .isNotChecked]
        }
    }
}

public struct FilterRule: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var propertyID: String
    public var op: FilterOperator
    public var value: String

    public init(id: UUID = UUID(), propertyID: String, op: FilterOperator, value: String = "") {
        self.id = id
        self.propertyID = propertyID
        self.op = op
        self.value = value
    }
}

public enum Conjunction: String, Codable, CaseIterable, Sendable {
    case and, or
}

public struct SortRule: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var propertyID: String
    public var ascending: Bool

    public init(id: UUID = UUID(), propertyID: String, ascending: Bool = true) {
        self.id = id
        self.propertyID = propertyID
        self.ascending = ascending
    }
}

public enum CardCover: String, Codable, CaseIterable, Sendable {
    case none, pageCover, pageContent

    public var title: String {
        switch self {
        case .none: return "None"
        case .pageCover: return "Page cover"
        case .pageContent: return "Page content"
        }
    }
}

public enum ChartKind: String, Codable, CaseIterable, Sendable {
    case bar, donut, line

    public var title: String { rawValue.capitalized }
}

public struct DatabaseView: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var type: ViewType
    public var filters: [FilterRule]
    public var conjunction: Conjunction
    public var sorts: [SortRule]
    public var groupBy: String?
    public var hiddenProperties: [String]
    /// Property display order (ids). Properties missing from it are shown after, in schema order.
    public var propertyOrder: [String]
    public var dateProperty: String?
    public var endDateProperty: String?
    public var cardCover: CardCover
    public var wrapCells: Bool
    public var chartKind: ChartKind
    public var hideEmptyGroups: Bool
    public var collapsedGroups: [String]
    public var columnWidths: [String: Double]

    public init(id: UUID = UUID(), name: String? = nil, type: ViewType = .table, filters: [FilterRule] = [],
                conjunction: Conjunction = .and, sorts: [SortRule] = [], groupBy: String? = nil,
                hiddenProperties: [String] = [], propertyOrder: [String] = [], dateProperty: String? = nil,
                endDateProperty: String? = nil, cardCover: CardCover = .pageCover, wrapCells: Bool = false,
                chartKind: ChartKind = .bar, hideEmptyGroups: Bool = false, collapsedGroups: [String] = [],
                columnWidths: [String: Double] = [:]) {
        self.id = id
        self.name = name ?? type.title
        self.type = type
        self.filters = filters
        self.conjunction = conjunction
        self.sorts = sorts
        self.groupBy = groupBy
        self.hiddenProperties = hiddenProperties
        self.propertyOrder = propertyOrder
        self.dateProperty = dateProperty
        self.endDateProperty = endDateProperty
        self.cardCover = cardCover
        self.wrapCells = wrapCells
        self.chartKind = chartKind
        self.hideEmptyGroups = hideEmptyGroups
        self.collapsedGroups = collapsedGroups
        self.columnWidths = columnWidths
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID())
        type = c.value(.type, .table)
        name = c.value(.name, type.title)
        filters = c.value(.filters, [])
        conjunction = c.value(.conjunction, .and)
        sorts = c.value(.sorts, [])
        groupBy = c.value(.groupBy, nil)
        hiddenProperties = c.value(.hiddenProperties, [])
        propertyOrder = c.value(.propertyOrder, [])
        dateProperty = c.value(.dateProperty, nil)
        endDateProperty = c.value(.endDateProperty, nil)
        cardCover = c.value(.cardCover, .pageCover)
        wrapCells = c.value(.wrapCells, false)
        chartKind = c.value(.chartKind, .bar)
        hideEmptyGroups = c.value(.hideEmptyGroups, false)
        collapsedGroups = c.value(.collapsedGroups, [])
        columnWidths = c.value(.columnWidths, [:])
    }

    /// The schema's properties in this view's order.
    public func orderedProperties(_ schema: DatabaseSchema) -> [PropertyDefinition] {
        var result: [PropertyDefinition] = []
        for pid in propertyOrder { if let p = schema.property(id: pid) { result.append(p) } }
        for p in schema.properties where !result.contains(where: { $0.id == p.id }) { result.append(p) }
        // The title always comes first.
        if let t = result.firstIndex(where: { $0.type == .title }), t != 0 { result.insert(result.remove(at: t), at: 0) }
        return result
    }

    public func visibleProperties(_ schema: DatabaseSchema) -> [PropertyDefinition] {
        orderedProperties(schema).filter { $0.type == .title || !hiddenProperties.contains($0.id) }
    }
}

// MARK: - Values

public struct DateValue: Codable, Hashable, Sendable {
    public var start: Date
    public var end: Date?
    public var includeTime: Bool

    public init(start: Date, end: Date? = nil, includeTime: Bool = false) {
        self.start = start
        self.end = end
        self.includeTime = includeTime
    }
}

/// A value stored in a row's property.
public enum PropertyValue: Codable, Hashable, Sendable {
    case text(String)
    case number(Double)
    /// Select or status: the option id.
    case select(String)
    case multiSelect([String])
    case date(DateValue)
    case checkbox(Bool)
    case url(String)
    case email(String)
    case phone(String)
    case relation([UUID])
    case people([String])
    case files([String])

    public var isEmpty: Bool {
        switch self {
        case .text(let s), .url(let s), .email(let s), .phone(let s), .select(let s): return s.isEmpty
        case .number: return false
        case .multiSelect(let a): return a.isEmpty
        case .date: return false
        case .checkbox: return false
        case .relation(let a): return a.isEmpty
        case .people(let a), .files(let a): return a.isEmpty
        }
    }

    public var textValue: String? {
        switch self {
        case .text(let s), .url(let s), .email(let s), .phone(let s): return s
        default: return nil
        }
    }
}

/// Short random ids for properties and options ("k3x9q2").
public enum ShortID {
    public static func make() -> String {
        let chars = Array("abcdefghijkmnopqrstuvwxyz23456789")
        return String((0..<6).map { _ in chars[Int.random(in: 0..<chars.count)] })
    }
}
