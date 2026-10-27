import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import VisionKit
import SynapseKit

/// Make notes from anything: record, or add audio, video, documents of any type, photos and scans. Speech is
/// transcribed (on the iPhone or with Whisper on the computer), documents are read on the iPhone (or converted on
/// the computer), and the chosen model writes the notes — optionally checking facts on the web and adding references.
struct MakeNotesSheet: View {
    @Environment(AIService.self) private var ai
    @Environment(WorkspaceStore.self) private var store
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    /// Insert into this page after `anchor`; nil makes a new page.
    var model: PageEditorModel?
    var anchor: UUID?
    var start: Start = .none

    enum Start { case none, record, files }
    enum Phase { case collect, recording, working, done }

    struct SourceItem: Identifiable {
        enum Status: Equatable {
            case waiting
            case working(String, Double?)
            case ready
            case failed(String)
        }

        let id = UUID()
        var name: String
        var kind: NotesSource.Kind
        var file: URL?
        var images: [UIImage] = []
        var text = ""
        var method = ""
        var status: Status = .waiting

        var source: NotesSource {
            NotesSource(id: id, name: name, kind: kind, text: text, asset: kind == .recording || kind == .audio ? file.map(AssetStore.reference(for:)) : nil)
        }
    }

    @State private var phase: Phase = .collect
    @State private var recorder = AudioRecorder()
    @State private var title = "Notes – \(DateText.short(Date()))"
    @AppStorage("notes.style") private var styleRaw = NoteStyle.meeting.rawValue
    @AppStorage("notes.onComputer") private var transcribeOnComputer = false
    @AppStorage("notes.checkWeb") private var checkWeb = true
    @AppStorage("notes.cleanTranscripts") private var cleanTranscripts = false
    @State private var keepAudio = true
    @State private var sources: [SourceItem] = []
    @State private var choice: ModelChoice = .auto
    @State private var locales: [Locale] = []
    @State private var locale: Locale = .current
    @State private var showFiles = false
    @State private var showPhotos = false
    @State private var showScanner = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var notes = ""
    @State private var progressLabel = ""
    @State private var progressValue: Double?
    @State private var error: String?
    @State private var answer: AIAnswerInfo?
    @State private var steps: [AgentStep] = []
    @State private var task: Task<Void, Never>?
    @State private var queue: Task<Void, Never>?

    private var style: NoteStyle { NoteStyle(rawValue: styleRaw) ?? .meeting }
    private var ready: [SourceItem] { sources.filter { $0.status == .ready } }
    private var busy: Bool { sources.contains { if case .working = $0.status { return true }; return $0.status == .waiting } }
    private var whisperReady: Bool { ai.bridgeWhisper?.available == true && ai.bridgeEndpoint != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    TextField("Title", text: $title)
                        .font(.title2.bold())
                        .disabled(phase == .recording || phase == .working)
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.subheadline)
                    }
                    switch phase {
                    case .recording: recordingView
                    case .working: workingView
                    case .done: doneView
                    case .collect: collectView
                    }
                }
                .padding()
            }
            .navigationTitle("Make notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { close() } }
                ToolbarItem(placement: .topBarTrailing) {
                    ModelChip(engine: ai.engine(for: choice), answer: phase == .done ? answer : nil)
                }
            }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { addFiles(urls) }
            }
            .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 30, matching: .images)
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                addPhotos(items)
                photoItems = []
            }
            .fullScreenCover(isPresented: $showScanner) {
                DocumentScanner { images in
                    showScanner = false
                    if !images.isEmpty {
                        add(SourceItem(name: "Scan (\(images.count) page\(images.count == 1 ? "" : "s"))", kind: .image, images: images))
                    }
                }
                .ignoresSafeArea()
            }
            .task {
                locales = await Transcriber.supportedLocales()
                if let l = await Transcriber.defaultLocale() { locale = l }
                if ai.bridgeEndpoint != nil && (ai.bridgeWhisper == nil || ai.bridgeSandbox == nil) { _ = await ai.checkBridge() }
            }
            .onAppear {
                switch start {
                case .record: if phase == .collect && sources.isEmpty { startRecording() }
                case .files: if sources.isEmpty { showFiles = true }
                case .none: break
                }
            }
        }
        .interactiveDismissDisabled(phase == .recording || phase == .working || busy)
    }

    // MARK: Collect

    private var collectView: some View {
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                addButton("Record", "mic.fill", tint: .red) { startRecording() }
                addButton("Files", "doc.badge.plus") { showFiles = true }
                addButton("Photos", "photo.on.rectangle") { showPhotos = true }
                addButton("Scan", "doc.viewfinder") { showScanner = true }
                    .disabled(!VNDocumentCameraViewController.isSupported)
            }

            if sources.isEmpty {
                Text("Add a recording, audio or video, documents of any type (PDF, Word, PowerPoint, Excel, text, web pages, e-books…), photos or scans. Several at once make one set of notes.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(sources) { item in sourceRow(item) }
                }
            }

            optionsView

            Button { makeNotes() } label: {
                Label("Make \(style.title.lowercased())", systemImage: "sparkles").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(ready.isEmpty || busy)
            if busy {
                Text("Reading your sources…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func addButton(_ title: String, _ symbol: String, tint: Color = Palette.accent, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.title3)
                Text(title).font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(tint)
            .background(Color(UIColor.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func sourceRow(_ item: SourceItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: Self.symbol(item.kind)).frame(width: 22).foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.subheadline.weight(.medium)).lineLimit(1)
                switch item.status {
                case .waiting:
                    Text("Waiting…").font(.caption).foregroundStyle(.secondary)
                case .working(let label, let value):
                    if let value { ProgressView(value: value) }
                    Text(label).font(.caption).foregroundStyle(.secondary)
                case .ready:
                    Text("\(item.method) · \(item.text.split(whereSeparator: \.isWhitespace).count) words").font(.caption).foregroundStyle(.secondary)
                case .failed(let why):
                    Text(why).font(.caption).foregroundStyle(.orange)
                    Button("Try again") { retry(item.id) }.font(.caption)
                }
            }
            Spacer(minLength: 0)
            Button { remove(item.id) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(item.name)")
        }
        .padding(10)
        .background(Color(UIColor.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    private var optionsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(selection: $styleRaw) {
                ForEach(NoteStyle.allCases) { s in Label(s.title, systemImage: s.symbol).tag(s.rawValue) }
            } label: { Label("Style", systemImage: "list.bullet.rectangle") }
            Text(style.detail).font(.caption).foregroundStyle(.secondary)

            Menu {
                ForEach(ai.modelGroups) { group in
                    Section(group.title) {
                        ForEach(group.options) { option in
                            Button {
                                choice = option.choice
                            } label: {
                                if option.choice == choice { Label(option.title, systemImage: "checkmark") } else { Text(option.title) }
                            }
                        }
                    }
                }
            } label: {
                HStack {
                    Label("Notes by", systemImage: ai.engine(for: choice) == .onDevice ? "iphone" : "cloud")
                    Spacer()
                    Text(choice == .auto ? "Auto · \(ai.modelName(ai.everydayEngine))" : ai.name(for: choice))
                        .foregroundStyle(.secondary).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
                }
            }

            if whisperReady {
                Picker(selection: $transcribeOnComputer) {
                    Text("This iPhone (Apple)").tag(false)
                    Text("Computer (Whisper \(ai.bridgeWhisper?.model ?? ""))").tag(true)
                } label: { Label("Transcribe on", systemImage: "waveform") }
            }
            if !locales.isEmpty {
                Picker(selection: $locale) {
                    ForEach(locales, id: \.identifier) { Text(Transcriber.name(of: $0)).tag($0) }
                } label: { Label("Speech language", systemImage: "globe") }
            }
            if sources.contains(where: { $0.kind == .recording || $0.kind == .audio }) {
                Toggle(isOn: $cleanTranscripts) { Label("Clean up transcripts first (slower)", systemImage: "text.badge.checkmark") }
            }
            if ai.agentWeb {
                Toggle(isOn: $checkWeb) { Label("Check facts on the web and add references", systemImage: "checkmark.seal") }
            }
            Toggle(isOn: $keepAudio) { Label("Keep recordings on the page", systemImage: "waveform.circle") }
        }
        .font(.subheadline)
    }

    // MARK: Recording

    private var recordingView: some View {
        VStack(spacing: 18) {
            Text(AudioAttachmentView.time(recorder.elapsed))
                .font(.system(size: 48, weight: .light, design: .rounded).monospacedDigit())
                .frame(maxWidth: .infinity)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(UIColor.tertiarySystemFill))
                    Capsule().fill(recorder.isPaused ? Color.secondary : Color.red)
                        .frame(width: max(6, geo.size.width * CGFloat(recorder.level)))
                        .animation(.linear(duration: 0.1), value: recorder.level)
                }
            }
            .frame(height: 8)
            Text(recorder.isPaused ? "Paused" : "Recording… (keeps going with the screen locked)").font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 28) {
                Button(role: .destructive) {
                    recorder.discard()
                    phase = .collect
                } label: {
                    Image(systemName: "trash").font(.title2).frame(width: 56, height: 56)
                        .background(Color(UIColor.secondarySystemBackground), in: Circle())
                }
                .accessibilityLabel("Discard recording")
                Button { recorder.togglePause() } label: {
                    Image(systemName: recorder.isPaused ? "play.fill" : "pause.fill").font(.title2).frame(width: 56, height: 56)
                        .background(Color(UIColor.secondarySystemBackground), in: Circle())
                }
                .accessibilityLabel(recorder.isPaused ? "Resume" : "Pause")
                Button {
                    if let url = recorder.stop() {
                        add(SourceItem(name: "Recording \(Date().formatted(date: .omitted, time: .shortened))", kind: .recording, file: url))
                    }
                    phase = .collect
                } label: {
                    Image(systemName: "stop.fill").font(.title2).foregroundStyle(.white).frame(width: 72, height: 72)
                        .background(Color.red, in: Circle())
                }
                .accessibilityLabel("Stop recording")
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 12)
    }

    // MARK: Working / done

    private var workingView: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let progressValue { ProgressView(value: progressValue) } else { ProgressView().frame(maxWidth: .infinity) }
            Text(progressLabel).font(.subheadline).foregroundStyle(.secondary)
            Text(ai.engine(for: choice) == .onDevice && ai.models.loading ? "Loading \(ai.local.card.name) into memory…" : "Using \(ai.name(for: choice))")
                .font(.caption).foregroundStyle(.secondary)
            AgentStepsView(steps: steps)
            Button("Cancel", role: .cancel) {
                task?.cancel()
                phase = .collect
            }
        }
    }

    private var doneView: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let answer {
                Label(answer.note ?? (answer.engine == .onDevice ? "Written on this iPhone by \(answer.model)" : "Written by \(answer.model)"),
                      systemImage: answer.engine == .onDevice ? "iphone" : "cloud")
                    .font(.caption).foregroundStyle(.secondary)
            }
            AgentStepsView(steps: steps)
            Text(markdown(notes)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button { save() } label: {
                Label(model == nil ? "Create page" : "Add to page", systemImage: model == nil ? "doc.badge.plus" : "text.insert")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Menu {
                ForEach(ai.modelGroups) { group in
                    Section(group.title) {
                        ForEach(group.options) { option in
                            Button(option.title) {
                                choice = option.choice
                                makeNotes()
                            }
                        }
                    }
                }
            } label: { Label("Redo with another model", systemImage: "arrow.triangle.2.circlepath") }
            Button { phase = .collect } label: { Label("Back to sources", systemImage: "chevron.left") }
                .font(.subheadline)
        }
    }

    // MARK: Sources

    private func startRecording() {
        Task { @MainActor in
            do {
                try await recorder.start()
                error = nil
                phase = .recording
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func addFiles(_ urls: [URL]) {
        for url in urls {
            do {
                if SourceExtractor.isAudioVisual(url) {
                    // Kept in the asset store so the page can play it.
                    let copy = try AssetStore.importFile(url)
                    add(SourceItem(name: url.lastPathComponent, kind: .audio, file: copy))
                } else {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sources", isDirectory: true)
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let copy = dir.appendingPathComponent(String(UUID().uuidString.prefix(8)) + "-" + url.lastPathComponent)
                    try FileManager.default.copyItem(at: url, to: copy)
                    add(SourceItem(name: url.lastPathComponent, kind: .document, file: copy))
                }
            } catch {
                sources.append(SourceItem(name: url.lastPathComponent, kind: .document, status: .failed("Couldn't open: \(error.localizedDescription)")))
            }
        }
        if title.hasPrefix("Notes – "), let first = urls.first { title = first.deletingPathExtension().lastPathComponent }
    }

    private func addPhotos(_ items: [PhotosPickerItem]) {
        let all = items
        Task { @MainActor in
            var images: [UIImage] = []
            for item in all {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) { images.append(image) }
            }
            if !images.isEmpty {
                add(SourceItem(name: images.count == 1 ? "Photo" : "\(images.count) photos", kind: .image, images: images))
            }
        }
    }

    private func add(_ item: SourceItem) {
        sources.append(item)
        enqueue(item.id)
    }

    /// Sources are read one at a time.
    private func enqueue(_ id: UUID) {
        let previous = queue
        queue = Task { @MainActor in
            await previous?.value
            await process(id)
        }
    }

    private func retry(_ id: UUID) {
        update(id) { $0.status = .waiting }
        enqueue(id)
    }

    private func remove(_ id: UUID) {
        if let item = sources.first(where: { $0.id == id }), item.kind == .recording, let file = item.file {
            try? FileManager.default.removeItem(at: file)
        }
        sources.removeAll { $0.id == id }
    }

    private func update(_ id: UUID, _ change: (inout SourceItem) -> Void) {
        if let i = sources.firstIndex(where: { $0.id == id }) { change(&sources[i]) }
    }

    private func process(_ id: UUID) async {
        guard let item = sources.first(where: { $0.id == id }) else { return }
        update(id) { $0.status = .working("Starting…", nil) }
        let report: @MainActor (String, Double?) -> Void = { label, value in update(id) { $0.status = .working(label, value) } }
        do {
            switch item.kind {
            case .recording, .audio:
                guard let file = item.file else { throw AIError(message: "The audio file is missing.") }
                if transcribeOnComputer, whisperReady, let bridge = ai.bridgeEndpoint {
                    let text = try await bridge.transcribe(file, language: locale.language.languageCode?.identifier, progress: report)
                    update(id) { $0.text = text; $0.method = "Whisper on your computer"; $0.status = .ready }
                } else {
                    let text = try await Transcriber.transcribe(file, locale: locale, progress: report)
                    update(id) { $0.text = text; $0.method = "Transcribed on iPhone"; $0.status = .ready }
                }
            case .image where !item.images.isEmpty:
                report("Reading text…", nil)
                let text = try await OCR.text(fromImages: item.images)
                update(id) { $0.text = text; $0.method = "OCR on iPhone"; $0.status = text.isEmpty ? .failed("No text found.") : .ready }
            case .document, .image:
                guard let file = item.file else { throw AIError(message: "The file is missing.") }
                let r = try await SourceExtractor.extract(file, bridge: ai.bridgeSandbox?.available == true ? ai.bridgeEndpoint : nil) { label in
                    report(label, nil)
                }
                update(id) { $0.text = r.text; $0.method = r.method; $0.kind = r.kind; $0.status = .ready }
            }
        } catch is CancellationError {
            update(id) { $0.status = .failed("Cancelled.") }
        } catch {
            update(id) { $0.status = .failed(error.localizedDescription) }
        }
    }

    // MARK: Notes

    private func makeNotes() {
        let use = choice
        let used = ready
        let material = MeetingNotes.material(used.map(\.source))
        let complex = AIRouter.notesComplexity(characters: material.count, budget: ai.localBudget)
        let concrete = ai.concrete(use, complexReason: complex)
        let name = title
        let noteStyle = style
        let ai = self.ai
        phase = .working
        steps = []
        error = nil
        answer = nil
        progressLabel = "Writing notes…"
        progressValue = nil
        let speech = cleanTranscripts ? used.filter { $0.kind == .recording || $0.kind == .audio } : []
        task = Task { @MainActor in
            var budget = min(ai.budget(for: concrete).prompt - 1_200, 150_000)
            var material = material
            // Clean transcripts first (mis-hearings, punctuation, paragraphs); the clean text is what the page keeps.
            for item in speech {
                do {
                    // Parts of at most 4,000 characters: the cleaned part (about as long) always fits one reply.
                    let cleaned = try await MeetingNotes.cleanTranscript(item.text, title: name, budget: max(1_000, min(4_000, ai.budget(for: concrete).rewrite - 600)),
                                                                         complete: { req in try await ai.complete(req, choice: concrete, fallback: use == .auto) },
                                                                         progress: { step in
                        progressLabel = "\(item.name): \(step.label)"
                        progressValue = step.total > 0 ? Double(step.done) / Double(step.total) : nil
                    })
                    update(item.id) { $0.text = cleaned }
                } catch is CancellationError {
                    return
                } catch {
                    self.error = error.localizedDescription
                    phase = .collect
                    return
                }
            }
            if !speech.isEmpty { material = MeetingNotes.material(ready.map(\.source)) }
            progressLabel = "Writing notes…"
            for attempt in 0..<2 {
                do {
                    var info: AIAnswerInfo?
                    var result = try await MeetingNotes.generate(material: material, title: name, style: noteStyle, budget: budget, complete: { req in
                        let reply = try await ai.complete(req, choice: concrete, fallback: use == .auto)
                        info = ai.lastAnswer
                        return reply
                    }, progress: { step in
                        progressLabel = step.label
                        progressValue = step.total > 0 ? Double(step.done) / Double(step.total) : nil
                    })
                    if checkWeb && ai.agentWeb {
                        progressLabel = "Checking facts on the web…"
                        progressValue = nil
                        let runner = AgentRunner(ai: ai)
                        let request = Agent.referencesRequest(notes: result, title: name, limit: max(2_000, budget / 3))
                        let refs = try await runner.run(request, choice: concrete, tools: [.webSearch, .fetchURL], steps: $steps)
                        if !refs.isEmpty { result += "\n\n" + refs }
                    }
                    notes = result
                    answer = info
                    phase = .done
                    return
                } catch is CancellationError {
                    return
                } catch LocalAIError.tooLong where attempt == 0 {
                    budget /= 2
                } catch {
                    self.error = error.localizedDescription
                    phase = .collect
                    return
                }
            }
        }
    }

    private func save() {
        let list = ready.map { item -> NotesSource in
            var s = item.source
            if !keepAudio { s.asset = nil }
            return s
        }
        if !keepAudio {
            for item in ready where item.kind == .recording { if let f = item.file { try? FileManager.default.removeItem(at: f) } }
        }
        let blocks = MeetingNotes.blocks(notes: notes, sources: list)
        if let model {
            // An untitled page takes the notes' title; otherwise the notes get a heading.
            if store.page(model.pageID)?.title.isEmpty == true && !title.isEmpty {
                store.update(model.pageID) { $0.title = title }
                model.insertBlocks(blocks, after: anchor)
            } else {
                model.insertBlocks((title.isEmpty ? [] : [Block(type: .heading2, text: title)]) + blocks, after: anchor)
            }
            dismiss()
        } else {
            let id = store.newPage(title: title, icon: style == .lecture ? "🎓" : "🗒️", blocks: blocks)
            dismiss()
            app.open(id)
        }
    }

    private func close() {
        task?.cancel()
        queue?.cancel()
        if recorder.isRecording { recorder.discard() }
        dismiss()
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    static func symbol(_ kind: NotesSource.Kind) -> String {
        switch kind {
        case .recording: return "mic"
        case .audio: return "waveform"
        case .document: return "doc.text"
        case .image: return "photo"
        }
    }
}

/// Shown on a new, empty page: start from a recording, from files, or ask AI.
struct EmptyPageActions: View {
    var record: () -> Void
    var files: () -> Void
    var ask: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Start with").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                chip("Record", "mic.fill", action: record)
                chip("Upload files", "doc.badge.plus", action: files)
                chip("Ask AI", "sparkles", action: ask)
            }
        }
    }

    private func chip(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(UIColor.secondarySystemBackground), in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.accent)
    }
}

/// VisionKit's document camera.
struct DocumentScanner: UIViewControllerRepresentable {
    let onFinish: ([UIImage]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onFinish: ([UIImage]) -> Void
        init(onFinish: @escaping ([UIImage]) -> Void) { self.onFinish = onFinish }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            onFinish((0..<scan.pageCount).map { scan.imageOfPage(at: $0) })
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { onFinish([]) }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { onFinish([]) }
    }
}
