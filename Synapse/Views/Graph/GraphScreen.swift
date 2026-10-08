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

    func load(_ d: GraphData) {
        let first = data.nodes.isEmpty
        data = d
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

enum GraphColorMode: String, CaseIterable {
    case type, tag

    var title: String { self == .type ? "Type" : "First tag" }
}

struct GraphScreen: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(AppModel.self) private var app
    let focus: UUID?

    @State private var sim = GraphSimulation()
    @State private var options = GraphOptions()
    @State private var localMode = true
    @State private var colorMode = GraphColorMode.type
    @State private var dragStartOffset: CGSize?
    @State private var draggingNode: String?
    @State private var pinchStartZoom: CGFloat?
    @State private var canvasSize = CGSize(width: 390, height: 600)
    @State private var didFit = false

    private var effectiveOptions: GraphOptions {
        var o = options
        o.focus = (focus != nil && localMode) ? focus : nil
        return o
    }

    var body: some View {
        let _ = sim.frame
        ZStack(alignment: .bottom) {
            Color(UIColor.systemBackground).ignoresSafeArea()
            GeometryReader { geo in
                Canvas { ctx, size in draw(ctx, size) }
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
        .searchable(text: $options.search, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Filter nodes")
        .toolbar { toolbar }
        .onAppear { rebuild() }
        .onDisappear { sim.stop() }
        .onChange(of: store.linkIndex.outgoing) { _, _ in rebuild() }
        .onChange(of: effectiveOptions) { _, _ in rebuild() }
        .animation(.spring(duration: 0.25), value: sim.selected)
    }

    private func rebuild() {
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
            Menu {
                if focus != nil {
                    Picker("Scope", selection: $localMode) {
                        Text("Local graph").tag(true)
                        Text("Whole workspace").tag(false)
                    }
                    if localMode {
                        Picker("Depth", selection: $options.depth) {
                            ForEach(1...4, id: \.self) { Text("\($0) link\($0 == 1 ? "" : "s") away").tag($0) }
                        }
                    }
                }
                Section("Show") {
                    Toggle("Tags", isOn: $options.showTags)
                    Toggle("Unresolved links", isOn: $options.showUnresolved)
                    Toggle("Orphans", isOn: $options.showOrphans)
                    Toggle("Database rows", isOn: $options.showRows)
                    Toggle("Daily notes", isOn: $options.showDaily)
                    Toggle("Relations", isOn: $options.showRelations)
                    Toggle("Page hierarchy", isOn: $options.showHierarchy)
                }
                Picker("Colour by", selection: $colorMode) {
                    ForEach(GraphColorMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Button { sim.reheat() } label: { Label("Re-run layout", systemImage: "arrow.triangle.2.circlepath") }
            } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
        }
    }

    // MARK: Drawing

    private func color(for node: GraphNode) -> Color {
        if colorMode == .tag {
            if node.kind == .tag { return Tint.stable(for: node.title).dot }
            if let t = node.tag { return Tint.stable(for: t).dot }
            return Color.gray
        }
        switch node.kind {
        case .page: return Palette.accent
        case .database: return Tint.orange.dot
        case .row: return Tint.blue.dot
        case .daily: return Tint.green.dot
        case .tag: return Tint.pink.dot
        case .unresolved: return Color.gray.opacity(0.6)
        }
    }

    private func radius(_ node: GraphNode) -> CGFloat {
        let base: CGFloat = node.kind == .tag ? 3.5 : 4.5
        return (base + CGFloat(sqrt(Double(node.degree))) * 2.2) * min(1.6, max(0.6, sim.zoom))
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let layout = sim.layout
        let selected = sim.selected
        let hood = selected.flatMap { sim.neighbors[$0] } ?? []
        // Edges
        for e in sim.data.edges {
            guard let a = layout.position(of: e.source), let b = layout.position(of: e.target) else { continue }
            var path = Path()
            path.move(to: sim.toScreen(a, size))
            path.addLine(to: sim.toScreen(b, size))
            let lit = selected != nil && (e.source == selected || e.target == selected)
            let dim = selected != nil && !lit
            let style: StrokeStyle = e.kind == .relation ? StrokeStyle(lineWidth: 1, dash: [4, 3]) :
                (e.kind == .parent ? StrokeStyle(lineWidth: 0.8, dash: [1, 3]) : StrokeStyle(lineWidth: lit ? 1.8 : 1))
            ctx.stroke(path, with: .color(lit ? Palette.accent : Color.secondary.opacity(dim ? 0.12 : 0.35)), style: style)
        }
        // Nodes
        let showAllLabels = sim.zoom > 0.9 || sim.data.nodes.count < 25
        for node in sim.data.nodes {
            guard let p = layout.position(of: node.id) else { continue }
            let c = sim.toScreen(p, size)
            if c.x < -50 || c.y < -50 || c.x > size.width + 50 || c.y > size.height + 50 { continue }
            let r = radius(node)
            let isSel = node.id == selected
            let dim = selected != nil && !isSel && !hood.contains(node.id)
            let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
            if isSel {
                ctx.fill(Path(ellipseIn: rect.insetBy(dx: -5, dy: -5)), with: .color(Palette.accent.opacity(0.25)))
            }
            let fill = color(for: node).opacity(dim ? 0.25 : 1)
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

    // MARK: Gestures

    private func dragGesture(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { v in
                if dragStartOffset == nil && draggingNode == nil {
                    let w = sim.toWorld(v.startLocation, size)
                    if let hit = sim.layout.hitTest(w, radius: Double(18 / sim.zoom)) {
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
        let hit = sim.layout.hitTest(w, radius: Double(22 / sim.zoom))
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
