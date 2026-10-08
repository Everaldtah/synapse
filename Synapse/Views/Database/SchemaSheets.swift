import SwiftUI
import SynapseKit

/// Manage a database's properties.
struct SchemaSheet: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let databaseID: UUID

    var body: some View {
        NavigationStack {
            List {
                if let schema = store.page(databaseID)?.schema {
                    Section {
                        ForEach(schema.properties) { p in
                            NavigationLink {
                                PropertyConfigView(databaseID: databaseID, propertyID: p.id)
                            } label: {
                                Label(p.name, systemImage: p.type.symbol)
                                    .badge(Text(p.type.title))
                            }
                            .deleteDisabled(p.type == .title)
                        }
                        .onMove { from, to in
                            store.update(databaseID, touch: false) { $0.schema?.properties.move(fromOffsets: from, toOffset: to) }
                        }
                        .onDelete { idx in
                            let ids = idx.map { schema.properties[$0].id }
                            store.mutate { ws in for id in ids { ws.removeProperty(id, from: databaseID) } }
                        }
                    }
                    Section("Add a property") {
                        ForEach(PropertyType.creatable, id: \.self) { t in
                            if t == .relation {
                                NavigationLink {
                                    NewRelationView(databaseID: databaseID)
                                } label: { Label(t.title, systemImage: t.symbol) }
                            } else {
                                Button { add(t) } label: { Label(t.title, systemImage: t.symbol) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Properties")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) { EditButton() }
            }
        }
    }

    private func add(_ type: PropertyType) {
        guard let schema = store.page(databaseID)?.schema else { return }
        var name = type.title
        var n = 2
        while schema.property(named: name) != nil { name = "\(type.title) \(n)"; n += 1 }
        var p = PropertyDefinition(name: name, type: type)
        if type == .status { p.options = PropertyDefinition.defaultStatusOptions() }
        if type == .formula { p.formula = "prop(\"\(schema.titleProperty.name)\").length()" }
        if type == .uniqueID {
            store.mutate { ws in
                ws[databaseID]?.schema?.properties.append(p)
                var next = ws[databaseID]?.schema?.nextUniqueNumber ?? 1
                for r in ws.rows(of: databaseID) {
                    ws[r.id]?.properties[p.id] = .number(Double(next))
                    next += 1
                }
                ws[databaseID]?.schema?.nextUniqueNumber = next
            }
            return
        }
        store.update(databaseID, touch: false) { $0.schema?.properties.append(p) }
    }
}

struct NewRelationView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let databaseID: UUID
    @State private var target: UUID?
    @State private var twoWay = true
    @State private var name = ""

    var body: some View {
        Form {
            Section("Related database") {
                ForEach(store.workspace.databases) { db in
                    Button {
                        target = db.id
                        if name.isEmpty { name = db.displayTitle }
                    } label: {
                        HStack {
                            PageRowLabel(page: db)
                            if target == db.id { Image(systemName: "checkmark").foregroundStyle(Palette.accent) }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Section {
                TextField("Property name", text: $name)
                Toggle("Show on the related database too", isOn: $twoWay)
                    .disabled(target == databaseID)
            }
            Button("Add relation") {
                guard let target else { return }
                store.mutate { $0.addRelation(in: databaseID, name: name.isEmpty ? "Related" : name, to: target, twoWay: twoWay && target != databaseID) }
                dismiss()
            }
            .disabled(target == nil)
        }
        .navigationTitle("New relation")
    }
}

/// Name, type and settings of one property.
struct PropertyConfigView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let databaseID: UUID
    let propertyID: String
    @State private var name = ""
    @State private var formula = ""
    @State private var newOption = ""

    var body: some View {
        Form {
            if let db = store.page(databaseID), let schema = db.schema, let p = schema.property(id: propertyID) {
                Section {
                    TextField("Name", text: $name)
                        .onSubmit { change { $0.name = name.isEmpty ? $0.name : name } }
                    if p.type != .title {
                        Picker("Type", selection: Binding(get: { p.type }, set: { t in
                            store.mutate { $0.changePropertyType(propertyID, in: databaseID, to: t) }
                        })) {
                            ForEach(PropertyType.creatable, id: \.self) { t in Label(t.title, systemImage: t.symbol).tag(t) }
                        }
                    }
                }
                switch p.type {
                case .select, .multiSelect, .status:
                    optionsSection(p)
                case .number:
                    Picker("Number format", selection: Binding(get: { p.numberFormat }, set: { f in change { $0.numberFormat = f } })) {
                        ForEach(NumberFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                case .date:
                    Toggle("Include time by default", isOn: Binding(get: { p.includeTime }, set: { v in change { $0.includeTime = v } }))
                case .uniqueID:
                    TextField("Prefix (e.g. TASK)", text: Binding(get: { p.idPrefix }, set: { v in change { $0.idPrefix = v.uppercased() } }))
                case .formula:
                    formulaSection(p, schema: schema, db: db)
                case .relation:
                    relationSection(p)
                case .rollup:
                    rollupSection(p, schema: schema)
                default:
                    EmptyView()
                }
                if p.type != .title {
                    Section {
                        Button("Delete property", role: .destructive) {
                            store.mutate { $0.removeProperty(propertyID, from: databaseID) }
                            dismiss()
                        }
                    }
                }
            }
        }
        .navigationTitle(name.isEmpty ? "Property" : name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let p = store.page(databaseID)?.schema?.property(id: propertyID)
            name = p?.name ?? ""
            formula = p?.formula ?? ""
        }
        .onDisappear {
            change { p in
                if !name.trimmingCharacters(in: .whitespaces).isEmpty { p.name = name.trimmingCharacters(in: .whitespaces) }
                if p.type == .formula { p.formula = formula }
            }
        }
    }

    private func change(_ edit: (inout PropertyDefinition) -> Void) {
        guard var schema = store.page(databaseID)?.schema, var p = schema.property(id: propertyID) else { return }
        let before = p
        edit(&p)
        guard p != before else { return }
        schema.update(p)
        store.update(databaseID, touch: false) { $0.schema = schema }
    }

    @ViewBuilder private func optionsSection(_ p: PropertyDefinition) -> some View {
        Section("Options") {
            ForEach(p.options) { o in
                HStack {
                    OptionChip(name: o.name, color: o.color, dot: p.type == .status)
                    Spacer()
                    if p.type == .status {
                        Menu((o.group ?? .todo).title) {
                            ForEach(StatusGroup.allCases, id: \.self) { g in
                                Button(g.title) { change { prop in if let i = prop.options.firstIndex(where: { $0.id == o.id }) { prop.options[i].group = g } } }
                            }
                        }
                        .font(.caption)
                    }
                    Menu {
                        ForEach(Tint.allCases, id: \.self) { t in
                            Button(t.title) { change { prop in if let i = prop.options.firstIndex(where: { $0.id == o.id }) { prop.options[i].color = t } } }
                        }
                    } label: { Circle().fill(o.color.dot).frame(width: 14, height: 14) }
                }
            }
            .onMove { from, to in change { $0.options.move(fromOffsets: from, toOffset: to) } }
            .onDelete { idx in change { $0.options.remove(atOffsets: idx) } }
            HStack {
                TextField("New option", text: $newOption)
                Button("Add") {
                    let n = newOption.trimmingCharacters(in: .whitespaces)
                    guard !n.isEmpty else { return }
                    change { $0.options.append(SelectOption(name: n, group: $0.type == .status ? .todo : nil)) }
                    newOption = ""
                }
            }
        }
    }

    @ViewBuilder private func formulaSection(_ p: PropertyDefinition, schema: DatabaseSchema, db: Page) -> some View {
        Section {
            TextEditor(text: $formula)
                .font(.callout.monospaced())
                .frame(minHeight: 90)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            let preview: String = {
                guard let row = store.workspace.rows(of: databaseID).first else { return "Add a row to preview." }
                var test = p
                test.formula = formula
                var s = schema
                s.update(test)
                return PropertyResolver.displayText(PropertyResolver.resolve(row, test, schema: s, in: store.workspace), test, in: store.workspace)
            }()
            Label(preview.isEmpty ? "(empty)" : preview, systemImage: preview.hasPrefix("⚠︎") ? "exclamationmark.triangle" : "eye")
                .font(.footnote)
                .foregroundStyle(preview.hasPrefix("⚠︎") ? Color.orange : Color.secondary)
            Button("Save formula") { change { $0.formula = formula } }
        } header: {
            Text("Formula")
        } footer: {
            Text("Example: if(prop(\"Done\"), \"✅\", \"⏳\") · dateBetween(prop(\"Due\"), now(), \"days\") · prop(\"Tags\").length()")
        }
        Section("Insert a property") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(schema.properties.filter { $0.id != propertyID }) { other in
                        Button(other.name) { formula += "prop(\"\(other.name)\")" }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
        }
        Section("Functions") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(["if(", "and(", "or(", "not(", "empty(", "concat(", "length(", "contains(", "round(", "sum(", "now()", "today()",
                             "dateAdd(", "dateBetween(", "formatDate(", "map(", "filter(", "lets("], id: \.self) { f in
                        Button(f) { formula += f }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .font(.caption.monospaced())
                    }
                }
            }
        }
    }

    @ViewBuilder private func relationSection(_ p: PropertyDefinition) -> some View {
        Section("Related database") {
            Picker("Database", selection: Binding(get: { p.relation?.databaseID }, set: { id in
                change { prop in prop.relation = id.map { RelationConfig(databaseID: $0, reversePropertyID: prop.relation?.reversePropertyID) } }
            })) {
                Text("None").tag(UUID?.none)
                ForEach(store.workspace.databases) { db in Text(db.displayTitle).tag(UUID?.some(db.id)) }
            }
            if p.relation?.reversePropertyID != nil {
                Label("Two-way relation", systemImage: "arrow.left.arrow.right").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func rollupSection(_ p: PropertyDefinition, schema: DatabaseSchema) -> some View {
        let relations = schema.properties.filter { $0.type == .relation }
        let cfg = p.rollup ?? RollupConfig(relationPropertyID: relations.first?.id ?? "", targetPropertyID: "")
        let targetSchema = schema.property(id: cfg.relationPropertyID)?.relation.flatMap { store.page($0.databaseID)?.schema }
        Section("Rollup") {
            if relations.isEmpty {
                Text("Add a Relation property first.").foregroundStyle(.secondary)
            } else {
                Picker("Relation", selection: Binding(get: { cfg.relationPropertyID }, set: { v in
                    change { $0.rollup = RollupConfig(relationPropertyID: v, targetPropertyID: "", function: cfg.function) }
                })) {
                    ForEach(relations) { Text($0.name).tag($0.id) }
                }
                if let targetSchema {
                    Picker("Property", selection: Binding(get: { cfg.targetPropertyID }, set: { v in
                        change { $0.rollup = RollupConfig(relationPropertyID: cfg.relationPropertyID, targetPropertyID: v, function: cfg.function) }
                    })) {
                        Text("Choose…").tag("")
                        ForEach(targetSchema.properties) { Text($0.name).tag($0.id) }
                    }
                }
                Picker("Calculate", selection: Binding(get: { cfg.function }, set: { v in
                    change { $0.rollup = RollupConfig(relationPropertyID: cfg.relationPropertyID, targetPropertyID: cfg.targetPropertyID, function: v) }
                })) {
                    ForEach(RollupFunction.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
        }
    }
}

/// Layout, filters, sorts, grouping and visible properties of a view.
struct ViewSettingsSheet: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let databaseID: UUID
    let viewID: UUID

    var body: some View {
        NavigationStack {
            Form {
                if let db = store.page(databaseID), let schema = db.schema, let view = db.views.first(where: { $0.id == viewID }) {
                    Section("Layout") {
                        TextField("View name", text: Binding(get: { view.name }, set: { v in edit { $0.name = v } }))
                        Picker("Layout", selection: Binding(get: { view.type }, set: { t in edit { $0.type = t } })) {
                            ForEach(ViewType.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
                        }
                        if [.board, .chart, .table, .list].contains(view.type) {
                            Picker("Group by", selection: Binding(get: { view.groupBy }, set: { g in edit { $0.groupBy = g } })) {
                                Text("None").tag(String?.none)
                                ForEach(view.type == .chart ? schema.properties.filter { $0.type != .title } : DatabaseQuery.groupable(schema)) {
                                    Text($0.name).tag(String?.some($0.id))
                                }
                            }
                        }
                        if view.type == .board {
                            Toggle("Hide empty groups", isOn: Binding(get: { view.hideEmptyGroups }, set: { v in edit { $0.hideEmptyGroups = v } }))
                        }
                        if view.type == .calendar || view.type == .timeline {
                            let dates = schema.properties.filter { [.date, .createdTime, .lastEditedTime].contains($0.type) }
                            Picker(view.type == .timeline ? "Start date" : "Show by", selection: Binding(get: { view.dateProperty }, set: { d in edit { $0.dateProperty = d } })) {
                                Text("None").tag(String?.none)
                                ForEach(dates) { Text($0.name).tag(String?.some($0.id)) }
                            }
                            if view.type == .timeline {
                                Picker("End date", selection: Binding(get: { view.endDateProperty }, set: { d in edit { $0.endDateProperty = d } })) {
                                    Text("Same as start / date range").tag(String?.none)
                                    ForEach(dates) { Text($0.name).tag(String?.some($0.id)) }
                                }
                            }
                        }
                        if view.type == .gallery || view.type == .board {
                            Picker("Card preview", selection: Binding(get: { view.cardCover }, set: { c in edit { $0.cardCover = c } })) {
                                ForEach(CardCover.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                        }
                        if view.type == .chart {
                            Picker("Chart", selection: Binding(get: { view.chartKind }, set: { c in edit { $0.chartKind = c } })) {
                                ForEach(ChartKind.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented)
                        }
                        if view.type == .table {
                            Toggle("Wrap cells", isOn: Binding(get: { view.wrapCells }, set: { v in edit { $0.wrapCells = v } }))
                        }
                    }

                    Section {
                        ForEach(view.filters) { rule in
                            FilterRuleRow(rule: rule, schema: schema) { updated in
                                edit { v in if let i = v.filters.firstIndex(where: { $0.id == rule.id }) { v.filters[i] = updated } }
                            }
                        }
                        .onDelete { idx in edit { $0.filters.remove(atOffsets: idx) } }
                        Menu {
                            ForEach(schema.properties) { p in
                                Button(p.name) {
                                    let op = FilterOperator.operators(for: p.type).first ?? .contains
                                    edit { $0.filters.append(FilterRule(propertyID: p.id, op: op)) }
                                }
                            }
                        } label: { Label("Add filter", systemImage: "plus") }
                        if view.filters.count > 1 {
                            Picker("Match", selection: Binding(get: { view.conjunction }, set: { c in edit { $0.conjunction = c } })) {
                                Text("All filters").tag(Conjunction.and)
                                Text("Any filter").tag(Conjunction.or)
                            }
                        }
                    } header: { Text("Filters") }

                    Section {
                        ForEach(view.sorts) { s in
                            HStack {
                                Text(schema.property(id: s.propertyID)?.name ?? "?")
                                Spacer()
                                Picker("", selection: Binding(get: { s.ascending }, set: { a in
                                    edit { v in if let i = v.sorts.firstIndex(where: { $0.id == s.id }) { v.sorts[i].ascending = a } }
                                })) {
                                    Text("Ascending").tag(true)
                                    Text("Descending").tag(false)
                                }
                                .labelsHidden()
                            }
                        }
                        .onDelete { idx in edit { $0.sorts.remove(atOffsets: idx) } }
                        .onMove { from, to in edit { $0.sorts.move(fromOffsets: from, toOffset: to) } }
                        Menu {
                            ForEach(schema.properties) { p in
                                Button(p.name) { edit { $0.sorts.append(SortRule(propertyID: p.id)) } }
                            }
                        } label: { Label("Add sort", systemImage: "plus") }
                    } header: { Text("Sorts") }

                    Section {
                        ForEach(view.orderedProperties(schema)) { p in
                            Toggle(isOn: Binding(get: { p.type == .title || !view.hiddenProperties.contains(p.id) }, set: { on in
                                edit { v in
                                    v.hiddenProperties.removeAll { $0 == p.id }
                                    if !on { v.hiddenProperties.append(p.id) }
                                }
                            })) { Label(p.name, systemImage: p.type.symbol) }
                            .disabled(p.type == .title)
                        }
                        .onMove { from, to in
                            edit { v in
                                var order = v.orderedProperties(schema).map(\.id)
                                order.move(fromOffsets: from, toOffset: to)
                                v.propertyOrder = order
                            }
                        }
                    } header: { Text("Properties") } footer: { Text("Tap Edit to reorder.") }
                }
            }
            .navigationTitle("View settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) { EditButton() }
            }
        }
    }

    private func edit(_ change: @escaping (inout DatabaseView) -> Void) {
        store.update(databaseID, touch: false) { p in
            if let i = p.views.firstIndex(where: { $0.id == viewID }) { change(&p.views[i]) }
        }
    }
}

struct FilterRuleRow: View {
    let rule: FilterRule
    let schema: DatabaseSchema
    let onChange: (FilterRule) -> Void

    var body: some View {
        let prop = schema.property(id: rule.propertyID)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(prop?.name ?? "?", systemImage: prop?.type.symbol ?? "questionmark").font(.subheadline.weight(.medium))
                Spacer()
                Picker("", selection: Binding(get: { rule.op }, set: { op in var r = rule; r.op = op; onChange(r) })) {
                    ForEach(FilterOperator.operators(for: prop?.type ?? .text), id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
            }
            if let prop, !rule.op.isUnary {
                switch prop.type {
                case .select, .status, .multiSelect:
                    Picker("Value", selection: Binding(get: { rule.value }, set: { v in var r = rule; r.value = v; onChange(r) })) {
                        Text("Choose…").tag("")
                        ForEach(prop.options) { Text($0.name).tag($0.id) }
                    }
                case .date, .createdTime, .lastEditedTime:
                    DatePicker("Date", selection: Binding(get: { DateText.parse(rule.value) ?? Date() }, set: { d in
                        var r = rule
                        r.value = DateText.iso(d)
                        onChange(r)
                    }), displayedComponents: .date)
                case .number:
                    TextField("Value", text: Binding(get: { rule.value }, set: { v in var r = rule; r.value = v; onChange(r) }))
                        .keyboardType(.decimalPad)
                default:
                    TextField("Value", text: Binding(get: { rule.value }, set: { v in var r = rule; r.value = v; onChange(r) }))
                }
            }
        }
    }
}
