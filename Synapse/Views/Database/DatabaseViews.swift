import SwiftUI
import Charts
import SynapseKit

// MARK: - Value display

/// A property value, compact (cells, cards) or full.
struct PropertyValueView: View {
    @Environment(WorkspaceStore.self) private var store
    let value: ResolvedValue
    let prop: PropertyDefinition
    var placeholder = ""

    var body: some View {
        switch value {
        case .empty:
            Text(placeholder).foregroundStyle(.tertiary)
        case .options(let opts):
            if opts.isEmpty {
                Text(placeholder).foregroundStyle(.tertiary)
            } else {
                HStack(spacing: 4) {
                    ForEach(opts) { o in OptionChip(name: o.name, color: o.color, dot: prop.type == .status) }
                }
            }
        case .bool(let b):
            if prop.type == .checkbox {
                Image(systemName: b ? "checkmark.square.fill" : "square").foregroundStyle(b ? Palette.accent : Color.secondary)
            } else {
                Text(b ? "true" : "false")
            }
        case .pages(let ids):
            HStack(spacing: 6) {
                ForEach(ids, id: \.self) { id in
                    if let p = store.page(id) {
                        HStack(spacing: 3) {
                            PageIconView(page: p, size: 11)
                            Text(p.displayTitle).underline(color: Color.secondary.opacity(0.4)).lineLimit(1)
                        }
                    }
                }
            }
        case .strings(let s):
            if prop.type == .person {
                HStack(spacing: 4) {
                    ForEach(s, id: \.self) { name in
                        HStack(spacing: 3) {
                            Text(String(name.prefix(1)).uppercased())
                                .font(.caption2.bold())
                                .frame(width: 18, height: 18)
                                .background(Tint.stable(for: name).chip, in: Circle())
                            Text(name).lineLimit(1)
                        }
                    }
                }
            } else {
                Text(s.joined(separator: ", ")).lineLimit(1)
            }
        case .text(let s):
            if prop.type == .url || prop.type == .email || prop.type == .phone {
                Text(s).underline().foregroundStyle(Palette.accent).lineLimit(1)
            } else {
                Text(prop.type == .title ? s : InlineMarkdown.plainText(s)).lineLimit(prop.type == .title ? 2 : 3)
            }
        default:
            Text(PropertyResolver.displayText(value, prop, in: store.workspace)).lineLimit(2)
        }
    }
}

extension View {
    /// Opens URL/email/phone values.
    func openValue(_ value: ResolvedValue, _ prop: PropertyDefinition) {
        guard case .text(let s) = value else { return }
        var url: URL?
        switch prop.type {
        case .url: url = URL(string: s.contains("://") ? s : "https://" + s)
        case .email: url = URL(string: "mailto:" + s)
        case .phone: url = URL(string: "tel:" + s.filter { $0.isNumber || $0 == "+" })
        default: break
        }
        if let url { UIApplication.shared.open(url) }
    }
}

// MARK: - Table

struct DBTableView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(AppModel.self) private var app
    let db: Page
    let schema: DatabaseSchema
    let view: DatabaseView
    let rows: [Page]
    let edit: (CellTarget) -> Void
    let newRow: () -> Void

    private func width(_ p: PropertyDefinition) -> CGFloat {
        if let w = view.columnWidths[p.id] { return CGFloat(w) }
        switch p.type {
        case .title: return 220
        case .checkbox: return 80
        case .text, .relation, .multiSelect, .formula, .rollup: return 190
        default: return 150
        }
    }

    var body: some View {
        let props = view.visibleProperties(schema)
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(props) { p in
                        Menu {
                            Button { sort(p, ascending: true) } label: { Label("Sort ascending", systemImage: "arrow.up") }
                            Button { sort(p, ascending: false) } label: { Label("Sort descending", systemImage: "arrow.down") }
                            if p.type != .title {
                                Button { store.update(db.id, touch: false) { pg in
                                    if let i = pg.views.firstIndex(where: { $0.id == view.id }) { pg.views[i].hiddenProperties.append(p.id) }
                                } } label: { Label("Hide", systemImage: "eye.slash") }
                            }
                            Menu("Width") {
                                ForEach([100, 150, 200, 260, 320], id: \.self) { w in
                                    Button("\(w) pt") { store.update(db.id, touch: false) { pg in
                                        if let i = pg.views.firstIndex(where: { $0.id == view.id }) { pg.views[i].columnWidths[p.id] = Double(w) }
                                    } }
                                }
                            }
                        } label: {
                            Label(p.name, systemImage: p.type.symbol)
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(width: width(p) - 16, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 8)
                        }
                        .overlay(alignment: .trailing) { Rectangle().fill(Color(UIColor.separator)).frame(width: 0.5) }
                    }
                }
                Divider()
                ForEach(rows) { row in
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(props) { p in
                            cell(row, p)
                                .frame(width: width(p) - 16, alignment: .leading)
                                .frame(minHeight: 22, alignment: .topLeading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 8)
                                .overlay(alignment: .trailing) { Rectangle().fill(Color(UIColor.separator)).frame(width: 0.5) }
                        }
                    }
                    .contextMenu { rowMenu(row) }
                    Divider()
                }
                Button(action: newRow) {
                    Label("New", systemImage: "plus").font(.footnote).foregroundStyle(.secondary).padding(10)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
        }
    }

    @ViewBuilder private func cell(_ row: Page, _ p: PropertyDefinition) -> some View {
        let value = PropertyResolver.resolve(row, p, schema: schema, in: store.workspace)
        switch p.type {
        case .title:
            Button { app.open(row.id) } label: {
                HStack(spacing: 6) {
                    if !row.icon.isEmpty { Text(row.icon).font(.footnote) }
                    Text(row.displayTitle)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(row.title.isEmpty ? .secondary : .primary)
                        .lineLimit(view.wrapCells ? 4 : 1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        case .checkbox:
            Button {
                var on = false
                if case .bool(let b) = value { on = b }
                store.setProperty(row.id, p.id, .checkbox(!on))
                Haptics.tap()
            } label: { PropertyValueView(value: value, prop: p) }
            .buttonStyle(.plain)
        default:
            PropertyValueView(value: value, prop: p)
                .font(.subheadline)
                .lineLimit(view.wrapCells ? 6 : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { if !p.type.isComputed || p.type == .formula || p.type == .rollup { edit(CellTarget(rowID: row.id, propertyID: p.id)) } }
        }
    }

    private func sort(_ p: PropertyDefinition, ascending: Bool) {
        store.update(db.id, touch: false) { pg in
            if let i = pg.views.firstIndex(where: { $0.id == view.id }) { pg.views[i].sorts = [SortRule(propertyID: p.id, ascending: ascending)] }
        }
    }

    @ViewBuilder private func rowMenu(_ row: Page) -> some View {
        Button { app.open(row.id) } label: { Label("Open", systemImage: "arrow.up.right") }
        Button { store.duplicate(row.id) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
        Button(role: .destructive) { store.trash(row.id) } label: { Label("Delete", systemImage: "trash") }
    }
}

// MARK: - Board

struct DBBoardView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(AppModel.self) private var app
    let db: Page
    let schema: DatabaseSchema
    let view: DatabaseView
    let rows: [Page]
    let edit: (CellTarget) -> Void
    @State private var targeted: String?

    var body: some View {
        let groupProp = view.groupBy.flatMap { schema.property(id: $0) } ?? DatabaseQuery.groupable(schema).first
        if let groupProp {
            let groups = DatabaseQuery.groups(rows, by: groupProp, schema: schema, in: store.workspace, hideEmpty: view.hideEmptyGroups)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(groups) { group in
                        column(group, prop: groupProp)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }
        } else {
            ContentUnavailableView("Group by a property", systemImage: "rectangle.split.3x1",
                                   description: Text("Add a Select, Status or Checkbox property to use a board."))
        }
    }

    private func column(_ group: RowGroup, prop: PropertyDefinition) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if group.id.isEmpty {
                    Text(group.title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                } else {
                    OptionChip(name: group.title, color: group.color, dot: prop.type == .status)
                }
                Text("\(group.rows.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    let v = DatabaseQuery.value(forGroup: group.id, prop: prop, current: nil)
                    if let id = store.newRow(in: db.id, properties: v.map { [prop.id: $0] } ?? [:]) { app.open(id) }
                } label: { Image(systemName: "plus").font(.caption) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            ForEach(group.rows) { row in
                BoardCard(row: row, schema: schema, view: view, hide: prop.id)
                    .onTapGesture { app.open(row.id) }
                    .draggable(row.id.uuidString)
                    .contextMenu {
                        Button(role: .destructive) { store.trash(row.id) } label: { Label("Delete", systemImage: "trash") }
                    }
            }
            Button {
                let v = DatabaseQuery.value(forGroup: group.id, prop: prop, current: nil)
                if let id = store.newRow(in: db.id, properties: v.map { [prop.id: $0] } ?? [:]) { app.open(id) }
            } label: {
                Label("New", systemImage: "plus").font(.footnote).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 20)
        }
        .padding(10)
        .frame(width: 260)
        .background((group.color == .none ? Color(UIColor.secondarySystemBackground) : group.color.background).opacity(targeted == group.id ? 0.6 : 1),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(targeted == group.id ? Palette.accent : Color.clear, lineWidth: 2))
        .dropDestination(for: String.self) { ids, _ in
            for s in ids {
                guard let id = UUID(uuidString: s) else { continue }
                let current = store.page(id)?.properties[prop.id]
                store.setProperty(id, prop.id, DatabaseQuery.value(forGroup: group.id, prop: prop, current: current))
            }
            Haptics.tap()
            return true
        } isTargeted: { on in targeted = on ? group.id : (targeted == group.id ? nil : targeted) }
    }
}

/// A row as a card (board and gallery).
struct BoardCard: View {
    @Environment(WorkspaceStore.self) private var store
    let row: Page
    let schema: DatabaseSchema
    let view: DatabaseView
    var hide: String?
    var showCover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showCover {
                cover.frame(height: 110).clipped()
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if !row.icon.isEmpty { Text(row.icon) }
                    Text(row.displayTitle).font(.subheadline.weight(.semibold))
                        .foregroundStyle(row.title.isEmpty ? .secondary : .primary)
                        .lineLimit(3)
                }
                ForEach(view.visibleProperties(schema).filter { $0.type != .title && $0.id != hide }.prefix(5)) { p in
                    let v = PropertyResolver.resolve(row, p, schema: schema, in: store.workspace)
                    if !v.isEmpty && !(p.type == .checkbox && v == .bool(false)) {
                        PropertyValueView(value: v, prop: p).font(.caption)
                    }
                }
            }
            .padding(showCover ? 10 : 0)
        }
        .padding(showCover ? 0 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(UIColor.systemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(UIColor.separator).opacity(0.5), lineWidth: 0.5))
    }

    @ViewBuilder private var cover: some View {
        if view.cardCover == .pageCover, let c = row.cover {
            CoverView(cover: c, height: 110)
        } else if view.cardCover != .none, let img = row.firstImageURL {
            StoredImage(source: img, contentMode: .fill)
        } else if view.cardCover == .pageContent || view.cardCover == .pageCover {
            ZStack(alignment: .topLeading) {
                Color(UIColor.secondarySystemBackground)
                Text(row.excerpt(maxLength: 140)).font(.caption2).foregroundStyle(.secondary).padding(8)
            }
        } else {
            EmptyView()
        }
    }
}

// MARK: - List

struct DBListView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(AppModel.self) private var app
    let db: Page
    let schema: DatabaseSchema
    let view: DatabaseView
    let rows: [Page]
    let newRow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                Button { app.open(row.id) } label: {
                    HStack(spacing: 8) {
                        PageIconView(page: row, size: 15)
                        Text(row.displayTitle).foregroundStyle(row.title.isEmpty ? .secondary : .primary).lineLimit(1)
                        Spacer()
                        ForEach(view.visibleProperties(schema).filter { $0.type != .title }.prefix(2)) { p in
                            PropertyValueView(value: PropertyResolver.resolve(row, p, schema: schema, in: store.workspace), prop: p)
                                .font(.caption)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu { Button(role: .destructive) { store.trash(row.id) } label: { Label("Delete", systemImage: "trash") } }
                Divider()
            }
            Button(action: newRow) { Label("New", systemImage: "plus").font(.footnote).foregroundStyle(.secondary).padding(.vertical, 10) }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
    }
}

// MARK: - Gallery

struct DBGalleryView: View {
    @Environment(AppModel.self) private var app
    @Environment(WorkspaceStore.self) private var store
    let db: Page
    let schema: DatabaseSchema
    let view: DatabaseView
    let rows: [Page]
    let newRow: () -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
            ForEach(rows) { row in
                BoardCard(row: row, schema: schema, view: view, showCover: view.cardCover != .none)
                    .onTapGesture { app.open(row.id) }
                    .contextMenu { Button(role: .destructive) { store.trash(row.id) } label: { Label("Delete", systemImage: "trash") } }
            }
            Button(action: newRow) {
                VStack {
                    Image(systemName: "plus").font(.title3)
                    Text("New").font(.footnote)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120)
                .background(RoundedRectangle(cornerRadius: 10).stroke(style: StrokeStyle(lineWidth: 1, dash: [4])).foregroundStyle(.tertiary))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
    }
}

// MARK: - Calendar

struct DBCalendarView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(AppModel.self) private var app
    let db: Page
    let schema: DatabaseSchema
    let view: DatabaseView
    let rows: [Page]
    let edit: (CellTarget) -> Void
    @State private var month = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date()))!
    @State private var selectedDay: Date?

    var body: some View {
        let cal = Calendar.current
        let dateProp = view.dateProperty.flatMap { schema.property(id: $0) } ?? schema.properties.first { $0.type == .date }
        VStack(spacing: 8) {
            HStack {
                Text(month.formatted(.dateTime.month(.wide).year())).font(.headline)
                Spacer()
                Button { month = cal.date(byAdding: .month, value: -1, to: month)! } label: { Image(systemName: "chevron.left") }
                Button("Today") { month = cal.date(from: cal.dateComponents([.year, .month], from: Date()))! }.font(.footnote)
                Button { month = cal.date(byAdding: .month, value: 1, to: month)! } label: { Image(systemName: "chevron.right") }
            }
            .padding(.horizontal, 20)
            if let dateProp {
                let byDay = rowsByDay(dateProp)
                let days = monthGrid()
                let symbols = cal.veryShortStandaloneWeekdaySymbols
                let first = cal.firstWeekday - 1
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
                    ForEach(0..<7, id: \.self) { i in
                        Text(symbols[(i + first) % 7]).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    ForEach(days, id: \.self) { day in
                        let inMonth = cal.isDate(day, equalTo: month, toGranularity: .month)
                        let items = byDay[cal.startOfDay(for: day)] ?? []
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(cal.component(.day, from: day))")
                                .font(.caption2.weight(cal.isDateInToday(day) ? .bold : .regular))
                                .foregroundStyle(cal.isDateInToday(day) ? Color.white : (inMonth ? Color.primary : Color.secondary))
                                .frame(width: 20, height: 20)
                                .background(cal.isDateInToday(day) ? Palette.accent : Color.clear, in: Circle())
                            ForEach(items.prefix(2)) { r in
                                Text(r.displayTitle).font(.system(size: 9)).lineLimit(1)
                                    .padding(.horizontal, 3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Palette.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                            }
                            if items.count > 2 { Text("+\(items.count - 2)").font(.system(size: 9)).foregroundStyle(.secondary) }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
                        .padding(2)
                        .background(inMonth ? Color(UIColor.secondarySystemBackground) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                        .onTapGesture { selectedDay = cal.startOfDay(for: day) }
                    }
                }
                .padding(.horizontal, 12)
                .sheet(item: Binding(get: { selectedDay.map { DayBox(date: $0) } }, set: { selectedDay = $0?.date })) { box in
                    DayRowsSheet(db: db, date: box.date, dateProp: dateProp, rows: byDay[box.date] ?? [])
                }
                let undated = rows.filter { PropertyResolver.resolve($0, dateProp, schema: schema, in: store.workspace).dateValue == nil }
                if !undated.isEmpty {
                    DisclosureGroup("No \(dateProp.name) (\(undated.count))") {
                        ForEach(undated) { r in
                            Button { app.open(r.id) } label: { PageRowLabel(page: r) }.buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                    .font(.footnote)
                }
            } else {
                ContentUnavailableView("No date property", systemImage: "calendar", description: Text("Add a Date property to use the calendar."))
            }
        }
    }

    private func rowsByDay(_ prop: PropertyDefinition) -> [Date: [Page]] {
        let cal = Calendar.current
        var out: [Date: [Page]] = [:]
        for r in rows {
            let v = PropertyResolver.resolve(r, prop, schema: schema, in: store.workspace)
            guard case .date(let d) = v else { continue }
            var day = cal.startOfDay(for: d.start)
            let end = cal.startOfDay(for: d.end ?? d.start)
            var guardCount = 0
            while day <= end && guardCount < 62 {
                out[day, default: []].append(r)
                day = cal.date(byAdding: .day, value: 1, to: day)!
                guardCount += 1
            }
        }
        return out
    }

    private func monthGrid() -> [Date] {
        let cal = Calendar.current
        let firstWeekday = cal.component(.weekday, from: month)
        let lead = (firstWeekday - cal.firstWeekday + 7) % 7
        let start = cal.date(byAdding: .day, value: -lead, to: month)!
        let daysInMonth = cal.range(of: .day, in: .month, for: month)?.count ?? 30
        let total = Int(ceil(Double(lead + daysInMonth) / 7)) * 7
        return (0..<total).map { cal.date(byAdding: .day, value: $0, to: start)! }
    }
}

struct DayBox: Identifiable {
    var id: Date { date }
    var date: Date
}

struct DayRowsSheet: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let db: Page
    let date: Date
    let dateProp: PropertyDefinition
    let rows: [Page]

    var body: some View {
        NavigationStack {
            List {
                ForEach(rows) { r in
                    Button {
                        dismiss()
                        app.open(r.id)
                    } label: { PageRowLabel(page: r) }
                    .buttonStyle(.plain)
                }
                Button {
                    let id = store.newRow(in: db.id, properties: [dateProp.id: .date(DateValue(start: date))])
                    dismiss()
                    if let id { app.open(id) }
                } label: { Label("New on this day", systemImage: "plus") }
            }
            .navigationTitle(date.formatted(date: .complete, time: .omitted))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Timeline

struct DBTimelineView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(AppModel.self) private var app
    let db: Page
    let schema: DatabaseSchema
    let view: DatabaseView
    let rows: [Page]
    private let dayWidth: CGFloat = 28

    var body: some View {
        let cal = Calendar.current
        let startProp = view.dateProperty.flatMap { schema.property(id: $0) } ?? schema.properties.first { $0.type == .date }
        let endProp = view.endDateProperty.flatMap { schema.property(id: $0) }
        if let startProp {
            let spans: [TimelineSpan] = rows.compactMap { r in
                guard case .date(let d) = PropertyResolver.resolve(r, startProp, schema: schema, in: store.workspace) else { return nil }
                var end = d.end ?? d.start
                if let endProp, case .date(let e) = PropertyResolver.resolve(r, endProp, schema: schema, in: store.workspace) { end = e.start }
                return TimelineSpan(page: r, start: cal.startOfDay(for: d.start), end: cal.startOfDay(for: max(end, d.start)))
            }
            let today = cal.startOfDay(for: Date())
            let first = cal.date(byAdding: .day, value: -3, to: min(spans.map(\.start).min() ?? today, today))!
            let last = cal.date(byAdding: .day, value: 7, to: max(spans.map(\.end).max() ?? today, today))!
            let dayCount = max(1, (cal.dateComponents([.day], from: first, to: last).day ?? 1) + 1)
            ScrollView(.horizontal, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 0) {
                        ForEach(0..<dayCount, id: \.self) { i in
                            let d = cal.date(byAdding: .day, value: i, to: first)!
                            VStack(spacing: 1) {
                                if cal.component(.day, from: d) == 1 || i == 0 {
                                    Text(d.formatted(.dateTime.month(.abbreviated))).font(.system(size: 9, weight: .semibold))
                                } else {
                                    Text(" ").font(.system(size: 9))
                                }
                                Text("\(cal.component(.day, from: d))").font(.system(size: 10))
                                    .foregroundStyle(cal.isDateInToday(d) ? Palette.accent : .secondary)
                            }
                            .frame(width: dayWidth)
                        }
                    }
                    ForEach(spans) { span in
                        let offset = CGFloat(cal.dateComponents([.day], from: first, to: span.start).day ?? 0) * dayWidth
                        let length = CGFloat((cal.dateComponents([.day], from: span.start, to: span.end).day ?? 0) + 1) * dayWidth
                        Button { app.open(span.page.id) } label: {
                            Text(span.page.displayTitle).font(.caption.weight(.medium)).lineLimit(1)
                                .padding(.horizontal, 8)
                                .frame(width: max(length, dayWidth * 3), height: 26, alignment: .leading)
                                .background(Palette.accent.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, offset)
                    }
                    if spans.isEmpty {
                        Text("No rows with a \(startProp.name) yet.").font(.footnote).foregroundStyle(.secondary).padding()
                    }
                }
                .padding(.horizontal, 20)
                .background(alignment: .topLeading) {
                    let x = CGFloat(cal.dateComponents([.day], from: first, to: today).day ?? 0) * dayWidth + 20 + dayWidth / 2
                    Rectangle().fill(Palette.accent.opacity(0.4)).frame(width: 1).padding(.leading, x)
                }
            }
        } else {
            ContentUnavailableView("No date property", systemImage: "chart.bar.xaxis", description: Text("Add a Date property to use the timeline."))
        }
    }
}

struct TimelineSpan: Identifiable {
    var id: UUID { page.id }
    let page: Page
    let start: Date
    let end: Date
}

// MARK: - Chart

struct DBChartView: View {
    @Environment(WorkspaceStore.self) private var store
    let db: Page
    let schema: DatabaseSchema
    let view: DatabaseView
    let rows: [Page]

    struct Point: Identifiable {
        var id: String { label }
        var label: String
        var count: Int
        var color: Tint
    }

    var body: some View {
        let prop = view.groupBy.flatMap { schema.property(id: $0) } ?? DatabaseQuery.groupable(schema).first
        let data = DatabaseQuery.chartData(rows: rows, by: prop, schema: schema, in: store.workspace)
            .map { Point(label: $0.label, count: $0.count, color: $0.color) }
        VStack(alignment: .leading, spacing: 8) {
            Text(prop.map { "Rows by \($0.name)" } ?? "Rows").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            if data.isEmpty {
                Text("Nothing to chart yet.").foregroundStyle(.secondary)
            } else {
                Group {
                    switch view.chartKind {
                    case .bar:
                        Chart(data) { p in
                            BarMark(x: .value("Group", p.label), y: .value("Count", p.count))
                                .foregroundStyle(p.color.dot)
                                .annotation(position: .top) { Text("\(p.count)").font(.caption2).foregroundStyle(.secondary) }
                        }
                    case .donut:
                        Chart(data) { p in
                            SectorMark(angle: .value("Count", p.count), innerRadius: .ratio(0.6), angularInset: 1.5)
                                .foregroundStyle(p.color.dot)
                                .annotation(position: .overlay) { Text("\(p.count)").font(.caption2.bold()).foregroundStyle(.white) }
                        }
                        .chartBackground { _ in
                            VStack {
                                Text("\(rows.count)").font(.title.bold())
                                Text("rows").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    case .line:
                        Chart(data) { p in
                            LineMark(x: .value("Group", p.label), y: .value("Count", p.count))
                            PointMark(x: .value("Group", p.label), y: .value("Count", p.count))
                        }
                        .foregroundStyle(Palette.accent)
                    }
                }
                .frame(height: 240)
                if view.chartKind == .donut {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(data) { p in
                            HStack(spacing: 6) {
                                Circle().fill(p.color.dot).frame(width: 8, height: 8)
                                Text(p.label).font(.caption)
                                Spacer()
                                Text("\(p.count)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 20)
    }
}
