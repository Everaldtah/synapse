import SwiftUI
import UniformTypeIdentifiers
import SynapseKit

/// Writes the workspace as an Obsidian-style Markdown vault and zips it.
enum VaultExporter {
    static func export(_ ws: Workspace) -> URL? {
        let fm = FileManager.default
        let stamp = DateText.iso(Date())
        let tmp = fm.temporaryDirectory.appendingPathComponent("vault-export-\(UUID().uuidString)", isDirectory: true)
        let root = tmp.appendingPathComponent("Synapse Vault \(stamp)", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)

        var used = Set<String>()
        func uniquePath(_ dir: URL, _ name: String, ext: String) -> URL {
            var candidate = dir.appendingPathComponent(name + ext)
            var n = 2
            while used.contains(candidate.path.lowercased()) {
                candidate = dir.appendingPathComponent("\(name) \(n)\(ext)")
                n += 1
            }
            used.insert(candidate.path.lowercased())
            return candidate
        }

        // Children are written inside a folder named like their parent.
        func write(_ parent: UUID?, into dir: URL) {
            let children = ws.pages.values
                .filter { $0.parentID == parent && !$0.isTrashed && !$0.isTemplate }
                .sorted { ($0.order, $0.createdAt) < ($1.order, $1.createdAt) }
            for page in children {
                let name = MarkdownCodec.fileName(for: page.displayTitle)
                let file = uniquePath(dir, name, ext: ".md")
                let md = MarkdownCodec.export(page, in: ws)
                try? md.data(using: .utf8)?.write(to: file)
                let hasChildren = ws.pages.values.contains { $0.parentID == page.id && !$0.isTrashed }
                if hasChildren {
                    let sub = dir.appendingPathComponent(file.deletingPathExtension().lastPathComponent, isDirectory: true)
                    try? fm.createDirectory(at: sub, withIntermediateDirectories: true)
                    write(page.id, into: sub)
                }
            }
        }
        write(nil, into: root)

        // Images
        let assets = AssetStore.directory
        if let files = try? fm.contentsOfDirectory(at: assets, includingPropertiesForKeys: nil), !files.isEmpty {
            let dest = root.appendingPathComponent("assets", isDirectory: true)
            try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
            for f in files { try? fm.copyItem(at: f, to: dest.appendingPathComponent(f.lastPathComponent)) }
        }

        var result: URL?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: root, options: .forUploading, error: &error) { zipURL in
            let dest = tmp.appendingPathComponent("Synapse Vault \(stamp).zip")
            try? fm.removeItem(at: dest)
            if (try? fm.copyItem(at: zipURL, to: dest)) != nil { result = dest }
        }
        return result
    }
}

/// Imports Markdown files or whole folders (Obsidian vaults, Notion Markdown exports).
enum MarkdownImporter {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic"]

    /// Returns the top imported page and how many pages were created.
    @MainActor
    static func run(_ urls: [URL], store: WorkspaceStore, parent: UUID?) -> (UUID?, Int) {
        var count = 0
        var top: UUID?
        store.mutate { ws in
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                if isDir.boolValue {
                    let root = ws.createPage(title: cleanName(url.lastPathComponent), icon: "📥", parentID: parent,
                                             blocks: [Block(type: .callout, text: "Imported from **\(url.lastPathComponent)** on \(DateText.short(Date())).", icon: "📥")])
                    count += 1
                    count += importFolder(url, into: root, ws: &ws)
                    top = top ?? root
                } else if url.pathExtension.lowercased() == "md" || url.pathExtension.lowercased() == "markdown" || url.pathExtension.lowercased() == "txt" {
                    if let id = importFile(url, parent: parent, ws: &ws) {
                        count += 1
                        top = top ?? id
                    }
                }
            }
        }
        return (top, count)
    }

    private static func importFolder(_ dir: URL, into parent: UUID, ws: inout Workspace) -> Int {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return 0 }
        var count = 0
        var pageByName: [String: UUID] = [:]
        // Files first, so a folder can attach to the page of the same name (Notion export layout).
        for f in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let ext = f.pathExtension.lowercased()
            if ext == "md" || ext == "markdown" {
                if let id = importFile(f, parent: parent, ws: &ws) {
                    pageByName[cleanName(f.deletingPathExtension().lastPathComponent).lowercased()] = id
                    count += 1
                }
            } else if imageExtensions.contains(ext) {
                let dest = AssetStore.directory.appendingPathComponent(f.lastPathComponent)
                try? fm.createDirectory(at: AssetStore.directory, withIntermediateDirectories: true)
                if !fm.fileExists(atPath: dest.path) { try? fm.copyItem(at: f, to: dest) }
            }
        }
        for f in items where (try? f.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let name = cleanName(f.lastPathComponent)
            if name.hasPrefix(".") { continue }
            let target: UUID
            if let existing = pageByName[name.lowercased()] {
                target = existing
            } else {
                target = ws.createPage(title: name, parentID: parent, blocks: [Block()])
                count += 1
            }
            count += importFolder(f, into: target, ws: &ws)
        }
        return count
    }

    private static func importFile(_ url: URL, parent: UUID?, ws: inout Workspace) -> UUID? {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        let imported = MarkdownCodec.parse(text, fallbackTitle: cleanName(url.deletingPathExtension().lastPathComponent))
        var blocks = imported.blocks
        if !imported.tags.isEmpty {
            blocks.insert(Block(text: imported.tags.map { "#" + $0.replacingOccurrences(of: " ", with: "-") }.joined(separator: " ")), at: 0)
        }
        let icon = imported.frontmatter["icon"] ?? ""
        let id = ws.createPage(title: imported.title, icon: icon.count <= 2 ? icon : "", parentID: parent, blocks: blocks)
        ws[id]?.aliases = imported.aliases
        if let daily = imported.frontmatter["daily"] { ws[id]?.dailyDate = daily }
        return id
    }

    /// "Page title 1a2b…(32 hex)" from Notion exports → "Page title".
    static func cleanName(_ name: String) -> String {
        if let r = name.range(of: " [0-9a-f]{32}$", options: .regularExpression) { return String(name[..<r.lowerBound]) }
        return name
    }
}

struct MarkdownImportModifier: ViewModifier {
    @Environment(WorkspaceStore.self) private var store
    @Environment(AppModel.self) private var app
    @Binding var isPresented: Bool
    let parent: UUID?

    func body(content: Content) -> some View {
        content.fileImporter(isPresented: $isPresented,
                             allowedContentTypes: [.folder, .plainText, .text, UTType(filenameExtension: "md") ?? .plainText],
                             allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            let (top, count) = MarkdownImporter.run(urls, store: store, parent: parent)
            app.show(toast: count == 0 ? "Nothing to import" : "Imported \(count) page\(count == 1 ? "" : "s")")
            if let top { app.open(top) }
        }
    }
}

extension View {
    func markdownImporter(isPresented: Binding<Bool>, parent: UUID?) -> some View {
        modifier(MarkdownImportModifier(isPresented: isPresented, parent: parent))
    }
}
