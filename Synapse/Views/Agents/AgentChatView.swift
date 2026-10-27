import PhotosUI
import QuickLook
import SwiftUI
import SynapseKit
import UniformTypeIdentifiers
import VisionKit

/// A chat with one agent: messages with the steps it took, files it made, attachments, the model picker,
/// approvals for changes and undo.
struct AgentChatView: View {
    @Environment(AgentCenter.self) private var center
    @Environment(AIService.self) private var ai
    @Environment(WorkspaceStore.self) private var store
    @Environment(AppModel.self) private var app
    let conversationID: UUID

    @State private var draft = ""
    @State private var attachments: [AgentAttachmentDraft] = []
    @State private var showFiles = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showScanner = false
    @State private var recorder = AudioRecorder()
    @State private var preview: URL?
    @State private var undoFor: UUID?
    @State private var attachError: String?
    @FocusState private var inputFocused: Bool

    private var conversation: AgentConversation? { center.conversation(conversationID) }
    private var agent: AgentProfile? { conversation.flatMap { center.profile($0.agentID) } }

    var body: some View {
        let session = center.session(conversationID)
        dialogs(pickers(chat(session)), session: session)
    }

    private func chat(_ session: AgentSession) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if conversation?.messages.isEmpty ?? true, let agent { intro(agent) }
                    ForEach(conversation?.messages ?? []) { m in
                        message(m).id(m.id)
                    }
                    if AgentBrowser.shared.conversationID == conversationID && AgentBrowser.shared.hasPage { BrowserPanel() }
                    if session.running { live(session).id("live") }
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: conversation?.messages.count) { _, _ in
                if let last = conversation?.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            .onChange(of: session.steps.count) { _, _ in withAnimation { proxy.scrollTo("live", anchor: .bottom) } }
        }
        .safeAreaInset(edge: .bottom) { composer(session) }
        .navigationTitle(agent?.name ?? "Agent")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
    }

    /// Quick Look and the attachment pickers.
    private func pickers<Content: View>(_ content: Content) -> some View {
        content
            .quickLookPreview($preview)
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { for url in urls { attach(url) } }
            }
            .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 10, matching: .any(of: [.images, .videos]))
            .onChange(of: photoItems) { _, items in addPhotos(items) }
            .fullScreenCover(isPresented: $showScanner) {
                DocumentScanner { images in
                    showScanner = false
                    addScan(images)
                }
                .ignoresSafeArea()
            }
    }

    /// Approvals, undo confirmation and attach errors.
    private func dialogs<Content: View>(_ content: Content, session: AgentSession) -> some View {
        let approval = Binding<PendingApproval?>(get: { session.approval }, set: { value in
            if value == nil { session.approval?.resume(false, false) }
        })
        let confirmUndo = Binding<Bool>(get: { undoFor != nil }, set: { if !$0 { undoFor = nil } })
        let pages = undoFor.map { center.undoCount($0) } ?? 0
        return content
            .sheet(item: approval) { pending in
                ApprovalSheet(approval: pending)
                    .presentationDetents([.medium])
                    .interactiveDismissDisabled()
            }
            .confirmationDialog("Undo this reply's changes?", isPresented: confirmUndo, titleVisibility: .visible) {
                Button("Undo changes to \(pages) page\(pages == 1 ? "" : "s")", role: .destructive) {
                    if let id = undoFor { center.undo(id, in: conversationID, store: store) }
                    undoFor = nil
                }
            } message: {
                Text("Pages go back to how they were before the agent changed them, and pages it created are removed. Edits you made to those pages since then are lost.")
            }
            .alert("Couldn't attach", isPresented: Binding(get: { attachError != nil }, set: { if !$0 { attachError = nil } })) {
                Button("OK") { attachError = nil }
            } message: { Text(attachError ?? "") }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            if let conversation, let agent {
                AgentModelMenu(selection: conversation.model ?? agent.model, compact: true) { key in
                    center.update(conversationID) { $0.model = key }
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if let agent {
                    Button { app.agentsPath.append(.agentChat(center.newConversation(agent: agent.id))) } label: {
                        Label("New chat with \(agent.name)", systemImage: "square.and.pencil")
                    }
                    Button { app.agentsPath.append(.agentEditor(agent.id)) } label: { Label("Edit agent", systemImage: "slider.horizontal.3") }
                }
                Button { app.agentsPath.append(.agentFiles) } label: { Label("Agent files", systemImage: "folder") }
                Button(role: .destructive) {
                    center.delete(conversation: conversationID)
                    if !app.agentsPath.isEmpty { app.agentsPath.removeLast() }
                } label: { Label("Delete chat", systemImage: "trash") }
            } label: { Image(systemName: "ellipsis.circle") }
        }
    }

    // MARK: Intro

    private func intro(_ agent: AgentProfile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(agent.icon).font(.system(size: 44))
            Text(agent.name).font(.title2.bold())
            Text(agent.summary).foregroundStyle(.secondary)
            FlowChips(items: AgentCapability.allCases.filter { agent.capabilities.contains($0) }.map { ($0.title, $0.symbol) })
            if !ai.canAnswer && APIProviderStore.shared.readyProviders.isEmpty {
                Button { app.agentsPath.append(.apiProviders) } label: { Label("Add a free AI model first", systemImage: "key") }
                    .buttonStyle(.borderedProminent)
            }
            ForEach(Self.examples(for: agent), id: \.self) { q in
                Button {
                    draft = q
                    inputFocused = true
                } label: {
                    Text(q).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color(UIColor.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 12)
    }

    static func examples(for agent: AgentProfile) -> [String] {
        switch agent.id {
        case AgentPresets.researcher.id:
            return ["Research the latest on solid-state batteries and save a sourced page", "Compare three note-taking methods with references"]
        case AgentPresets.graphArchitect.id:
            return ["Connect my notes: link related pages and tag them", "Make a hub page for each topic and colour the graph by topic"]
        case AgentPresets.analyst.id:
            return ["Turn the attached CSV into a spreadsheet with totals", "Make a budget database for this month"]
        case AgentPresets.presenter.id:
            return ["Make a 6-slide deck from my page \"Project plan\"", "Write a one-page PDF summary of this week's notes"]
        case AgentPresets.coder.id:
            return ["Convert the attached audio to MP3 and save it", "Write and run a Python script that plots y = x²"]
        case AgentPresets.browser.id:
            return ["Go to Wikipedia and find out when the Eiffel Tower opened", "Search Hacker News for the top story today and summarise it", "Open bbc.com and tell me the main headline"]
        default:
            return ["Organise my workspace: group pages under topics", "Create a reading list database with five books", "Show my graph with tags, coloured by tag"]
        }
    }

    // MARK: Messages

    @ViewBuilder private func message(_ m: AgentChatMessage) -> some View {
        if m.role == .user {
            VStack(alignment: .trailing, spacing: 6) {
                if !m.files.isEmpty { fileChips(m.files) }
                if !m.text.isEmpty {
                    Text(m.text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Palette.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if !m.steps.isEmpty { AgentStepsView(steps: AgentCenter.steps(of: m)) }
                Text(AgentText.linkified(m.text))
                    .textSelection(.enabled)
                    .foregroundStyle(m.failed ? Color.orange : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .environment(\.openURL, OpenURLAction { url in
                        app.handle(url: url, store: store)
                        return url.scheme == "synapse" ? .handled : .systemAction
                    })
                if !m.files.isEmpty { fileChips(m.files) }
                HStack(spacing: 14) {
                    if let model = m.model { Label(model, systemImage: "cpu").lineLimit(1) }
                    Button { UIPasteboard.general.string = m.text } label: { Image(systemName: "doc.on.doc") }
                        .accessibilityLabel("Copy")
                    Button {
                        let imported = MarkdownCodec.parse(m.text, fallbackTitle: "\(agent?.name ?? "Agent") – \(DateText.short(Date()))")
                        app.open(store.newPage(title: imported.title, icon: agent?.icon ?? "✨", blocks: imported.blocks))
                    } label: { Image(systemName: "doc.badge.plus") }
                    .accessibilityLabel("Save as page")
                    if m.changedWorkspace && center.canUndo(m.id) {
                        Button { undoFor = m.id } label: { Label("Undo changes", systemImage: "arrow.uturn.backward") }
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
            }
        }
    }

    private func fileChips(_ files: [AgentFile]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(files) { f in
                    Button { preview = AgentFileStore.url(for: f) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: f.symbol).foregroundStyle(Palette.accent)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(f.name).font(.caption.weight(.medium)).lineLimit(1)
                                Text(AgentFileStore.format(f.bytes)).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(Color(UIColor.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        ShareLink(item: AgentFileStore.url(for: f)) { Label("Share", systemImage: "square.and.arrow.up") }
                        Button { preview = AgentFileStore.url(for: f) } label: { Label("Open", systemImage: "eye") }
                    }
                }
            }
        }
    }

    private func live(_ session: AgentSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            AgentStepsView(steps: session.steps)
            if !session.liveText.isEmpty {
                Text(AgentText.linkified(session.liveText)).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                ProgressView()
                Text(session.status.isEmpty ? "Working…" : session.status)
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    // MARK: Composer

    private func composer(_ session: AgentSession) -> some View {
        VStack(spacing: 8) {
            if recorder.isRecording {
                HStack {
                    Image(systemName: "record.circle").foregroundStyle(.red)
                    Text("Recording \(Duration.seconds(recorder.elapsed).formatted(.time(pattern: .minuteSecond)))").font(.subheadline.monospacedDigit())
                    Spacer()
                    Button("Discard", role: .destructive) { recorder.discard() }
                    Button("Attach") { if let url = recorder.stop() { attach(url, name: "Recording \(DateText.short(Date(), includeTime: true)).m4a") } }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal)
            }
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(attachments) { a in
                            HStack(spacing: 5) {
                                Image(systemName: a.file.symbol)
                                Text(a.file.name).lineLimit(1)
                                Button { attachments.removeAll { $0.id == a.id } } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain).foregroundStyle(.secondary)
                            }
                            .font(.caption)
                            .padding(.horizontal, 9).padding(.vertical, 6)
                            .background(Color(UIColor.tertiarySystemFill), in: Capsule())
                        }
                    }
                    .padding(.horizontal)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    Button { showFiles = true } label: { Label("Files (any type)", systemImage: "folder") }
                    Button { showPhotos = true } label: { Label("Photos and videos", systemImage: "photo.on.rectangle") }
                    if VNDocumentCameraViewController.isSupported {
                        Button { showScanner = true } label: { Label("Scan documents", systemImage: "doc.viewfinder") }
                    }
                    Button {
                        Task { @MainActor in
                            do { try await recorder.start() } catch { attachError = error.localizedDescription }
                        }
                    } label: { Label("Record audio", systemImage: "mic") }
                } label: {
                    Image(systemName: "plus.circle.fill").font(.system(size: 30)).foregroundStyle(Palette.accent)
                }
                .accessibilityLabel("Attach")
                TextField("Message \(agent?.name ?? "the agent")…", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($inputFocused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color(UIColor.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                Button {
                    if session.running { center.stop(conversationID) } else { send() }
                } label: {
                    Image(systemName: session.running ? "stop.circle.fill" : "arrow.up.circle.fill").font(.system(size: 32))
                }
                .disabled(!session.running && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)
                .accessibilityLabel(session.running ? "Stop" : "Send")
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        draft = ""
        let files = attachments
        attachments = []
        inputFocused = false
        center.send(text, attachments: files, to: conversationID, ai: ai, store: store, app: app)
    }

    // MARK: Attaching

    private func attach(_ url: URL, name: String? = nil) {
        do {
            var file = try AgentFileStore.importFile(url, in: AgentFileStore.uploads)
            if let name {
                let dest = AgentFileStore.uniqueURL(in: AgentFileStore.uploads, name: name)
                try FileManager.default.moveItem(at: AgentFileStore.url(for: file), to: dest)
                file = AgentFileStore.record(for: dest)
                try? FileManager.default.removeItem(at: url)   // the recorder's own copy
            }
            attachments.append(AgentAttachmentDraft(file: file))
        } catch {
            attachError = error.localizedDescription
        }
    }

    private func addPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        photoItems = []
        Task { @MainActor in
            for (i, item) in items.enumerated() {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                let type = item.supportedContentTypes.first
                let ext = type?.preferredFilenameExtension ?? "jpg"
                let kind = type?.conforms(to: .movie) == true ? "Video" : "Photo"
                do {
                    let file = try AgentFileStore.save(data, name: "\(kind) \(DateText.short(Date()))\(items.count > 1 ? " \(i + 1)" : "").\(ext)",
                                                       in: AgentFileStore.uploads)
                    attachments.append(AgentAttachmentDraft(file: file))
                } catch {
                    attachError = error.localizedDescription
                }
            }
        }
    }

    /// Scanned pages become one PDF (read with OCR).
    private func addScan(_ images: [UIImage]) {
        guard !images.isEmpty else { return }
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let data = renderer.pdfData { ctx in
            for image in images {
                ctx.beginPage()
                let s = min(612 / image.size.width, 792 / image.size.height)
                let size = CGSize(width: image.size.width * s, height: image.size.height * s)
                image.draw(in: CGRect(x: (612 - size.width) / 2, y: (792 - size.height) / 2, width: size.width, height: size.height))
            }
        }
        do {
            attachments.append(AgentAttachmentDraft(file: try AgentFileStore.save(data, name: "Scan \(DateText.short(Date())).pdf", in: AgentFileStore.uploads)))
        } catch {
            attachError = error.localizedDescription
        }
    }
}

/// Ask before a change (agents set to "Ask before changes").
private struct ApprovalSheet: View {
    let approval: PendingApproval

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Label(AgentStepsView.title(approval.call), systemImage: AgentStepsView.symbol(approval.call))
                    .font(.headline)
                if !approval.call.input.isEmpty {
                    ScrollView {
                        Text(approval.call.input)
                            .font(.footnote.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .padding(10)
                    .background(Color(UIColor.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                }
                Spacer(minLength: 0)
                HStack {
                    Button("Don't allow", role: .destructive) { approval.resume(false, false) }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("Allow all") { approval.resume(true, true) }
                        .buttonStyle(.bordered)
                    Button("Allow") { approval.resume(true, false) }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .navigationTitle("\(approval.agentName) wants to")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Pick the model a chat or agent runs on, from everything set up (on-device, subscriptions, API providers).
struct AgentModelMenu: View {
    @Environment(AIService.self) private var ai
    @Environment(AppModel.self) private var app
    /// A model key ("" = Auto).
    let selection: String
    var compact = false
    let onPick: (String) -> Void

    var body: some View {
        let choice = ModelChoice(key: selection)
        let available = ai.isAvailable(choice)
        let name = available && choice != .auto ? ai.name(for: choice) : "Auto"
        let local = available && choice != .auto && ai.engine(for: choice) == .onDevice
        Menu {
            ForEach(ai.modelGroups) { group in
                Section(group.title) {
                    ForEach(group.options) { option in
                        Toggle(isOn: Binding(get: { option.choice.key == selection }, set: { _ in onPick(option.choice.key) })) {
                            Text(option.title)
                            if !option.detail.isEmpty { Text(option.detail) }
                        }
                    }
                }
            }
            Section {
                Button { app.tab = .agents; app.agentsPath.append(.apiProviders) } label: {
                    Label("Add free API providers…", systemImage: "key")
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: local ? "iphone" : "cloud").font(.caption2.weight(.bold))
                Text(name).font(compact ? .caption.weight(.semibold) : .subheadline).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .padding(.horizontal, compact ? 10 : 12)
            .padding(.vertical, compact ? 5 : 7)
            .foregroundStyle(local ? Color.green : Palette.accent)
            .background((local ? Color.green : Palette.accent).opacity(0.12), in: Capsule())
        }
        .accessibilityLabel("Model: \(name). Change model.")
    }
}

/// Small capsules that wrap onto new lines.
struct FlowChips: View {
    let items: [(String, String)]

    var body: some View {
        WrapLayout(spacing: 6) {
            ForEach(items, id: \.0) { item in
                Label(item.0, systemImage: item.1)
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color(UIColor.tertiarySystemFill), in: Capsule())
            }
        }
    }
}

/// Lays children out left to right, wrapping like text.
struct WrapLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(width, widest), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}

@MainActor
enum AgentText {
    /// Markdown with `[[Page]]` turned into tappable links (inline formatting, whitespace kept).
    static func linkified(_ text: String) -> AttributedString {
        var s = text
        for link in InlineMarkdown.wikiLinks(in: text).reversed() {
            if let url = AppModel.openLink(title: link.target) {
                s = s.replacingOccurrences(of: link.markdown, with: "[\(link.label)](\(url.absoluteString))")
            }
        }
        return (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
