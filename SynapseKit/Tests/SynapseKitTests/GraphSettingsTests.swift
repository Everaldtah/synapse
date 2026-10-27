import XCTest
@testable import SynapseKit

final class GraphSettingsTests: XCTestCase {
    // MARK: Codable

    func testEmptyJSONDecodesToDefaults() throws {
        let s = try JSONDecoder().decode(GraphViewSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(s, GraphViewSettings.default)
        XCTAssertEqual(s, GraphViewSettings())
    }

    func testOldJSONKeepsSavedValuesAndDefaultsTheRest() throws {
        // Saved by an older build: a few keys, one group without an id, an unknown key, a malformed value.
        let json = """
        {"showTags": true, "repelForce": 500, "colorMode": "groups", "nodeSize": "big", "futureThing": 3,
         "groups": [{"query": "#idea", "color": "red"}]}
        """
        let s = try JSONDecoder().decode(GraphViewSettings.self, from: Data(json.utf8))
        XCTAssertTrue(s.showTags)
        XCTAssertEqual(s.repelForce, 500)
        XCTAssertEqual(s.colorMode, .groups)
        XCTAssertEqual(s.nodeSize, 1)
        XCTAssertEqual(s.groups.count, 1)
        XCTAssertEqual(s.groups.first?.query, "#idea")
        XCTAssertEqual(s.groups.first?.color, .red)
        XCTAssertEqual(s.linkDistance, GraphViewSettings.default.linkDistance)
        XCTAssertEqual(s.showOrphans, true)
        XCTAssertEqual(s.labelZoom, 0.9)

        // Unknown enum values and out-of-range numbers fall back or clamp.
        let odd = try JSONDecoder().decode(GraphViewSettings.self, from: Data(#"{"colorMode": "rainbow", "depth": 40, "linkForce": -2}"#.utf8))
        XCTAssertEqual(odd.colorMode, .type)
        XCTAssertEqual(odd.depth, 5)
        XCTAssertEqual(odd.linkForce, 0)
    }

    func testRoundTrip() throws {
        var s = GraphViewSettings()
        s.showArrows = true
        s.search = "alpha"
        s.addGroup(query: "path:Projects", color: .green)
        let back = try JSONDecoder().decode(GraphViewSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }

    // MARK: set

    func testSetEveryKey() throws {
        var s = GraphViewSettings()
        let bools: [(String, WritableKeyPath<GraphViewSettings, Bool>)] = [
            ("show_tags", \.showTags), ("show_unresolved", \.showUnresolved), ("show_orphans", \.showOrphans),
            ("show_rows", \.showRows), ("show_daily", \.showDaily), ("show_hierarchy", \.showHierarchy),
            ("show_relations", \.showRelations), ("arrows", \.showArrows),
        ]
        for (key, kp) in bools {
            let flipped = !s[keyPath: kp]
            _ = try s.set(key, to: flipped ? "true" : "false")
            XCTAssertEqual(s[keyPath: kp], flipped, key)
        }
        let numbers: [(String, WritableKeyPath<GraphViewSettings, Double>, Double)] = [
            ("node_size", \.nodeSize, 2), ("link_thickness", \.linkThickness, 3), ("label_zoom", \.labelZoom, 1.5),
            ("center_force", \.centerForce, 0.1), ("repel_force", \.repelForce, 500), ("link_force", \.linkForce, 1.2),
            ("link_distance", \.linkDistance, 150),
        ]
        for (key, kp, v) in numbers {
            _ = try s.set(key, to: GraphViewSettings.format(v))
            XCTAssertEqual(s[keyPath: kp], v, accuracy: 1e-9, key)
        }
        _ = try s.set("depth", to: "3")
        XCTAssertEqual(s.depth, 3)
        _ = try s.set("search", to: "  \"weekly meeting\" ")
        XCTAssertEqual(s.search, "weekly meeting")
        _ = try s.set("color_by", to: "groups")
        XCTAssertEqual(s.colorMode, .groups)
        _ = try s.set("color_by", to: "First tag")
        XCTAssertEqual(s.colorMode, .tag)
        _ = try s.set("color_by", to: "type")
        XCTAssertEqual(s.colorMode, .type)

        // Every listed key is settable to "default".
        for key in GraphViewSettings.keys where key != "search" {
            _ = try s.set(key, to: "default")
        }
        _ = try s.set("search", to: "")
        XCTAssertEqual(s, GraphViewSettings.default)
    }

    func testSetDescribesTheChange() throws {
        var s = GraphViewSettings()
        XCTAssertEqual(try s.set("repel_force", to: "500"), "repel_force 260 → 500")
        XCTAssertEqual(try s.set("center_force", to: "0.1"), "center_force 0.045 → 0.1")
        XCTAssertEqual(try s.set("show_tags", to: "on"), "show_tags false → true")
        XCTAssertEqual(try s.set("show_tags", to: "on"), "show_tags already true")
        XCTAssertEqual(try s.set("color_by", to: "tag"), "color_by type → tag")
        XCTAssertEqual(try s.set("search", to: "x"), "search \"\" → \"x\"")
    }

    func testClamping() throws {
        var s = GraphViewSettings()
        XCTAssertEqual(try s.set("node_size", to: "10"), "node_size 1 → 3 (max 3)")
        XCTAssertEqual(s.nodeSize, 3)
        _ = try s.set("node_size", to: "0")
        XCTAssertEqual(s.nodeSize, 0.4)
        _ = try s.set("repel_force", to: "-5")
        XCTAssertEqual(s.repelForce, 0)
        _ = try s.set("repel_force", to: "99999")
        XCTAssertEqual(s.repelForce, 2000)
        _ = try s.set("link_distance", to: "1")
        XCTAssertEqual(s.linkDistance, 10)
        _ = try s.set("link_thickness", to: "100")
        XCTAssertEqual(s.linkThickness, 4)
        _ = try s.set("label_zoom", to: "0")
        XCTAssertEqual(s.labelZoom, 0.1)
        _ = try s.set("center_force", to: "1")
        XCTAssertEqual(s.centerForce, 0.3)
        _ = try s.set("link_force", to: "9")
        XCTAssertEqual(s.linkForce, 1.5)
        _ = try s.set("depth", to: "9")
        XCTAssertEqual(s.depth, 5)
        _ = try s.set("depth", to: "0")
        XCTAssertEqual(s.depth, 1)
        _ = try s.set("depth", to: "2.6")
        XCTAssertEqual(s.depth, 3)
        _ = try s.set("depth", to: "1e300")
        XCTAssertEqual(s.depth, 5)
    }

    func testBoolSpellings() throws {
        var s = GraphViewSettings()
        for word in ["true", "yes", "on", "TRUE", "Yes", "1", "show"] {
            s.showTags = false
            _ = try s.set("show_tags", to: word)
            XCTAssertTrue(s.showTags, word)
        }
        for word in ["false", "no", "off", "OFF", "0", "hide"] {
            s.showTags = true
            _ = try s.set("show_tags", to: word)
            XCTAssertFalse(s.showTags, word)
        }
        _ = try s.set("show_tags", to: "toggle")
        XCTAssertTrue(s.showTags)
        _ = try s.set("show_tags", to: "toggle")
        XCTAssertFalse(s.showTags)
    }

    func testKeySpellings() throws {
        var s = GraphViewSettings()
        _ = try s.set("Show-Tags", to: "yes")
        XCTAssertTrue(s.showTags)
        _ = try s.set("showOrphans", to: "no")
        XCTAssertFalse(s.showOrphans)
        _ = try s.set("colour by", to: "groups")
        XCTAssertEqual(s.colorMode, .groups)
        _ = try s.set("gravity", to: "0.2")
        XCTAssertEqual(s.centerForce, 0.2)
        _ = try s.set("text fade threshold", to: "2")
        XCTAssertEqual(s.labelZoom, 2)
    }

    func testErrors() {
        var s = GraphViewSettings()
        XCTAssertThrowsError(try s.set("wobble", to: "1")) { error in
            let message = (error as? GraphSettingsError)?.message ?? ""
            XCTAssertTrue(message.contains("wobble"))
            for key in GraphViewSettings.keys { XCTAssertTrue(message.contains(key), key) }
            XCTAssertEqual(error.localizedDescription, message)
        }
        XCTAssertThrowsError(try s.set("show_tags", to: "maybe")) { error in
            XCTAssertTrue(((error as? GraphSettingsError)?.message ?? "").contains("true or false"))
        }
        XCTAssertThrowsError(try s.set("repel_force", to: "lots")) { error in
            XCTAssertTrue(((error as? GraphSettingsError)?.message ?? "").contains("0 to 2000"))
        }
        XCTAssertThrowsError(try s.set("repel_force", to: "nan"))
        XCTAssertThrowsError(try s.set("node_size", to: "inf"))
        XCTAssertThrowsError(try s.set("depth", to: "deep"))
        XCTAssertThrowsError(try s.set("color_by", to: "rainbow")) { error in
            let message = (error as? GraphSettingsError)?.message ?? ""
            XCTAssertTrue(message.contains("type") && message.contains("tag") && message.contains("groups"))
        }
        // A rejected value leaves everything as it was.
        XCTAssertEqual(s, GraphViewSettings.default)
    }

    // MARK: Groups

    private struct Fixture {
        var ws = Workspace()
        var data = GraphData(nodes: [], edges: [])

        func node(_ title: String) -> GraphNode { data.nodes.first { $0.title == title }! }
        func page(_ node: GraphNode) -> Page? { node.pageID.flatMap { ws[$0] } }
    }

    private func fixture() -> Fixture {
        var f = Fixture()
        let projects = Page(title: "Projects", blocks: [Block(text: "All the [[Alpha plan]] work")])
        let alpha = Page(title: "Alpha plan", parentID: projects.id,
                         blocks: [Block(text: "Kickoff #idea and #project/alpha, see [[Missing page]]")])
        let notes = Page(title: "Alpha notes", parentID: alpha.id, blocks: [Block(text: "Budget review")])
        let db = Page(kind: .database, title: "Tasks")
        let row = Page(kind: .row, title: "Write spec", parentID: db.id)
        let daily = Page(title: "2026-10-26", blocks: [Block(text: "Talked about the budget #Idea")], dailyDate: "2026-10-26")
        let meeting = Page(title: "Weekly Meeting", blocks: [Block(text: "Notes")])
        let other = Page(title: "Unrelated projects")
        for p in [projects, alpha, notes, db, row, daily, meeting, other] { f.ws.pages[p.id] = p }
        var o = GraphOptions()
        o.showTags = true
        o.showUnresolved = true
        f.data = GraphBuilder.build(f.ws, index: LinkIndex(workspace: f.ws), options: o)
        return f
    }

    private func matching(_ query: String, _ f: Fixture) -> Set<String> {
        let g = GraphGroup(query: query, color: .blue)
        return Set(f.data.nodes.filter { g.matches($0, page: f.page($0), workspace: f.ws) }.map(\.title))
    }

    func testGroupQueryForms() {
        let f = fixture()
        // Tags: tag:, #, nested tags, case, and the tag node itself.
        XCTAssertEqual(matching("tag:idea", f), ["Alpha plan", "2026-10-26", "#idea"])
        XCTAssertEqual(matching("#idea", f), matching("tag:idea", f))
        XCTAssertEqual(matching("tag:#IDEA", f), matching("tag:idea", f))
        XCTAssertEqual(matching("#project", f), ["Alpha plan", "#project/alpha"])
        XCTAssertEqual(matching("#proj", f), [])
        // Path: the page and everything under it, exact titles, multi-part paths.
        XCTAssertEqual(matching("path:Projects", f), ["Projects", "Alpha plan", "Alpha notes"])
        XCTAssertEqual(matching("path:projects/alpha plan", f), ["Alpha plan", "Alpha notes"])
        XCTAssertEqual(matching("path:Tasks", f), ["Tasks", "Write spec"])
        XCTAssertEqual(matching("path:Nowhere", f), [])
        // Kind.
        XCTAssertEqual(matching("kind:database", f), ["Tasks"])
        XCTAssertEqual(matching("kind:row", f), ["Write spec"])
        XCTAssertEqual(matching("kind:daily", f), ["2026-10-26"])
        XCTAssertEqual(matching("kind:row|daily", f), ["Write spec", "2026-10-26"])
        XCTAssertEqual(matching("kind:page", f), ["Projects", "Alpha plan", "Alpha notes", "Weekly Meeting", "Unrelated projects"])
        XCTAssertEqual(matching("kind:unresolved", f), ["Missing page"])
        // Title and plain text: title contains, case-insensitive.
        XCTAssertEqual(matching("title:meeting", f), ["Weekly Meeting"])
        XCTAssertEqual(matching("meeting", f), ["Weekly Meeting"])
        XCTAssertEqual(matching("title:\"weekly meeting\"", f), ["Weekly Meeting"])
        XCTAssertEqual(matching("missing", f), ["Missing page"])
        // Line: page text contains.
        XCTAssertEqual(matching("line:budget", f), ["Alpha notes", "2026-10-26"])
        XCTAssertEqual(matching("line:Weekly", f), [])
        // An unknown prefix is plain text; empty queries match nothing.
        XCTAssertEqual(matching("Re: x", f), [])
        XCTAssertEqual(matching("", f), [])
        XCTAssertEqual(matching("tag:", f), [])
    }

    func testFirstGroupWins() {
        let f = fixture()
        let alpha = f.node("Alpha plan")
        let groups = [GraphGroup(query: "#idea", color: .red), GraphGroup(query: "path:Projects", color: .green)]
        XCTAssertEqual(GraphViewSettings.groupColor(for: alpha, page: f.page(alpha), workspace: f.ws, groups: groups), .red)
        XCTAssertEqual(GraphViewSettings.groupColor(for: alpha, page: f.page(alpha), workspace: f.ws, groups: groups.reversed()), .green)
        let notes = f.node("Alpha notes")
        XCTAssertEqual(GraphViewSettings.groupColor(for: notes, page: f.page(notes), workspace: f.ws, groups: groups), .green)
        let other = f.node("Unrelated projects")
        XCTAssertNil(GraphViewSettings.groupColor(for: other, page: f.page(other), workspace: f.ws, groups: groups))
        XCTAssertNil(GraphViewSettings.groupColor(for: alpha, page: f.page(alpha), workspace: f.ws, groups: []))
    }

    func testAddAndRemoveGroups() {
        var s = GraphViewSettings()
        s.addGroup(query: "tag:idea", color: .blue)
        XCTAssertEqual(s.colorMode, .groups)
        s.addGroup(query: "#Idea", color: .red)
        XCTAssertEqual(s.groups.count, 1)
        XCTAssertEqual(s.groups[0].color, .red)
        XCTAssertEqual(s.groups[0].query, "tag:idea")
        s.addGroup(query: "path:Projects", color: .green)
        s.addGroup(query: "   ", color: .green)
        XCTAssertEqual(s.groups.map(\.query), ["tag:idea", "path:Projects"])
        XCTAssertTrue(s.removeGroup(query: "#idea"))
        XCTAssertFalse(s.removeGroup(query: "#idea"))
        XCTAssertEqual(s.groups.map(\.query), ["path:Projects"])
    }

    // MARK: Summary and mapping

    func testSummaryListsEveryKeyAndGroup() {
        var s = GraphViewSettings()
        XCTAssertTrue(s.summary.contains("groups: none"))
        s.addGroup(query: "#idea", color: .purple)
        let summary = s.summary
        for key in GraphViewSettings.keys {
            XCTAssertTrue(summary.contains("\(key): "), key)
            XCTAssertNotNil(s.value(forKey: key), key)
        }
        XCTAssertTrue(summary.contains("repel_force: 260"))
        XCTAssertTrue(summary.contains("center_force: 0.045"))
        XCTAssertTrue(summary.contains("color_by: groups"))
        XCTAssertTrue(summary.contains("#idea → purple"))
        XCTAssertEqual(GraphViewSettings.keys.count, Set(GraphViewSettings.keys).count)
        XCTAssertNil(s.value(forKey: "nope"))
    }

    func testOptionsAndForcesMapping() {
        var s = GraphViewSettings()
        s.showTags = true
        s.showUnresolved = true
        s.showOrphans = false
        s.showRows = false
        s.showDaily = false
        s.showHierarchy = true
        s.showRelations = false
        s.depth = 3
        s.search = "alpha"
        let o = s.options
        XCTAssertTrue(o.showTags)
        XCTAssertTrue(o.showUnresolved)
        XCTAssertFalse(o.showOrphans)
        XCTAssertFalse(o.showRows)
        XCTAssertFalse(o.showDaily)
        XCTAssertTrue(o.showHierarchy)
        XCTAssertFalse(o.showRelations)
        XCTAssertEqual(o.depth, 3)
        XCTAssertEqual(o.search, "alpha")
        XCTAssertNil(o.focus)
        // Defaults match the builder's.
        XCTAssertEqual(GraphViewSettings.default.options, GraphOptions())

        let layout = ForceLayout()
        let fresh = ForceLayout()
        GraphViewSettings.default.applyForces(to: layout)
        XCTAssertEqual(layout.charge, fresh.charge)
        XCTAssertEqual(layout.gravity, fresh.gravity)
        XCTAssertEqual(layout.linkStrength, fresh.linkStrength)
        XCTAssertEqual(layout.linkDistance, fresh.linkDistance)
        s.repelForce = 800
        s.centerForce = 0.1
        s.linkForce = 1.1
        s.linkDistance = 200
        s.applyForces(to: layout)
        XCTAssertEqual(layout.charge, -800)
        XCTAssertEqual(layout.gravity, 0.1)
        XCTAssertEqual(layout.linkStrength, 1.1)
        XCTAssertEqual(layout.linkDistance, 200)
    }
}
