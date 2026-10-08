import Foundation

public enum GraphNodeKind: String, Hashable, Sendable {
    case page, database, row, daily, tag, unresolved
}

public struct GraphNode: Identifiable, Hashable, Sendable {
    /// "p:<uuid>", "t:<tag>" or "u:<title>"
    public var id: String
    public var kind: GraphNodeKind
    public var title: String
    public var icon: String
    public var pageID: UUID?
    public var degree: Int
    /// First tag of the page, for colouring by tag.
    public var tag: String?
}

public enum GraphEdgeKind: String, Hashable, Sendable {
    case link, tag, relation, parent
}

public struct GraphEdge: Hashable, Sendable {
    public var source: String
    public var target: String
    public var kind: GraphEdgeKind
}

public struct GraphOptions: Equatable, Sendable {
    public var showTags = false
    public var showUnresolved = false
    public var showOrphans = true
    public var showRows = true
    public var showDaily = true
    public var showHierarchy = false
    public var showRelations = true
    /// Local graph around this page.
    public var focus: UUID?
    public var depth = 1
    public var search = ""

    public init() {}
}

public struct GraphData: Sendable {
    public var nodes: [GraphNode]
    public var edges: [GraphEdge]

    public init(nodes: [GraphNode], edges: [GraphEdge]) {
        self.nodes = nodes
        self.edges = edges
    }

    public static func nodeID(_ id: UUID) -> String { "p:" + id.uuidString }
}

/// Builds the graph of pages, links, tags and relations.
public enum GraphBuilder {
    public static func build(_ ws: Workspace, index: LinkIndex, options: GraphOptions) -> GraphData {
        var nodes: [String: GraphNode] = [:]
        var edges = Set<GraphEdge>()

        let pages = ws.livePages.filter { p in
            if p.isTemplate { return false }
            if !options.showRows && p.kind == .row { return false }
            if !options.showDaily && p.dailyDate != nil { return false }
            return true
        }
        let included = Set(pages.map(\.id))
        for p in pages {
            let kind: GraphNodeKind = p.dailyDate != nil ? .daily : (p.kind == .database ? .database : (p.kind == .row ? .row : .page))
            let tags = p.tags.sorted()
            nodes[GraphData.nodeID(p.id)] = GraphNode(id: GraphData.nodeID(p.id), kind: kind, title: p.displayTitle, icon: p.icon,
                                                      pageID: p.id, degree: 0, tag: tags.first)
        }
        for p in pages {
            let src = GraphData.nodeID(p.id)
            for t in index.outgoing[p.id] ?? [] where included.contains(t) {
                edges.insert(GraphEdge(source: src, target: GraphData.nodeID(t), kind: .link))
            }
            if options.showRelations {
                for t in index.relations[p.id] ?? [] where included.contains(t) && p.id.uuidString < t.uuidString {
                    edges.insert(GraphEdge(source: src, target: GraphData.nodeID(t), kind: .relation))
                }
            }
            if options.showHierarchy, let parent = p.parentID, included.contains(parent) {
                edges.insert(GraphEdge(source: GraphData.nodeID(parent), target: src, kind: .parent))
            }
            if options.showUnresolved {
                for u in index.unresolved[p.id] ?? [] {
                    let uid = "u:" + Workspace.normalize(u)
                    if nodes[uid] == nil { nodes[uid] = GraphNode(id: uid, kind: .unresolved, title: u, icon: "", pageID: nil, degree: 0, tag: nil) }
                    edges.insert(GraphEdge(source: src, target: uid, kind: .link))
                }
            }
        }
        if options.showTags {
            for (tag, ids) in index.tags {
                let tid = "t:" + tag
                let members = ids.filter { included.contains($0) }
                guard !members.isEmpty else { continue }
                nodes[tid] = GraphNode(id: tid, kind: .tag, title: "#" + tag, icon: "", pageID: nil, degree: 0, tag: tag)
                for m in members { edges.insert(GraphEdge(source: GraphData.nodeID(m), target: tid, kind: .tag)) }
            }
        }

        // Degrees
        for e in edges {
            nodes[e.source]?.degree += 1
            nodes[e.target]?.degree += 1
        }

        // Local graph: keep nodes within `depth` hops of the focus.
        if let focus = options.focus {
            let start = GraphData.nodeID(focus)
            var adjacency: [String: Set<String>] = [:]
            for e in edges {
                adjacency[e.source, default: []].insert(e.target)
                adjacency[e.target, default: []].insert(e.source)
            }
            var keep: Set<String> = [start]
            var frontier: Set<String> = [start]
            for _ in 0..<max(1, options.depth) {
                var next = Set<String>()
                for n in frontier { next.formUnion(adjacency[n] ?? []) }
                next.subtract(keep)
                keep.formUnion(next)
                frontier = next
            }
            nodes = nodes.filter { keep.contains($0.key) }
            edges = edges.filter { keep.contains($0.source) && keep.contains($0.target) }
        } else if !options.showOrphans {
            nodes = nodes.filter { $0.value.degree > 0 }
        }

        let q = options.search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            let hits = Set(nodes.values.filter { $0.title.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }.map(\.id))
            var keep = hits
            for e in edges where hits.contains(e.source) || hits.contains(e.target) {
                keep.insert(e.source)
                keep.insert(e.target)
            }
            nodes = nodes.filter { keep.contains($0.key) }
            edges = edges.filter { keep.contains($0.source) && keep.contains($0.target) }
        }

        let sorted = nodes.values.sorted { $0.id < $1.id }
        let edgeList = edges.sorted { ($0.source, $0.target) < ($1.source, $1.target) }
        return GraphData(nodes: sorted, edges: edgeList)
    }
}

/// A force-directed layout (repulsion between all nodes, springs along edges, gentle pull to the centre),
/// cooled like d3-force. Call `tick()` once per frame until `isSettled`.
public final class ForceLayout {
    public struct Point: Hashable, Sendable {
        public var x: Double
        public var y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }

    public private(set) var ids: [String] = []
    public private(set) var positions: [Point] = []
    private var velocities: [Point] = []
    private var pinned: [Bool] = []
    private var links: [(Int, Int, Double)] = []
    private var indexByID: [String: Int] = [:]

    public var alpha: Double = 1
    public var alphaMin: Double = 0.002
    public var alphaDecay: Double = 0.0228
    public var velocityDecay: Double = 0.42
    public var charge: Double = -260
    public var linkDistance: Double = 70
    public var linkStrength: Double = 0.7
    public var gravity: Double = 0.045

    public init() {}

    public var isSettled: Bool { alpha < alphaMin }

    public func index(of id: String) -> Int? { indexByID[id] }

    public func position(of id: String) -> Point? { indexByID[id].map { positions[$0] } }

    /// Load a graph, keeping the positions of nodes that were already laid out.
    public func load(_ data: GraphData, reheat: Double = 0.8) {
        var oldPositions: [String: Point] = [:]
        for (i, id) in ids.enumerated() { oldPositions[id] = positions[i] }
        ids = data.nodes.map(\.id)
        indexByID = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        positions = []
        velocities = []
        pinned = []
        let golden = Double.pi * (3 - sqrt(5))
        for (i, id) in ids.enumerated() {
            if let p = oldPositions[id] {
                positions.append(p)
            } else {
                // Phyllotaxis start (deterministic), jittered by a stable hash so new nodes don't stack.
                let r = 12 * sqrt(Double(i) + 0.5)
                let jitter = Double(StableHash.of(id) % 1000) / 1000
                let a = Double(i) * golden + jitter
                positions.append(Point(x: r * cos(a), y: r * sin(a)))
            }
            velocities.append(Point(x: 0, y: 0))
            pinned.append(false)
        }
        var degree = Array(repeating: 0, count: ids.count)
        var l: [(Int, Int, Double)] = []
        for e in data.edges {
            guard let s = indexByID[e.source], let t = indexByID[e.target], s != t else { continue }
            degree[s] += 1
            degree[t] += 1
            l.append((s, t, e.kind == .tag ? 0.5 : 1))
        }
        links = l.map { link in (link.0, link.1, link.2 / Double(max(1, min(degree[link.0], degree[link.1])))) }
        alpha = max(alpha, reheat)
    }

    public func reheat(_ a: Double = 0.5) { alpha = max(alpha, a) }

    public func pin(_ id: String, at p: Point?) {
        guard let i = indexByID[id] else { return }
        if let p {
            positions[i] = p
            velocities[i] = Point(x: 0, y: 0)
            pinned[i] = true
        } else {
            pinned[i] = false
        }
    }

    /// One simulation step.
    public func tick() {
        let n = positions.count
        guard n > 0 else { return }
        alpha += (0 - alpha) * alphaDecay

        // Many-body repulsion. O(n²) up to 700 nodes; beyond that only nearby pairs (grid buckets).
        if n <= 700 {
            for i in 0..<n {
                for j in (i + 1)..<n { repel(i, j) }
            }
        } else {
            let cell = 120.0
            var grid: [Int: [Int]] = [:]
            func key(_ p: Point) -> Int { Int((p.x / cell).rounded(.down)) &* 73856093 ^ Int((p.y / cell).rounded(.down)) &* 19349663 }
            for i in 0..<n { grid[key(positions[i]), default: []].append(i) }
            for i in 0..<n {
                let cx = Int((positions[i].x / cell).rounded(.down)), cy = Int((positions[i].y / cell).rounded(.down))
                for dx in -1...1 {
                    for dy in -1...1 {
                        for j in grid[(cx + dx) &* 73856093 ^ (cy + dy) &* 19349663] ?? [] where j > i { repel(i, j) }
                    }
                }
            }
        }

        // Springs
        for (s, t, w) in links {
            var dx = positions[t].x + velocities[t].x - positions[s].x - velocities[s].x
            var dy = positions[t].y + velocities[t].y - positions[s].y - velocities[s].y
            if dx == 0 && dy == 0 { dx = 0.01; dy = 0.01 }
            let dist = sqrt(dx * dx + dy * dy)
            let k = (dist - linkDistance) / dist * alpha * linkStrength * w
            dx *= k
            dy *= k
            velocities[t].x -= dx * 0.5
            velocities[t].y -= dy * 0.5
            velocities[s].x += dx * 0.5
            velocities[s].y += dy * 0.5
        }

        // Gravity to the centre, then integrate.
        for i in 0..<n {
            if pinned[i] { velocities[i] = Point(x: 0, y: 0); continue }
            velocities[i].x -= positions[i].x * gravity * alpha
            velocities[i].y -= positions[i].y * gravity * alpha
            velocities[i].x *= (1 - velocityDecay)
            velocities[i].y *= (1 - velocityDecay)
            positions[i].x += velocities[i].x
            positions[i].y += velocities[i].y
        }
    }

    private func repel(_ i: Int, _ j: Int) {
        var dx = positions[j].x - positions[i].x
        var dy = positions[j].y - positions[i].y
        var d2 = dx * dx + dy * dy
        if d2 < 1e-6 {
            dx = Double((i * 7 + j * 13) % 11 - 5) * 0.01 + 0.001
            dy = Double((i * 11 + j * 5) % 7 - 3) * 0.01 + 0.001
            d2 = dx * dx + dy * dy
        }
        if d2 > 640_000 { return } // farther than 800 pt: negligible
        let d2c = max(d2, 25)
        let f = charge * alpha / d2c
        let fx = dx * f, fy = dy * f
        velocities[i].x += fx
        velocities[i].y += fy
        velocities[j].x -= fx
        velocities[j].y -= fy
    }

    /// Run the simulation without drawing (e.g. before the first frame).
    public func warmUp(steps: Int = 120) {
        for _ in 0..<steps where !isSettled { tick() }
    }

    /// The bounding box of all nodes.
    public var bounds: (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        guard let f = positions.first else { return (-100, -100, 100, 100) }
        var b = (minX: f.x, minY: f.y, maxX: f.x, maxY: f.y)
        for p in positions {
            b.minX = min(b.minX, p.x); b.maxX = max(b.maxX, p.x)
            b.minY = min(b.minY, p.y); b.maxY = max(b.maxY, p.y)
        }
        return b
    }

    /// The node nearest to a point within `radius`.
    public func hitTest(_ p: Point, radius: Double) -> String? {
        var best: (Int, Double)?
        for (i, q) in positions.enumerated() {
            let d = (q.x - p.x) * (q.x - p.x) + (q.y - p.y) * (q.y - p.y)
            if d <= radius * radius, d < (best?.1 ?? .infinity) { best = (i, d) }
        }
        return best.map { ids[$0.0] }
    }
}
