import SwiftUI
import SynapseKit

/// Runs the force simulation and holds the camera.
@MainActor
@Observable
final class GraphSimulation {
    @ObservationIgnored let layout = ForceLayout()
    private(set) var data = GraphData(nodes: [], edges: [])
    private(set) var frame = 0
    var selected: String?
    var offset = CGSize.zero
    var zoom: CGFloat = 1
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored var neighbors: [String: Set<String>] = [:]
    @ObservationIgnored var nodeByID: [String: GraphNode] = [:]
    /// Bumped by every load, so cached node colours know when to refresh.
    @ObservationIgnored private(set) var version = 0
    @ObservationIgnored var colorCache: (key: ColorKey, colors: [String: Color])?

    /// What node colours depend on.
    struct ColorKey: Equatable {
        var version: Int
        var mode: GraphColorMode
        var groups: [GraphGroup]
        var revision: Int
    }

    func load(_ d: GraphData) {
        let first = data.nodes.isEmpty
        data = d
        version &+= 1
        layout.load(d, reheat: first ? 1 : 0.4)
        if first { layout.warmUp(steps: 60) }
        neighbors = [:]
        for e in d.edges {
            neighbors[e.source, default: []].insert(e.target)
            neighbors[e.target, default: []].insert(e.source)
        }
        nodeByID = Dictionary(uniqueKeysWithValues: d.nodes.map { ($0.id, $0) })
        if let s = selected, nodeByID[s] == nil { selected = nil }
        start()
    }

    func start() {
        guard running == nil else { return }
        running = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.layout.isSettled {
                    self.running = nil
                    return
                }
                self.layout.tick()
                self.frame &+= 1
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
    }

    func stop() {
        running?.cancel()
        running = nil
    }

    func reheat() {
        layout.reheat(0.6)
        start()
    }

    /// Fit everything on screen.
    func fit(in size: CGSize) {
        let b = layout.bounds
        let w = max(1, b.maxX - b.minX), h = max(1, b.maxY - b.minY)
        zoom = max(0.15, min(2.5, min(size.width / CGFloat(w), size.height / CGFloat(h)) * 0.85))
        offset = CGSize(width: -CGFloat(b.minX + b.maxX) / 2 * zoom, height: -CGFloat(b.minY + b.maxY) / 2 * zoom)
    }

    func toScreen(_ p: ForceLayout.Point, _ size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2 + offset.width + CGFloat(p.x) * zoom, y: size.height / 2 + offset.height + CGFloat(p.y) * zoom)
    }

    func toWorld(_ p: CGPoint, _ size: CGSize) -> ForceLayout.Point {
        ForceLayout.Point(x: Double((p.x - size.width / 2 - offset.width) / zoom), y: Double((p.y - size.height / 2 - offset.height) / zoom))
    }
}

struct GraphScreen: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(AppModel.self) private var app
    let focus: UUID?

    @State private var sim = GraphSimulation()
    @State private var localMode = true
    @State private var showSettings = false
    @State private var dragStartOffset: CGSize?
    @State private var draggingNode: String?
    @State private var pinchStartZoom: CGFloat?
    @State private var canvasSize = CGSize(width: 390, height: 600)
    @State private var didFit = false

    /// Filters, colours, display and forces, shared with every graph screen and the AI agent.
    private var graphSettings: GraphSettingsStore { GraphSettingsStore.shared }

    private var effectiveOptions: GraphOptions {
        var o = graphSettings.settings.options
        o.focus = (focus != nil && localMode) ? focus : nil
        return o
    }

    /// The forces, to notice when they change.
    private var forces: [Double] {
        let s = graphSettings.settings
        return [s.centerForce, s.repelForce, s.linkForce, s.linkDistance]
    }

    var body: some View {
        let _ = sim.frame
        let settings = graphSettings.settings
        @Bindable var shared = graphSettings
        ZStack(alignment: .bottom) {
            Color(UIColor.systemBackground).ignoresSafeArea()
            GeometryReader { geo in
                Canvas { ctx, size in draw(ctx, size, settings) }
                    .contentShape(Rectangle())
                    .gesture(dragGesture(geo.size))
                    .simultaneousGesture(pinchGesture)
                    .simultaneousGesture(SpatialTapGesture().onEnded { v in tap(v.location, geo.size) })
                    .onAppear {
                        canvasSize = geo.size
                    }
                    .onChange(of: geo.size) { _, s in canvasSize = s }
            }
            if let sel = sim.selected, let node = sim.nodeByID[sel] {
                NodeCard(node: node, neighbors: sim.neighbors[sel]?.count ?? 0,
                         open: { open(node) },
                         focus: { if let p = node.pageID { app.push(.graph(focus: p)) } },
                         close: { sim.selected = nil })
                    .padding()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .navigationTitle(focus.flatMap { store.page($0)?.displayTitle }.map { "Graph · \($0)" } ?? "Graph")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $shared.settings.search, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Filter nodes")
        .toolbar { toolbar }
        .sheet(isPresented: $showSettings) {
            GraphSettingsSheet(localMode: focus != nil ? $localMode : nil)
        }
        .onAppear { rebuild() }
        .onDisappear { sim.stop() }
        .onChange(of: store.linkIndex.outgoing) { _, _ in rebuild() }
        .onChange(of: store.linkIndex.tags) { _, _ in rebuild() }
        .onChange(of: effectiveOptions) { _, _ in rebuild() }
        .onChange(of: forces) { _, _ in
            graphSettings.settings.applyForces(to: sim.layout)
            sim.reheat()
        }
        .onChange(of: graphSettings.fitRequest) { _, _ in
            withAnimation(.easeOut(duration: 0.3)) { sim.fit(in: canvasSize) }
        }
        .onChange(of: graphSettings.reheatRequest) { _, _ in sim.reheat() }
        .animation(.spring(duration: 0.25), value: sim.selected)
    }

    private func rebuild() {
        graphSettings.settings.applyForces(to: sim.layout)
        let data = GraphBuilder.build(store.workspace, index: store.linkIndex, options: effectiveOptions)
        sim.load(data)
        if !didFit {
            didFit = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                withAnimation(.easeOut(duration: 0.4)) { sim.fit(in: canvasSize) }
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                withAnimation(.easeOut(duration: 0.3)) { sim.fit(in: canvasSize) }
            } label: { Image(systemName: "scope") }
            .accessibilityLabel("Fit to screen")
            Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                .accessibilityLabel("Graph settings")
        }
    }

    // MARK: Drawing

    private func typeColor(_ node: GraphNode) -> Color {
        switch node.kind {
        case .page: return Palette.accent
        case .database: return Tint.orange.dot
        case .row: return Tint.blue.dot
        case .daily: return Tint.green.dot
        case .tag: return Tint.pink.dot
        case .unresolved: return Color.gray.opacity(0.6)
        }
    }

    /// Every node's colour, cached until the graph, the colour mode, the groups or (for groups) the pages change.
    private func nodeColors(_ s: GraphViewSettings) -> [String: Color] {
        let grouped = s.colorMode == .groups
        let key = GraphSimulation.ColorKey(version: sim.version, mode: s.colorMode, groups: grouped ? s.groups : [],
                                           revision: grouped ? store.revision : 0)
        if let cache = sim.colorCache, cache.key == key { return cache.colors }
        let ws = store.workspace
        var colors: [String: Color] = [:]
        for node in sim.data.nodes {
            switch s.colorMode {
            case .type:
                colors[node.id] = typeColor(node)
            case .tag:
                // Tag nodes carry their own tag, so #idea and the pages tagged idea share a colour.
                colors[node.id] = node.tag.map { Tint.stable(for: $0).dot } ?? Color.gray
            case .groups:
                // First matching group wins; the rest keep a hint of their type colour, greyed (like Obsidian).
                let page = node.pageID.flatMap { ws[$0] }
                if let tint = GraphViewSettings.groupColor(for: node, page: page, workspace: ws, groups: s.groups) {
                    colors[node.id] = tint.dot
                } else {
                    colors[node.id] = typeColor(node).mix(with: .gray, by: 0.75)
                }
            }
        }
        sim.colorCache = (key, colors)
        return colors
    }

    private func radius(_ node: GraphNode, _ s: GraphViewSettings) -> CGFloat {
        let base: CGFloat = node.kind == .tag ? 3.5 : 4.5
        return (base + CGFloat(sqrt(Double(node.degree))) * 2.2) * min(1.6, max(0.6, sim.zoom)) * CGFloat(s.nodeSize)
    }

    /// Hit areas grow with big nodes.
    private var hitScale: CGFloat { max(1, CGFloat(graphSettings.settings.nodeSize)) }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, _ s: GraphViewSettings) {
        let layout = sim.layout
        let selected = sim.selected
        let hood = selected.flatMap { sim.neighbors[$0] } ?? []
        let thickness = CGFloat(s.linkThickness)
        let colors = nodeColors(s)
        // Edges
        for e in sim.data.edges {
            guard let a = layout.position(of: e.source), let b = layout.position(of: e.target) else { continue }
            let from = sim.toScreen(a, size), to = sim.toScreen(b, size)
            var path = Path()
            path.move(to: from)
            path.addLine(to: to)
            let lit = selected != nil && (e.source == selected || e.target == selected)
            let dim = selected != nil && !lit
            let style: StrokeStyle = e.kind == .relation ? StrokeStyle(lineWidth: thickness, dash: [4, 3]) :
                (e.kind == .parent ? StrokeStyle(lineWidth: 0.8 * thickness, dash: [1, 3]) : StrokeStyle(lineWidth: (lit ? 1.8 : 1) * thickness))
            let color = lit ? Palette.accent : Color.secondary.opacity(dim ? 0.12 : 0.35)
            ctx.stroke(path, with: .color(color), style: style)
            if s.showArrows, e.kind == .link, let target = sim.nodeByID[e.target] {
                drawArrow(ctx, from: from, to: to, gap: radius(target, s) + 1.5, lineWidth: style.lineWidth, color: color)
            }
        }
        // Nodes
        let showAllLabels = sim.zoom > CGFloat(s.labelZoom) || sim.data.nodes.count < 25
        for node in sim.data.nodes {
            guard let p = layout.position(of: node.id) else { continue }
            let c = sim.toScreen(p, size)
            let r = radius(node, s)
            let margin = 50 + r
            if c.x < -margin || c.y < -margin || c.x > size.width + margin || c.y > size.height + margin { continue }
            let isSel = node.id == selected
            let dim = selected != nil && !isSel && !hood.contains(node.id)
            let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
            if isSel {
                ctx.fill(Path(ellipseIn: rect.insetBy(dx: -5, dy: -5)), with: .color(Palette.accent.opacity(0.25)))
            }
            let fill = (colors[node.id] ?? typeColor(node)).opacity(dim ? 0.25 : 1)
            if node.kind == .unresolved {
                ctx.stroke(Path(ellipseIn: rect), with: .color(fill), lineWidth: 1.5)
            } else {
                ctx.fill(Path(ellipseIn: rect), with: .color(fill))
            }
            if showAllLabels || isSel || hood.contains(node.id) || node.degree >= 4 {
                let label = Text(node.title)
                    .font(.system(size: max(9, min(13, 11 * sim.zoom)), weight: isSel ? .semibold : .regular))
                    .foregroundStyle(dim ? Color.secondary.opacity(0.4) : Color.primary)
                ctx.draw(label, at: CGPoint(x: c.x, y: c.y + r + 8), anchor: .center)
            }
        }
    }

    /// A small arrowhead on a link, its tip just outside the target node.
    private func drawArrow(_ ctx: GraphicsContext, from a: CGPoint, to b: CGPoint, gap: CGFloat, lineWidth: CGFloat, color: Color) {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = sqrt(dx * dx + dy * dy)
        let size = max(5, 3 + lineWidth * 2.5)
        guard length > gap + size else { return }
        let ux = dx / length, uy = dy / length
        let tip = CGPoint(x: b.x - ux * gap, y: b.y - uy * gap)
        let base = CGPoint(x: tip.x - ux * size, y: tip.y - uy * size)
        let half = size * 0.5
        var head = Path()
        head.move(to: tip)
        head.addLine(to: CGPoint(x: base.x - uy * half, y: base.y + ux * half))
        head.addLine(to: CGPoint(x: base.x + uy * half, y: base.y - ux * half))
        head.closeSubpath()
        ctx.fill(head, with: .color(color))
    }

    // MARK: Gestures

    private func dragGesture(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { v in
                if dragStartOffset == nil && draggingNode == nil {
                    let w = sim.toWorld(v.startLocation, size)
                    if let hit = sim.layout.hitTest(w, radius: Double(18 * hitScale / sim.zoom)) {
                        draggingNode = hit
                        sim.selected = hit
                    } else {
                        dragStartOffset = sim.offset
                    }
                }
                if let n = draggingNode {
                    sim.layout.pin(n, at: sim.toWorld(v.location, size))
                    sim.reheat()
                } else if let start = dragStartOffset {
                    sim.offset = CGSize(width: start.width + v.translation.width, height: start.height + v.translation.height)
                }
            }
            .onEnded { _ in
                if let n = draggingNode { sim.layout.pin(n, at: nil) }
                draggingNode = nil
                dragStartOffset = nil
            }
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { v in
                if pinchStartZoom == nil { pinchStartZoom = sim.zoom }
                let z = max(0.1, min(4, (pinchStartZoom ?? 1) * v.magnification))
                let ratio = z / sim.zoom
                sim.offset = CGSize(width: sim.offset.width * ratio, height: sim.offset.height * ratio)
                sim.zoom = z
            }
            .onEnded { _ in pinchStartZoom = nil }
    }

    private func tap(_ point: CGPoint, _ size: CGSize) {
        let w = sim.toWorld(point, size)
        let hit = sim.layout.hitTest(w, radius: Double(22 * hitScale / sim.zoom))
        if let hit, hit == sim.selected, let node = sim.nodeByID[hit] {
            open(node)
        } else {
            sim.selected = hit
            if hit != nil { Haptics.tap() }
        }
    }

    private func open(_ node: GraphNode) {
        if let id = node.pageID {
            app.open(id)
        } else if node.kind == .tag {
            app.push(.tag(String(node.title.dropFirst())))
        } else if node.kind == .unresolved, let id = store.pageForLink(node.title) {
            app.open(id)
        }
    }
}

private struct NodeCard: View {
    @Environment(WorkspaceStore.self) private var store
    let node: GraphNode
    let neighbors: Int
    let open: () -> Void
    let focus: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if !node.icon.isEmpty { Text(node.icon).font(.title2) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.title).font(.headline).lineLimit(2)
                    Text("\(neighbors) connection\(neighbors == 1 ? "" : "s") · \(kindTitle)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: close) { Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
            }
            if let id = node.pageID, let page = store.page(id) {
                let excerpt = page.excerpt(maxLength: 140)
                if !excerpt.isEmpty { Text(excerpt).font(.footnote).foregroundStyle(.secondary).lineLimit(3) }
            }
            HStack {
                Button(action: open) {
                    Label(node.kind == .unresolved ? "Create page" : "Open", systemImage: node.kind == .unresolved ? "plus" : "arrow.up.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                if node.pageID != nil {
                    Button(action: focus) {
                        Label("Local graph", systemImage: "point.3.connected.trianglepath.dotted").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            Text("Tip: tap a selected node again to open it.").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }

    private var kindTitle: String {
        switch node.kind {
        case .page: return "Page"
        case .database: return "Database"
        case .row: return "Database row"
        case .daily: return "Daily note"
        case .tag: return "Tag"
        case .unresolved: return "Not created yet"
        }
    }
}
