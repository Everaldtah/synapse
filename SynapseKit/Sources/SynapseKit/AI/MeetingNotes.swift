import Foundation

/// The kind of notes to write from source material.
public enum NoteStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Summary, key points, decisions and action items.
    case meeting
    /// Concepts, details, definitions and review questions (lectures, lessons, reading).
    case lecture
    /// A short summary and key points.
    case summary

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .meeting: return "Meeting notes"
        case .lecture: return "Lecture & study notes"
        case .summary: return "Summary"
        }
    }

    public var symbol: String {
        switch self {
        case .meeting: return "person.3"
        case .lecture: return "graduationcap"
        case .summary: return "text.append"
        }
    }

    public var detail: String {
        switch self {
        case .meeting: return "Summary, key points, decisions and to-dos"
        case .lecture: return "Concepts, details, definitions and review questions"
        case .summary: return "A short summary and the key points"
        }
    }

    var finalFormat: String {
        switch self {
        case .meeting:
            return """
            ## Summary
            Two to four sentences on what it was about and what came out of it.

            ## Key points
            - One line per point.

            ## Decisions
            - One line per decision.

            ## Action items
            - [ ] Task — owner, due date if mentioned.

            Leave out any section that would be empty.
            """
        case .lecture:
            return """
            ## Summary
            Three to five sentences on the topic and its main ideas.

            ## Key concepts
            - **Concept** — a clear one- or two-line explanation.

            ## Details and examples
            - Important facts, formulas, dates and examples, one per line.

            ## Definitions
            - **Term** — definition.

            ## Questions to review
            - [ ] A question that checks understanding.

            Leave out any section that would be empty.
            """
        case .summary:
            return """
            ## Summary
            One short paragraph.

            ## Key points
            - Five to ten bullets.

            Leave out any section that would be empty.
            """
        }
    }

    var partFormat: String {
        switch self {
        case .meeting:
            return """
            ### Points
            - …
            ### Decisions
            - …
            ### Action items
            - [ ] …
            Skip a heading if there is nothing for it.
            """
        case .lecture:
            return """
            ### Concepts
            - …
            ### Details
            - …
            ### Terms
            - …
            Skip a heading if there is nothing for it.
            """
        case .summary:
            return """
            ### Points
            - …
            """
        }
    }
}

/// One thing notes are made from: a recording, an audio or video file, a document, or text read from a photo.
public struct NotesSource: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case recording, audio, document, image

        public var label: String {
            switch self {
            case .recording: return "Recording"
            case .audio: return "Audio"
            case .document: return "Document"
            case .image: return "Photo text"
            }
        }
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    public var text: String
    /// `asset:` reference of audio kept on the page.
    public var asset: String?

    public init(id: UUID = UUID(), name: String, kind: Kind, text: String, asset: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.text = text
        self.asset = asset
    }

    public var isSpeech: Bool { kind == .recording || kind == .audio }
}

/// Turns source material (transcripts, documents, slides, photographed text) into notes. Long material is split into
/// parts that fit the on-device model, each part is noted, and the part notes are merged (map-reduce), so an hour of
/// audio or a long PDF works offline.
public enum MeetingNotes {
    static let system = AIPrompts.baseSystem + """

    You turn source material (recording transcripts, documents, slides and text read from photos) into clear notes. \
    Transcripts come from speech recognition and photo text from OCR, so fix obvious mis-hearings and misreadings from \
    context, but never invent facts. Keep names, numbers, formulas and dates exactly as given.
    """

    /// Every source as one text, each under a header when there are several.
    public static func material(_ sources: [NotesSource]) -> String {
        let used = sources.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if used.count == 1 { return used[0].text }
        return used.map { "=== \($0.kind.label): \($0.name) ===\n\($0.text)" }.joined(separator: "\n\n")
    }

    /// Notes for all the material in one request (short material, or the cloud).
    public static func notesRequest(material: String, title: String, style: NoteStyle = .meeting) -> AIRequest {
        let user = """
        Write \(style.title.lowercased()) for "\(AIPrompts.escape(title))" from the material below, in exactly this Markdown \
        format:

        \(style.finalFormat)

        <material>
        \(material)
        </material>
        """
        return AIRequest(system: system, messages: [AIMessage(role: .user, content: user)])
    }

    /// Notes for one part of long material (map step).
    public static func partRequest(_ chunk: String, part: Int, of count: Int, title: String, style: NoteStyle = .meeting) -> AIRequest {
        let user = """
        This is part \(part) of \(count) of the material for "\(AIPrompts.escape(title))". Write short notes on this part \
        only, as Markdown bullets under these headings:

        \(style.partFormat)

        <material part="\(part)">
        \(chunk)
        </material>
        """
        return AIRequest(system: system, messages: [AIMessage(role: .user, content: user)])
    }

    /// Merge consecutive part notes. `final` gives the finished format; otherwise the result is part notes again
    /// (used when there are too many parts to merge at once).
    public static func mergeRequest(_ partials: [String], title: String, final: Bool, style: NoteStyle = .meeting) -> AIRequest {
        let parts = partials.enumerated().map { "<notes part=\"\($0.offset + 1)\">\n\($0.element)\n</notes>" }.joined(separator: "\n")
        let user = """
        These are notes on consecutive parts of the material for "\(AIPrompts.escape(title))". Merge them into one set of \
        notes. Remove repeats and keep every distinct point. Use exactly this Markdown format:

        \(final ? style.finalFormat : style.partFormat)

        \(parts)
        """
        return AIRequest(system: system, messages: [AIMessage(role: .user, content: user)])
    }

    /// Split text into chunks of at most `maxCharacters`, breaking between paragraphs, then sentences, then words.
    public static func chunks(_ text: String, maxCharacters: Int) -> [String] {
        let limit = max(200, maxCharacters)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        if trimmed.count <= limit { return [trimmed] }

        // Pieces no longer than the limit, in order; `starts` marks pieces that begin a paragraph.
        var pieces: [(text: String, starts: Bool)] = []
        for paragraph in trimmed.components(separatedBy: "\n") where !paragraph.trimmingCharacters(in: .whitespaces).isEmpty {
            var first = true
            func add(_ piece: String) {
                pieces.append((piece, first))
                first = false
            }
            if paragraph.count <= limit { add(paragraph); continue }
            for sentence in sentences(paragraph) {
                if sentence.count <= limit { add(sentence); continue }
                var line = ""
                for word in sentence.split(separator: " ") {
                    if !line.isEmpty && line.count + 1 + word.count > limit { add(line); line = "" }
                    // A single "word" longer than the limit (no spaces) is cut hard.
                    var w = Substring(word)
                    while w.count > limit { add(String(w.prefix(limit))); w = w.dropFirst(limit) }
                    line = line.isEmpty ? String(w) : line + " " + w
                }
                if !line.isEmpty { add(line) }
            }
        }

        // Pack pieces greedily.
        var out: [String] = []
        var current = ""
        for p in pieces {
            let sep = current.isEmpty ? "" : (p.starts ? "\n" : " ")
            if current.count + sep.count + p.text.count > limit {
                out.append(current)
                current = p.text
            } else {
                current += sep + p.text
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Split after sentence-ending punctuation followed by a space (`.bySentences` isn't in Linux Foundation).
    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        var previous: Character = " "
        for ch in text {
            if ch == " " && ".?!。？！".contains(previous) {
                let s = current.trimmingCharacters(in: .whitespaces)
                if !s.isEmpty { out.append(s) }
                current = ""
            } else {
                current.append(ch)
            }
            previous = ch
        }
        let s = current.trimmingCharacters(in: .whitespaces)
        if !s.isEmpty { out.append(s) }
        return out.isEmpty ? [text] : out
    }

    /// Progress of `generate`.
    public struct Step: Equatable, Sendable {
        public var done: Int
        public var total: Int
        public var label: String
    }

    /// Run the whole pipeline with any model.
    /// - Parameters:
    ///   - material: from `material(_:)`.
    ///   - budget: the most material characters one request may carry (the on-device budget minus the prompt;
    ///     something large for the cloud).
    ///   - complete: sends one request and returns the whole reply.
    public static func generate(material: String, title: String, style: NoteStyle = .meeting, budget: Int,
                                complete: (AIRequest) async throws -> String,
                                progress: (Step) -> Void = { _ in },
                                isolation: isolated (any Actor)? = #isolation) async throws -> String {
        let parts = chunks(material, maxCharacters: budget)
        guard !parts.isEmpty else { return "" }
        if parts.count == 1 {
            progress(Step(done: 0, total: 1, label: "Writing notes"))
            let notes = try await complete(notesRequest(material: parts[0], title: title, style: style))
            progress(Step(done: 1, total: 1, label: "Done"))
            return clean(notes)
        }

        // Map: notes for each part. Then reduce in as many rounds as the budget needs.
        var total = parts.count + mergeRounds(parts: parts.count)
        var done = 0
        var notes: [String] = []
        for (i, part) in parts.enumerated() {
            try Task.checkCancellation()
            progress(Step(done: done, total: total, label: "Noting part \(i + 1) of \(parts.count)"))
            notes.append(clean(try await complete(partRequest(part, part: i + 1, of: parts.count, title: title, style: style))))
            done += 1
        }
        while true {
            try Task.checkCancellation()
            let groups = group(notes, budget: budget)
            if groups.count == 1 {
                progress(Step(done: done, total: total, label: "Merging notes"))
                let final = try await complete(mergeRequest(groups[0], title: title, final: true, style: style))
                progress(Step(done: total, total: total, label: "Done"))
                return clean(final)
            }
            var merged: [String] = []
            for (i, g) in groups.enumerated() {
                progress(Step(done: done, total: total, label: "Merging notes \(i + 1) of \(groups.count)"))
                merged.append(g.count == 1 ? g[0] : clean(try await complete(mergeRequest(g, title: title, final: false, style: style))))
                done += 1
                total = max(total, done + 1)
            }
            // Guard against a model that doesn't shorten anything: force progress by pairing.
            if merged.count >= notes.count { merged = stride(from: 0, to: merged.count, by: 2).map { i in
                merged[i..<min(i + 2, merged.count)].joined(separator: "\n")
            } }
            notes = merged
        }
    }

    /// Consecutive groups whose joined text fits the budget. A note longer than the budget is cut to fit.
    static func group(_ notes: [String], budget: Int) -> [[String]] {
        var groups: [[String]] = []
        var current: [String] = []
        var size = 0
        for n in notes {
            let note = n.count > budget ? String(n.prefix(budget)) : n
            if !current.isEmpty && size + note.count + 40 > budget {
                groups.append(current)
                current = []
                size = 0
            }
            current.append(note)
            size += note.count + 40
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    /// A rough count of merge requests, for the progress bar (assumes about four part notes fit one merge).
    static func mergeRounds(parts: Int) -> Int {
        let perGroup = 4
        var n = parts
        var rounds = 0
        repeat {
            n = (n + perGroup - 1) / perGroup
            rounds += n
        } while n > 1
        return rounds
    }

    /// Strip a stray code fence or preamble line.
    static func clean(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            t = t.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            if t.hasSuffix("```") { t = String(t.dropLast(3)) }
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let first = t.components(separatedBy: "\n").first, first.lowercased().hasPrefix("here are") || first.lowercased().hasPrefix("here is") {
            t = t.components(separatedBy: "\n").dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return t
    }

    /// Blocks for a notes page: the notes, any audio (with a player), then each source's text inside a collapsed
    /// toggle ("Transcript — name" for speech, "Text — name" for documents and photos).
    public static func blocks(notes: String, sources: [NotesSource]) -> [Block] {
        var blocks = MarkdownCodec.parseBlocks(notes)
        for source in sources {
            if let asset = source.asset {
                blocks.append(Block(type: .file, url: asset, caption: source.name))
            }
        }
        for source in sources {
            let paragraphs = source.text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !paragraphs.isEmpty else { continue }
            let label = sources.count == 1 && source.isSpeech ? "Transcript" : "\(source.isSpeech ? "Transcript" : "Text") — \(source.name)"
            blocks.append(Block(type: .toggle, text: escapeMarkdown(label), collapsed: true))
            blocks += paragraphs.map { Block(type: .paragraph, text: escapeMarkdown($0), indent: 1) }
        }
        return blocks
    }

    /// Blocks for one recording (see `blocks(notes:sources:)`).
    public static func blocks(notes: String, transcript: String, audio: String?, audioCaption: String = "Recording") -> [Block] {
        blocks(notes: notes, sources: [NotesSource(name: audioCaption, kind: .recording, text: transcript, asset: audio)])
    }

    /// Transcripts are plain speech; keep characters that mean something in inline Markdown from turning into links,
    /// tags or emphasis.
    static func escapeMarkdown(_ s: String) -> String {
        s.replacingOccurrences(of: "[[", with: "[ [").replacingOccurrences(of: "#", with: "＃")
    }
}
