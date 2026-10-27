import Foundation
import SynapseKit
import UIKit

/// Files agents make or are given, in `Documents/Synapse/Agent Files` (visible in the Files app).
enum AgentFileStore {
    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Synapse/Agent Files", isDirectory: true)
    }

    /// Where attachments the user adds are kept.
    static var uploads: URL { directory.appendingPathComponent("Attachments", isDirectory: true) }

    /// `name` in `folder`, or "name 2.ext", "name 3.ext"… when taken.
    static func uniqueURL(in folder: URL, name: String) -> URL {
        let clean = safeName(name)
        let fm = FileManager.default
        var url = folder.appendingPathComponent(clean)
        let base = (clean as NSString).deletingPathExtension, ext = (clean as NSString).pathExtension
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }

    /// A file name without path separators or characters iOS dislikes.
    static func safeName(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")
        let s = name.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "File" : String(s.prefix(120))
    }

    /// Save bytes as a new file; returns its record.
    static func save(_ data: Data, name: String, in folder: URL = directory) throws -> AgentFile {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = uniqueURL(in: folder, name: name)
        try data.write(to: url, options: .atomic)
        return record(for: url)
    }

    /// Copy a file in (e.g. from a picker or the shell's share folder).
    static func importFile(_ source: URL, in folder: URL = directory) throws -> AgentFile {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = uniqueURL(in: folder, name: source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: url)
        return record(for: url)
    }

    static func record(for url: URL) -> AgentFile {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let root = directory.standardizedFileURL.path
        var rel = url.standardizedFileURL.path
        if rel.hasPrefix(root + "/") { rel = String(rel.dropFirst(root.count + 1)) }
        return AgentFile(name: url.lastPathComponent, path: rel, kind: AgentFile.kind(forExtension: url.pathExtension), bytes: size)
    }

    static func url(for file: AgentFile) -> URL {
        file.path.hasPrefix("/") ? URL(fileURLWithPath: file.path) : directory.appendingPathComponent(file.path)
    }

    /// Every file, newest first (attachments included).
    static func all() -> [URL] {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                    options: [.skipsHiddenFiles]) else { return [] }
        var out: [(URL, Date)] = []
        for case let url as URL in e {
            let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            if v?.isRegularFile == true { out.append((url, v?.contentModificationDate ?? .distantPast)) }
        }
        return out.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// Put a copy in the page asset folder and add a file block to the page, so it opens from there too.
    @MainActor
    static func attach(_ file: AgentFile, to pageID: UUID, store: WorkspaceStore) {
        let source = url(for: file)
        let dest = AssetStore.newFileURL(ext: source.pathExtension)
        guard (try? FileManager.default.copyItem(at: source, to: dest)) != nil else { return }
        store.update(pageID) { p in
            p.blocks = p.blocks.filter { !($0.type == .paragraph && $0.text.isEmpty && $0.pageID == nil) }
            p.blocks.append(Block(type: .file, url: AssetStore.reference(for: dest), caption: file.name))
        }
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// The file kinds agents (and the page Export menu) can make.
enum DocumentFormat: String, CaseIterable, Identifiable {
    case pdf, docx, pptx, xlsx, md

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pdf: return "PDF"
        case .docx: return "Word document"
        case .pptx: return "PowerPoint presentation"
        case .xlsx: return "Excel spreadsheet"
        case .md: return "Markdown"
        }
    }

    var symbol: String {
        switch self {
        case .pdf: return "doc.richtext"
        case .docx: return "doc.text"
        case .pptx: return "rectangle.on.rectangle.angled"
        case .xlsx: return "tablecells"
        case .md: return "number"
        }
    }
}

enum DocumentMaker {
    /// File bytes from Markdown (pdf, docx, md), slides (pptx) or CSV / Markdown tables (xlsx).
    static func make(_ format: DocumentFormat, title: String, text: String, theme: String? = nil) throws -> Data {
        switch format {
        case .pdf: return PDFMaker.pdf(markdown: text, title: title)
        case .md: return Data(text.utf8)
        case .docx: return try OfficeDocument.make(.docx, title: title, text: text)
        case .pptx: return try OfficeDocument.make(.pptx, title: title, text: text, theme: theme)
        case .xlsx: return try OfficeDocument.make(.xlsx, title: title, text: text)
        }
    }

    /// Make and save a file; returns its record.
    static func save(_ format: DocumentFormat, title: String, text: String, theme: String? = nil) throws -> AgentFile {
        let data = try make(format, title: title, text: text, theme: theme)
        let base = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : title
        return try AgentFileStore.save(data, name: base + "." + format.rawValue)
    }

    /// What to feed `make` for an existing page.
    static func text(for page: Page, in ws: Workspace, format: DocumentFormat) throws -> String {
        let md = MarkdownCodec.blocksToMarkdown(page.blocks, workspace: ws)
        switch format {
        case .xlsx:
            guard page.kind == .database else {
                // A page's tables become sheets; otherwise there's nothing tabular to export.
                let tables = page.blocks.filter { $0.type == .table && !$0.table.isEmpty }
                guard !tables.isEmpty else { throw AgentToolError("\"\(page.displayTitle)\" has no tables. Excel export works for databases and pages with tables.") }
                return tables.enumerated().map { i, t in "### Sheet: Table \(i + 1)\n" + t.table.map(csvLine).joined(separator: "\n") }.joined(separator: "\n\n")
            }
            return WorkspaceOps.databaseTable(page.id, in: ws).map(csvLine).joined(separator: "\n")
        case .pptx:
            return SlideOutline.slides(title: page.displayTitle, markdown: md)
        case .pdf, .docx, .md:
            return "# \(page.displayTitle)\n\n" + md
        }
    }

    static func csvLine(_ cells: [String]) -> String {
        cells.map { c in
            c.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) ? "\"" + c.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : c
        }.joined(separator: ",")
    }
}

/// Markdown → a paginated PDF (US Letter), styled like a Synapse page.
enum PDFMaker {
    static let page = CGRect(x: 0, y: 0, width: 612, height: 792)
    static let margin: CGFloat = 54

    static func pdf(markdown: String, title: String) -> Data {
        let text = NSMutableAttributedString()
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.hasPrefix("# ") && !title.isEmpty {
            text.append(paragraph(title, font: .systemFont(ofSize: 26, weight: .bold), spacingAfter: 14))
        }
        var number = 0
        for block in MarkdownCodec.parseBlocks(trimmed) {
            if block.type != .numbered { number = 0 }
            text.append(render(block, number: &number))
        }
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: title, kCGPDFContextCreator as String: "Synapse"]
        let renderer = UIGraphicsPDFRenderer(bounds: page, format: format)
        let body = page.insetBy(dx: margin, dy: margin)
        return renderer.pdfData { ctx in
            let storage = NSTextStorage(attributedString: text)
            let layout = NSLayoutManager()
            storage.addLayoutManager(layout)
            var pageNumber = 0
            var drawn = 0
            repeat {
                let container = NSTextContainer(size: CGSize(width: body.width, height: body.height - 18))
                container.lineFragmentPadding = 0
                layout.addTextContainer(container)
                let range = layout.glyphRange(for: container)
                guard range.length > 0 else { break }
                ctx.beginPage()
                pageNumber += 1
                layout.drawBackground(forGlyphRange: range, at: body.origin)
                layout.drawGlyphs(forGlyphRange: range, at: body.origin)
                let footer = NSAttributedString(string: "\(pageNumber)", attributes: [
                    .font: UIFont.systemFont(ofSize: 9), .foregroundColor: UIColor.gray])
                footer.draw(at: CGPoint(x: page.width / 2 - footer.size().width / 2, y: page.height - margin + 18))
                drawn = NSMaxRange(range)
            } while drawn < layout.numberOfGlyphs
            if pageNumber == 0 { ctx.beginPage() }
        }
    }

    private static func style(spacingBefore: CGFloat = 0, spacingAfter: CGFloat = 6, indent: CGFloat = 0, headIndent: CGFloat? = nil,
                              tabs: [CGFloat] = []) -> NSParagraphStyle {
        let s = NSMutableParagraphStyle()
        s.paragraphSpacingBefore = spacingBefore
        s.paragraphSpacing = spacingAfter
        s.firstLineHeadIndent = indent
        s.headIndent = headIndent ?? indent
        s.lineHeightMultiple = 1.15
        if !tabs.isEmpty { s.tabStops = tabs.map { NSTextTab(textAlignment: .left, location: $0) } }
        return s
    }

    private static func paragraph(_ s: String, font: UIFont, color: UIColor = .black, spacingBefore: CGFloat = 0, spacingAfter: CGFloat = 6) -> NSAttributedString {
        NSAttributedString(string: s + "\n", attributes: [.font: font, .foregroundColor: color,
                                                          .paragraphStyle: style(spacingBefore: spacingBefore, spacingAfter: spacingAfter)])
    }

    /// Inline Markdown (bold, italic, code, links, [[wiki links]]) on a base font.
    static func inline(_ raw: String, font: UIFont, color: UIColor = .black) -> NSMutableAttributedString {
        var s = raw
        for link in InlineMarkdown.wikiLinks(in: raw).reversed() { s = s.replacingOccurrences(of: link.markdown, with: link.label) }
        s = s.replacingOccurrences(of: "==", with: "")
        let out = NSMutableAttributedString()
        guard let parsed = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return NSMutableAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
        }
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            var f = font
            var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            if let intent = run.inlinePresentationIntent {
                var traits: UIFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
                if intent.contains(.emphasized) { traits.insert(.traitItalic) }
                if intent.contains(.code) {
                    f = .monospacedSystemFont(ofSize: font.pointSize * 0.92, weight: .regular)
                    attrs[.backgroundColor] = UIColor(white: 0.94, alpha: 1)
                }
                if intent.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if !traits.isEmpty, let d = f.fontDescriptor.withSymbolicTraits(f.fontDescriptor.symbolicTraits.union(traits)) {
                    f = UIFont(descriptor: d, size: f.pointSize)
                }
            }
            if let link = run.link {
                attrs[.link] = link
                attrs[.foregroundColor] = UIColor.systemBlue
            }
            attrs[.font] = f
            out.append(NSAttributedString(string: piece, attributes: attrs))
        }
        return out
    }

    private static func render(_ b: Block, number: inout Int) -> NSAttributedString {
        let body = UIFont.systemFont(ofSize: 11.5)
        let indent = CGFloat(b.indent) * 18
        func line(_ prefix: String, _ text: String, font: UIFont = body, color: UIColor = .black, spacingBefore: CGFloat = 0,
                  spacingAfter: CGFloat = 5, listIndent: Bool = false) -> NSAttributedString {
            let s = NSMutableAttributedString(string: prefix, attributes: [.font: font, .foregroundColor: color])
            s.append(inline(text, font: font, color: color))
            s.append(NSAttributedString(string: "\n"))
            let hanging = listIndent ? indent + 16 : indent
            s.addAttribute(.paragraphStyle, value: style(spacingBefore: spacingBefore, spacingAfter: spacingAfter, indent: indent,
                                                         headIndent: hanging, tabs: listIndent ? [indent + 16] : []),
                           range: NSRange(location: 0, length: s.length))
            return s
        }
        switch b.type {
        case .heading1: return line("", b.text, font: .systemFont(ofSize: 22, weight: .bold), spacingBefore: 14, spacingAfter: 8)
        case .heading2: return line("", b.text, font: .systemFont(ofSize: 17, weight: .semibold), spacingBefore: 12, spacingAfter: 6)
        case .heading3: return line("", b.text, font: .systemFont(ofSize: 14, weight: .semibold), spacingBefore: 10, spacingAfter: 4)
        case .bulleted: return line(b.indent % 2 == 0 ? "•\t" : "◦\t", b.text, spacingAfter: 3, listIndent: true)
        case .numbered:
            number += 1
            return line("\(number).\t", b.text, spacingAfter: 3, listIndent: true)
        case .todo: return line(b.checked ? "☑\t" : "☐\t", b.text, color: b.checked ? .gray : .black, spacingAfter: 3, listIndent: true)
        case .toggle: return line("▸\t", b.text, spacingAfter: 3, listIndent: true)
        case .quote: return line("", b.text, font: .italicSystemFont(ofSize: 11.5), color: .darkGray, spacingAfter: 6)
        case .callout: return line((b.icon.isEmpty ? "💡" : b.icon) + "  ", b.text, spacingAfter: 6)
        case .code:
            let s = NSMutableAttributedString(string: b.text + "\n", attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 9.5, weight: .regular), .backgroundColor: UIColor(white: 0.95, alpha: 1),
                .paragraphStyle: style(spacingAfter: 8, indent: 6)])
            return s
        case .divider:
            return paragraph(String(repeating: "─", count: 48), font: .systemFont(ofSize: 8), color: .lightGray, spacingBefore: 4, spacingAfter: 8)
        case .equation:
            return line("", b.text, font: .monospacedSystemFont(ofSize: 11, weight: .regular))
        case .table:
            let columns = max(1, b.table.map(\.count).max() ?? 1)
            let width = (page.width - margin * 2) / CGFloat(columns)
            let s = NSMutableAttributedString()
            for (i, row) in b.table.enumerated() {
                let font = i == 0 && b.headerRow ? UIFont.systemFont(ofSize: 10, weight: .semibold) : UIFont.systemFont(ofSize: 10)
                let r = NSMutableAttributedString()
                for (j, cell) in row.enumerated() {
                    if j > 0 { r.append(NSAttributedString(string: "\t", attributes: [.font: font])) }
                    r.append(inline(cell, font: font))
                }
                r.append(NSAttributedString(string: "\n"))
                r.addAttribute(.paragraphStyle, value: style(spacingAfter: 2, tabs: (1..<columns).map { CGFloat($0) * width }),
                               range: NSRange(location: 0, length: r.length))
                s.append(r)
            }
            s.append(paragraph("", font: .systemFont(ofSize: 4)))
            return s
        case .image, .bookmark, .embed, .file:
            let label = b.caption.isEmpty ? b.url : b.caption
            return label.isEmpty ? NSAttributedString() : line("", "[\(label)]", color: .gray)
        case .pageLink, .childPage, .childDatabase, .tableOfContents, .breadcrumb:
            return b.text.isEmpty ? NSAttributedString() : line("→ ", b.text)
        case .paragraph:
            return b.text.isEmpty ? paragraph("", font: .systemFont(ofSize: 6)) : line("", b.text)
        }
    }
}
