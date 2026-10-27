import SwiftUI
import SynapseKit

/// Settings › API providers: the free and bring-your-own-key OpenAI-compatible providers, and the user's own servers.
struct APIProvidersView: View {
    @State private var showAdd = false
    @State private var added: String?
    @State private var opened: String?

    private var store: APIProviderStore { .shared }
    private var customProviders: [APIProviderInfo] { store.providers.filter(\.custom) }

    var body: some View {
        Form {
            Section {
                LabeledContent("Ready to use", value: "\(store.readyProviders.count) of \(store.providers.count)")
            } footer: {
                Text("These providers are OpenAI-compatible. Free tiers checked 26 October 2026 — they change, so Synapse also loads each provider's live model list.")
            }

            Section("Free") {
                ForEach(APIProviderCatalog.free) { link($0) }
            }

            Section {
                ForEach(APIProviderCatalog.byok) { link($0) }
            } header: {
                Text("Bring your own key")
            } footer: {
                Text("Paid APIs that work the same way; usage is billed to your key.")
            }

            Section {
                ForEach(customProviders) { link($0) }
                    .onDelete { offsets in
                        let ids = offsets.map { customProviders[$0].id }
                        for id in ids { store.removeCustom(id) }
                    }
                Button { showAdd = true } label: { Label("Add a server…", systemImage: "plus") }
            } header: {
                Text("Your own server")
            } footer: {
                Text("LM Studio, Ollama, vLLM or llama.cpp on your computer, or any other OpenAI-compatible endpoint.")
            }
        }
        .navigationTitle("API providers")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $opened) { APIProviderDetailView(id: $0) }
        .sheet(isPresented: $showAdd, onDismiss: {
            if let id = added {
                added = nil
                opened = id
            }
        }) {
            AddAPIServerSheet { added = $0.id }
        }
    }

    private func link(_ p: APIProviderInfo) -> some View {
        NavigationLink { APIProviderDetailView(id: p.id) } label: { APIProviderRow(provider: p) }
    }
}

/// What a provider needs before it can be used.
enum APIProviderStatus: Equatable {
    case ready, keyless, needsKey
    /// A placeholder value is missing ("account ID").
    case needs(String)

    @MainActor init(_ p: APIProviderInfo, store: APIProviderStore) {
        if p.needsKey && !store.hasKey(p.id) {
            self = .needsKey
        } else if let missing = store.missingPlaceholders(p).first {
            self = .needs(APIProviderStore.label(forPlaceholder: missing))
        } else {
            self = store.hasKey(p.id) ? .ready : .keyless
        }
    }

    var title: String {
        switch self {
        case .ready: return "Ready"
        case .keyless: return "Keyless"
        case .needsKey: return "Needs key"
        case .needs(let what): return "Needs \(what)"
        }
    }

    var isReady: Bool { self == .ready || self == .keyless }
}

/// One provider in the list: name, status and its terms in a line.
private struct APIProviderRow: View {
    let provider: APIProviderInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(provider.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                APIStatusCapsule(status: APIProviderStatus(provider, store: .shared))
            }
            Text(provider.terms).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.vertical, 1)
    }
}

private struct APIStatusCapsule: View {
    let status: APIProviderStatus

    var body: some View {
        let color = status.isReady ? Color.green : Color.secondary
        Text(status.title)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
    }
}

/// One provider: terms, key, account values, a test request, and its models (starred ones show in model pickers).
struct APIProviderDetailView: View {
    let id: String
    @Environment(\.dismiss) private var dismiss
    @State private var keyText = ""
    @State private var testing = false
    @State private var testResult: Result<String, AIError>?
    @State private var refreshing = false
    @State private var refreshError: String?
    @State private var confirmRemove = false

    private var store: APIProviderStore { .shared }

    var body: some View {
        Group {
            if let p = store.provider(id) {
                form(p)
            } else {
                ContentUnavailableView("Provider removed", systemImage: "server.rack")
            }
        }
        .navigationTitle(store.provider(id)?.name ?? "API provider")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear(perform: saveKey)
        .task { await autoRefresh() }
    }

    private func form(_ p: APIProviderInfo) -> some View {
        Form {
            aboutSection(p)
            if p.keyURL != nil || p.custom { keySection(p) }
            if !p.placeholders.isEmpty { placeholderSection(p) }
            testSection(p)
            modelsSection(p)
            if p.custom {
                Section {
                    Button("Remove this server", role: .destructive) { confirmRemove = true }
                }
            }
        }
        .confirmationDialog("Remove \(p.name)? Its key is deleted from this iPhone.", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                store.removeCustom(p.id)
                dismiss()
            }
        }
    }

    // MARK: Sections

    private func aboutSection(_ p: APIProviderInfo) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(p.terms).font(.subheadline)
                if !p.verified.isEmpty {
                    Text("Checked \(Self.formatted(p.verified))").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
            if let s = p.keyURL, let url = URL(string: s) {
                Link(destination: url) { Label(p.isFree ? "Get a free key" : "Get a key", systemImage: "key") }
            } else if !p.custom {
                Label("No key or account needed", systemImage: "checkmark.circle").foregroundStyle(.green)
            }
            if p.custom {
                LabeledContent("Address") {
                    Text(p.baseURL).font(.footnote.monospaced()).textSelection(.enabled)
                }
            }
        }
    }

    private func keySection(_ p: APIProviderInfo) -> some View {
        Section {
            SecureField(store.hasKey(p.id) ? "Saved — paste to replace" : (p.needsKey ? "Paste your API key" : "API key (optional)"), text: $keyText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit(saveKey)
            if !keyText.isEmpty {
                Button("Save key", action: saveKey)
            }
            if store.hasKey(p.id) {
                Button("Remove key", role: .destructive) {
                    store.setKey("", for: p.id)
                    testResult = nil
                }
            }
        } header: {
            Text("API key")
        } footer: {
            Text(keyFooter(p))
        }
    }

    private func placeholderSection(_ p: APIProviderInfo) -> some View {
        Section {
            ForEach(p.placeholders, id: \.self) { name in
                TextField(Self.capitalized(APIProviderStore.label(forPlaceholder: name)), text: Binding(
                    get: { store.placeholderValue(name, for: p.id) },
                    set: { store.setPlaceholder(name, $0, for: p.id) }))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        } header: {
            Text("Account")
        } footer: {
            Text(p.id == "cloudflare"
                 ? "Your account ID is on the Cloudflare dashboard (Workers AI, or the address after dash.cloudflare.com/). The API token needs Workers AI permission."
                 : "Filled into \(p.baseURL).")
        }
    }

    private func testSection(_ p: APIProviderInfo) -> some View {
        let model = store.favoriteModels(for: p.id).first?.id
        let title: String = model.map { "Test with \(APIModelInfo($0).shortName)" } ?? "Test"
        return Section {
            Button {
                Task { await runTest(p, model: model) }
            } label: {
                HStack {
                    Label(title, systemImage: "paperplane")
                    if testing { Spacer(); ProgressView() }
                }
            }
            .disabled(testing)
            if let testResult {
                switch testResult {
                case .success(let line):
                    Label(line, systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(.green)
                case .failure(let error):
                    Text(error.message).font(.footnote).foregroundStyle(.orange)
                }
            }
        } footer: {
            Text(testFooter(p))
        }
    }

    private func modelsSection(_ p: APIProviderInfo) -> some View {
        let models = store.models(for: p.id)
        return Section {
            if p.listsModels {
                Button {
                    Task { await refresh(p) }
                } label: {
                    HStack {
                        Label("Refresh model list", systemImage: "arrow.clockwise")
                        if refreshing { Spacer(); ProgressView() }
                    }
                }
                .disabled(refreshing)
            }
            if let refreshError {
                Text(refreshError).font(.footnote).foregroundStyle(.orange)
            }
            if models.isEmpty {
                Text(p.listsModels ? "No models yet. Refresh the list to load them." : "No models listed.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(models) { modelRow($0, provider: p.id) }
        } header: {
            Text(store.hasLiveModels(p.id) ? "Models · \(models.count) live" : "Models")
        } footer: {
            Text("Starred models show in every model picker; until you star some, Synapse shows its suggestions. \(Image(systemName: "wrench.and.screwdriver")) native tool calling, \(Image(systemName: "eye")) accepts images. The agent works with any model: it doesn't need native tool calling.")
        }
    }

    private func modelRow(_ m: APIModelInfo, provider pid: String) -> some View {
        let starred = store.isFavorite(m.id, provider: pid)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(m.shortName).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if m.tools == true {
                        Image(systemName: "wrench.and.screwdriver").font(.caption2).foregroundStyle(.secondary)
                            .accessibilityLabel("Native tool calling")
                    }
                    if m.vision == true {
                        Image(systemName: "eye").font(.caption2).foregroundStyle(.secondary)
                            .accessibilityLabel("Accepts images")
                    }
                }
                Text(m.id).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let detail = Self.detail(m) {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button {
                store.toggleFavorite(m.id, provider: pid)
            } label: {
                Image(systemName: starred ? "star.fill" : "star")
                    .font(.title3)
                    .foregroundStyle(starred ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(starred ? "Unstar \(m.shortName)" : "Star \(m.shortName)")
        }
    }

    // MARK: Actions

    private func saveKey() {
        let k = keyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty, store.provider(id) != nil else { return }
        store.setKey(k, for: id)
        keyText = ""
        testResult = nil
    }

    private func runTest(_ p: APIProviderInfo, model: String?) async {
        saveKey()
        testing = true
        testResult = await store.test(p.id, model: model)
        testing = false
    }

    private func refresh(_ p: APIProviderInfo, quiet: Bool = false) async {
        refreshing = true
        defer { refreshing = false }
        do {
            try await store.refreshModels(p.id)
            refreshError = nil
        } catch {
            if !quiet { refreshError = error.localizedDescription }
        }
    }

    /// Load the live model list once, when the provider can be used.
    private func autoRefresh() async {
        guard let p = store.provider(id), p.listsModels, !store.hasLiveModels(id), store.isReady(id) else { return }
        await refresh(p, quiet: true)
    }

    // MARK: Text

    private func keyFooter(_ p: APIProviderInfo) -> String {
        let sentOnly = "Stored in this iPhone's Keychain and sent only to \(Self.host(p.baseURL))."
        if p.custom { return "Only if your server needs one (LM Studio and Ollama don't). \(sentOnly)" }
        if p.keyOptional { return "Optional: it works without a key, and a free key raises the limits. \(sentOnly)" }
        return sentOnly
    }

    private func testFooter(_ p: APIProviderInfo) -> String {
        switch APIProviderStatus(p, store: store) {
        case .needsKey: return "Paste a key above, then test."
        case .needs(let what): return "Fill in your \(what) above, then test."
        case .ready, .keyless: return "Sends \"Reply with OK.\" and times the answer."
        }
    }

    /// "128K context · Best reasoning on Groq".
    private static func detail(_ m: APIModelInfo) -> String? {
        var parts: [String] = []
        if let c = m.contextTokens, c > 0 { parts.append("\(APIProviderStore.compactTokens(c)) context") }
        if !m.note.isEmpty { parts.append(m.note) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "2026-10-26" → the date in the user's style.
    private static func formatted(_ day: String) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: day)?.formatted(date: .long, time: .omitted) ?? day
    }

    /// The host part of a base URL that may still contain `{placeholders}`.
    private static func host(_ base: String) -> String {
        let afterScheme = base.range(of: "://").map { String(base[$0.upperBound...]) } ?? base
        return afterScheme.split(separator: "/").first.map(String.init) ?? base
    }

    private static func capitalized(_ s: String) -> String {
        s.prefix(1).uppercased() + s.dropFirst()
    }
}

/// Add any OpenAI-compatible server: LM Studio, Ollama, vLLM, llama.cpp or a company gateway.
struct AddAPIServerSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onAdd: (APIProviderInfo) -> Void
    @State private var name = ""
    @State private var url = ""
    @State private var key = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, e.g. LM Studio", text: $name)
                    TextField("http://my-pc:1234/v1", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API key (optional)", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Use the address that ends in /v1: LM Studio is http://my-pc:1234/v1, Ollama http://my-pc:11434/v1. Let the server accept network connections (LM Studio: Serve on Local Network; Ollama: OLLAMA_HOST=0.0.0.0). Away from home, use the computer's Tailscale address.")
                }
            }
            .navigationTitle("Add a server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd(APIProviderStore.shared.addCustom(name: name, baseURL: url, key: key))
                        dismiss()
                    }
                    .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
