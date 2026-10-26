import Foundation
import ImageIO
import PDFKit
import UIKit
import UniformTypeIdentifiers
import Vision
import SynapseKit

/// Text recognition on the iPhone (Vision), for photos, scans and image-only PDFs.
enum OCR {
    static func text(from image: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest { req, error in
                    if let error { continuation.resume(throwing: error); return }
                    let lines = (req.results as? [VNRecognizedTextObservation] ?? []).compactMap { $0.topCandidates(1).first?.string }
                    continuation.resume(returning: lines.joined(separator: "\n"))
                }
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.automaticallyDetectsLanguage = true
                do {
                    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func text(fromImageData data: Data) async throws -> String {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { throw AIError(message: "Couldn't read that image.") }
        var pages: [String] = []
        // Multi-page TIFFs and similar.
        for i in 0..<min(CGImageSourceGetCount(src), 50) {
            let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 3_000,
                           kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
            if let img = CGImageSourceCreateThumbnailAtIndex(src, i, options) {
                pages.append(try await text(from: img))
            }
        }
        return pages.joined(separator: "\n\n")
    }

    static func text(fromImages images: [UIImage]) async throws -> String {
        var pages: [String] = []
        for (i, image) in images.enumerated() {
            guard let cg = image.cgImage else { continue }
            let t = try await text(from: cg)
            pages.append(images.count > 1 ? "Page \(i + 1)\n\(t)" : t)
        }
        return pages.joined(separator: "\n\n")
    }
}

/// Turns any file into text for notes. Everything common is read on the iPhone; formats it can't open go to the
/// bridge's Linux sandbox (pandoc, LibreOffice, pdftotext, tesseract) when it's paired; anything else falls back
/// to the file's readable text runs.
enum SourceExtractor {
    struct Result {
        var text: String
        /// How it was read ("PDF text", "OCR", "Word document", "Computer: pandoc"…), shown in the sources list.
        var method: String
        var kind: NotesSource.Kind
    }

    static let maxCharacters = 3_000_000

    /// Audio or video: transcribe instead of extracting.
    static func isAudioVisual(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .audiovisualContent) || type.conforms(to: .audio) || type.conforms(to: .movie)
    }

    static func extract(_ url: URL, bridge: BridgeTools?, progress: @escaping @MainActor (String) -> Void = { _ in }) async throws -> Result {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let ext = url.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        var local: Result?
        do {
            local = try await extractLocally(url, ext: ext, type: type, progress: progress)
        } catch {
            local = nil
        }
        if var r = local, !r.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            r.text = String(r.text.prefix(maxCharacters))
            return r
        }
        // The iPhone couldn't read it (or found no text): ask the computer.
        if let bridge {
            await progress("Converting on your computer…")
            if let r = try? await bridge.extract(url), !r.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return Result(text: String(r.text.prefix(maxCharacters)), method: "Computer: \(r.method)", kind: .document)
            }
        }
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let runs = SourceText.printableRuns(data)
        if runs.count > 200 {
            return Result(text: runs, method: "Readable text runs", kind: .document)
        }
        throw AIError(message: bridge == nil
            ? "The iPhone can't read \(ext.isEmpty ? "this file" : ".\(ext) files"). Pair Synapse Bridge with its Linux sandbox to read it on your computer."
            : "No text could be read from \(url.lastPathComponent).")
    }

    private static func extractLocally(_ url: URL, ext: String, type: UTType?,
                                       progress: @escaping @MainActor (String) -> Void) async throws -> Result? {
        switch ext {
        case "pdf":
            return try await pdf(url, progress: progress)
        case "docx", "docm", "dotx", "dotm":
            let zip = try ZipReader(url: url)
            let parts = ["word/document.xml", "word/footnotes.xml", "word/endnotes.xml"].compactMap { zip.text($0) }.map(SourceText.word)
            return Result(text: parts.filter { !$0.isEmpty }.joined(separator: "\n\n"), method: "Word document", kind: .document)
        case "pptx", "pptm", "ppsx", "potx":
            let zip = try ZipReader(url: url)
            let slides = SourceText.sortedSlidePaths(zip.names)
            var out: [String] = []
            for (i, path) in slides.enumerated() {
                var page = "Slide \(i + 1)\n" + SourceText.slide(zip.text(path) ?? "")
                let notesPath = path.replacingOccurrences(of: "slides/slide", with: "notesSlides/notesSlide")
                if let notes = zip.text(notesPath).map(SourceText.slide), !notes.isEmpty { page += "\nSpeaker notes: " + notes }
                out.append(page)
            }
            return Result(text: out.joined(separator: "\n\n"), method: "PowerPoint (\(slides.count) slides)", kind: .document)
        case "xlsx", "xlsm", "xltx":
            let zip = try ZipReader(url: url)
            let shared = zip.text("xl/sharedStrings.xml").map(SourceText.xlsxSharedStrings) ?? []
            let sheets = zip.names.filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }
                .sorted { Int($0.filter(\.isNumber)) ?? 0 < Int($1.filter(\.isNumber)) ?? 0 }
            let text = sheets.enumerated().map { "Sheet \($0.offset + 1)\n" + SourceText.xlsxSheet(zip.text($0.element) ?? "", shared: shared) }
            return Result(text: text.joined(separator: "\n\n"), method: "Excel (\(sheets.count) sheets)", kind: .document)
        case "odt", "ods", "odp", "odg", "ott":
            let zip = try ZipReader(url: url)
            return Result(text: SourceText.openDocument(zip.text("content.xml") ?? ""), method: "OpenDocument", kind: .document)
        case "epub":
            let zip = try ZipReader(url: url)
            let chapters = zip.names.filter { ["xhtml", "html", "htm"].contains(($0 as NSString).pathExtension.lowercased()) }.sorted()
            let text = chapters.compactMap { zip.text($0) }.map { HTMLText.text($0) }.filter { !$0.isEmpty }
            return Result(text: text.joined(separator: "\n\n"), method: "EPUB (\(chapters.count) sections)", kind: .document)
        case "pages", "numbers", "key":
            // iWork files are protobuf inside; on the iPhone only the preview image is readable (the computer's
            // LibreOffice reads the real content, so the bridge is tried first when this comes back short).
            let zip = try ZipReader(url: url)
            if let preview = zip.read("preview.jpg") ?? zip.read("QuickLook/Thumbnail.jpg") {
                return Result(text: try await OCR.text(fromImageData: preview), method: "First page (preview OCR)", kind: .document)
            }
            return nil
        case "html", "htm", "xhtml", "mht", "mhtml":
            let html = try String(contentsOf: url, encoding: .utf8)
            return Result(text: HTMLText.text(html), method: "Web page", kind: .document)
        case "rtf", "rtfd":
            let attr = try NSAttributedString(url: url, options: [:], documentAttributes: nil)
            return Result(text: attr.string, method: "Rich text", kind: .document)
        case "zip":
            return try await archive(url, progress: progress)
        default:
            break
        }
        if let type, type.conforms(to: .image) {
            await progress("Reading text in the image…")
            return Result(text: try await OCR.text(fromImageData: Data(contentsOf: url)), method: "OCR", kind: .image)
        }
        // Anything that decodes as text: notes, Markdown, CSV, JSON, code, subtitles, logs…
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        if SourceText.looksLikeText(data) {
            let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
                ?? String(data: data, encoding: .isoLatin1) ?? ""
            return Result(text: text, method: "Text", kind: .document)
        }
        return nil
    }

    /// PDF text; pages with almost no text (scans) are read with OCR.
    private static func pdf(_ url: URL, progress: @escaping @MainActor (String) -> Void) async throws -> Result {
        guard let doc = PDFDocument(url: url) else { throw AIError(message: "Couldn't open the PDF.") }
        var pages: [String] = []
        var ocrPages = 0
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            var text = page.string ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 25 && ocrPages < 120 {
                await progress("Reading scanned page \(i + 1) of \(doc.pageCount)…")
                let size = page.bounds(for: .mediaBox).size
                let scale = min(3, 2_400 / max(size.width, size.height, 1))
                let image = page.thumbnail(of: CGSize(width: size.width * scale, height: size.height * scale), for: .mediaBox)
                if let cg = image.cgImage { text = (try? await OCR.text(from: cg)) ?? "" }
                ocrPages += 1
            }
            pages.append(text)
        }
        let method = ocrPages == 0 ? "PDF (\(doc.pageCount) pages)" : "PDF (\(doc.pageCount) pages, \(ocrPages) by OCR)"
        return Result(text: SourceText.tidy(pages.joined(separator: "\n\n")), method: method, kind: .document)
    }

    /// Every readable file inside a .zip, each under its name.
    private static func archive(_ url: URL, progress: @escaping @MainActor (String) -> Void) async throws -> Result {
        let zip = try ZipReader(url: url)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zip-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var parts: [String] = []
        var total = 0
        for entry in zip.entries where !entry.isDirectory && !entry.name.hasPrefix("__MACOSX") && !(entry.name as NSString).lastPathComponent.hasPrefix(".") {
            guard total < maxCharacters, let data = zip.read(entry) else { continue }
            let file = dir.appendingPathComponent((entry.name as NSString).lastPathComponent)
            try data.write(to: file)
            await progress("Reading \(entry.name)…")
            let ext = file.pathExtension.lowercased()
            if isAudioVisual(file) || ext == "zip" { parts.append("=== \(entry.name) ===\n(audio, video or nested archive: add it on its own)"); continue }
            if let r = try? await extractLocally(file, ext: ext, type: UTType(filenameExtension: ext), progress: progress),
               !r.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append("=== \(entry.name) ===\n\(r.text)")
                total += r.text.count
            }
        }
        return Result(text: parts.joined(separator: "\n\n"), method: "ZIP (\(zip.entries.filter { !$0.isDirectory }.count) files)", kind: .document)
    }
}
