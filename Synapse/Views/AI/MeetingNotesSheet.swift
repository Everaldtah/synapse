import SwiftUI
import UniformTypeIdentifiers
import SynapseKit

/// Record (or import) audio, transcribe it on this iPhone, and turn the transcript into meeting notes.
/// Notes run on the on-device model by default; long recordings are noted in parts and merged.
struct MeetingNotesSheet: View {
    @Environment(AIService.self) private var ai
    @Environment(WorkspaceStore.self) private var store
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    /// Insert into this page after `anchor`; nil makes a new page.
    var model: PageEditorModel?
    var anchor: UUID?

    enum Phase { case ready, recording, transcribing, writing, done, failed }

    @State private var phase: Phase = .ready
    @State private var recorder = AudioRecorder()
    @State private var title = "Meeting – \(DateText.short(Date()))"
    @State private var audioURL: URL?
    @State private var transcript = ""
    @State private var notes = ""
    @State private var progressLabel = ""
    @State private var progressValue: Double?
    @State private var error: String?
    @State private var locales: [Locale] = []
    @State private var locale: Locale = .current
    @State private var keepAudio = true
    @State private var showImporter = false
    @State private var showTranscript = false
    @State private var engine: AIEngine?
    @State private var answer: AIAnswerInfo?
    @State private var task: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    TextField("Title", text: $title)
                        .font(.title2.bold())
                        .disabled(phase == .recording)
                    switch phase {
                    case .ready: readyView
                    case .recording: recordingView
                    case .transcribing, .writing: progressView
                    case .done: doneView
                    case .failed: failedView
                    }
                    if !transcript.isEmpty && phase != .recording {
                        DisclosureGroup(isExpanded: $showTranscript) {
                            Text(transcript).font(.callout).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 6)
                        } label: {
                            Label("Transcript · \(transcript.split(separator: " ").count) words", systemImage: "text.quote")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Meeting notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { close() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ModelChip(engine: engine, answer: phase == .done ? answer : nil)
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio, .movie]) { result in
                if case .success(let url) = result {
                    do {
                        let copy = try AssetStore.importFile(url)
                        audioURL = copy
                        if title.hasPrefix("Meeting – ") { title = url.deletingPathExtension().lastPathComponent }
                        transcribe()
                    } catch {
                        fail("Couldn't open that file: \(error.localizedDescription)")
                    }
                }
            }
            .task {
                locales = await Transcriber.supportedLocales()
                if let l = await Transcriber.defaultLocale() { locale = l }
            }
        }
        .interactiveDismissDisabled(phase == .recording || phase == .transcribing || phase == .writing)
    }

    // MARK: Phases

    private var readyView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button { startRecording() } label: {
                HStack(spacing: 14) {
                    Image(systemName: "mic.fill").font(.title2).foregroundStyle(.white)
                        .frame(width: 56, height: 56).background(Color.red, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Record").font(.headline)
                        Text("Keeps recording with the screen locked").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(14)
                .background(Color(UIColor.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)

            Button { showImporter = true } label: {
                Label("Transcribe an audio file…", systemImage: "waveform.badge.plus")
            }

            if !locales.isEmpty {
                Picker("Language", selection: $locale) {
                    ForEach(locales, id: \.identifier) { Text(Transcriber.name(of: $0)).tag($0) }
                }
                .pickerStyle(.menu)
            }
            Toggle("Keep the recording on the page", isOn: $keepAudio)

            VStack(alignment: .leading, spacing: 6) {
                Label("Transcribed on this iPhone by \(ModelCatalog.appleSpeech.name)", systemImage: "iphone")
                Label("Notes by \(ai.modelName(ai.everydayEngine))\(ai.everydayEngine == .onDevice ? " (on device)" : "")",
                      systemImage: ai.everydayEngine == .onDevice ? "iphone" : "cloud")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

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
            Text(recorder.isPaused ? "Paused" : "Recording…").font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 28) {
                Button(role: .destructive) {
                    recorder.discard()
                    phase = .ready
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
                    audioURL = recorder.stop()
                    transcribe()
                } label: {
                    Image(systemName: "stop.fill").font(.title2).foregroundStyle(.white).frame(width: 72, height: 72)
                        .background(Color.red, in: Circle())
                }
                .accessibilityLabel("Stop and write notes")
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 12)
    }

    private var progressView: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let progressValue {
                ProgressView(value: progressValue)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
            Text(progressLabel).font(.subheadline).foregroundStyle(.secondary)
            if phase == .writing {
                Text(engine == .onDevice ? "Writing on this iPhone with \(ai.local.card.name)…" : "Writing with \(ai.cloudCard.name)…")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Cancel", role: .cancel) {
                task?.cancel()
                phase = transcript.isEmpty ? .ready : .failed
                error = transcript.isEmpty ? nil : "Cancelled. The transcript is kept."
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
            Text(markdown(notes)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button { save() } label: {
                Label(model == nil ? "Create page" : "Add to page", systemImage: model == nil ? "doc.badge.plus" : "text.insert")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            HStack {
                if answer?.engine == .onDevice && ai.isConfigured {
                    Button { writeNotes(force: .cloud) } label: { Label("Redo with \(ai.cloudCard.name)", systemImage: "cloud") }
                }
                if answer?.engine == .cloud && ai.localReady {
                    Button { writeNotes(force: .onDevice) } label: { Label("Redo on this iPhone", systemImage: "iphone") }
                }
            }
            .font(.subheadline)
        }
    }

    private var failedView: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            if !transcript.isEmpty {
                Button { writeNotes() } label: { Label("Write the notes again", systemImage: "arrow.clockwise") }
                if ai.isConfigured {
                    Button { writeNotes(force: .cloud) } label: { Label("Write them with \(ai.cloudCard.name)", systemImage: "cloud") }
                }
                Button { notes = ""; save() } label: { Label("Save the transcript only", systemImage: "doc.text") }
            } else if audioURL != nil {
                Button { transcribe() } label: { Label("Transcribe again", systemImage: "arrow.clockwise") }
            } else {
                Button { phase = .ready; error = nil } label: { Label("Start over", systemImage: "arrow.uturn.backward") }
            }
        }
    }

    // MARK: Actions

    private func startRecording() {
        Task { @MainActor in
            do {
                try await recorder.start()
                phase = .recording
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    private func transcribe() {
        guard let url = audioURL else { return }
        phase = .transcribing
        progressLabel = "Preparing…"
        progressValue = nil
        error = nil
        let wanted = locale
        task = Task { @MainActor in
            do {
                transcript = try await Transcriber.transcribe(url, locale: wanted) { label, value in
                    progressLabel = label
                    progressValue = value
                }
                writeNotes()
            } catch is CancellationError {
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    /// Notes from the transcript. Meeting notes are everyday work: the on-device model handles any length in parts.
    private func writeNotes(force: AIEngine? = nil) {
        let route = force.map { AIRoute(engine: $0, reason: "Chosen by you", complex: false) } ?? ai.route(complexReason: nil)
        engine = route.engine
        answer = nil
        phase = .writing
        progressLabel = "Writing notes…"
        progressValue = nil
        error = nil
        let text = transcript
        let name = title
        let ai = self.ai
        task = Task { @MainActor in
            var budget = route.engine == .onDevice ? AIRouter.localPromptBudget - 1_200 : 150_000
            for attempt in 0..<2 {
                do {
                    var used: AIAnswerInfo?
                    let result = try await MeetingNotes.generate(transcript: text, title: name, budget: budget, complete: { req in
                        let reply = try await ai.complete(req, on: route.engine, fallback: force == nil)
                        used = await ai.lastAnswer
                        return reply
                    }, progress: { step in
                        Task { @MainActor in
                            progressLabel = step.label
                            progressValue = step.total > 0 ? Double(step.done) / Double(step.total) : nil
                        }
                    })
                    notes = result
                    answer = used
                    phase = .done
                    return
                } catch is CancellationError {
                    return
                } catch LocalAIError.tooLong where attempt == 0 {
                    // The tokenizer counted more than we estimated: smaller parts.
                    budget /= 2
                } catch {
                    fail(error.localizedDescription)
                    return
                }
            }
        }
    }

    private func save() {
        let ref = keepAudio ? audioURL.map(AssetStore.reference(for:)) : nil
        let blocks = MeetingNotes.blocks(notes: notes, transcript: transcript, audio: ref, audioCaption: title)
        if !keepAudio, let audioURL { try? FileManager.default.removeItem(at: audioURL) }
        if let model {
            if !title.isEmpty { model.insertBlocks([Block(type: .heading2, text: title)] + blocks, after: anchor) }
            else { model.insertBlocks(blocks, after: anchor) }
            dismiss()
        } else {
            let id = store.newPage(title: title, icon: "🎙️", blocks: blocks)
            dismiss()
            app.open(id)
        }
    }

    private func close() {
        task?.cancel()
        if recorder.isRecording { recorder.discard() }
        dismiss()
    }

    private func fail(_ message: String) {
        error = message
        phase = .failed
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}
