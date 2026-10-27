import SwiftUI
import SynapseKit

/// The model in use, as a small capsule. Tap it to switch models. Shown on every AI screen; `/model` opens the same
/// switcher from a page.
struct ModelChip: View {
    @Environment(AIService.self) private var ai
    /// Show this engine instead of the one everyday work uses (e.g. the engine a request is about to use).
    var engine: AIEngine?
    /// Show the model that wrote an answer.
    var answer: AIAnswerInfo?
    @State private var showSwitcher = false

    var body: some View {
        let e = answer?.engine ?? engine ?? ai.everydayEngine
        let name = answer?.model ?? ai.modelName(e)
        Button { showSwitcher = true } label: {
            HStack(spacing: 5) {
                Image(systemName: e == .onDevice ? "iphone" : "cloud")
                    .font(.caption2.weight(.bold))
                Text(name).font(.caption.weight(.semibold)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(e == .onDevice ? Color.green : Palette.accent)
            .background((e == .onDevice ? Color.green : Palette.accent).opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Model: \(name), \(e == .onDevice ? "on this iPhone" : "in the cloud"). Switch model.")
        .sheet(isPresented: $showSwitcher) { ModelSwitcherSheet() }
    }
}

/// Pick the routing mode, the on-device model and the cloud model, and read what each one is.
struct ModelSwitcherSheet: View {
    @Environment(AIService.self) private var ai
    @Environment(\.dismiss) private var dismiss
    @State private var detail: ModelCard?
    @State private var checking = false
    @State private var deleting: ModelCard?

    var body: some View {
        @Bindable var ai = ai
        NavigationStack {
            Form {
                Section {
                    usingRow(title: "Everyday tasks", subtitle: "Notes, summaries, rewrites, transcripts",
                             engine: ai.everydayEngine)
                    usingRow(title: "Complex tasks", subtitle: "Workspace questions, long pages, deep reasoning",
                             engine: ai.route(complexReason: "complex").engine)
                    if let last = ai.lastAnswer {
                        LabeledContent("Last answer") {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(last.model).font(.subheadline)
                                if let note = last.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                } header: {
                    Text("Now using")
                }

                Section {
                    Picker("Mode", selection: $ai.routingMode) {
                        ForEach(AIRoutingMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                } footer: {
                    Text(ai.routingMode.detail)
                }

                Section {
                    modelRow(ModelCatalog.appleFoundation, selected: !isDownloadedChoice, status: localStatus(ModelCatalog.appleFoundation)) {
                        ai.localModelID = ModelCatalog.appleFoundation.id
                    }
                    ForEach(ModelCatalog.downloadable) { card in downloadableRow(card) }
                } header: {
                    Label("On this iPhone", systemImage: "iphone")
                } footer: {
                    Text("Free and private: nothing leaves the phone, and it works offline. Apple's model is built in; the others download once (Wi-Fi recommended) and run on the iPhone's GPU with an 8K-token window.")
                }

                Section {
                    modelRow(ModelCatalog.appleSpeech, selected: true, status: "Used for every recording", action: nil)
                    if ai.bridgeWhisper?.available == true {
                        modelRow(ModelCatalog.whisperTurbo, selected: false,
                                 status: "Ready on your computer (\(ai.bridgeWhisper?.device == "cuda" ? "GPU" : "CPU")) · pick it in Make notes", action: nil)
                    }
                } header: {
                    Label("Transcription", systemImage: "waveform")
                }

                OnDeviceLinuxSection()

                if ai.bridgeSandbox != nil || ai.bridgeHarness != nil {
                    Section {
                        if let sandbox = ai.bridgeSandbox {
                            LabeledContent("Linux sandbox", value: sandbox.available == true ? "Ready · \(sandbox.distro ?? "Ubuntu")" : "Not set up")
                        }
                        if let harness = ai.bridgeHarness {
                            modelRow(ModelCatalog.claudeCodeHarness, selected: false,
                                     status: harness.loggedIn == true ? "Connected\(harness.email.map { " · \($0)" } ?? "")"
                                        : "Sign in once on your computer: wsl -d synapse-sandbox -u claude -- claude auth login",
                                     action: nil)
                        }
                        AgentToolsSection()
                    } header: {
                        Label("Agent tools on your computer", systemImage: "desktopcomputer")
                    }
                }

                cloudSection

                Section {
                    NavigationLink { ConnectClaudeView() } label: {
                        Label(ai.isConfigured ? "Cloud connection" : "Connect a cloud model", systemImage: "link")
                    }
                } footer: {
                    Text("Tip: type /model in any page to open this switcher.")
                }
            }
            .navigationTitle("AI models")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $detail) { card in ModelCardView(card: card) }
            .confirmationDialog(deleting.map { "Delete \($0.name)? You can download it again later." } ?? "",
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible) {
                Button("Delete \(deleting.map { LocalModelManager.format(ai.models.bytesOnDisk($0)) } ?? "")", role: .destructive) {
                    if let card = deleting { ai.deleteModel(card) }
                    deleting = nil
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task {
                ai.localCheck += 1
                if ai.provider.usesBridge && ai.isConfigured && (ai.codexInfo == nil || ai.bridgeAccount == nil) {
                    checking = true
                    _ = await ai.checkBridge()
                    checking = false
                }
            }
        }
    }

    // MARK: Rows

    private func usingRow(title: String, subtitle: String, engine: AIEngine) -> some View {
        HStack(spacing: 12) {
            Image(systemName: engine == .onDevice ? "iphone" : "cloud.fill")
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(engine == .onDevice ? Color.green : Palette.accent, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(ai.modelName(engine)).font(.subheadline).multilineTextAlignment(.trailing)
                Text(engine == .onDevice ? "on device" : ai.provider.shortTitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func modelRow(_ card: ModelCard, selected: Bool, status: String, action: (() -> Void)?) -> some View {
        HStack(spacing: 12) {
            Button {
                action?()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Palette.accent : Color.secondary)
                        .opacity(action == nil ? 0 : 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(card.name).font(.subheadline.weight(.semibold))
                        Text(card.specLine).font(.caption).foregroundStyle(.secondary)
                        Text(status).font(.caption2).foregroundStyle(status.hasPrefix("Ready") || status.hasPrefix("Used") || status.hasPrefix("Connected") ? Color.green : Color.orange)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(action == nil)
            Button { detail = card } label: { Image(systemName: "info.circle").font(.title3) }
                .buttonStyle(.borderless)
                .accessibilityLabel("About \(card.name)")
        }
    }

    private func localStatus(_ card: ModelCard) -> String {
        _ = ai.localCheck
        if card.id == ModelCatalog.appleFoundation.id {
            return ai.apple.unavailableReason ?? "Ready · built in"
        }
        switch ai.models.state(card) {
        case .notDownloaded: return "Not downloaded"
        case .downloading(let f): return "Downloading… \(Int(f * 100))%"
        case .downloaded:
            if let why = LocalModelManager.unsupportedReason { return why }
            return ai.models.loadedID == card.id ? "Ready · in memory" : "Ready · downloaded"
        case .failed(let why): return why
        }
    }

    /// The chosen on-device model is a downloaded one that's still on the phone.
    private var isDownloadedChoice: Bool {
        ModelCatalog.downloadable.contains { $0.id == ai.localModelID && ai.models.isDownloaded($0) }
    }

    @ViewBuilder private func downloadableRow(_ card: ModelCard) -> some View {
        let state = ai.models.state(card)
        VStack(alignment: .leading, spacing: 8) {
            modelRow(card, selected: ai.localModelID == card.id && state == .downloaded, status: localStatus(card),
                     action: state == .downloaded ? { ai.localModelID = card.id } : nil)
            switch state {
            case .notDownloaded, .failed:
                Button {
                    ai.models.download(card)
                } label: {
                    Label("Download · \(LocalModelManager.format(card.downloadBytes))", systemImage: "arrow.down.circle")
                        .font(.subheadline)
                }
                .buttonStyle(.borderless)
            case .downloading(let fraction):
                HStack {
                    ProgressView(value: fraction)
                    Button("Cancel") { ai.models.cancelDownload(card) }
                        .buttonStyle(.borderless)
                        .font(.subheadline)
                }
            case .downloaded:
                Button(role: .destructive) {
                    deleting = card
                } label: {
                    Label("Delete download", systemImage: "trash").font(.subheadline)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder private var cloudSection: some View {
        @Bindable var ai = ai
        Section {
            Picker("Provider", selection: $ai.provider) {
                ForEach(AIProviderKind.allCases) { Text($0.title).tag($0) }
            }
            switch ai.provider {
            case .bridge:
                ForEach(AIModelOption.bridge) { opt in
                    let card = ModelCatalog.claude(opt.id, kind: .subscription)
                    modelRow(card, selected: ai.bridgeModel == opt.id, status: cloudStatus) { ai.bridgeModel = opt.id }
                }
            case .codex:
                let models = ai.codexInfo?.models ?? []
                modelRow(ModelCatalog.codex(id: "default", description: "The model set in Codex on your computer" +
                                                (ai.codexInfo?.defaultModel.map { " (\($0))" } ?? "")),
                         selected: ai.codexModel == "default", status: cloudStatus) { ai.codexModel = "default" }
                ForEach(models) { m in
                    let card = ModelCatalog.codex(id: m.id, name: m.name, description: m.description ?? "", contextWindow: m.contextWindow)
                    modelRow(card, selected: ai.codexModel == m.id, status: cloudStatus) { ai.codexModel = m.id }
                }
                if models.isEmpty && !checking {
                    Text("Pair the bridge and run `codex login` on your computer to list Codex models.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .apiKey:
                ForEach(AIModelOption.api) { opt in
                    let card = ModelCatalog.claude(opt.id, kind: .api)
                    modelRow(card, selected: ai.apiModel == opt.id, status: cloudStatus) { ai.apiModel = opt.id }
                }
            case .freeAPI:
                let apis = APIProviderStore.shared
                ForEach(apis.readyProviders) { p in
                    ForEach(apis.favoriteModels(for: p.id)) { m in
                        modelRow(ai.apiCard(p.id, m.id), selected: ai.apiProviderID == p.id && ai.apiProviderModel == m.id, status: "Ready · \(p.name)") {
                            ai.apiProviderID = p.id
                            ai.apiProviderModel = m.id
                        }
                    }
                }
                NavigationLink { APIProvidersView() } label: {
                    Label(apis.readyProviders.isEmpty ? "Add a free API provider" : "API providers", systemImage: "key")
                }
            }
            Picker("Thinking effort", selection: $ai.effort) {
                Text("Low").tag("low")
                Text("Medium").tag("medium")
                Text("High").tag("high")
            }
        } header: {
            HStack {
                Label("Cloud — complex tasks", systemImage: "cloud")
                if checking { Spacer(); ProgressView().controlSize(.mini) }
            }
        } footer: {
            Text("Subscriptions run through Synapse Bridge on your computer (Claude Code or Codex, tools off). Use them for the heavy lifting; everything else stays on the iPhone.")
        }
    }

    private var cloudStatus: String {
        if !ai.isConfigured {
            switch ai.provider {
            case .apiKey: return "No API key"
            case .freeAPI: return "No API provider chosen"
            case .bridge, .codex: return "Bridge not paired"
            }
        }
        switch ai.provider {
        case .bridge: return ai.bridgeAccount.map { "Connected · \($0)" } ?? "Paired with \(ai.bridgeName.isEmpty ? "bridge" : ai.bridgeName)"
        case .codex:
            if ai.codexInfo?.loggedIn == true { return "Connected · ChatGPT via Codex \(ai.codexInfo?.version.map { "(\($0))" } ?? "")" }
            return ai.codexInfo == nil ? "Paired — checking Codex…" : "Codex not signed in on the bridge computer"
        case .apiKey: return "Connected · API key"
        case .freeAPI: return "Connected · \(ai.cloudCard.maker)"
        }
    }
}

/// Everything about one model: size, parameters, context, what it's good at and where it falls short.
struct ModelCardView: View {
    let card: ModelCard

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: card.kind == .onDevice ? "iphone" : "cloud.fill")
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(card.kind == .onDevice ? Color.green : Palette.accent, in: RoundedRectangle(cornerRadius: 9))
                        VStack(alignment: .leading) {
                            Text(card.name).font(.title3.bold())
                            Text("\(card.maker) · \(kindTitle)").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    Text(card.summary).font(.subheadline)
                }
                .padding(.vertical, 4)
            }
            Section("Specs") {
                LabeledContent("Parameters", value: card.parameters)
                if !card.quantization.isEmpty { LabeledContent("Quantization", value: card.quantization) }
                LabeledContent("Context window", value: card.contextWindow)
                if !card.maxOutput.isEmpty { LabeledContent("Max reply", value: card.maxOutput) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.kind == .onDevice ? "Size" : "Runs on")
                    Text(card.size).font(.footnote).foregroundStyle(.secondary)
                }
                if !card.requirements.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Needs")
                        Text(card.requirements).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Good at") {
                ForEach(card.goodAt, id: \.self) { Label($0, systemImage: "checkmark.circle").foregroundStyle(.primary) }
            }
            Section("Limits") {
                ForEach(card.limits, id: \.self) { Label($0, systemImage: "exclamationmark.circle").foregroundStyle(.primary) }
            }
        }
        .navigationTitle(card.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var kindTitle: String {
        switch card.kind {
        case .onDevice: return "Runs on this iPhone"
        case .subscription: return "Subscription"
        case .api: return "API"
        }
    }
}

/// Install and see Linux on this iPhone.
struct OnDeviceLinuxSection: View {
    @Environment(AIService.self) private var ai

    var body: some View {
        let linux = ai.linux
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("Alpine Linux 3.20 (x86, emulated by iSH)").font(.subheadline.weight(.semibold))
                Text("bash, python3, git, ripgrep and the apk package manager. Offline and private; slower than the computer's sandbox.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            switch linux.state {
            case .notInstalled:
                if linux.isInstalled {
                    Button { Task { await linux.start() } } label: { Label("Start Linux", systemImage: "play.circle") }
                } else {
                    Button { Task { await linux.start() } } label: {
                        Label("Install Linux · \(ByteCountFormatter.string(fromByteCount: linux.pin.bytes, countStyle: .file))", systemImage: "arrow.down.circle")
                    }
                }
            case .downloading(let f):
                HStack { ProgressView(value: f); Text("Downloading… \(Int(f * 100))%").font(.subheadline).monospacedDigit() }
            case .importing:
                HStack { ProgressView(); Text("Unpacking…").font(.subheadline) }
            case .booting:
                HStack { ProgressView(); Text("Starting…").font(.subheadline) }
            case .ready:
                LabeledContent("Status", value: linux.bootMs.map { "Running · booted in \(Int($0)) ms" } ?? "Running")
            case .failed(let why):
                Text(why).font(.caption).foregroundStyle(.orange)
                Button { Task { await linux.start() } } label: { Label("Try again", systemImage: "arrow.clockwise") }
            }
        } header: {
            Label("Linux on this iPhone", systemImage: "terminal")
        } footer: {
            Text("The AI's shell tool uses it when you allow the Linux shell. iSH is GPL-3.0 software, so Synapse is GPL-3.0 too.")
        }
    }
}
