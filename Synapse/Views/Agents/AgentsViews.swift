import QuickLook
import SwiftUI
import SynapseKit

/// The Agents tab: the agents, recent chats, and the tools around them (terminal, files, API providers, quick ask).
struct AgentsHomeView: View {
    @Environment(AgentCenter.self) private var center
    @Environment(AIService.self) private var ai
    @Environment(AppModel.self) private var app

    var body: some View {
        List {
            Section {
                ForEach(center.profiles) { p in
                    Button { start(p) } label: { AgentRow(profile: p) }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button { app.agentsPath.append(.agentEditor(p.id)) } label: { Label("Edit", systemImage: "slider.horizontal.3") }
                                .tint(Palette.accent)
                        }
                        .contextMenu {
                            Button { app.agentsPath.append(.agentEditor(p.id)) } label: { Label("Edit", systemImage: "slider.horizontal.3") }
                            Button { app.agentsPath.append(.agentEditor(center.duplicate(p).id)) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                            if !p.builtIn {
                                Button(role: .destructive) { center.delete(p) } label: { Label("Delete", systemImage: "trash") }
                            }
                        }
                }
                Button { app.agentsPath.append(.agentEditor(nil)) } label: { Label("New agent", systemImage: "plus") }
            } header: {
                Text("Agents")
            } footer: {
                Text("Agents work in steps with tools: your pages and databases, the graph, files (Excel, PowerPoint, Word, PDF), the web, a browser you can watch (Computer) and a Linux terminal. Tap one to start a chat; switch models any time from the chat's title.")
            }

            let chats = center.conversations.filter { !$0.messages.isEmpty || center.session($0.id).running }
            if !chats.isEmpty {
                Section("Recent chats") {
                    ForEach(chats.prefix(40)) { c in
                        NavigationLink(value: Route.agentChat(c.id)) { ChatRow(conversation: c) }
                    }
                    .onDelete { offsets in
                        for i in offsets { center.delete(conversation: chats[i].id) }
                    }
                }
            }

            Section {
                NavigationLink(value: Route.ask) { Label("Ask about your notes", systemImage: "questionmark.bubble") }
                NavigationLink(value: Route.computer) {
                    LabeledContent {
                        let b = AgentBrowser.shared
                        if b.hasPage { Text(b.title.isEmpty ? "Open" : b.title).lineLimit(1) }
                    } label: { Label("Computer", systemImage: "macwindow") }
                }
                NavigationLink(value: Route.terminal) { Label("Terminal", systemImage: "terminal") }
                NavigationLink(value: Route.agentFiles) { Label("Agent files", systemImage: "folder") }
                NavigationLink(value: Route.apiProviders) {
                    LabeledContent {
                        let n = APIProviderStore.shared.readyProviders.count
                        Text(n == 0 ? "Add free models" : "\(n) connected")
                    } label: { Label("API providers", systemImage: "key") }
                }
            } header: {
                Text("Tools")
            }
        }
        .navigationTitle("Agents")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { app.agentsPath.append(.agentEditor(nil)) } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New agent")
            }
        }
    }

    private func start(_ p: AgentProfile) {
        // Reuse an empty chat with this agent rather than piling up new ones.
        let id = center.conversations.first { $0.agentID == p.id && $0.messages.isEmpty }?.id ?? center.newConversation(agent: p.id)
        app.agentsPath.append(.agentChat(id))
    }
}

private struct AgentRow: View {
    @Environment(AIService.self) private var ai
    let profile: AgentProfile

    var body: some View {
        HStack(spacing: 12) {
            Text(profile.icon).font(.title2).frame(width: 40, height: 40)
                .background(Palette.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name).font(.headline)
                Text(profile.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                let choice = ModelChoice(key: profile.model)
                Text(choice == .auto || !ai.isAvailable(choice) ? "Auto model" : ai.name(for: choice))
                    .font(.caption2).foregroundStyle(Palette.accent)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

private struct ChatRow: View {
    @Environment(AgentCenter.self) private var center
    let conversation: AgentConversation

    var body: some View {
        let agent = center.profile(conversation.agentID)
        HStack(spacing: 10) {
            Text(agent?.icon ?? "🤖").frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.displayTitle).lineLimit(1)
                HStack(spacing: 4) {
                    Text(agent?.name ?? "Agent")
                    Text("·")
                    Text(conversation.updatedAt, style: .relative)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if center.session(conversation.id).running { ProgressView().controlSize(.small) }
        }
    }
}

// MARK: - Editor

/// Create or edit an agent: persona, instructions, tools, model and limits.
struct AgentEditorView: View {
    @Environment(AgentCenter.self) private var center
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let agentID: UUID?
    @State private var draft = AgentProfile(name: "New agent", icon: "🤖",
                                            capabilities: [.readWorkspace, .editWorkspace, .graph, .navigate, .documents, .web])
    @State private var loaded = false
    @State private var confirmDelete = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    TextField("🤖", text: $draft.icon)
                        .font(.system(size: 34))
                        .multilineTextAlignment(.center)
                        .frame(width: 56)
                        .onChange(of: draft.icon) { _, v in if v.count > 1 { draft.icon = String(v.suffix(1)) } }
                    VStack(alignment: .leading) {
                        TextField("Name", text: $draft.name).font(.headline)
                        TextField("What it's for", text: $draft.summary, axis: .vertical).font(.subheadline).lineLimit(1...3)
                    }
                }
            }
            Section {
                TextField("How it should work, what to focus on, the tone…", text: $draft.instructions, axis: .vertical)
                    .lineLimit(5...16)
            } header: {
                Text("Instructions")
            } footer: {
                Text("Added to the agent's system prompt. Example: \"You are my study coach. Turn lecture notes into flashcards and link each to its topic page.\"")
            }
            Section {
                ForEach(AgentCapability.allCases) { cap in
                    Toggle(isOn: Binding(get: { draft.capabilities.contains(cap) }, set: { on in
                        if on { draft.capabilities.insert(cap) } else { draft.capabilities.remove(cap) }
                    })) { Label(cap.title, systemImage: cap.symbol) }
                }
            } header: {
                Text("Tools")
            } footer: {
                Text("The terminal runs in a sandbox: Alpine Linux on this iPhone (installed on first use) or the bridge computer's Linux sandbox — never on your own files. The browser is the app's own; you watch it under Computer. The web, terminal and Claude Code also follow the switches in AI models.")
            }
            Section {
                LabeledContent("Model") {
                    AgentModelMenu(selection: draft.model) { draft.model = $0 }
                }
                Stepper(value: $draft.maxSteps, in: 4...80, step: 2) {
                    LabeledContent("Steps per task", value: "\(draft.maxSteps)")
                }
                Toggle("Ask before changes", isOn: $draft.confirmChanges)
            } header: {
                Text("Running")
            } footer: {
                Text("Small on-device models run with fewer steps and a shorter tool list. With \"Ask before changes\" on, you approve each edit to your workspace; either way, every reply that changed pages can be undone.")
            }
            if let id = agentID, let existing = center.profile(id) {
                Section {
                    if existing.builtIn {
                        Button("Reset to the original") {
                            center.reset(existing)
                            if let p = center.profile(id) { draft = p }
                        }
                    } else {
                        Button("Delete agent", role: .destructive) { confirmDelete = true }
                    }
                }
            }
        }
        .navigationTitle(agentID == nil ? "New agent" : "Edit agent")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    var p = draft
                    p.name = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if p.name.isEmpty { p.name = "Agent" }
                    if p.icon.isEmpty { p.icon = "🤖" }
                    center.save(p)
                    dismiss()
                }
            }
        }
        .confirmationDialog("Delete \(draft.name)? Its chats stay.", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                center.delete(draft)
                dismiss()
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let id = agentID, let p = center.profile(id) { draft = p }
        }
    }
}

// MARK: - Files

/// Everything agents made or were given, with Quick Look and sharing.
struct AgentFilesView: View {
    @State private var files: [URL] = []
    @State private var preview: URL?

    var body: some View {
        List {
            if files.isEmpty {
                ContentUnavailableView("No files yet", systemImage: "folder",
                                       description: Text("Spreadsheets, decks, documents and PDFs agents make appear here, along with files you attach. They're also in the Files app under Synapse › Synapse › Agent Files."))
            }
            ForEach(files, id: \.self) { url in
                let record = AgentFileStore.record(for: url)
                Button { preview = url } label: {
                    HStack(spacing: 12) {
                        Image(systemName: record.symbol).font(.title3).foregroundStyle(Palette.accent).frame(width: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(url.lastPathComponent).lineLimit(1)
                            Text(subtitle(url, record)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button(role: .destructive) {
                        try? FileManager.default.removeItem(at: url)
                        reload()
                    } label: { Label("Delete", systemImage: "trash") }
                    ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                }
                .contextMenu {
                    ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                }
            }
        }
        .navigationTitle("Agent files")
        .quickLookPreview($preview, in: files)
        .refreshable { reload() }
        .onAppear { reload() }
    }

    private func reload() { files = AgentFileStore.all() }

    private func subtitle(_ url: URL, _ record: AgentFile) -> String {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        let folder = url.deletingLastPathComponent().lastPathComponent == "Attachments" ? " · attached" : ""
        return "\(AgentFileStore.format(record.bytes)) · \(DateText.short(date, includeTime: true))\(folder)"
    }
}

// MARK: - Terminal

/// A Linux terminal: an interactive bash on this iPhone (Alpine, installed on first use) or commands in the bridge
/// computer's sandbox. The same shells agents use.
struct TerminalView: View {
    @Environment(AIService.self) private var ai
    @State private var target = "iphone"
    @State private var command = ""
    @State private var shell: OnDeviceLinux.Shell?
    @State private var opening = false
    @State private var openError: String?
    @State private var entries: [Entry] = []
    @State private var running = false
    @State private var history: [String] = []
    @FocusState private var focused: Bool

    struct Entry: Identifiable {
        let id = UUID()
        var target: String
        var command: String
        var output: String
    }

    private var pc: Bool { ai.bridgeSandbox?.available == true && ai.bridgeEndpoint != nil }
    private var onPhone: Bool { target == "iphone" || !pc }

    var body: some View {
        VStack(spacing: 0) {
            if pc {
                Picker("Where", selection: $target) {
                    Text("This iPhone (Alpine)").tag("iphone")
                    Text("Computer (Ubuntu)").tag("pc")
                }
                .pickerStyle(.segmented)
                .padding()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if onPhone {
                            phoneScreen
                        } else {
                            ForEach(entries) { e in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("pc $ \(e.command)").foregroundStyle(Color.green)
                                    Text(e.output).foregroundStyle(Color.white.opacity(0.88)).textSelection(.enabled)
                                }
                                .id(e.id)
                            }
                            if running { ProgressView().tint(.white) }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
                .background(Color.black)
                .onChange(of: entries.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: shell?.text.count ?? 0) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
            inputBar
        }
        .navigationTitle("Terminal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if onPhone, let shell {
                        Button { shell.interrupt() } label: { Label("Interrupt (Ctrl-C)", systemImage: "xmark.octagon") }
                        Button { shell.close(); self.shell = nil; openShell() } label: { Label("Restart shell", systemImage: "arrow.clockwise") }
                    } else {
                        Button { entries = [] } label: { Label("Clear", systemImage: "trash") }.disabled(entries.isEmpty)
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .onAppear {
            if !pc { target = "iphone" }
            if onPhone && ai.linux.isInstalled && shell == nil { openShell() }
            focused = true
        }
        .onChange(of: target) { _, _ in if onPhone && ai.linux.isInstalled && shell == nil { openShell() } }
    }

    /// The iPhone shell's screen, or the install step before it.
    @ViewBuilder private var phoneScreen: some View {
        let linux = ai.linux
        if let shell {
            Text(shell.text.isEmpty ? "Starting bash…" : shell.text).foregroundStyle(Color.white.opacity(0.88)).textSelection(.enabled)
            if let code = shell.exitCode {
                Text("[bash exited with code \(code)]").foregroundStyle(Color.orange)
                Button("Start a new shell") { self.shell = nil; openShell() }.foregroundStyle(Color.green)
            }
        } else if opening || [.downloading(0), .importing, .booting].contains(where: { Self.same($0, linux.state) }) {
            HStack(spacing: 10) {
                ProgressView().tint(.white)
                Text(linux.stateLabel).foregroundStyle(Color.white.opacity(0.88))
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Alpine Linux 3.20 on this iPhone — bash, python3, git, ripgrep, apk. Private, offline, emulated (slower than a computer).")
                    .foregroundStyle(Color.white.opacity(0.88))
                if let openError { Text(openError).foregroundStyle(Color.orange) }
                else if case .failed(let why) = linux.state { Text(why).foregroundStyle(Color.orange) }
                Button {
                    openShell()
                } label: {
                    Label(linux.isInstalled ? "Start Linux" : "Install Linux · \(ByteCountFormatter.string(fromByteCount: linux.pin.bytes, countStyle: .file))",
                          systemImage: linux.isInstalled ? "play.circle" : "arrow.down.circle")
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Palette.accent, in: Capsule())
                        .foregroundStyle(.white)
                }
            }
        }
    }

    private static func same(_ a: OnDeviceLinux.State, _ b: OnDeviceLinux.State) -> Bool {
        switch (a, b) {
        case (.downloading, .downloading), (.importing, .importing), (.booting, .booting): return true
        default: return false
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            Text("$").font(.body.monospaced()).foregroundStyle(.secondary)
            TextField("command", text: $command)
                .font(.body.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused)
                .submitLabel(.go)
                .onSubmit(run)
            Menu {
                ForEach(history.suffix(15).reversed(), id: \.self) { h in Button(h) { command = h } }
            } label: { Image(systemName: "clock.arrow.circlepath") }
            .disabled(history.isEmpty)
            if onPhone, let shell, shell.isRunning {
                Button { shell.interrupt() } label: { Text("^C").font(.body.monospaced().weight(.semibold)) }
                    .accessibilityLabel("Interrupt")
            }
            Button(action: run) { Image(systemName: "return") }
                .disabled(running || command.trimmingCharacters(in: .whitespaces).isEmpty || (onPhone && !(shell?.isRunning ?? false)))
        }
        .padding()
        .background(.bar)
    }

    private func openShell() {
        guard !opening else { return }
        opening = true
        openError = nil
        Task { @MainActor in
            do { shell = try await ai.linux.openShell() } catch { openError = error.localizedDescription }
            opening = false
        }
    }

    private func run() {
        let cmd = command.trimmingCharacters(in: .whitespaces)
        guard !cmd.isEmpty, !running else { return }
        command = ""
        history.removeAll { $0 == cmd }
        history.append(cmd)
        if onPhone {
            shell?.send(cmd)
            return
        }
        running = true
        Task { @MainActor in
            var output: String
            do {
                if let bridge = ai.bridgeEndpoint {
                    output = try await bridge.shell(cmd, timeout: 300).summary
                } else {
                    output = "No computer sandbox is connected."
                }
            } catch {
                output = "error: \(error.localizedDescription)"
            }
            entries.append(Entry(target: "pc", command: cmd, output: output.isEmpty ? "(no output)" : output))
            running = false
        }
    }
}
