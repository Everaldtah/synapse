import XCTest
@testable import SynapseKit

final class AIRouterTests: XCTestCase {
    func testEverydayWorkStaysOnDevice() {
        XCTAssertNil(AIRouter.complexity(of: .summarize, inputCharacters: 3_000))
        XCTAssertNil(AIRouter.complexity(of: .improve, inputCharacters: 1_200))
        XCTAssertNil(AIRouter.complexity(of: .translate, inputCharacters: 500, language: "French"))
        XCTAssertNil(AIRouter.complexity(of: .custom, inputCharacters: 500, instruction: "Make this a bulleted list"))
        let r = AIRouter.route(complexReason: nil, mode: .localFirst, localReady: true, cloudReady: true)
        XCTAssertEqual(r.engine, .onDevice)
        XCTAssertFalse(r.complex)
    }

    func testComplexWorkGoesToTheCloud() {
        XCTAssertNotNil(AIRouter.complexity(of: .improve, inputCharacters: AIRouter.localRewriteBudget + 1))
        XCTAssertNotNil(AIRouter.complexity(of: .summarize, inputCharacters: AIRouter.localPromptBudget + 1))
        XCTAssertNotNil(AIRouter.complexity(of: .translate, inputCharacters: 100, language: "Swahili"))
        XCTAssertNotNil(AIRouter.complexity(of: .suggestLinks, inputCharacters: 500, extraCharacters: 5_000))
        XCTAssertNotNil(AIRouter.complexity(of: .custom, inputCharacters: 100, instruction: "Analyze the trade-offs step by step"))
        let reason = AIRouter.complexity(of: .custom, inputCharacters: 100, instruction: "Debug this code")
        let r = AIRouter.route(complexReason: reason, mode: .localFirst, localReady: true, cloudReady: true)
        XCTAssertEqual(r.engine, .cloud)
        XCTAssertTrue(r.complex)
    }

    func testModesAndFallbacks() {
        // Complex but no cloud connected: try on device.
        XCTAssertEqual(AIRouter.route(complexReason: "x", mode: .localFirst, localReady: true, cloudReady: false).engine, .onDevice)
        // On-device model missing: use the cloud when there is one.
        XCTAssertEqual(AIRouter.route(complexReason: nil, mode: .localFirst, localReady: false, cloudReady: true).engine, .cloud)
        // Local only never leaves the device; cloud only never uses it.
        XCTAssertEqual(AIRouter.route(complexReason: "x", mode: .localOnly, localReady: true, cloudReady: true).engine, .onDevice)
        XCTAssertEqual(AIRouter.route(complexReason: nil, mode: .cloudOnly, localReady: true, cloudReady: true).engine, .cloud)
    }

    func testLocalContextLimit() {
        let page = String(repeating: "word ", count: 5_000)
        let req = AIPrompts.request(for: .summarize, text: "", pageTitle: "T", pageContext: page, contextLimit: AIRouter.localPageContext)
        XCTAssertLessThan(req.messages[0].content.count, AIRouter.localPageContext + 400)
        let full = AIPrompts.request(for: .summarize, text: "", pageTitle: "T", pageContext: page)
        XCTAssertGreaterThan(full.messages[0].content.count, 20_000)
    }
}

final class ModelCatalogTests: XCTestCase {
    func testDisplayNames() {
        XCTAssertEqual(ModelCatalog.displayName(claude: "claude-opus-5-5"), "Claude Opus 5.5")
        XCTAssertEqual(ModelCatalog.displayName(claude: "claude-haiku-5-5"), "Claude Haiku 5.5")
        XCTAssertEqual(ModelCatalog.displayName(claude: "claude-fable-5-1"), "Claude Fable 5.1")
        XCTAssertEqual(ModelCatalog.displayName(claude: "opus"), "opus")
        XCTAssertEqual(ModelCatalog.displayName(codex: "gpt-5.4"), "GPT-5.4")
        XCTAssertEqual(ModelCatalog.displayName(codex: "gpt-5.4-mini"), "GPT-5.4 Mini")
        XCTAssertEqual(ModelCatalog.displayName(codex: "gpt-5.3-codex"), "GPT-5.3 Codex")
        XCTAssertEqual(ModelCatalog.displayName(codex: "default"), "Codex default")
    }

    func testCards() {
        let apple = ModelCatalog.appleFoundation
        XCTAssertEqual(apple.kind, .onDevice)
        XCTAssertTrue(apple.specLine.contains("3 billion"))
        XCTAssertTrue(apple.specLine.contains("4,096"))
        XCTAssertEqual(ModelCatalog.claude("opus", kind: .subscription).name, "Claude Opus 5.5")
        XCTAssertEqual(ModelCatalog.claude("claude-sonnet-5-5", kind: .api).id, "claude-sonnet-5-5")
        XCTAssertEqual(ModelCatalog.codex(id: "gpt-5.4", contextWindow: 272_000).contextWindow, "272K tokens")
        XCTAssertFalse(ModelCatalog.claude("opus", kind: .api).specLine.contains("Not published"))
    }
}

final class MeetingNotesTests: XCTestCase {
    func testChunksRespectTheLimitAndKeepEverything() {
        let sentence = "We agreed to ship the beta on Friday and Sam will write the release notes. "
        let transcript = (0..<300).map { i in i % 10 == 9 ? sentence + "\n" : sentence }.joined()
        let chunks = MeetingNotes.chunks(transcript, maxCharacters: 2_000)
        XCTAssertGreaterThan(chunks.count, 5)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 2_000 })
        let words = { (s: String) in s.split(whereSeparator: { $0 == " " || $0 == "\n" }).count }
        XCTAssertEqual(chunks.map(words).reduce(0, +), words(transcript))
        XCTAssertEqual(MeetingNotes.chunks("  short  ", maxCharacters: 2_000), ["short"])
        XCTAssertEqual(MeetingNotes.chunks("", maxCharacters: 2_000), [])
        // No spaces at all still splits.
        XCTAssertTrue(MeetingNotes.chunks(String(repeating: "x", count: 5_000), maxCharacters: 1_000).allSatisfy { $0.count <= 1_000 })
    }

    func testShortTranscriptIsOneRequest() async throws {
        var requests: [AIRequest] = []
        let notes = try await MeetingNotes.generate(transcript: "Quick sync. Ana owns the budget.", title: "Sync", budget: 6_000) { req in
            requests.append(req)
            return "```markdown\n## Summary\nA quick sync.\n```"
        }
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests[0].messages[0].content.contains("Ana owns the budget"))
        XCTAssertEqual(notes, "## Summary\nA quick sync.")
    }

    func testLongTranscriptMapsThenReduces() async throws {
        let transcript = (0..<400).map { "Point number \($0) was discussed at length by the team." }.joined(separator: " ")
        var parts = 0
        var merges = 0
        var finals = 0
        var steps: [MeetingNotes.Step] = []
        let notes = try await MeetingNotes.generate(transcript: transcript, title: "Long", budget: 1_500, complete: { req in
            let text = req.messages[0].content
            if text.contains("<transcript part=") {
                parts += 1
                return "### Points\n- part \(parts) " + String(repeating: "detail ", count: 40)
            }
            if text.contains("## Summary") {
                finals += 1
                return "## Summary\nAll merged."
            }
            merges += 1
            return "### Points\n- merged \(merges)"
        }, progress: { steps.append($0) })
        XCTAssertEqual(parts, MeetingNotes.chunks(transcript, maxCharacters: 1_500).count)
        XCTAssertGreaterThan(merges, 0, "part notes don't fit one merge at this budget, so there's an intermediate round")
        XCTAssertEqual(finals, 1)
        XCTAssertEqual(notes, "## Summary\nAll merged.")
        XCTAssertEqual(steps.last?.label, "Done")
    }

    func testMeetingBlocks() {
        let blocks = MeetingNotes.blocks(notes: "## Summary\nShort.\n\n## Action items\n- [ ] Send deck", transcript: "Hello all.\nSee #42 and [[x]].",
                                         audio: "asset:a.m4a")
        XCTAssertTrue(blocks.contains { $0.type == .todo && $0.text == "Send deck" })
        XCTAssertTrue(blocks.contains { $0.type == .file && $0.url == "asset:a.m4a" })
        let toggle = blocks.firstIndex { $0.type == .toggle && $0.text == "Transcript" }!
        XCTAssertTrue(blocks[toggle].collapsed)
        let lines = blocks[(toggle + 1)...]
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines.allSatisfy { $0.indent == 1 })
        XCTAssertTrue(InlineMarkdown.wikiLinks(in: lines.last!.text).isEmpty, "speech never becomes a page link")
    }
}
