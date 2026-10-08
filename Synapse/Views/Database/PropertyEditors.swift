import SwiftUI
import SynapseKit

/// The property list at the top of a database row's page.
struct RowPropertiesView: View {
    @Environment(WorkspaceStore.self) private var store
    let rowID: UUID
    let databaseID: UUID
    @State private var editing: CellTarget?
    @State private var showSchema = false

    var body: some View {
        if let db = store.page(databaseID), let schema = db.schema, let row = store.page(rowID) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(schema.properties.filter { $0.type != .title }) { p in
                    let value = PropertyResolver.resolve(row, p, schema: schema, in: store.workspace)
                    HStack(alignment: .top, spacing: 8) {
                        Label(p.name, systemImage: p.type.symbol)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(width: 130, alignment: .leading)
                        Group {
                            if p.type == .checkbox {
                                Button {
                                    var on = false
                                    if case .bool(let b) = value { on = b }
                                    store.setProperty(rowID, p.id, .checkbox(!on))
                                    Haptics.tap()
                                } label: { PropertyValueView(value: value, prop: p) }
                                .buttonStyle(.plain)
                            } else {
                                PropertyValueView(value: value, prop: p, placeholder: p.type.isComputed && p.type != .formula && p.type != .rollup ? "" : "Empty")
                                    .font(.subheadline)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                    .onTapGesture { editing = CellTarget(rowID: rowID, propertyID: p.id) }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 5)
                }
                Button { showSchema = true } label: {
                    Label("Add a property", systemImage: "plus").font(.subheadline).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            .sheet(item: $editing) { t in PropertyEditorSheet(rowID: t.rowID, propertyID: t.propertyID, databaseID: databaseID) }
            .sheet(isPresented: $showSchema) { SchemaSheet(databaseID: databaseID) }
        }
    }
}

/// Edit one property value of one row.
struct PropertyEditorSheet: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let rowID: UUID
    let propertyID: String
    let databaseID: UUID

    @State private var text = ""
    @State private var newOption = ""
    @State private var showConfig = false

    var body: some View {
        NavigationStack {
            if let db = store.page(databaseID), let schema = db.schema, let prop = schema.property(id: propertyID), let row = store.page(rowID) {
                Form {
                    editor(prop, row: row, schema: schema)
                }
                .navigationTitle(prop.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { save(prop); dismiss() } }
                    ToolbarItem(placement: .topBarLeading) {
                        Button { showConfig = true } label: { Image(systemName: "slider.horizontal.3") }
                    }
                }
                .onAppear { text = initialText(row, prop) }
                .onDisappear { save(prop) }
                .sheet(isPresented: $showConfig) {
                    NavigationStack { PropertyConfigView(databaseID: databaseID, propertyID: propertyID) }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func initialText(_ row: Page, _ p: PropertyDefinition) -> String {
        switch row.properties[p.id] {
        case .text(let s)?, .url(let s)?, .email(let s)?, .phone(let s)?: return s
        case .number(let n)?: return n == n.rounded() ? String(Int(n)) : String(n)
        default: return ""
        }
    }

    private func save(_ p: PropertyDefinition) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var value: PropertyValue?
        switch p.type {
        case .text: value = t.isEmpty ? nil : .text(t)
        case .url: value = t.isEmpty ? nil : .url(t)
        case .email: value = t.isEmpty ? nil : .email(t)
        case .phone: value = t.isEmpty ? nil : .phone(t)
        case .number: value = Double(t.replacingOccurrences(of: ",", with: "")).map { .number($0) }
        default: return
        }
        if store.page(rowID)?.properties[p.id] != value { store.setProperty(rowID, p.id, value) }
    }

    @ViewBuilder private func editor(_ p: PropertyDefinition, row: Page, schema: DatabaseSchema) -> some View {
        switch p.type {
        case .text:
            TextField("Empty", text: $text, axis: .vertical).lineLimit(3...12)
        case .url:
            TextField("https://", text: $text).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            if !text.isEmpty, let url = URL(string: text.contains("://") ? text : "https://" + text) {
                Link(destination: url) { Label("Open link", systemImage: "safari") }
            }
        case .email:
            TextField("name@example.com", text: $text).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
            if !text.isEmpty, let url = URL(string: "mailto:" + text) { Link(destination: url) { Label("Send email", systemImage: "envelope") } }
        case .phone:
            TextField("Phone", text: $text).keyboardType(.phonePad)
            if !text.isEmpty, let url = URL(string: "tel:" + text.filter { $0.isNumber || $0 == "+" }) { Link(destination: url) { Label("Call", systemImage: "phone") } }
        case .number:
            TextField("0", text: $text).keyboardType(.decimalPad)
            Text("Format: \(p.numberFormat.title)").font(.footnote).foregroundStyle(.secondary)
        case .select, .status, .multiSelect:
            optionEditor(p, row: row)
        case .date:
            dateEditor(p, row: row)
        case .checkbox:
            Toggle(p.name, isOn: Binding(get: {
                if case .checkbox(let b)? = store.page(rowID)?.properties[p.id] { return b }
                return false
            }, set: { store.setProperty(rowID, p.id, .checkbox($0)) }))
        case .person, .files:
            stringListEditor(p, row: row)
        case .relation:
            relationEditor(p, row: row)
        case .formula, .rollup, .createdTime, .lastEditedTime, .uniqueID, .title:
            let v = PropertyResolver.resolve(row, p, schema: schema, in: store.workspace)
            Section {
                PropertyValueView(value: v, prop: p, placeholder: "Empty")
            } footer: {
                if p.type == .formula { Text(p.formula).font(.caption.monospaced()) }
                else { Text("Calculated automatically.") }
            }
            if p.type == .formula || p.type == .rollup {
                Button { showConfig = true } label: { Label(p.type == .formula ? "Edit formula" : "Edit rollup", systemImage: "function") }
            }
        }
    }

    // MARK: Options

    @ViewBuilder private func optionEditor(_ p: PropertyDefinition, row: Page) -> some View {
        let selected: [String] = {
            switch row.properties[p.id] {
            case .select(let id)?: return [id]
            case .multiSelect(let ids)?: return ids
            default: return []
            }
        }()
        Section {
            HStack {
                TextField("Search or create an option", text: $newOption)
                    .onSubmit { createOption(p) }
                if !newOption.trimmingCharacters(in: .whitespaces).isEmpty && p.option(named: newOption.trimmingCharacters(in: .whitespaces)) == nil {
                    Button("Create") { createOption(p) }
                }
            }
        }
        if p.type == .status {
            ForEach(StatusGroup.allCases, id: \.self) { g in
                Section(g.title) {
                    ForEach(filtered(p).filter { ($0.group ?? .todo) == g }) { o in optionRow(o, p: p, selected: selected) }
                }
            }
        } else {
            Section {
                ForEach(filtered(p)) { o in optionRow(o, p: p, selected: selected) }
            }
        }
        if !selected.isEmpty {
            Button("Clear", role: .destructive) { store.setProperty(rowID, p.id, nil) }
        }
    }

    private func filtered(_ p: PropertyDefinition) -> [SelectOption] {
        let q = newOption.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? p.options : p.options.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    private func optionRow(_ o: SelectOption, p: PropertyDefinition, selected: [String]) -> some View {
        Button {
            toggle(o.id, p: p, selected: selected)
        } label: {
            HStack {
                OptionChip(name: o.name, color: o.color, dot: p.type == .status)
                Spacer()
                if selected.contains(o.id) { Image(systemName: "checkmark").foregroundStyle(Palette.accent) }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Menu("Colour") {
                ForEach(Tint.allCases, id: \.self) { t in
                    Button(t.title) { updateOption(p, o.id) { $0.color = t } }
                }
            }
            Button(role: .destructive) {
                store.update(databaseID, touch: false) { $0.schema?.update({ var np = p; np.options.removeAll { $0.id == o.id }; return np }()) }
            } label: { Label("Delete option", systemImage: "trash") }
        }
    }

    private func updateOption(_ p: PropertyDefinition, _ id: String, _ change: @escaping (inout SelectOption) -> Void) {
        store.update(databaseID, touch: false) { page in
            guard var schema = page.schema, var prop = schema.property(id: p.id), let i = prop.options.firstIndex(where: { $0.id == id }) else { return }
            change(&prop.options[i])
            schema.update(prop)
            page.schema = schema
        }
    }

    private func toggle(_ id: String, p: PropertyDefinition, selected: [String]) {
        if p.type == .multiSelect {
            var ids = selected
            if let i = ids.firstIndex(of: id) { ids.remove(at: i) } else { ids.append(id) }
            store.setProperty(rowID, p.id, ids.isEmpty ? nil : .multiSelect(ids))
        } else {
            store.setProperty(rowID, p.id, selected.contains(id) ? nil : .select(id))
            dismiss()
        }
        Haptics.tap()
    }

    private func createOption(_ p: PropertyDefinition) {
        let name = newOption.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if let existing = p.option(named: name) {
            toggle(existing.id, p: p, selected: currentSelection(p))
            newOption = ""
            return
        }
        let o = SelectOption(name: name, group: p.type == .status ? .todo : nil)
        store.update(databaseID, touch: false) { page in
            guard var schema = page.schema, var prop = schema.property(id: p.id) else { return }
            prop.options.append(o)
            schema.update(prop)
            page.schema = schema
        }
        toggle(o.id, p: p, selected: currentSelection(p))
        newOption = ""
    }

    private func currentSelection(_ p: PropertyDefinition) -> [String] {
        switch store.page(rowID)?.properties[p.id] {
        case .select(let id)?: return [id]
        case .multiSelect(let ids)?: return ids
        default: return []
        }
    }

    // MARK: Dates

    @ViewBuilder private func dateEditor(_ p: PropertyDefinition, row: Page) -> some View {
        let current: DateValue? = { if case .date(let d)? = row.properties[p.id] { return d }; return nil }()
        let value = current ?? DateValue(start: Calendar.current.startOfDay(for: Date()), includeTime: p.includeTime)
        Section {
            DatePicker("Date", selection: Binding(get: { value.start }, set: { d in
                var v = value
                v.start = d
                if let e = v.end, e < d { v.end = d }
                store.setProperty(rowID, p.id, .date(v))
            }), displayedComponents: value.includeTime ? [.date, .hourAndMinute] : [.date])
            .datePickerStyle(.graphical)
            Toggle("End date", isOn: Binding(get: { value.end != nil }, set: { on in
                var v = value
                v.end = on ? Calendar.current.date(byAdding: .day, value: 1, to: v.start) : nil
                store.setProperty(rowID, p.id, .date(v))
            }))
            if let end = value.end {
                DatePicker("Ends", selection: Binding(get: { end }, set: { d in
                    var v = value
                    v.end = max(d, v.start)
                    store.setProperty(rowID, p.id, .date(v))
                }), displayedComponents: value.includeTime ? [.date, .hourAndMinute] : [.date])
            }
            Toggle("Include time", isOn: Binding(get: { value.includeTime }, set: { on in
                var v = value
                v.includeTime = on
                store.setProperty(rowID, p.id, .date(v))
            }))
        }
        Section {
            HStack {
                Button("Today") { store.setProperty(rowID, p.id, .date(DateValue(start: Calendar.current.startOfDay(for: Date())))) }
                Spacer()
                Button("Tomorrow") { store.setProperty(rowID, p.id, .date(DateValue(start: Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!))) }
                Spacer()
                Button("Clear", role: .destructive) { store.setProperty(rowID, p.id, nil) }
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: People / files

    @ViewBuilder private func stringListEditor(_ p: PropertyDefinition, row: Page) -> some View {
        let items: [String] = {
            switch row.properties[p.id] {
            case .people(let a)?, .files(let a)?: return a
            default: return []
            }
        }()
        Section {
            ForEach(items, id: \.self) { s in
                if p.type == .files, let url = URL(string: s) {
                    Link(s, destination: url).lineLimit(1)
                } else {
                    Text(s)
                }
            }
            .onDelete { idx in
                var a = items
                a.remove(atOffsets: idx)
                store.setProperty(rowID, p.id, a.isEmpty ? nil : (p.type == .person ? .people(a) : .files(a)))
            }
            HStack {
                TextField(p.type == .person ? "Add a name" : "Add a file link", text: $newOption)
                    .textInputAutocapitalization(p.type == .person ? .words : .never)
                Button("Add") {
                    let s = newOption.trimmingCharacters(in: .whitespaces)
                    guard !s.isEmpty else { return }
                    let a = items + [s]
                    store.setProperty(rowID, p.id, p.type == .person ? .people(a) : .files(a))
                    newOption = ""
                }
            }
            if p.type == .person {
                let known = Set(store.workspace.rows(of: databaseID).flatMap { r -> [String] in
                    if case .people(let a)? = r.properties[p.id] { return a }
                    return []
                }).subtracting(items).sorted()
                if !known.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(known, id: \.self) { n in
                                Button(n) { store.setProperty(rowID, p.id, .people(items + [n])) }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Relations

    @ViewBuilder private func relationEditor(_ p: PropertyDefinition, row: Page) -> some View {
        let selected: [UUID] = { if case .relation(let r)? = row.properties[p.id] { return r }; return [] }()
        if let target = p.relation?.databaseID, let targetDB = store.page(target) {
            Section("Linked") {
                ForEach(selected, id: \.self) { id in
                    if let page = store.page(id) {
                        HStack {
                            Button { dismiss(); app.open(id) } label: { PageRowLabel(page: page) }.buttonStyle(.plain)
                            Button { store.setProperty(rowID, p.id, .relation(selected.filter { $0 != id })) } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if selected.isEmpty { Text("Nothing linked yet.").foregroundStyle(.secondary) }
            }
            Section("Add from \(targetDB.displayTitle)") {
                TextField("Search", text: $newOption)
                let candidates = store.workspace.rows(of: target).filter { !selected.contains($0.id) && $0.id != rowID &&
                    (newOption.isEmpty || $0.displayTitle.localizedCaseInsensitiveContains(newOption)) }
                ForEach(candidates.prefix(50)) { r in
                    Button { store.setProperty(rowID, p.id, .relation(selected + [r.id])) } label: { PageRowLabel(page: r) }
                        .buttonStyle(.plain)
                }
                if !newOption.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button {
                        if let id = store.newRow(in: target, title: newOption.trimmingCharacters(in: .whitespaces)) {
                            store.setProperty(rowID, p.id, .relation(selected + [id]))
                            newOption = ""
                        }
                    } label: { Label("New “\(newOption)” in \(targetDB.displayTitle)", systemImage: "plus") }
                }
            }
        } else {
            Text("This relation has no database. Choose one in the property settings.").foregroundStyle(.secondary)
            Button("Property settings") { showConfig = true }
        }
    }
}
