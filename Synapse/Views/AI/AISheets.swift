import SwiftUI
import SynapseKit

/// Claude on a block, a selection, or the whole page.
struct AIEditSheet: View {
    @Environment(AIService.self) private var ai
    @Environment(WorkspaceStore.self) private var store
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let request: EditorAIRequest
    let model: PageEditorModel

    @State private var action: AIAction?
    @State private var instruction = ""
    @State private var language = "Spanish"
    @State private var output = ""
    @State private var running = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var linkPicks: Set<String> = []
    /// The engine and model behind the current result.
    @State private var engine: AIEngine?
    @State private var answer: AIAnswerInfo?
    @State private var routeReason: String?

    private var isWholePage: Bool { request.blockIDs.count > 1 || (request.selectedText.isEmpty && request.range == nil) }
    private var sourceText: String {
        if !request.selectedText.isEmpty { return request.selectedText }
        if request.blockIDs.count == 1 { return model.markdown(of: request.blockIDs) }
        return ""
    }

    static let languages = ["English", "Spanish", "French", "German", "Italian", "Portuguese", "Dutch", "Japanese", "Korean",
                            "Chinese (Simplified)", "Arabic", "Hindi", "Russian", "Turkish", "Polish", "Swahili"]

    var body: some View {
        NavigationStack {
            Group {
                if action == nil {
                    actionList
                } else {
                    resultView
                }
            }
            .navigationTitle(action?.title ?? "Ask AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        task?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ModelChip(engine: engine, answer: running ? nil : answer)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            if let a = request.action { run(a) }
        }
        .onDisappear { task?.cancel() }
    }

    // MARK: Choosing

    private var actionList: some View {
        List {
            if !ai.canAnswer {
                Section {
                    Label("Turn on Apple Intelligence, or connect a cloud model in Settings, to use AI.", systemImage: "exclamationmark.triangle")
                    Button("Open Settings") {
                        dismiss()
                        app.tab = .settings
                    }
                }
            }
            Section {
                HStack {
                    TextField("Tell AI what to do…", text: $instruction, axis: .vertical)
                        .onSubmit { if !instruction.isEmpty { run(.custom) } }
                    Button { run(.custom) } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .disabled(instruction.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } footer: {
                Text(isWholePage ? "About the whole page." : "About: “\(String(sourceText.prefix(80)))\(sourceText.count > 80 ? "…" : "")”")
            }
            if !sourceText.isEmpty {
                Section("Edit") {
                    ForEach(AIAction.editGroup) { a in actionButton(a) }
                    Menu {
                        ForEach(AIAction.toneGroup) { a in Button(a.title) { run(a) } }
                    } label: { Label("Change tone", systemImage: "theatermasks") }
                    Menu {
                        ForEach(Self.languages, id: \.self) { l in
                            Button(l) {
                                language = l
                                run(.translate)
                            }
                        }
                    } label: { Label("Translate", systemImage: "character.bubble") }
                }
            }
            Section("Generate") {
                ForEach(AIAction.generateGroup) { a in actionButton(a) }
            }
        }
    }

    private func actionButton(_ a: AIAction) -> some View {
        Button { run(a) } label: { Label(a.title, systemImage: a.symbol) }
    }

    // MARK: Running

    /// Run an action; `force` picks the engine instead of the router (the "Redo with…" buttons).
    private func run(_ a: AIAction, force: AIEngine? = nil) {
        action = a
        output = ""
        error = nil
        running = true
        linkPicks = []
        answer = nil
        let page = store.page(model.pageID)
        let titles = store.workspace.livePages.filter { $0.id != model.pageID && !$0.isTemplate && $0.kind != .row }.map(\.displayTitle)
        let pageText = model.markdown
        let reason = AIRouter.complexity(of: a, inputCharacters: a == .suggestLinks ? 600 : (sourceText.isEmpty ? pageText.count : sourceText.count),
                                         extraCharacters: a == .suggestLinks ? titles.joined(separator: "\n").count : 0,
                                         instruction: instruction, language: language, budget: ai.localBudget)
        let route = force.map { AIRoute(engine: $0, reason: "Chosen by you", complex: reason != nil) } ?? ai.route(complexReason: reason)
        let local = route.engine == .onDevice
        engine = route.engine
        routeReason = route.engine == .cloud && reason != nil ? reason : nil
        // On device the window is small (4K tokens for Apple's model, 8K for downloaded ones): the page is the subject
        // when nothing is selected, else background.
        let budget = ai.localBudget
        let contextLimit = local ? (sourceText.isEmpty ? budget.prompt - 1_000 : budget.pageContext) : 24_000
        let req = AIPrompts.request(for: a, text: a == .suggestLinks ? "" : sourceText, pageTitle: page?.displayTitle ?? "",
                                    pageContext: pageText, language: language, instruction: instruction,
                                    linkCandidates: local ? Array(titles.prefix(120)) : titles, contextLimit: contextLimit)
        task?.cancel()
        task = Task { @MainActor in
            do {
                for try await chunk in ai.stream(req, on: route.engine, fallback: force == nil) { output += chunk }
                answer = ai.lastAnswer
                if a == .suggestLinks {
                    linkPicks = Set(AIPrompts.parseLinkSuggestions(output).map { $0.title }.filter { store.workspace.resolve($0) != nil })
                }
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
            running = false
        }
    }

    private var resultView: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    if action == .suggestLinks && !running {
                        let suggestions = AIPrompts.parseLinkSuggestions(output)
                            .filter { store.workspace.resolve($0.title) != nil }
                            .map { LinkSuggestion(title: $0.title, reason: $0.reason) }
                        if suggestions.isEmpty {
                            Text(output.isEmpty ? "No suggestions." : output).foregroundStyle(.secondary)
                        }
                        ForEach(suggestions) { s in
                            Button {
                                if linkPicks.contains(s.title) { linkPicks.remove(s.title) } else { linkPicks.insert(s.title) }
                            } label: {
                                HStack(alignment: .top) {
                                    Image(systemName: linkPicks.contains(s.title) ? "checkmark.circle.fill" : "circle").foregroundStyle(Palette.accent)
                                    VStack(alignment: .leading) {
                                        Text("[[\(s.title)]]").fontWeight(.semibold)
                                        if !s.reason.isEmpty { Text(s.reason).font(.footnote).foregroundStyle(.secondary) }
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        Text(markdown(output.isEmpty && running ? "…" : output))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if running {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(engine == .onDevice ? (ai.models.loading ? "Loading \(ai.local.card.name) into memory…"
                                                                           : "Writing on this iPhone (\(ai.local.card.name))…")
                                 : "\(ai.cloudCard.name) is writing (\(ai.provider.shortTitle))…")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    } else if let answer {
                        Label {
                            Text(answer.note ?? routeReason.map { "Sent to \(answer.model): \($0.lowercased())" }
                                 ?? (answer.engine == .onDevice ? "Written on this iPhone by \(answer.model)" : "Written by \(answer.model)"))
                        } icon: {
                            Image(systemName: answer.engine == .onDevice ? "iphone" : "cloud")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            Divider()
            actionsBar
                .padding()
        }
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    @ViewBuilder private var actionsBar: some View {
        let done = !running && error == nil && !output.isEmpty
        HStack(spacing: 10) {
            if action == .suggestLinks {
                Button {
                    let links = linkPicks.sorted().map { "[[\($0)]]" }.joined(separator: " · ")
                    model.insertMarkdown("Related: " + links, after: model.items.last?.id)
                    dismiss()
                } label: { Label("Add links", systemImage: "link.badge.plus").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
                .disabled(linkPicks.isEmpty)
            } else {
                if let a = action, a.replacesSelection, !isWholePage {
                    Button {
                        if let range = request.range, let id = request.blockIDs.first {
                            model.replaceText(in: id, range: range, with: output)
                        } else {
                            model.replace(request.blockIDs, with: output)
                        }
                        dismiss()
                    } label: { Label("Replace", systemImage: "arrow.2.squarepath").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!done)
                }
                Button {
                    model.insertMarkdown(output, after: isWholePage ? model.items.last?.id : request.blockIDs.last)
                    dismiss()
                } label: { Label(isWholePage ? "Add to page" : "Insert below", systemImage: "text.insert").frame(maxWidth: .infinity) }
                .buttonStyle(.bordered)
                .disabled(!done)
            }
            Menu {
                Button { UIPasteboard.general.string = output } label: { Label("Copy", systemImage: "doc.on.doc") }
                Button {
                    if let a = action { run(a) }
                } label: { Label("Try again", systemImage: "arrow.clockwise") }
                if answer?.engine == .onDevice && ai.isConfigured {
                    Button {
                        if let a = action { run(a, force: .cloud) }
                    } label: { Label("Redo with \(ai.cloudCard.name)", systemImage: "cloud") }
                }
                if answer?.engine == .cloud && ai.localReady {
                    Button {
                        if let a = action { run(a, force: .onDevice) }
                    } label: { Label("Redo on this iPhone", systemImage: "iphone") }
                }
                Button {
                    let imported = MarkdownCodec.parse(output, fallbackTitle: action?.title ?? "AI draft")
                    let id = store.newPage(parent: model.pageID, title: imported.title, blocks: imported.blocks)
                    dismiss()
                    app.open(id)
                } label: { Label("Save as sub-page", systemImage: "doc.badge.plus") }
                Button { action = nil; output = "" } label: { Label("Back", systemImage: "chevron.left") }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title2)
            }
            .disabled(running)
        }
    }
}

struct LinkSuggestion: Identifiable {
    var id: String { title }
    var title: String
    var reason: String
}

// MARK: - Ask Synapse

struct AskMessage: Identifiable, Equatable {
    var id = UUID()
    var role: AIMessage.Role
    var text: String
    var sources: [String] = []
    /// For answers: the question, and the model that wrote it.
    var question: String?
    var answer: AIAnswerInfo?
}

/// Chat with Claude about your workspace.
struct AskView: View {
    @Environment(AIService.self) private var ai
    @Environment(WorkspaceStore.self) private var store
    @Environment(AppModel.self) private var app
    @State private var messages: [AskMessage] = []
    @State private var draft = ""
    @State private var running = false
    @State private var task: Task<Void, Never>?
    @FocusState private var inputFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if messages.isEmpty { intro }
                    ForEach(messages) { m in
                        bubble(m).id(m.id)
                    }
                    if running {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Reading your pages…").font(.footnote).foregroundStyle(.secondary)
                        }
                        .id("progress")
                    }
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages) { _, m in
                if let last = m.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask about your workspace…", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($inputFocused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color(UIColor.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                Button {
                    if running { task?.cancel(); running = false } else { send() }
                } label: {
                    Image(systemName: running ? "stop.circle.fill" : "arrow.up.circle.fill").font(.system(size: 32))
                }
                .disabled(!running && draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .navigationTitle("Ask Synapse")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ModelChip(engine: ai.route(complexReason: AIRouter.askComplexReason).engine)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { messages = [] } label: { Image(systemName: "square.and.pencil") }
                    .disabled(messages.isEmpty)
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(Palette.accent)
            Text("Ask anything about your notes").font(.title2.bold())
            Text("Synapse finds the relevant pages and answers with links to them. Questions across your workspace go to your cloud model when one is connected; otherwise they run on this iPhone with fewer pages.")
                .foregroundStyle(.secondary)
            if !ai.canAnswer {
                Button { app.tab = .settings } label: { Label("Set up AI first", systemImage: "link") }
                    .buttonStyle(.borderedProminent)
            }
            ForEach(["What are my open tasks?", "Summarize what I wrote this week", "Which notes talk about ideas I haven't linked yet?"], id: \.self) { q in
                Button {
                    draft = q
                    send()
                } label: {
                    Text(q).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color(UIColor.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 20)
    }

    private func bubble(_ m: AskMessage) -> some View {
        VStack(alignment: m.role == .user ? .trailing : .leading, spacing: 6) {
            if m.role == .user {
                Text(m.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Palette.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                Text(linkified(m.text))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .environment(\.openURL, OpenURLAction { url in
                        app.handle(url: url, store: store)
                        return url.scheme == "synapse" ? .handled : .systemAction
                    })
                if !m.sources.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(m.sources, id: \.self) { s in
                                Button {
                                    if let p = store.workspace.resolve(s) { app.open(p.id) }
                                } label: {
                                    Label(s, systemImage: "doc.text").font(.caption)
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .background(Color(UIColor.tertiarySystemFill), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                if !m.text.isEmpty {
                    HStack(spacing: 14) {
                        if let a = m.answer {
                            Label(a.note ?? a.model, systemImage: a.engine == .onDevice ? "iphone" : "cloud")
                                .lineLimit(1)
                        }
                        if let q = m.question, !running, let a = m.answer {
                            if a.engine == .onDevice && ai.isConfigured {
                                Button { send(q, force: .cloud) } label: { Label("Ask \(ai.cloudCard.name)", systemImage: "cloud") }
                            } else if a.engine == .cloud && ai.localReady {
                                Button { send(q, force: .onDevice) } label: { Label("On iPhone", systemImage: "iphone") }
                            }
                        }
                        Button { UIPasteboard.general.string = m.text } label: { Image(systemName: "doc.on.doc") }
                        Button {
                            let imported = MarkdownCodec.parse(m.text, fallbackTitle: "Answer – \(DateText.short(Date()))")
                            let id = store.newPage(title: imported.title, icon: "✨", blocks: imported.blocks)
                            app.open(id)
                        } label: { Image(systemName: "doc.badge.plus") }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Markdown with `[[Page]]` turned into tappable links.
    private func linkified(_ text: String) -> AttributedString {
        var s = text
        for link in InlineMarkdown.wikiLinks(in: text).reversed() {
            if let url = AppModel.openLink(title: link.target) {
                s = s.replacingOccurrences(of: link.markdown, with: "[\(link.label)](\(url.absoluteString))")
            }
        }
        return (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    private func send() {
        let q = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !running else { return }
        draft = ""
        send(q, force: nil)
    }

    /// Ask a question; `force` re-asks it on a chosen engine.
    private func send(_ q: String, force: AIEngine?) {
        guard !running else { return }
        let history = messages.filter { !$0.text.isEmpty }.map { AIMessage(role: $0.role, content: $0.text) }
        if force == nil { messages.append(AskMessage(role: .user, text: q)) }
        let engine = force ?? ai.route(complexReason: AIRouter.askComplexReason).engine
        // On device: fewer, shorter sources and history to fit the ~4K-token window.
        let local = engine == .onDevice
        let sources = local ? AIPrompts.retrieve(q, in: store.workspace, limit: 4, budget: ai.localBudget.ask)
                            : AIPrompts.retrieve(q, in: store.workspace)
        let req = AIPrompts.ask(question: q, sources: sources, history: Array(history.suffix(local ? 2 : 10)))
        let answer = AskMessage(role: .assistant, text: "", sources: sources.map { $0.title }, question: q)
        let answerID = answer.id
        messages.append(answer)
        running = true
        task = Task { @MainActor in
            var text = ""
            do {
                for try await chunk in ai.stream(req, on: engine, fallback: force == nil) {
                    text += chunk
                    if let i = messages.firstIndex(where: { $0.id == answerID }) { messages[i].text = text }
                }
                if let i = messages.firstIndex(where: { $0.id == answerID }) { messages[i].answer = ai.lastAnswer }
            } catch is CancellationError {
            } catch {
                if let i = messages.firstIndex(where: { $0.id == answerID }) {
                    messages[i].text = "⚠️ " + error.localizedDescription
                    messages[i].sources = []
                }
            }
            running = false
        }
    }
}
