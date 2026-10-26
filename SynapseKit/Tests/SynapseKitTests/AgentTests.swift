import XCTest
@testable import SynapseKit

final class SourceTextTests: XCTestCase {
    func testParagraphsBreakAtPauses() {
        let segs = [SourceText.Segment(start: 0, end: 2, text: " Hello all."), SourceText.Segment(start: 2.2, end: 4, text: "Welcome."),
                    SourceText.Segment(start: 7, end: 9, text: "Item one."), SourceText.Segment(start: 9.1, end: 9.5, text: "  ")]
        XCTAssertEqual(SourceText.paragraphs(segs), "Hello all. Welcome.\nItem one.")
    }

    func testWordAndSlideXML() {
        let word = """
        <w:document><w:body><w:p><w:r><w:t>Hello</w:t></w:r><w:r><w:t xml:space="preserve"> world &amp; co</w:t></w:r></w:p>\
        <w:p><w:r><w:t>A</w:t><w:tab/><w:t>B</w:t><w:br/><w:t>C &#8212; &#x2713;</w:t></w:r></w:p><w:p></w:p><w:tbl><w:tr><w:tc>\
        <w:p><w:r><w:t>cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl></w:body></w:document>
        """
        XCTAssertEqual(SourceText.word(word), "Hello world & co\nA\tB\nC — ✓\ncell")
        let slide = "<p:sld><a:p><a:r><a:t>Title</a:t></a:r></a:p><a:p><a:r><a:t>Point &lt;1&gt;</a:t></a:r></a:p></p:sld>"
        XCTAssertEqual(SourceText.slide(slide), "Title\nPoint <1>")
        XCTAssertEqual(SourceText.sortedSlidePaths(["ppt/slides/slide10.xml", "ppt/slides/slide2.xml", "ppt/slides/_rels/slide2.xml.rels", "ppt/media/a.png"]),
                       ["ppt/slides/slide2.xml", "ppt/slides/slide10.xml"])
        XCTAssertEqual(SourceText.tidy("a  \n\n\n b\n\n"), "a\n\nb")
    }

    func testSpreadsheetAndOpenDocument() {
        let shared = SourceText.xlsxSharedStrings("<sst><si><t>Name</t></si><si><r><t>Ama</t></r><r><t xml:space=\"preserve\">ra &amp; co</t></r></si></sst>")
        XCTAssertEqual(shared, ["Name", "Amara & co"])
        let sheet = """
        <worksheet><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="inlineStr"><is><t>Total</t></is></c></row>\
        <row r="2"><c r="A2" t="s"><v>1</v></c><c r="B2"><v>42.5</v></c><c r="C2"/></row></sheetData></worksheet>
        """
        XCTAssertEqual(SourceText.xlsxSheet(sheet, shared: shared), "Name\tTotal\nAmara & co\t42.5")
        let odt = "<office:text><text:h>Intro</text:h><text:p>One<text:tab/>two<text:s/>three</text:p><table:table-row><table:table-cell><text:p>A</text:p></table:table-cell><table:table-cell><text:p>B</text:p></table:table-cell></table:table-row></office:text>"
        XCTAssertEqual(SourceText.openDocument(odt), "Intro\nOne\ttwo three\nA\tB")
        XCTAssertEqual(SourceText.printableRuns(Data([0, 1] + Array("hello world".utf8) + [0, 2] + Array("abc".utf8))), "hello world\n")
        XCTAssertTrue(SourceText.looksLikeText(Data("plain".utf8)))
        XCTAssertFalse(SourceText.looksLikeText(Data([0x50, 0x4b, 0x03, 0x04, 0x00])))
    }

    func testNotesComplexity() {
        XCTAssertNil(AIRouter.notesComplexity(characters: 30_000, budget: .apple))
        XCTAssertNotNil(AIRouter.notesComplexity(characters: 200_000, budget: .apple))
        XCTAssertNil(AIRouter.notesComplexity(characters: 200_000, budget: .context(tokens: 8_192)))
    }
}

final class WebTextTests: XCTestCase {
    func testHTMLText() {
        let html = """
        <html><head><title>Photo&shy;synthesis &amp; light</title><style>p{color:red}</style></head><body>
        <nav>Home | About</nav><h1>Photosynthesis</h1><p>Plants turn&nbsp;light into
        sugar.</p><script>var x = "<p>no</p>";</script><ul><li>Light</li><li>Water</li></ul><!-- hidden -->
        <table><tr><td>A</td><td>B</td></tr></table><footer>© 2026</footer></body></html>
        """
        XCTAssertEqual(HTMLText.title(html), "Photosynthesis & light")
        let text = HTMLText.text(html)
        XCTAssertTrue(text.contains("# Photosynthesis"))
        XCTAssertTrue(text.contains("Plants turn light into sugar."))
        XCTAssertTrue(text.contains("- Light\n- Water"))
        XCTAssertFalse(text.contains("color:red"))
        XCTAssertFalse(text.contains("no"))
        XCTAssertFalse(text.contains("Home | About"))
        XCTAssertFalse(text.contains("2026"))
    }

    func testDuckDuckGoResults() {
        let html = """
        <div class="result results_links results_links_deep result--ad"><a class="result__a" href="https://duckduckgo.com/y.js?ad_provider=x">Ad</a>
        <a class="result__snippet">Buy now</a></div>
        <div class="result results_links"><h2 class="result__title"><a rel="nofollow" class="result__a"
        href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fen.wikipedia.org%2Fwiki%2FPhotosynthesis&amp;rut=abc">Photo<b>synthesis</b> - Wikipedia</a></h2>
        <a class="result__snippet" href="x">Process used by <b>plants</b>.</a></div>
        <div class="result"><a href="https://example.org/a" class="result__a">Example</a><div class="result__snippet">Second &amp; last</div></div>
        """
        let r = WebSearchParse.duckDuckGo(html)
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r[0], WebResult(title: "Photosynthesis - Wikipedia", url: "https://en.wikipedia.org/wiki/Photosynthesis", snippet: "Process used by plants."))
        XCTAssertEqual(r[1].url, "https://example.org/a")
        XCTAssertEqual(r[1].snippet, "Second & last")
        XCTAssertTrue(WebSearchParse.format(r).hasPrefix("1. Photosynthesis - Wikipedia"))
    }

    func testWikipediaResults() {
        let json = #"{"query":{"search":[{"title":"Krebs cycle","snippet":"The <span class=\"searchmatch\">citric</span> acid cycle"}]}}"#
        let r = WebSearchParse.wikipedia(Data(json.utf8))
        XCTAssertEqual(r, [WebResult(title: "Krebs cycle", url: "https://en.wikipedia.org/wiki/Krebs_cycle", snippet: "The citric acid cycle")])
    }
}

final class AgentTests: XCTestCase {
    let tools: [AgentToolSpec] = [.webSearch, .fetchURL, .shell(targets: ["iphone", "pc"])]

    func testParseCall() {
        let known = Set(tools.map(\.name))
        XCTAssertEqual(Agent.parseCall("<tool name=\"web_search\">krebs cycle</tool>", known: known),
                       AgentToolCall(name: "web_search", input: "krebs cycle"))
        XCTAssertEqual(Agent.parseCall("Sure.\n<tool name='shell' where='pc'>\n```bash\nls -l files\n```\n</tool>", known: known),
                       AgentToolCall(name: "shell", input: "ls -l files", attributes: ["where": "pc"]))
        XCTAssertEqual(Agent.parseCall("<tool name=\"fetch_url\">https://a.b/c", known: known)?.input, "https://a.b/c")
        XCTAssertNil(Agent.parseCall("<tool name=\"rm_rf\">/</tool>", known: known))
        XCTAssertNil(Agent.parseCall("No tools needed. The answer is 4.", known: known))
        XCTAssertEqual(AgentToolCall(name: "shell", input: "ls", attributes: ["where": "pc"]).markup, "<tool name=\"shell\" where=\"pc\">ls</tool>")
        XCTAssertEqual(Agent.cleanAnswer("Answer.\n<tool name=\"web_search\">x</tool>"), "Answer.")
        XCTAssertTrue(Agent.truncate(String(repeating: "a", count: 5_000), limit: 1_000).contains("characters cut"))
        XCTAssertTrue(Agent.instructions(tools: tools, maxCalls: 3).contains("at most 3 tool calls"))
    }

    func testLoopCallsToolsThenAnswers() async throws {
        var replies = ["<tool name=\"web_search\">capital of Australia</tool>", "<tool name=\"fetch_url\">https://en.wikipedia.org/wiki/Canberra</tool>",
                       "The capital is [Canberra](https://en.wikipedia.org/wiki/Canberra)."]
        var seen: [AIRequest] = []
        var events: [AgentEvent] = []
        let answer = try await Agent.run(AIRequest(system: "S", messages: [AIMessage(role: .user, content: "Capital of Australia?")]),
                                         tools: tools, maxCalls: 3, resultLimit: 500, complete: { req in
            seen.append(req)
            return replies.removeFirst()
        }, execute: { call in
            call.name == "web_search" ? "1. Canberra - Wikipedia" : String(repeating: "Canberra is the capital. ", count: 100)
        }, event: { events.append($0) })
        XCTAssertEqual(answer, "The capital is [Canberra](https://en.wikipedia.org/wiki/Canberra).")
        XCTAssertEqual(seen.count, 3)
        XCTAssertTrue(seen[0].system.contains("TOOLS"))
        XCTAssertEqual(seen[2].messages.count, 5, "question, call, result, call, result")
        XCTAssertTrue(seen[2].messages[4].content.contains("characters cut"), "long tool output is shortened")
        XCTAssertEqual(events.filter { if case .calling = $0 { return true }; return false }.count, 2)
    }

    func testLoopStopsAtMaxCallsAndReportsErrors() async throws {
        var n = 0
        struct Boom: LocalizedError { var errorDescription: String? { "sandbox offline" } }
        let answer = try await Agent.run(AIRequest(system: "S", messages: [AIMessage(role: .user, content: "Q")]), tools: tools, maxCalls: 1,
                                         resultLimit: 500, complete: { req in
            n += 1
            if req.messages.last?.content.contains("used all your tool calls") == true { return "Final without tools." }
            return "<tool name=\"shell\" where=\"pc\">python3 x.py</tool>"
        }, execute: { _ in throw Boom() })
        XCTAssertEqual(answer, "Final without tools.")
        XCTAssertEqual(n, 3)
    }
}

final class NotesSourcesTests: XCTestCase {
    func testMaterialAndStyles() {
        let a = NotesSource(name: "Lecture 3", kind: .recording, text: "Today: enzymes.", asset: "asset:l3.m4a")
        let b = NotesSource(name: "Slides.pptx", kind: .document, text: "Enzymes lower activation energy.")
        let m = MeetingNotes.material([a, b, NotesSource(name: "empty", kind: .image, text: "  ")])
        XCTAssertTrue(m.contains("=== Recording: Lecture 3 ===\nToday: enzymes."))
        XCTAssertTrue(m.contains("=== Document: Slides.pptx ==="))
        XCTAssertFalse(m.contains("empty"))
        XCTAssertEqual(MeetingNotes.material([b]), "Enzymes lower activation energy.")
        XCTAssertTrue(MeetingNotes.notesRequest(material: m, title: "Bio", style: .lecture).messages[0].content.contains("## Key concepts"))
        XCTAssertTrue(MeetingNotes.notesRequest(material: m, title: "Bio", style: .meeting).messages[0].content.contains("## Action items"))

        let blocks = MeetingNotes.blocks(notes: "## Summary\nEnzymes.", sources: [a, b])
        XCTAssertTrue(blocks.contains { $0.type == .file && $0.url == "asset:l3.m4a" && $0.caption == "Lecture 3" })
        XCTAssertTrue(blocks.contains { $0.type == .toggle && $0.text == "Transcript — Lecture 3" })
        XCTAssertTrue(blocks.contains { $0.type == .toggle && $0.text == "Text — Slides.pptx" })
    }
}
