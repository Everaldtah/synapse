import Foundation
import Observation
import SynapseKit

/// Owns the workspace: loads it from disk, applies changes, saves them (debounced) and keeps the link index fresh.
///
/// Storage: `Documents/Synapse/pages/<uuid>.json` per page, `workspace.json` for metadata,
/// `history/<uuid>/<epoch>.json` page snapshots, `assets/` images.
@MainActor
@Observable
final class WorkspaceStore {
    private(set) var workspace: Workspace
    private(set) var linkIndex = LinkIndex()
    /// Bumped on every change, for views that cache derived data.
    private(set) var revision = 0
    private(set) var loadError: String?

    let root: URL
    @ObservationIgnored private var dirty = Set<UUID>()
    @ObservationIgnored private var removed = Set<UUID>()
    @ObservationIgnored private var metaDirty = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    @ObservationIgnored private var lastSnapshot: [UUID: Date] = [:]

    private var pagesDir: URL { root.appendingPathComponent("pages", isDirectory: true) }
    private var historyDir: URL { root.appendingPathComponent("history", isDirectory: true) }
    var assetsDir: URL { root.appendingPathComponent("assets", isDirectory: true) }

    init(root: URL? = nil) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.root = root ?? docs.appendingPathComponent("Synapse", isDirectory: true)
        self.workspace = Workspace()
        let fm = FileManager.default
        for dir in [self.root, pagesDir, historyDir, assetsDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if let loaded = Self.load(from: self.root) {
            workspace = loaded
        } else {
            workspace = Templates.seedWorkspace()
            dirty = Set(workspace.pages.keys)
            metaDirty = true
            scheduleSave(immediately: true)
        }
        rebuildIndex(immediately: true)
    }

    private struct Meta: Codable {
        var name: String
        var version: Int
    }

    private static func load(from root: URL) -> Workspace? {
        let fm = FileManager.default
        let metaURL = root.appendingPathComponent("workspace.json")
        guard let data = try? Data(contentsOf: metaURL), let meta = try? JSONDecoder().decode(Meta.self, from: data) else { return nil }
        var ws = Workspace(name: meta.name)
        let dir = root.appendingPathComponent("pages", isDirectory: true)
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for f in files where f.pathExtension == "json" {
            if let d = try? Data(contentsOf: f), let p = try? decoder.decode(Page.self, from: d) { ws.pages[p.id] = p }
        }
        return ws
    }

    // MARK: - Reading

    func page(_ id: UUID?) -> Page? { id.flatMap { workspace[$0] } }

    var name: String { workspace.name }

    // MARK: - Changing

    /// Change one page. Marks it edited and schedules a save.
    func update(_ id: UUID, touch: Bool = true, _ change: (inout Page) -> Void) {
        guard var p = workspace[id] else { return }
        let before = p
        change(&p)
        guard p != before else { return }
        if touch { p.updatedAt = Date() }
        snapshotIfNeeded(before, after: p)
        workspace[id] = p
        changed([id])
    }

    /// Change the workspace with any SynapseKit operation; changed pages are found by comparing.
    @discardableResult
    func mutate<T>(_ change: (inout Workspace) -> T) -> T {
        let before = workspace.pages
        var ws = workspace
        let result = change(&ws)
        var ids = Set<UUID>()
        for (id, page) in ws.pages where before[id] != page { ids.insert(id) }
        for id in before.keys where ws.pages[id] == nil { removed.insert(id); ids.insert(id) }
        if ws.name != workspace.name { metaDirty = true }
        workspace = ws
        if !ids.isEmpty || metaDirty { changed(ids) }
        return result
    }

    func rename(workspace newName: String) {
        mutate { $0.name = newName }
        metaDirty = true
        scheduleSave()
    }

    private func changed(_ ids: Set<UUID>) {
        for id in ids where workspace[id] != nil { dirty.insert(id); removed.remove(id) }
        revision &+= 1
        scheduleSave()
        rebuildIndex()
    }

    /// Record that a page was opened (for "Jump back in").
    func markOpened(_ id: UUID) {
        guard workspace[id] != nil else { return }
        workspace.pages[id]?.lastOpenedAt = Date()
        dirty.insert(id)
        scheduleSave()
    }

    // MARK: - Common operations

    @discardableResult
    func newPage(parent: UUID? = nil, title: String = "", icon: String = "", blocks: [Block] = []) -> UUID {
        mutate { $0.createPage(title: title, icon: icon, parentID: parent, blocks: blocks) }
    }

    @discardableResult
    func newDatabase(parent: UUID? = nil, title: String = "", inline: Bool = false) -> UUID {
        mutate { $0.createDatabase(title: title, parentID: parent, inline: inline) }
    }

    @discardableResult
    func newRow(in db: UUID, title: String = "", properties: [String: PropertyValue] = [:], template: UUID? = nil) -> UUID? {
        mutate { $0.createRow(in: db, title: title, properties: properties, template: template) }
    }

    func setProperty(_ row: UUID, _ prop: String, _ value: PropertyValue?) {
        mutate { $0.setProperty(row, prop, value) }
    }

    /// Rename a page and rewrite `[[links]]` that pointed at its old title.
    func rename(_ id: UUID, to title: String) {
        guard let old = workspace[id]?.title, old != title else { return }
        mutate { ws in
            ws.rename(id, to: title)
            if !old.trimmingCharacters(in: .whitespaces).isEmpty, ws.resolve(old) == nil {
                _ = ws.updateLinks(from: old, to: title)
            }
        }
    }

    func trash(_ id: UUID) { mutate { $0.trash(id) } }
    func restore(_ id: UUID) { mutate { $0.restore(id) } }

    func deleteForever(_ id: UUID) {
        let ids = mutate { $0.deletePermanently(id) }
        for i in ids { try? FileManager.default.removeItem(at: historyDir.appendingPathComponent(i.uuidString)) }
    }

    func emptyTrash() {
        let ids = mutate { $0.emptyTrash() }
        for i in ids { try? FileManager.default.removeItem(at: historyDir.appendingPathComponent(i.uuidString)) }
    }

    @discardableResult
    func duplicate(_ id: UUID) -> UUID? { mutate { $0.duplicate(id) } }

    func toggleFavorite(_ id: UUID) { update(id, touch: false) { $0.isFavorite.toggle() } }

    @discardableResult
    func move(_ id: UUID, to parent: UUID?) -> Bool { mutate { $0.move(id, to: parent) } }

    func todayNote() -> UUID { mutate { $0.dailyNote(for: Date()) } }

    /// Open (or create) the page a `[[link]]` names.
    func pageForLink(_ target: String, creatingUnder parent: UUID? = nil) -> UUID? {
        if let p = workspace.resolve(target) { return p.id }
        let title = target.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        return newPage(parent: parent, title: title)
    }

    // MARK: - Saving

    private func scheduleSave(immediately: Bool = false) {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            if !immediately { try? await Task.sleep(nanoseconds: 600_000_000) }
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Write pending changes now (also called when the app goes to the background).
    func flush() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var writes: [(URL, Data)] = []
        for id in dirty {
            guard let p = workspace[id], let data = try? encoder.encode(p) else { continue }
            writes.append((pagesDir.appendingPathComponent(id.uuidString + ".json"), data))
        }
        let deletes = removed.map { pagesDir.appendingPathComponent($0.uuidString + ".json") }
        if metaDirty || !FileManager.default.fileExists(atPath: root.appendingPathComponent("workspace.json").path),
           let meta = try? JSONEncoder().encode(Meta(name: workspace.name, version: 1)) {
            writes.append((root.appendingPathComponent("workspace.json"), meta))
        }
        dirty.removeAll()
        removed.removeAll()
        metaDirty = false
        guard !writes.isEmpty || !deletes.isEmpty else { return }
        Task.detached(priority: .utility) {
            for (url, data) in writes { try? data.write(to: url, options: .atomic) }
            for url in deletes { try? FileManager.default.removeItem(at: url) }
        }
    }

    // MARK: - Link index

    private func rebuildIndex(immediately: Bool = false) {
        indexTask?.cancel()
        let snapshot = workspace
        if immediately {
            linkIndex = LinkIndex(workspace: snapshot)
            return
        }
        indexTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            let index = await Task.detached(priority: .userInitiated) { LinkIndex(workspace: snapshot) }.value
            guard !Task.isCancelled else { return }
            self?.linkIndex = index
        }
    }

    // MARK: - History

    struct Snapshot: Identifiable, Hashable {
        var id: URL { url }
        var url: URL
        var date: Date
    }

    /// Keep a copy of a page's previous content at most every 10 minutes of editing.
    private func snapshotIfNeeded(_ before: Page, after: Page) {
        guard before.blocks != after.blocks || before.title != after.title else { return }
        let now = Date()
        if let last = lastSnapshot[before.id], now.timeIntervalSince(last) < 600 { return }
        lastSnapshot[before.id] = now
        guard before.blocks.contains(where: { !$0.text.isEmpty || $0.type != .paragraph }) else { return }
        let dir = historyDir.appendingPathComponent(before.id.uuidString, isDirectory: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(before) else { return }
        Task.detached(priority: .background) {
            let fm = FileManager.default
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: dir.appendingPathComponent("\(Int(now.timeIntervalSince1970)).json"), options: .atomic)
            // Keep the newest 40.
            if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil), files.count > 40 {
                for f in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).prefix(files.count - 40) {
                    try? fm.removeItem(at: f)
                }
            }
        }
    }

    func snapshots(for id: UUID) -> [Snapshot] {
        let dir = historyDir.appendingPathComponent(id.uuidString, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url in
            guard let t = Double(url.deletingPathExtension().lastPathComponent) else { return nil }
            return Snapshot(url: url, date: Date(timeIntervalSince1970: t))
        }.sorted { $0.date > $1.date }
    }

    func loadSnapshot(_ s: Snapshot) -> Page? {
        guard let data = try? Data(contentsOf: s.url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Page.self, from: data)
    }

    func restore(_ snapshot: Page) {
        lastSnapshot[snapshot.id] = nil
        update(snapshot.id) { p in
            p.blocks = snapshot.blocks
            p.title = snapshot.title
            p.icon = snapshot.icon
        }
    }

    // MARK: - Reset

    func resetToSample() {
        let fm = FileManager.default
        try? fm.removeItem(at: pagesDir)
        try? fm.removeItem(at: historyDir)
        try? fm.createDirectory(at: pagesDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: historyDir, withIntermediateDirectories: true)
        workspace = Templates.seedWorkspace()
        dirty = Set(workspace.pages.keys)
        metaDirty = true
        revision &+= 1
        scheduleSave(immediately: true)
        rebuildIndex(immediately: true)
    }

    /// Bytes used by the workspace on disk.
    func storageSize() -> Int64 {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
