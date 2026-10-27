import XCTest
@testable import SynapseKit

final class AgentLoopTests: XCTestCase {
    let tools: [AgentToolSpec] = [.listPages, .createPage, .linkPages, .webSearch]

    func testParsesSeveralCallsSelfClosingAndApostrophes() {
        let known = Set(tools.map(\.name))
        let reply = """
        I'll make the hub first.
        <tool name="create_page" title="Bob's notes" icon='🌱'>## Hi
        See [[Other]].</tool>
        <tool name="list_pages"/>
        <tool name='link_pages' from="Say \"hi\"">A, B</tool>
        """
        let calls = Agent.parseCalls(reply, known: known, inputOptional: ["list_pages"])
        XCTAssertEqual(calls.map(\.name), ["create_page", "list_pages", "link_pages"])
        XCTAssertEqual(calls[0].attributes["title"], "Bob's notes")
        XCTAssertEqual(calls[0].attributes["icon"], "🌱")
        XCTAssertEqual(calls[0].input, "## Hi\nSee [[Other]].")
        XCTAssertEqual(calls[1].input, "")
        XCTAssertEqual(Agent.parseCalls(reply, known: known).map(\.name), ["create_page", "link_pages"], "empty input dropped unless optional")
        XCTAssertEqual(Agent.parseCall(reply, known: known)?.name, "create_page")
        XCTAssertEqual(Agent.unknownCalls("<tool name=\"rm_rf\">/</tool>", known: known), ["rm_rf"])
        XCTAssertEqual(Agent.cleanAnswer("Done.<tool name=\"list_pages\"/>"), "Done.")
        // Junk closing tags from a model's own function format are dropped.
        XCTAssertEqual(Agent.parseCall("<tool name=\"web_search\">tag:biology\n</rfl:parameter>tool>\n</parameter></tool>", known: known)?.input, "tag:biology")
        XCTAssertEqual(Agent.parseCall("<tool name=\"web_search\">a\n</div></tool>", known: known)?.input, "a\n</div>")
        // Name-only form small models fall back to.
        XCTAssertEqual(Agent.parseCalls("<tool>list_pages</tool>", known: known, inputOptional: ["list_pages"]),
                       [AgentToolCall(name: "list_pages", input: "")])
        XCTAssertEqual(Agent.parseCall("<tool>\ncreate_page\n# Hi\n</tool>", known: known), AgentToolCall(name: "create_page", input: "# Hi"))
        XCTAssertEqual(Agent.cleanAnswer("Done <tool>list_pages</tool>"), "Done")
        XCTAssertTrue(Agent.instructions(tools: tools, maxCalls: 3, compact: true).contains("Call syntax: <tool name=\"read_page\">"))
        XCTAssertFalse(Agent.instructions(tools: tools, maxCalls: 3).contains("Call syntax"))
        // A missing closing tag ends at the next call.
        let open = Agent.parseCalls("<tool name=\"web_search\">a\n<tool name=\"web_search\">b</tool>", known: known)
        XCTAssertEqual(open.map(\.input), ["a", "b"])
    }

    func testBatchedCallsAndUnknownToolFeedback() async throws {
        var replies = ["<tool name=\"nope\">x</tool>",
                       "<tool name=\"list_pages\"/>\n<tool name=\"web_search\">q</tool>",
                       "All done."]
        var seen: [AIRequest] = []
        var ran: [String] = []
        var notes: [String] = []
        let answer = try await Agent.run(AIRequest(system: "S", messages: [AIMessage(role: .user, content: "Go")]), tools: tools,
                                         maxCalls: 6, resultLimit: 500, callsPerReply: 4, complete: { req in
            seen.append(req)
            return replies.removeFirst()
        }, execute: { call in
            ran.append(call.name)
            return "ok \(call.name)"
        }, event: { if case .note(let n) = $0 { notes.append(n) } })
        XCTAssertEqual(answer, "All done.")
        XCTAssertEqual(ran, ["list_pages", "web_search"])
        XCTAssertTrue(seen[1].messages.last!.content.contains("no tool called nope"))
        XCTAssertTrue(seen[2].messages.last!.content.contains("<result tool=\"list_pages\">"))
        XCTAssertTrue(seen[2].messages.last!.content.contains("<result tool=\"web_search\">"))
        XCTAssertTrue(seen[0].system.contains("up to 4 in one reply"))
        XCTAssertTrue(notes.isEmpty)
    }

    func testEmptyReplyIsNudgedOnce() async throws {
        var replies = ["", "<tool name=\"list_pages\"/>", "", "Done."]
        var count = 0
        let answer = try await Agent.run(AIRequest(system: "S", messages: [AIMessage(role: .user, content: "Go")]), tools: tools,
                                         maxCalls: 3, resultLimit: 500, complete: { req in
            count += 1
            if count == 2 { XCTAssertTrue(req.messages.last!.content.contains("reply was empty")) }
            return replies.removeFirst()
        }, execute: { _ in "pages" })
        XCTAssertEqual(answer, "", "a second empty reply is the answer (no endless nudging)")
        XCTAssertEqual(count, 3)
    }

    func testCompactShortensOldResults() {
        let big = "<result tool=\"x\">\n" + String(repeating: "data ", count: 400) + "\n</result>"
        let msgs = [AIMessage(role: .user, content: "Q")] + (0..<4).flatMap { _ in
            [AIMessage(role: .assistant, content: "<tool name=\"x\">y</tool>"), AIMessage(role: .user, content: big)]
        }
        let out = Agent.compact(msgs, limit: 3_000)
        XCTAssertEqual(out.count, msgs.count)
        XCTAssertTrue(out[2].content.contains("older result shortened"))
        XCTAssertEqual(out.last?.content, big, "recent results stay whole")
        XCTAssertEqual(Agent.compact(msgs, limit: .max), msgs)
    }
}

final class WorkspaceOpsTests: XCTestCase {
    func testCreateEditRenameMoveTrash() throws {
        var ws = Workspace()
        let (id, report) = try WorkspaceOps.createPage(&ws, title: "[[Photosynthesis]]", markdown: "# Photosynthesis\n## Overview\nUses [[Chlorophyll]]. #biology",
                                                       parent: "Biology", icon: "🌱")
        XCTAssertTrue(report.contains("made the parent page \"Biology\""))
        XCTAssertTrue(report.contains("Chlorophyll"), "mentions links to missing pages")
        let page = try XCTUnwrap(ws[id])
        XCTAssertEqual(page.title, "Photosynthesis")
        XCTAssertEqual(page.icon, "🌱")
        XCTAssertEqual(page.blocks.first?.type, .heading2, "repeated # title dropped")
        XCTAssertEqual(ws.resolve("Biology")?.id, page.parentID)
        XCTAssertThrowsError(try WorkspaceOps.createPage(&ws, title: "photosynthesis", markdown: "x"))

        _ = try WorkspaceOps.editPage(&ws, title: "Photosynthesis", markdown: "- step", mode: "append")
        XCTAssertEqual(ws[id]?.blocks.last?.type, .bulleted)
        _ = try WorkspaceOps.editPage(&ws, title: "Photosynthesis", markdown: "Fresh start", mode: "replace")
        XCTAssertEqual(ws[id]?.blocks.map(\.text), ["Fresh start"])

        let other = ws.createPage(title: "Notes", blocks: [Block(text: "See [[Photosynthesis]]")])
        XCTAssertTrue(try WorkspaceOps.renamePage(&ws, title: "Photosynthesis", to: "Light to sugar").contains("1 link"))
        XCTAssertEqual(ws[other]?.blocks.first?.text, "See [[Light to sugar]]")
        _ = try WorkspaceOps.movePage(&ws, title: "Light to sugar", to: "top")
        XCTAssertNil(ws[id]?.parentID)
        XCTAssertThrowsError(try WorkspaceOps.movePage(&ws, title: "Biology", to: "Missing page"))
        _ = try WorkspaceOps.trashPage(&ws, title: "Notes")
        XCTAssertTrue(ws[other]?.isTrashed == true)
        XCTAssertNil(WorkspaceOps.find("Notes", in: ws))
    }

    func testFillsEmptyLinkTarget() throws {
        var ws = Workspace()
        let a = ws.createPage(title: "Hub")
        _ = try WorkspaceOps.linkPages(&ws, from: "Hub", to: ["Topic A"])
        let (id, report) = try WorkspaceOps.createPage(&ws, title: "Topic A", markdown: "Body")
        XCTAssertTrue(report.contains("Filled in"))
        XCTAssertEqual(ws[id]?.blocks.first?.text, "Body")
        XCTAssertEqual(ws.livePages.filter { $0.title == "Topic A" }.count, 1)
        XCTAssertNotNil(ws[a])
    }

    func testLinksAndTags() throws {
        var ws = Workspace()
        let hub = ws.createPage(title: "Hub", blocks: [Block(text: "Intro [[Alpha]]")])
        ws.createPage(title: "Alpha")
        let r = try WorkspaceOps.linkPages(&ws, from: "Hub", to: WorkspaceOps.titles(in: "Alpha, [[Beta]]; Gamma"))
        XCTAssertTrue(r.contains("Already linked: Alpha"))
        XCTAssertTrue(r.contains("Created empty pages: Beta, Gamma"), r)
        XCTAssertEqual(WorkspaceOps.titles(in: "Alpha, [[Beta, the second]]; Gamma\n- Delta"), ["Alpha", "Beta, the second", "Gamma", "Delta"])
        _ = try WorkspaceOps.linkPages(&ws, from: "Hub", to: ["Gamma", "Delta"])
        let related = ws[hub]!.blocks.filter { $0.text.hasPrefix("Related: ") }
        XCTAssertEqual(related.count, 1)
        XCTAssertEqual(related[0].text, "Related: [[Beta]] · [[Gamma]] · [[Delta]]")
        XCTAssertEqual(LinkIndex(workspace: ws).outgoing[hub]?.count, 4)

        _ = try WorkspaceOps.tagPage(&ws, title: "Hub", tags: ["Machine Learning", "#ai #1bad", "ai"])
        XCTAssertEqual(ws[hub]?.tags, ["machine-learning", "ai", "bad"])
        XCTAssertTrue(try WorkspaceOps.tagPage(&ws, title: "Hub", tags: ["ai"]).contains("already"))
        XCTAssertNil(WorkspaceOps.tagName("###"))
    }

    func testDatabaseColumnsRowsAndUpdates() throws {
        let cols = try WorkspaceOps.parseColumns("Book: title\nAuthor: text, Genre: select(Fiction, Science)\n- Rating: number\nPrice: currency\nRead: checkbox\nFinished: date\nStage: status(Queued, Reading, Done)")
        XCTAssertEqual(cols.map(\.name), ["Book", "Author", "Genre", "Rating", "Price", "Read", "Finished", "Stage"])
        XCTAssertEqual(cols[0].id, PropertyDefinition.titleID)
        XCTAssertEqual(cols[2].options.map(\.name), ["Fiction", "Science"])
        XCTAssertEqual(cols[4].numberFormat, .dollar)
        XCTAssertEqual(cols[7].options.map(\.group), [.todo, .inProgress, .complete])
        XCTAssertEqual(try WorkspaceOps.parseColumns("Name, Notes").map(\.type), [.title, .text])
        XCTAssertThrowsError(try WorkspaceOps.parseColumns("Mood: vibes"))

        var ws = Workspace()
        let (db, _) = try WorkspaceOps.createDatabase(&ws, title: "Reading list", columns: "Book: title\nGenre: select(Fiction)\nRating: number\nRead: checkbox\nFinished: date")
        let report = try WorkspaceOps.addRows(&ws, database: "Reading list", rows: [
            ["Book", "Genre", "Rating", "Read", "Finished", "Shelf"],
            ["Dune", "Fiction", "4.5", "yes", "2026-10-20", "A1"],
            ["Cosmos", "Science", "1,000", "no", "", "B2"],
            ["", "", "", "", "", ""],
        ])
        XCTAssertTrue(report.contains("Added 2 rows"))
        XCTAssertTrue(report.contains("new text columns Shelf"))
        let schema = try XCTUnwrap(ws[db]?.schema)
        XCTAssertEqual(schema.property(named: "Genre")?.options.map(\.name), ["Fiction", "Science"], "new option added")
        let dune = try XCTUnwrap(ws.rows(of: db).first { $0.title == "Dune" })
        XCTAssertEqual(dune.properties[schema.property(named: "Rating")!.id], .number(4.5))
        XCTAssertEqual(dune.properties[schema.property(named: "Read")!.id], .checkbox(true))
        XCTAssertEqual(dune.properties[schema.property(named: "Shelf")!.id], .text("A1"))
        let cosmos = try XCTUnwrap(ws.rows(of: db).first { $0.title == "Cosmos" })
        XCTAssertEqual(cosmos.properties[schema.property(named: "Rating")!.id], .number(1000))

        _ = try WorkspaceOps.updateRow(&ws, database: "Reading list", row: "Dune", values: "Rating: 5\nGenre: Classic")
        let s2 = ws[db]!.schema!
        XCTAssertEqual(ws.rows(of: db).first { $0.title == "Dune" }?.properties[s2.property(named: "Rating")!.id], .number(5))
        XCTAssertTrue(s2.property(named: "Genre")!.options.contains { $0.name == "Classic" })
        XCTAssertThrowsError(try WorkspaceOps.updateRow(&ws, database: nil, row: "Dune", values: "Colour: red"))

        let read = try WorkspaceOps.readPage("Reading list", in: ws)
        XCTAssertTrue(read.contains("| Book | Genre | Rating"))
        XCTAssertTrue(read.contains("| Dune | Classic | 5"))
        XCTAssertTrue(WorkspaceOps.listPages(ws).contains("Reading list (database, 2 rows)"))
    }

    func testGraphOverviewAndReading() throws {
        var ws = Workspace()
        let hub = ws.createPage(title: "Hub", blocks: [Block(text: "[[A]] [[B]] [[Nowhere]] #topic")])
        ws.createPage(title: "A", blocks: [Block(text: "back to [[Hub]]")])
        ws.createPage(title: "B")
        ws.createPage(title: "Loner", blocks: [Block(text: "This mentions Hub without a link.")])
        let index = LinkIndex(workspace: ws)
        let o = WorkspaceOps.graphOverview(ws, index: index)
        XCTAssertTrue(o.contains("4 pages, 3 links"), o)
        XCTAssertTrue(o.contains("- Hub (3)"))
        XCTAssertTrue(o.contains("Orphans:\n- Loner"))
        XCTAssertTrue(o.contains("#topic (1)"))
        XCTAssertTrue(o.contains("Nowhere"))
        XCTAssertTrue(o.contains("Loner mentions Hub"))
        let read = try WorkspaceOps.readPage("hub", in: ws, index: index)
        XCTAssertTrue(read.contains("links to: A, B"))
        XCTAssertTrue(read.contains("linked from: A"))
        XCTAssertNotNil(ws[hub])
        XCTAssertThrowsError(try WorkspaceOps.readPage("Zzzz", in: ws))
        XCTAssertTrue(WorkspaceOps.search("mentions", in: ws).contains("## Loner"))
        let daily = WorkspaceOps.dailyNote(&ws, append: "- [ ] call")
        XCTAssertTrue(daily.report.contains("- [ ] call"))
    }

    func testProfilesCodable() throws {
        let p = AgentPresets.graphArchitect
        let data = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(AgentProfile.self, from: data), p)
        let json = #"{"name":"X","capabilities":["web","teleport"]}"#
        let decoded = try JSONDecoder().decode(AgentProfile.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.capabilities, [.web])
        XCTAssertEqual(decoded.maxSteps, 24)
        XCTAssertEqual(Set(AgentPresets.all.map(\.id)).count, AgentPresets.all.count)
        let tools = AgentToolCatalog.appTools(for: [.editWorkspace, .graph, .documents])
        XCTAssertTrue(tools.contains(.createDatabase) && tools.contains(.graphGroup) && tools.contains(.createPresentation))
        XCTAssertFalse(AgentToolCatalog.appTools(for: [.web]).contains(.listPages))
        XCTAssertLessThan(AgentToolCatalog.appTools(for: Set(AgentCapability.allCases), small: true).count,
                          AgentToolCatalog.appTools(for: Set(AgentCapability.allCases)).count)
        XCTAssertEqual(AgentModelKey.parts("api:openrouter:deepseek/deepseek-r1:free").b, "deepseek/deepseek-r1:free")
        XCTAssertEqual(AgentConversation.title(from: "Make a reading list\nwith genres"), "Make a reading list")
        XCTAssertEqual(AgentFile.kind(forExtension: "PPTX"), .presentation)
    }
}
