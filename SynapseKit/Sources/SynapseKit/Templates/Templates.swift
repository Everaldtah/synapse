import Foundation

/// Built-in templates (the template gallery) and the first-launch workspace.
public enum TemplateKind: String, CaseIterable, Identifiable, Sendable {
    case meetingNotes, journal, weeklyPlanner, wiki, taskTracker, projectTracker, readingList, habitTracker, crm, zettelkasten

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .meetingNotes: return "Meeting notes"
        case .journal: return "Journal entry"
        case .weeklyPlanner: return "Weekly planner"
        case .wiki: return "Team wiki"
        case .taskTracker: return "Task tracker"
        case .projectTracker: return "Projects"
        case .readingList: return "Reading list"
        case .habitTracker: return "Habit tracker"
        case .crm: return "Personal CRM"
        case .zettelkasten: return "Linked notes starter"
        }
    }

    public var icon: String {
        switch self {
        case .meetingNotes: return "🗣️"
        case .journal: return "📔"
        case .weeklyPlanner: return "🗓️"
        case .wiki: return "📚"
        case .taskTracker: return "✅"
        case .projectTracker: return "🚀"
        case .readingList: return "📖"
        case .habitTracker: return "🔁"
        case .crm: return "🤝"
        case .zettelkasten: return "🧠"
        }
    }

    public var summary: String {
        switch self {
        case .meetingNotes: return "Agenda, notes and action items."
        case .journal: return "A guided daily reflection."
        case .weeklyPlanner: return "Plan each day of the week."
        case .wiki: return "A home for shared knowledge."
        case .taskTracker: return "Board, table and calendar of tasks."
        case .projectTracker: return "Projects with owners, dates and progress."
        case .readingList: return "Books, articles and podcasts in a gallery."
        case .habitTracker: return "Daily check-ins with a score formula."
        case .crm: return "People, companies and follow-ups."
        case .zettelkasten: return "Atomic notes wired together with [[links]]."
        }
    }

    public var isDatabase: Bool {
        switch self {
        case .taskTracker, .projectTracker, .readingList, .habitTracker, .crm: return true
        default: return false
        }
    }
}

public enum Templates {
    private static func p(_ text: String, _ type: BlockType = .paragraph, indent: Int = 0, checked: Bool = false) -> Block {
        Block(type: type, text: text, indent: indent, checked: checked)
    }

    /// Create a template's pages in the workspace; returns the top page.
    @discardableResult
    public static func instantiate(_ kind: TemplateKind, in ws: inout Workspace, parent: UUID? = nil, date: Date = Date()) -> UUID {
        switch kind {
        case .meetingNotes:
            return ws.createPage(title: "Meeting notes – \(DateText.short(date))", icon: kind.icon, parentID: parent, blocks: [
                Block(type: .callout, text: "**When:** @\(DateText.iso(date))  ·  **Who:** ", icon: "📅"),
                p("Agenda", .heading2), p("", .numbered),
                p("Notes", .heading2), p("", .bulleted),
                p("Decisions", .heading2), p("", .bulleted),
                p("Action items", .heading2), p("", .todo),
            ])
        case .journal:
            return ws.createPage(title: DateText.long(date), icon: kind.icon, parentID: parent, blocks: [
                p("Grateful for", .heading3), p("", .bulleted),
                p("Today's focus", .heading3), p("", .todo),
                p("What happened", .heading3), p(""),
                p("What I learned", .heading3), p(""),
                Block(type: .callout, text: "Mood: ", icon: "🌤️"),
            ])
        case .weeklyPlanner:
            var blocks: [Block] = [Block(type: .callout, text: "Top 3 goals this week", icon: "🎯"),
                                   p("", .todo), p("", .todo), p("", .todo)]
            for day in ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"] {
                blocks.append(p(day, .toggle))
                blocks.append(p("", .todo, indent: 1))
            }
            return ws.createPage(title: "Week of \(DateText.short(date))", icon: kind.icon, parentID: parent, blocks: blocks)
        case .wiki:
            let root = ws.createPage(title: "Wiki", icon: kind.icon, parentID: parent, blocks: [
                Block(type: .callout, text: "Everything the team needs to know. Add a page per topic and link them with [[links]].", icon: "📌"),
                Block(type: .tableOfContents),
                p("Getting started", .heading2), p("[[Onboarding]] · [[How we work]]", .bulleted),
                p("Reference", .heading2), p("[[Tools & accounts]]", .bulleted),
            ])
            ws.createPage(title: "Onboarding", icon: "👋", parentID: root, blocks: [p("Week one", .heading2), p("Set up your accounts — see [[Tools & accounts]]", .todo), p("Read [[How we work]]", .todo)])
            ws.createPage(title: "How we work", icon: "🛠️", parentID: root, blocks: [p("Principles", .heading2), p("Write things down.", .bulleted), p("Default to async.", .bulleted)])
            ws.createPage(title: "Tools & accounts", icon: "🔑", parentID: root, blocks: [p("", .bulleted)])
            return root
        case .taskTracker:
            let status = PropertyDefinition(name: "Status", type: .status, options: PropertyDefinition.defaultStatusOptions())
            let priority = PropertyDefinition(name: "Priority", type: .select, options: [
                SelectOption(name: "High", color: .red), SelectOption(name: "Medium", color: .yellow), SelectOption(name: "Low", color: .gray)])
            let due = PropertyDefinition(name: "Due", type: .date)
            let assignee = PropertyDefinition(name: "Assignee", type: .person)
            let schema = DatabaseSchema(properties: [
                PropertyDefinition(id: PropertyDefinition.titleID, name: "Task", type: .title), status, priority, due, assignee,
                PropertyDefinition(name: "Overdue", type: .formula,
                                   formula: "if(empty(prop(\"Due\")) or prop(\"Status\") == \"Done\", \"\", if(prop(\"Due\") < today(), \"⚠️ Overdue\", \"\"))"),
            ])
            let db = ws.createDatabase(title: "Tasks", parentID: parent, schema: schema, views: [
                DatabaseView(name: "Board", type: .board, groupBy: status.id),
                DatabaseView(name: "All tasks", type: .table, sorts: [SortRule(propertyID: due.id)]),
                DatabaseView(name: "Calendar", type: .calendar, dateProperty: due.id),
            ], icon: kind.icon)
            let cal = Calendar.current
            let samples: [(String, Int, Int, Int)] = [("Plan the week", 1, 0, 0), ("Review pull requests", 0, 1, 1), ("Write release notes", 0, 0, 3), ("Book flights", 2, 2, -2)]
            for (title, s, pr, d) in samples {
                ws.createRow(in: db, title: title, properties: [
                    status.id: .select(status.options[s].id),
                    priority.id: .select(priority.options[pr].id),
                    due.id: .date(DateValue(start: cal.date(byAdding: .day, value: d, to: cal.startOfDay(for: date))!)),
                ])
            }
            return db
        case .projectTracker:
            let status = PropertyDefinition(name: "Status", type: .status, options: [
                SelectOption(name: "Planning", color: .gray, group: .todo), SelectOption(name: "In progress", color: .blue, group: .inProgress),
                SelectOption(name: "Paused", color: .orange, group: .inProgress), SelectOption(name: "Done", color: .green, group: .complete)])
            let owner = PropertyDefinition(name: "Owner", type: .person)
            let dates = PropertyDefinition(name: "Dates", type: .date)
            let progress = PropertyDefinition(name: "Progress", type: .number, numberFormat: .percent)
            let left = PropertyDefinition(name: "Days left", type: .formula, formula: "if(empty(prop(\"Dates\")), \"\", dateBetween(prop(\"Dates\"), today(), \"days\") + \" days\")")
            let schema = DatabaseSchema(properties: [PropertyDefinition(id: PropertyDefinition.titleID, name: "Project", type: .title), status, owner, dates, progress, left])
            let db = ws.createDatabase(title: "Projects", parentID: parent, schema: schema, views: [
                DatabaseView(name: "Board", type: .board, groupBy: status.id),
                DatabaseView(name: "Table", type: .table),
                DatabaseView(name: "Calendar", type: .calendar, dateProperty: dates.id),
                DatabaseView(name: "Progress", type: .chart, groupBy: status.id, chartKind: .donut),
            ], icon: kind.icon)
            ws.createRow(in: db, title: "Website refresh", properties: [status.id: .select(status.options[1].id), progress.id: .number(0.4),
                                                                         dates.id: .date(DateValue(start: Calendar.current.date(byAdding: .day, value: 14, to: date)!))])
            ws.createRow(in: db, title: "Mobile app beta", properties: [status.id: .select(status.options[0].id), progress.id: .number(0.1)])
            return db
        case .readingList:
            let type = PropertyDefinition(name: "Type", type: .select, options: [
                SelectOption(name: "Book", color: .brown), SelectOption(name: "Article", color: .blue),
                SelectOption(name: "Podcast", color: .purple), SelectOption(name: "Video", color: .red)])
            let author = PropertyDefinition(name: "Author", type: .text)
            let status = PropertyDefinition(name: "Status", type: .status, options: [
                SelectOption(name: "To read", color: .gray, group: .todo), SelectOption(name: "Reading", color: .blue, group: .inProgress),
                SelectOption(name: "Finished", color: .green, group: .complete)])
            let rating = PropertyDefinition(name: "Rating", type: .select, options: (1...5).map { SelectOption(name: String(repeating: "★", count: $0), color: .yellow) })
            let link = PropertyDefinition(name: "Link", type: .url)
            let schema = DatabaseSchema(properties: [PropertyDefinition(id: PropertyDefinition.titleID, name: "Title", type: .title), type, author, status, rating, link])
            let db = ws.createDatabase(title: "Reading list", parentID: parent, schema: schema, views: [
                DatabaseView(name: "Gallery", type: .gallery, cardCover: .pageCover),
                DatabaseView(name: "By status", type: .board, groupBy: status.id),
                DatabaseView(name: "Table", type: .table),
            ], icon: kind.icon)
            for (t, a, ty) in [("Thinking, Fast and Slow", "Daniel Kahneman", 0), ("How to Take Smart Notes", "Sönke Ahrens", 0), ("The Art of Doing Science and Engineering", "Richard Hamming", 0)] {
                if let r = ws.createRow(in: db, title: t, properties: [type.id: .select(type.options[ty].id), author.id: .text(a), status.id: .select(status.options[0].id)]) {
                    ws[r]?.cover = Cover(kind: .gradient, value: String(Int(StableHash.of(t) % UInt64(Cover.gradientCount))))
                }
            }
            return db
        case .habitTracker:
            let day = PropertyDefinition(name: "Date", type: .date)
            let habits = ["Exercise", "Read", "Meditate", "Sleep 8h"].map { PropertyDefinition(name: $0, type: .checkbox) }
            let sum = habits.map { "toNumber(prop(\"\($0.name)\"))" }.joined(separator: " + ")
            let score = PropertyDefinition(name: "Score", type: .formula, formula: "round((\(sum)) / \(habits.count) * 100) + \"%\"")
            let schema = DatabaseSchema(properties: [PropertyDefinition(id: PropertyDefinition.titleID, name: "Day", type: .title), day] + habits + [score])
            let db = ws.createDatabase(title: "Habits", parentID: parent, schema: schema, views: [
                DatabaseView(name: "Log", type: .table, sorts: [SortRule(propertyID: day.id, ascending: false)]),
                DatabaseView(name: "Calendar", type: .calendar, dateProperty: day.id),
            ], icon: kind.icon)
            let cal = Calendar.current
            for back in 0..<3 {
                let d = cal.date(byAdding: .day, value: -back, to: cal.startOfDay(for: date))!
                var props: [String: PropertyValue] = [day.id: .date(DateValue(start: d))]
                for (i, h) in habits.enumerated() { props[h.id] = .checkbox((i + back) % 2 == 0) }
                ws.createRow(in: db, title: DateText.short(d), properties: props)
            }
            return db
        case .crm:
            let company = PropertyDefinition(name: "Company", type: .text)
            let email = PropertyDefinition(name: "Email", type: .email)
            let phone = PropertyDefinition(name: "Phone", type: .phone)
            let tags = PropertyDefinition(name: "Tags", type: .multiSelect, options: [SelectOption(name: "Friend"), SelectOption(name: "Work"), SelectOption(name: "Investor")])
            let last = PropertyDefinition(name: "Last contact", type: .date)
            let follow = PropertyDefinition(name: "Follow up", type: .formula,
                                            formula: "if(empty(prop(\"Last contact\")), \"Reach out\", if(dateBetween(today(), prop(\"Last contact\"), \"days\") > 30, \"Reach out\", \"\"))")
            let schema = DatabaseSchema(properties: [PropertyDefinition(id: PropertyDefinition.titleID, name: "Name", type: .title), company, email, phone, tags, last, follow])
            let db = ws.createDatabase(title: "People", parentID: parent, schema: schema, views: [
                DatabaseView(name: "All", type: .table), DatabaseView(name: "Cards", type: .gallery, cardCover: .none),
            ], icon: kind.icon)
            ws.createRow(in: db, title: "Ada Lovelace", properties: [company.id: .text("Analytical Engines Ltd"), tags.id: .multiSelect([tags.options[1].id])])
            return db
        case .zettelkasten:
            let root = ws.createPage(title: "Linked notes", icon: kind.icon, parentID: parent, blocks: [
                p("Each note holds one idea. Connect ideas with [[links]] and watch them form clusters in the **Graph**."),
                p("Start at [[Atomic notes]], then follow the links.", .bulleted),
            ])
            ws.createPage(title: "Atomic notes", icon: "⚛️", parentID: root, blocks: [p("One idea per note makes ideas reusable. They combine through [[Links over folders]]. #method")])
            ws.createPage(title: "Links over folders", icon: "🔗", parentID: root, blocks: [p("A note can live in one folder but link to many notes. Structure emerges from [[Atomic notes]] and their connections — see [[Emergent structure]]. #method")])
            ws.createPage(title: "Emergent structure", icon: "🌱", parentID: root, blocks: [p("Clusters in the graph show topics you didn't plan. Review them weekly. Related: [[Links over folders]]. #insight")])
            return root
        }
    }

    /// The pages a new workspace starts with.
    public static func seedWorkspace(date: Date = Date()) -> Workspace {
        var ws = Workspace(name: "My Workspace")
        let welcome = ws.createPage(title: "Welcome to Synapse", icon: "🧠", blocks: [
            Block(type: .callout, text: "Synapse is your notes, docs and databases — with **linked thinking** built in. Everything here can be edited or deleted.", icon: "👋"),
            p("The basics", .heading2),
            p("Type **/** on an empty line to add any block: headings, to-dos, toggles, tables, databases and more.", .bulleted),
            p("Markdown works as you type: `# ` heading, `- ` bullet, `[] ` to-do, `> ` toggle, `\" ` quote, `---` divider.", .bulleted),
            p("Select text to make it **bold**, *italic*, ~~struck~~, ==highlighted== or `code`.", .bulleted),
            p("Link your thinking", .heading2),
            p("Type `[[` to link another page, like [[Linked thinking]]. Links to pages that don't exist yet are created when you tap them.", .bulleted),
            p("Every page shows its **backlinks** at the bottom — who links here.", .bulleted),
            p("Open the **Graph** tab to see how your notes connect. #synapse", .bulleted),
            p("Databases", .heading2),
            p("A database is a collection of pages with properties, shown as a table, board, list, gallery, calendar or chart. Try [[Tasks]].", .bulleted),
            p("AI", .heading2),
            p("Tap ✨ on the keyboard bar or **Ask Synapse** on Home. Connect your Claude account in **Settings › Claude** — Synapse runs on your own Claude subscription through Claude Code, or on an API key.", .bulleted),
            p("Try it", .heading2),
            p("Open [[Linked thinking]]", .todo),
            p("Add a task to [[Tasks]]", .todo),
            p("Look at the Graph tab", .todo),
        ])
        ws[welcome]?.cover = Cover(kind: .gradient, value: "3")
        ws[welcome]?.isFavorite = true
        let linked = ws.createPage(title: "Linked thinking", icon: "🔗", blocks: [
            p("Notes become more valuable as they connect. A link is a thought: *this relates to that*."),
            p("Ways to connect", .heading3),
            p("`[[Page]]` links, `[[Page|alias]]` to show different text, `[[Page#Heading]]` to point at a section.", .bulleted),
            p("`#tags` group notes across the workspace. #synapse #method", .bulleted),
            p("Unlinked mentions: Synapse finds where a page's title appears as plain text so you can link it in one tap.", .bulleted),
            p("Back to [[Welcome to Synapse]] · See also [[Ideas inbox]]"),
        ])
        _ = linked
        ws.createPage(title: "Ideas inbox", icon: "💡", blocks: [
            p("Capture first, organise later. Promote an idea to its own page with `[[`."),
            p("A reading habit — track it in a database", .bulleted),
            p("Weekly review of [[Linked thinking]] clusters #method", .bulleted),
        ])
        let tasks = Templates.instantiate(.taskTracker, in: &ws, date: date)
        _ = tasks
        return ws
    }
}
