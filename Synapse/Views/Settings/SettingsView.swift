import SwiftUI
import VisionKit
import SynapseKit

struct SettingsView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(AIService.self) private var ai
    @Environment(AppModel.self) private var app
    @AppStorage("appearance") private var appearance = 0
    @AppStorage("commentAuthor") private var author = "You"
    @State private var showExport = false
    @State private var exportURL: URL?
    @State private var exporting = false
    @State private var showImporter = false
    @State private var confirmReset = false
    @State private var showModels = false

    var body: some View {
        @Bindable var app = app
        Form {
            Section {
                Button {
                    showModels = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Palette.accent, in: RoundedRectangle(cornerRadius: 9))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("AI models").font(.headline).foregroundStyle(.primary)
                            Text(ai.statusText).font(.caption).foregroundStyle(ai.canAnswer ? Color.green : Color.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                }
                NavigationLink { ConnectClaudeView() } label: { Label("Cloud connection", systemImage: "link") }
            } footer: {
                Text("Everyday AI runs on this iPhone (Apple Intelligence). Complex tasks go to your Claude or ChatGPT subscription through Synapse Bridge on your computer, or to an Anthropic API key.")
            }

            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    Text("System").tag(0)
                    Text("Light").tag(1)
                    Text("Dark").tag(2)
                }
                .pickerStyle(.segmented)
                TextField("Your name (for comments)", text: $author)
            }

            Section("Workspace") {
                LabeledContent("Pages", value: "\(store.workspace.livePages.count)")
                LabeledContent("On this device", value: ByteCountFormatter.string(fromByteCount: store.storageSize(), countStyle: .file))
                Button {
                    exporting = true
                    Task { @MainActor in
                        exportURL = VaultExporter.export(store.workspace)
                        exporting = false
                        showExport = exportURL != nil
                    }
                } label: {
                    HStack {
                        Label("Export Markdown vault (.zip)", systemImage: "square.and.arrow.up")
                        if exporting { Spacer(); ProgressView() }
                    }
                }
                Button { showImporter = true } label: { Label("Import Markdown / Obsidian vault", systemImage: "square.and.arrow.down") }
                NavigationLink(value: Route.trash) { Label("Trash", systemImage: "trash") }
            }

            Section {
                Button("Reset to the sample workspace", role: .destructive) { confirmReset = true }
            } footer: {
                Text("Your workspace is stored on this device in Files › On My iPhone › Synapse. Sync across devices is planned.")
            }

            Section("About") {
                LabeledContent("Version", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))")
                Link(destination: URL(string: "https://github.com/Everaldtah/synapse")!) { Label("Source & Synapse Bridge", systemImage: "chevron.left.forwardslash.chevron.right") }
                Text("Synapse is not made by or affiliated with Anthropic or Notion. Claude and Claude Code are products of Anthropic.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $showExport) { if let exportURL { ShareSheet(items: [exportURL]) } }
        .markdownImporter(isPresented: $showImporter, parent: nil)
        .confirmationDialog("Replace everything with the sample workspace? This can't be undone.", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { store.resetToSample() }
        }
        .sheet(item: $app.pairing) { req in
            PairConfirmSheet(request: req)
        }
        .sheet(isPresented: $showModels) { ModelSwitcherSheet() }
    }
}

/// Connect Synapse to Claude: pair with Synapse Bridge, or use an API key.
struct ConnectClaudeView: View {
    @Environment(AIService.self) private var ai
    @State private var showScanner = false
    @State private var manualURL = ""
    @State private var manualToken = ""
    @State private var apiKey = ""
    @State private var checking = false
    @State private var checkResult: String?
    @State private var testOutput: String?

    var body: some View {
        @Bindable var ai = ai
        Form {
            Section {
                Picker("Use", selection: $ai.provider) {
                    ForEach(AIProviderKind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            if ai.provider.usesBridge {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(ai.provider == .codex ? "Your ChatGPT subscription, via Codex" : "Your Claude subscription, via Claude Code").font(.headline)
                        Text(ai.provider == .codex
                             ? "Synapse Bridge runs on your Mac or PC next to the official Codex CLI. You sign in there with OpenAI's own login, so Synapse never sees your password or tokens, and usage counts against your ChatGPT plan."
                             : "Synapse Bridge runs on your Mac or PC next to the official Claude Code. You sign in to Claude there with Anthropic's own login, so Synapse never sees your password or tokens, and AI usage counts against your Pro or Max plan.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    if ai.provider == .codex {
                        stepRow(1, "On your computer, install Codex and sign in:", code: "npm i -g @openai/codex && codex login")
                    } else {
                        stepRow(1, "On your computer, install Claude Code and sign in:", code: "claude auth login")
                    }
                    stepRow(2, "Start the bridge (from the Synapse repo):", code: "node bridge/synapse-bridge.mjs")
                    stepRow(3, "Scan the QR code it shows, or open its pairing link on this iPhone.", code: nil)
                    Button { showScanner = true } label: { Label("Scan pairing QR code", systemImage: "qrcode.viewfinder") }
                }

                if !ai.bridgeURL.isEmpty {
                    Section("Paired bridge") {
                        LabeledContent("Address", value: ai.bridgeURL)
                        if !ai.bridgeName.isEmpty { LabeledContent("Computer", value: ai.bridgeName) }
                        if let acct = ai.bridgeAccount { LabeledContent("Claude account", value: acct) }
                        if let codex = ai.codexInfo, codex.installed == true {
                            LabeledContent("Codex", value: codex.loggedIn == true ? "Signed in\(codex.defaultModel.map { " · \($0)" } ?? "")" : "Not signed in")
                        }
                        if ai.provider == .codex {
                            Picker("Model", selection: $ai.codexModel) {
                                Text("Codex default").tag("default")
                                ForEach(ai.codexInfo?.models ?? []) { m in Text(ModelCatalog.displayName(codex: m.id)).tag(m.id) }
                            }
                        } else {
                            Picker("Model", selection: $ai.bridgeModel) {
                                ForEach(AIModelOption.bridge) { Text($0.title).tag($0.id) }
                            }
                        }
                        effortPicker
                        Button {
                            checking = true
                            Task { @MainActor in
                                switch await ai.checkBridge() {
                                case .success: checkResult = "Connected."
                                case .failure(let e): checkResult = e.message
                                }
                                checking = false
                            }
                        } label: {
                            HStack { Text("Test connection"); if checking { Spacer(); ProgressView() } }
                        }
                        if let checkResult { Text(checkResult).font(.footnote).foregroundStyle(.secondary) }
                        testButton
                        Button("Unpair", role: .destructive) { ai.unpair(); checkResult = nil }
                    }
                }

                Section {
                    TextField("http://100.x.y.z:7799", text: $manualURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Pairing token", text: $manualToken)
                    Button("Pair") {
                        ai.pair(url: manualURL, token: manualToken, name: "")
                        manualURL = ""
                        manualToken = ""
                    }
                    .disabled(manualURL.isEmpty || manualToken.isEmpty)
                } header: {
                    Text("Pair manually")
                } footer: {
                    Text("Away from home? Install Tailscale on both devices and use the bridge's 100.x address, or run `tailscale serve` for HTTPS.")
                }
            } else {
                Section {
                    SecureField(ai.hasAPIKey ? "Saved — paste to replace" : "sk-ant-…", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Save key") {
                        ai.setAPIKey(apiKey)
                        apiKey = ""
                    }
                    .disabled(apiKey.isEmpty)
                    if ai.hasAPIKey {
                        Button("Remove key", role: .destructive) { ai.setAPIKey("") }
                    }
                } header: {
                    Text("Anthropic API key")
                } footer: {
                    Text("Create a key at platform.claude.com. It's stored in this iPhone's Keychain and sent only to api.anthropic.com. API usage is billed to that key.")
                }
                Section("Model") {
                    Picker("Model", selection: $ai.apiModel) {
                        ForEach(AIModelOption.api) { m in
                            VStack(alignment: .leading) {
                                Text(m.title)
                                Text(m.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(m.id)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    effortPicker
                    if ai.hasAPIKey { testButton }
                }
            }
        }
        .navigationTitle("Cloud connection")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showScanner) {
            QRScannerSheet { code in
                showScanner = false
                if let url = URL(string: code), url.scheme == "synapse",
                   let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                   let u = comps.queryItems?.first(where: { $0.name == "url" })?.value,
                   let t = comps.queryItems?.first(where: { $0.name == "token" })?.value {
                    ai.pair(url: u, token: t, name: comps.queryItems?.first(where: { $0.name == "name" })?.value ?? "")
                    Task { @MainActor in
                        switch await ai.checkBridge() {
                        case .success: checkResult = "Connected."
                        case .failure(let e): checkResult = e.message
                        }
                    }
                } else {
                    checkResult = "That QR code isn't a Synapse pairing code."
                }
            }
        }
        .task {
            if ai.provider.usesBridge && ai.isConfigured && (ai.bridgeAccount == nil || ai.codexInfo == nil) { _ = await ai.checkBridge() }
        }
    }

    private var effortPicker: some View {
        @Bindable var ai = ai
        return Picker("Thinking effort", selection: $ai.effort) {
            Text("Low").tag("low")
            Text("Medium").tag("medium")
            Text("High").tag("high")
        }
    }

    private var testButton: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                testOutput = "…"
                Task { @MainActor in
                    do {
                        let reply = try await ai.complete(AIRequest(system: "Reply in one short sentence.",
                                                                   messages: [AIMessage(role: .user, content: "Say hello to the Synapse user and name the model you are.")]),
                                                          on: .cloud)
                        testOutput = reply
                    } catch {
                        testOutput = "⚠️ " + error.localizedDescription
                    }
                }
            } label: { Label("Send a test message", systemImage: "paperplane") }
            if let testOutput {
                Text(testOutput).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func stepRow(_ n: Int, _ text: String, code: String?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.caption.bold()).foregroundStyle(.white).frame(width: 20, height: 20).background(Palette.accent, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(text).font(.subheadline)
                if let code {
                    Text(code).font(.footnote.monospaced())
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color(UIColor.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                        .textSelection(.enabled)
                }
            }
        }
    }
}

/// Confirm a pairing that arrived as a synapse://pair link.
struct PairConfirmSheet: View {
    @Environment(AIService.self) private var ai
    @Environment(\.dismiss) private var dismiss
    let request: PairingRequest
    @State private var result: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: "link.circle.fill").font(.system(size: 56)).foregroundStyle(Palette.accent)
                Text("Pair with \(request.name.isEmpty ? "Synapse Bridge" : request.name)?").font(.title3.bold())
                Text(request.url).font(.footnote.monospaced()).foregroundStyle(.secondary)
                Text("AI requests from Synapse will run through Claude Code on that computer, using the Claude account signed in there.")
                    .font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary)
                if let result { Text(result).font(.footnote).foregroundStyle(result == "Connected." ? .green : .orange) }
                Button {
                    busy = true
                    ai.pair(url: request.url, token: request.token, name: request.name)
                    Task { @MainActor in
                        switch await ai.checkBridge() {
                        case .success:
                            result = "Connected."
                            try? await Task.sleep(nanoseconds: 700_000_000)
                            dismiss()
                        case .failure(let e): result = e.message
                        }
                        busy = false
                    }
                } label: {
                    HStack { if busy { ProgressView() }; Text("Pair") }.frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(24)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}

/// Camera QR scanner (VisionKit).
struct QRScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onCode: (String) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    QRScanner(onCode: onCode).ignoresSafeArea()
                } else {
                    ContentUnavailableView("Camera unavailable", systemImage: "camera",
                                           description: Text("Allow camera access in Settings, or pair manually with the address and token."))
                }
            }
            .navigationTitle("Scan pairing code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

struct QRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                                           recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
                                           isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        var done = false

        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for item in addedItems {
                if case .barcode(let b) = item, let s = b.payloadStringValue {
                    done = true
                    dataScanner.stopScanning()
                    onCode(s)
                    return
                }
            }
        }
    }
}
