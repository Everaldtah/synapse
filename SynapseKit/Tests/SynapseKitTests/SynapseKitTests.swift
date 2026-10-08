import XCTest
@testable import SynapseKit

final class InlineMarkdownTests: XCTestCase {
    func testTokens() {
        let s = "A **bold** and *it* with [[Page|alias]] #tag `code` ==hi== ~~no~~ $x^2$ @2026-10-08 https://example.com."
        let kinds = InlineMarkdown.tokens(in: s).map(\.kind)
        XCTAssertTrue(kinds.contains(.bold))
        XCTAssertTrue(kinds.contains(.italic))
        XCTAssertTrue(kinds.contains(.code))
        XCTAssertTrue(kinds.contains(.highlight))
        XCTAssertTrue(kinds.contains(.strike))
        XCTAssertTrue(kinds.contains(.math))
        XCTAssertTrue(kinds.contains(.tag("tag")))
        XCTAssertTrue(kinds.contains(.date("2026-10-08")))
        XCTAssertTrue(kinds.contains(.url("https://example.com")))
        XCTAssertTrue(kinds.contains(.wikiLink(WikiLink(target: "Page", alias: "alias"))))
    }

    func testPlainText() {
        XCTAssertEqual(InlineMarkdown.plainText("A **bold** [[Page|alias]] and [[Other]] `x`"), "A bold alias and Other x")
        XCTAssertEqual(InlineMarkdown.plainText("price is $5 and $6"), "price is $5 and $6")
        XCTAssertEqual(InlineMarkdown.plainText("snake_case_name stays"), "snake_case_name stays")
    }

    func testCodeProtectsContent() {
        let toks = InlineMarkdown.tokens(in: "`**not bold**` [[x]]")
        XCTAssertFalse(toks.contains { $0.kind == .bold })
        XCTAssertEqual(InlineMarkdown.wikiLinks(in: "`[[no]]` [[yes]]").map(\.target), ["yes"])
    }

    func testWikiLinkParts() {
        let l = InlineMarkdown.parseWikiLink("Page#Section|shown")
        XCTAssertEqual(l.target, "Page")
        XCTAssertEqual(l.heading, "Section")
        XCTAssertEqual(l.alias, "shown")
        XCTAssertEqual(l.markdown, "[[Page#Section|shown]]")
        XCTAssertTrue(InlineMarkdown.parseWikiLink("Img", embed: true).isEmbed)
    }

    func testHeadingIsNotTag() {
        XCTAssertTrue(InlineMarkdown.tags(in: "# Heading").isEmpty)
        XCTAssertEqual(InlineMarkdown.tags(in: "x #Project/alpha y"), ["project/alpha"])
        XCTAssertTrue(InlineMarkdown.tags(in: "color #333 and a#b").isEmpty)
    }

    func testToggleWrap() {
        let (t, r) = InlineMarkdown.toggleWrap("hello world", range: NSRange(location: 6, length: 5), open: "**", close: "**")
        XCTAssertEqual(t, "hello **world**")
        XCTAssertEqual(r, NSRange(location: 8, length: 5))
        let (u, r2) = InlineMarkdown.toggleWrap(t, range: r, open: "**", close: "**")
        XCTAssertEqual(u, "hello world")
        XCTAssertEqual(r2, NSRange(location: 6, length: 5))
    }
}

final class MarkdownCodecTests: XCTestCase {
    func testRoundTrip() {
        let blocks: [Block] = [
            Block(type: .heading1, text: "Title"),
            Block(type: .paragraph, text: "Some **text** with [[Link]]"),
            Block(type: .bulleted, text: "one"),
            Block(type: .bulleted, text: "nested", indent: 1),
            Block(type: .numbered, text: "first"),
            Block(type: .numbered, text: "second"),
            Block(type: .todo, text: "done", checked: true),
            Block(type: .todo, text: "open"),
            Block(type: .toggle, text: "More"),
            Block(type: .paragraph, text: "hidden child", indent: 1),
            Block(type: .quote, text: "A quote"),
            Block(type: .callout, text: "Careful", icon: "⚠️"),
            Block(type: .divider),
            Block(type: .code, text: "let x = 1\nprint(x)", language: "swift"),
            Block(type: .equation, text: "E = mc^2"),
            Block(type: .table, table: [["a", "b"], ["1", "2"]]),
            Block(type: .image, url: "https://example.com/a.png", caption: "pic"),
        ]
        let md = MarkdownCodec.blocksToMarkdown(blocks)
        let back = MarkdownCodec.parseBlocks(md)
        XCTAssertEqual(back.map(\.type), blocks.map(\.type), md)
        XCTAssertEqual(back.map(\.text), blocks.map(\.text), md)
        XCTAssertEqual(back.map(\.indent), blocks.map(\.indent), md)
        XCTAssertEqual(back[6].checked, true)
        XCTAssertEqual(back[11].icon, "⚠️")
        XCTAssertEqual(back[13].language, "swift")
        XCTAssertEqual(back[15].table, [["a", "b"], ["1", "2"]])
        XCTAssertEqual(back[16].url, "https://example.com/a.png")
    }

    func testFrontmatterAndTitle() {
        let md = """
        ---
        tags: [alpha, "beta"]
        aliases:
          - Other name
        status: draft
        ---
        # My Note

        Body text #gamma
        """
        let imp = MarkdownCodec.parse(md, fallbackTitle: "file")
        XCTAssertEqual(imp.title, "My Note")
        XCTAssertEqual(imp.tags, ["alpha", "beta"])
        XCTAssertEqual(imp.aliases, ["Other name"])
        XCTAssertEqual(imp.frontmatter["status"], "draft")
        XCTAssertEqual(imp.blocks.first?.text, "Body text #gamma")
    }

    func testObsidianCallouts() {
        let md = "> [!warning] Watch out\n> second line\n\n> [!faq]- Folded\n> inside"
        let b = MarkdownCodec.parseBlocks(md)
        XCTAssertEqual(b[0].type, .callout)
        XCTAssertEqual(b[0].icon, "⚠️")
        XCTAssertEqual(b[0].text, "Watch out\nsecond line")
        XCTAssertEqual(b[1].type, .toggle)
        XCTAssertTrue(b[1].collapsed)
        XCTAssertEqual(b[2].indent, 1)
    }

    func testTwoSpaceLists() {
        let b = MarkdownCodec.parseBlocks("- a\n  - b\n    - c\n- d")
        XCTAssertEqual(b.map(\.indent), [0, 1, 2, 0])
    }

    func testFileName() {
        XCTAssertEqual(MarkdownCodec.fileName(for: "a/b:c?"), "a-b-c-")
        XCTAssertEqual(MarkdownCodec.fileName(for: "  "), "Untitled")
    }
}

final class FormulaTests: XCTestCase {
    func eval(_ src: String, props: [String: FormulaValue] = [:]) throws -> FormulaValue {
        let ctx = FormulaContext(now: Date(timeIntervalSince1970: 1_790_000_000)) { name in
            guard let v = props[name] else { throw FormulaError("No property \(name)") }
            return v
        }
        return try FormulaEvaluator.evaluate(try FormulaParser.parse(src), ctx)
    }

    func testArithmetic() throws {
        XCTAssertEqual(try eval("1 + 2 * 3"), .number(7))
        XCTAssertEqual(try eval("(1 + 2) * 3"), .number(9))
        XCTAssertEqual(try eval("2 ^ 3 ^ 2"), .number(512))
        XCTAssertEqual(try eval("10 % 4"), .number(2))
        XCTAssertEqual(try eval("-3 + 5"), .number(2))
        XCTAssertEqual(try eval("round(2.345, 2)"), .number(2.35))
    }

    func testLogicAndText() throws {
        XCTAssertEqual(try eval("if(prop(\"Done\"), \"yes\", \"no\")", props: ["Done": .bool(true)]), .string("yes"))
        XCTAssertEqual(try eval("prop(\"N\") > 3 and prop(\"N\") < 10", props: ["N": .number(5)]), .bool(true))
        XCTAssertEqual(try eval("prop(\"N\") > 3 ? \"big\" : \"small\"", props: ["N": .number(1)]), .string("small"))
        XCTAssertEqual(try eval("\"a\" + 1"), .string("a1"))
        XCTAssertEqual(try eval("concat(\"x\", \"y\")"), .string("xy"))
        XCTAssertEqual(try eval("upper(\"abc\").length()"), .number(3))
        XCTAssertEqual(try eval("replaceAll(\"a-b-c\", \"-\", \"+\")"), .string("a+b+c"))
        XCTAssertEqual(try eval("not empty(\"x\")"), .bool(true))
        XCTAssertEqual(try eval("ifs(false, 1, true, 2, 3)"), .number(2))
    }

    func testListsAndLambdas() throws {
        XCTAssertEqual(try eval("map([1, 2, 3], current * 2)"), .list([.number(2), .number(4), .number(6)]))
        XCTAssertEqual(try eval("[3, 1, 2].sort().join(\"-\")"), .string("1-2-3"))
        XCTAssertEqual(try eval("filter([1, 2, 3, 4], current % 2 == 0).length()"), .number(2))
        XCTAssertEqual(try eval("lets(a, 2, b, 3, a * b)"), .number(6))
        XCTAssertEqual(try eval("sum(1, 2, [3, 4])"), .number(10))
    }

    func testDates() throws {
        let d = Date(timeIntervalSince1970: 1_790_000_000)
        let later = Calendar.current.date(byAdding: .day, value: 10, to: d)!
        XCTAssertEqual(try eval("dateBetween(prop(\"A\"), prop(\"B\"), \"days\")", props: ["A": .date(later), "B": .date(d)]), .number(10))
        if case .date(let r) = try eval("dateAdd(prop(\"B\"), 1, \"weeks\")", props: ["B": .date(d)]) {
            XCTAssertEqual(Calendar.current.dateComponents([.day], from: d, to: r).day, 7)
        } else { XCTFail() }
        XCTAssertEqual(try eval("formatDate(fromTimestamp(0), \"YYYY\")").text.count, 4)
    }

    func testErrors() {
        XCTAssertThrowsError(try eval("1 +"))
        XCTAssertThrowsError(try eval("nope(1)"))
        XCTAssertThrowsError(try eval("prop(\"Missing\")"))
    }
}

final class WorkspaceTests: XCTestCase {
    func testTreeTrashRestoreDuplicate() {
        var ws = Workspace()
        let a = ws.createPage(title: "A")
        let b = ws.createPage(title: "B", parentID: a)
        let c = ws.createPage(title: "C", parentID: b, blocks: [Block(type: .childPage, pageID: nil)])
        XCTAssertEqual(ws.children(of: a).map(\.id), [b])
        XCTAssertEqual(ws.ancestors(of: c).map(\.title), ["A", "B"])
        XCTAssertFalse(ws.move(a, to: c), "a page can't move into its own descendant")
        ws.trash(b)
        XCTAssertTrue(ws[c]!.isTrashed)
        XCTAssertEqual(ws.trash.map(\.id), [b])
        ws.restore(b)
        XCTAssertFalse(ws[c]!.isTrashed)
        let copy = ws.duplicate(a)!
        XCTAssertEqual(ws.descendants(of: copy).count, 2)
        XCTAssertEqual(ws[copy]!.title, "A (copy)")
        XCTAssertEqual(ws.deletePermanently(copy).count, 3)
    }

    func testLinksBacklinksAndRename() {
        var ws = Workspace()
        let a = ws.createPage(title: "Alpha", blocks: [Block(text: "see [[Beta]] and [[Gamma]] #x")])
        let b = ws.createPage(title: "Beta", blocks: [Block(text: "mentions Alpha in plain text")])
        let index = LinkIndex(workspace: ws)
        XCTAssertEqual(index.outgoing[a], [b])
        XCTAssertEqual(index.unresolved[a], ["Gamma"])
        XCTAssertEqual(index.linkedMentions(of: b).map(\.sourceID), [a])
        XCTAssertEqual(index.tags["x"], [a])
        let unlinked = LinkIndex.unlinkedMentions(of: ws[a]!, in: ws)
        XCTAssertEqual(unlinked.map(\.sourceID), [b])
        XCTAssertEqual(LinkIndex.linkFirstMention(of: "Alpha", in: "mentions Alpha in plain text", target: "Alpha"), "mentions [[Alpha]] in plain text")
        ws.rename(b, to: "Bravo")
        XCTAssertEqual(ws.updateLinks(from: "Beta", to: "Bravo"), 1)
        XCTAssertEqual(ws[a]!.blocks[0].text, "see [[Bravo]] and [[Gamma]] #x")
        XCTAssertEqual(ws.resolve("bravo")?.id, b)
    }

    func testDailyNote() {
        var ws = Workspace()
        let d = Date()
        let id = ws.dailyNote(for: d)
        XCTAssertEqual(ws.dailyNote(for: d), id)
        XCTAssertEqual(ws.ancestors(of: id).first?.title, "Daily Notes")
    }

    func testCodableRoundTrip() throws {
        let ws = Templates.seedWorkspace()
        let data = try JSONEncoder().encode(ws)
        let back = try JSONDecoder().decode(Workspace.self, from: data)
        XCTAssertEqual(back.pages.count, ws.pages.count)
        let page = ws.pages.values.first { $0.kind == .database }!
        XCTAssertEqual(back[page.id], page)
        // Missing fields decode with defaults.
        let minimal = try JSONDecoder().decode(Page.self, from: Data(#"{"title":"x","blocks":[{"type":"futureBlock","text":"y"}]}"#.utf8))
        XCTAssertEqual(minimal.blocks.first?.type, .paragraph)
        XCTAssertEqual(minimal.title, "x")
    }
}

final class DatabaseTests: XCTestCase {
    func makeDB() -> (Workspace, UUID, PropertyDefinition, PropertyDefinition, PropertyDefinition) {
        var ws = Workspace()
        let status = PropertyDefinition(name: "Status", type: .status, options: PropertyDefinition.defaultStatusOptions())
        let n = PropertyDefinition(name: "Points", type: .number)
        let f = PropertyDefinition(name: "Double", type: .formula, formula: "prop(\"Points\") * 2")
        let db = ws.createDatabase(title: "DB", schema: DatabaseSchema(properties: [status, n, f]))
        ws.createRow(in: db, title: "one", properties: [status.id: .select(status.options[0].id), n.id: .number(3)])
        ws.createRow(in: db, title: "two", properties: [status.id: .select(status.options[2].id), n.id: .number(1)])
        ws.createRow(in: db, title: "three", properties: [n.id: .number(2)])
        return (ws, db, status, n, f)
    }

    func testFilterSortGroupFormula() {
        let (ws, db, status, n, f) = makeDB()
        let page = ws[db]!
        var view = DatabaseView(type: .table, sorts: [SortRule(propertyID: n.id)])
        XCTAssertEqual(DatabaseQuery.rows(for: view, database: page, in: ws).map(\.title), ["two", "three", "one"])
        view.filters = [FilterRule(propertyID: n.id, op: .greaterThan, value: "1")]
        XCTAssertEqual(DatabaseQuery.rows(for: view, database: page, in: ws).map(\.title), ["three", "one"])
        view.filters = [FilterRule(propertyID: status.id, op: .equals, value: "Done")]
        XCTAssertEqual(DatabaseQuery.rows(for: view, database: page, in: ws).map(\.title), ["two"])
        let groups = DatabaseQuery.groups(ws.rows(of: db), by: status, schema: page.schema!, in: ws)
        XCTAssertEqual(groups.map(\.title), ["No Status", "Not started", "In progress", "Done"])
        XCTAssertEqual(groups.map { $0.rows.count }, [1, 1, 0, 1])
        let one = ws.rows(of: db)[0]
        XCTAssertEqual(PropertyResolver.resolve(one, f, schema: page.schema!, in: ws), .number(6))
        XCTAssertEqual(DatabaseQuery.rows(for: DatabaseView(), database: page, in: ws, search: "thr").map(\.title), ["three"])
    }

    func testRelationsRollupsTwoWay() {
        var ws = Workspace()
        let projects = ws.createDatabase(title: "Projects")
        let tasksSchema = DatabaseSchema(properties: [PropertyDefinition(name: "Hours", type: .number)])
        let tasks = ws.createDatabase(title: "Tasks", schema: tasksSchema)
        let rel = ws.addRelation(in: projects, name: "Tasks", to: tasks, twoWay: true)!
        let hours = ws[tasks]!.schema!.property(named: "Hours")!
        let t1 = ws.createRow(in: tasks, title: "t1", properties: [hours.id: .number(2)])!
        let t2 = ws.createRow(in: tasks, title: "t2", properties: [hours.id: .number(5)])!
        let p = ws.createRow(in: projects, title: "P")!
        ws.setProperty(p, rel, .relation([t1, t2]))
        let reverse = ws[projects]!.schema!.property(id: rel)!.relation!.reversePropertyID!
        XCTAssertEqual(ws[t1]!.properties[reverse], .relation([p]))
        var schema = ws[projects]!.schema!
        let roll = PropertyDefinition(name: "Total", type: .rollup, rollup: RollupConfig(relationPropertyID: rel, targetPropertyID: hours.id, function: .sum))
        schema.properties.append(roll)
        ws[projects]!.schema = schema
        XCTAssertEqual(PropertyResolver.resolve(ws[p]!, roll, schema: schema, in: ws), .number(7))
        ws.setProperty(p, rel, .relation([t2]))
        XCTAssertEqual(ws[t1]!.properties[reverse], .relation([]))
    }

    func testUniqueIDAndNumberFormat() {
        var ws = Workspace()
        let uid = PropertyDefinition(name: "ID", type: .uniqueID, idPrefix: "TASK")
        let db = ws.createDatabase(title: "T", schema: DatabaseSchema(properties: [uid]))
        let r1 = ws.createRow(in: db)!
        let r2 = ws.createRow(in: db)!
        let schema = ws[db]!.schema!
        XCTAssertEqual(PropertyResolver.resolve(ws[r1]!, uid, schema: schema, in: ws), .text("TASK-1"))
        XCTAssertEqual(PropertyResolver.resolve(ws[r2]!, uid, schema: schema, in: ws), .text("TASK-2"))
        XCTAssertEqual(PropertyResolver.formatNumber(1234.5, .dollar), "$1,234.50")
        XCTAssertEqual(PropertyResolver.formatNumber(0.25, .percent), "25%")
    }

    func testChangePropertyType() {
        var ws = Workspace()
        let text = PropertyDefinition(name: "Kind", type: .text)
        let db = ws.createDatabase(title: "D", schema: DatabaseSchema(properties: [text]))
        let a = ws.createRow(in: db, properties: [text.id: .text("Book")])!
        let b = ws.createRow(in: db, properties: [text.id: .text("Article")])!
        ws.changePropertyType(text.id, in: db, to: .select)
        let prop = ws[db]!.schema!.property(id: text.id)!
        XCTAssertEqual(Set(prop.options.map(\.name)), ["Book", "Article"])
        XCTAssertEqual(ws[a]!.properties[text.id], .select(prop.option(named: "Book")!.id))
        ws.changePropertyType(text.id, in: db, to: .text)
        XCTAssertEqual(ws[b]!.properties[text.id], .text("Article"))
        ws.setProperty(a, text.id, .text("42"))
        ws.changePropertyType(text.id, in: db, to: .number)
        XCTAssertEqual(ws[a]!.properties[text.id], .number(42))
    }

    func testTemplatesAllEvaluate() {
        var ws = Workspace()
        for kind in TemplateKind.allCases { Templates.instantiate(kind, in: &ws) }
        for db in ws.databases {
            let schema = db.schema!
            for row in ws.rows(of: db.id) {
                for p in schema.properties {
                    if case .text(let t) = PropertyResolver.resolve(row, p, schema: schema, in: ws) {
                        XCTAssertFalse(t.hasPrefix("⚠︎"), "\(db.title).\(p.name): \(t)")
                    }
                }
            }
            for v in db.views { _ = DatabaseQuery.rows(for: v, database: db, in: ws) }
        }
    }
}

final class GraphAndSearchTests: XCTestCase {
    func testGraphBuildAndLayout() {
        let ws = Templates.seedWorkspace()
        let index = LinkIndex(workspace: ws)
        var opts = GraphOptions()
        opts.showTags = true
        let g = GraphBuilder.build(ws, index: index, options: opts)
        XCTAssertGreaterThan(g.nodes.count, 5)
        XCTAssertGreaterThan(g.edges.count, 3)
        XCTAssertTrue(g.nodes.contains { $0.kind == .tag })
        let layout = ForceLayout()
        layout.load(g)
        for _ in 0..<400 { layout.tick() }
        XCTAssertTrue(layout.isSettled)
        XCTAssertTrue(layout.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        // Linked nodes end up closer than the layout's spread.
        let b = layout.bounds
        XCTAssertLessThan(b.maxX - b.minX, 5000)

        let welcome = ws.livePages.first { $0.title == "Welcome to Synapse" }!
        opts.focus = welcome.id
        opts.showTags = false
        let local = GraphBuilder.build(ws, index: index, options: opts)
        XCTAssertTrue(local.nodes.contains { $0.pageID == welcome.id })
        XCTAssertLessThan(local.nodes.count, g.nodes.count)
    }

    func testSearch() {
        let ws = Templates.seedWorkspace()
        let hits = Search.run("linked thinking", in: ws)
        XCTAssertEqual(ws[hits[0].pageID]?.title, "Linked thinking")
        XCTAssertNotNil(Search.fuzzyScore("lth", "Linked thinking"))
        XCTAssertNil(Search.fuzzyScore("zzz", "Linked thinking"))
        XCTAssertEqual(Search.quickSwitch("ideas", in: ws).first?.title, "Ideas inbox")
    }

    func testAIPromptsAndRetrieval() {
        let ws = Templates.seedWorkspace()
        let req = AIPrompts.request(for: .improve, text: "hello", pageTitle: "T", pageContext: "ctx")
        XCTAssertTrue(req.messages[0].content.contains("<text>\nhello\n</text>"))
        let sources = AIPrompts.retrieve("how do links and tags work", in: ws)
        XCTAssertFalse(sources.isEmpty)
        let parsed = AIPrompts.parseLinkSuggestions("[[Ideas inbox]] — capture\nNone\n[[Tasks]]: work")
        XCTAssertEqual(parsed.map(\.title), ["Ideas inbox", "Tasks"])
    }
}
