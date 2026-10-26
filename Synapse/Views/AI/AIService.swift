import Foundation
import Observation
import Security
import SynapseKit

/// Where cloud AI requests go (complex tasks, and everything in "Cloud only" mode).
enum AIProviderKind: String, CaseIterable, Identifiable {
    /// Synapse Bridge on your computer, running Claude Code signed in to your Claude subscription.
    case bridge
    /// Synapse Bridge on your computer, running Codex signed in to your ChatGPT subscription.
    case codex
    /// Directly to the Claude API with your Anthropic API key.
    case apiKey

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bridge: return "Claude subscription (via Claude Code)"
        case .codex: return "ChatGPT subscription (via Codex)"
        case .apiKey: return "Anthropic API key"
        }
    }

    var shortTitle: String {
        switch self {
        case .bridge: return "Claude subscription"
        case .codex: return "ChatGPT subscription"
        case .apiKey: return "API key"
        }
    }

    var usesBridge: Bool { self != .apiKey }
}

struct AIModelOption: Identifiable, Hashable {
    var id: String
    var title: String
    var detail: String

    /// API models. Opus 5.5 is the default.
    static let api: [AIModelOption] = [
        AIModelOption(id: "claude-opus-5-5", title: "Claude Opus 5.5", detail: "Most capable for everyday work (default)"),
        AIModelOption(id: "claude-sonnet-5-5", title: "Claude Sonnet 5.5", detail: "Fast and capable"),
        AIModelOption(id: "claude-haiku-5-5", title: "Claude Haiku 5.5", detail: "Fastest and cheapest"),
        AIModelOption(id: "claude-fable-5-1", title: "Claude Fable 5.1", detail: "Anthropic's most capable model"),
    ]

    /// Claude Code model aliases (the bridge passes them to `claude --model`).
    static let bridge: [AIModelOption] = [
        AIModelOption(id: "default", title: "Claude Code default", detail: "Whatever your plan uses by default"),
        AIModelOption(id: "opus", title: "Opus", detail: "Latest Opus"),
        AIModelOption(id: "sonnet", title: "Sonnet", detail: "Latest Sonnet"),
        AIModelOption(id: "haiku", title: "Haiku", detail: "Latest Haiku"),
    ]
}

struct AIError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// Which model wrote the latest answer, for the model chip and the note under a reply.
struct AIAnswerInfo: Equatable {
    var engine: AIEngine
    var model: String
    /// Set when the request moved, e.g. "Sent to the cloud: too long for on-device".
    var note: String?
}

/// What the bridge reported about Codex.
struct CodexInfo: Decodable, Equatable {
    struct Model: Decodable, Equatable, Identifiable {
        var id: String
        var name: String?
        var description: String?
        var contextWindow: Int?
    }
    var installed: Bool?
    var loggedIn: Bool?
    var method: String?
    var version: String?
    var defaultModel: String?
    var models: [Model]?
}

/// What the bridge reported about Whisper on the computer.
struct WhisperInfo: Decodable, Equatable {
    var available: Bool?
    var model: String?
    var device: String?
}

/// What the bridge reported about its Linux sandbox.
struct SandboxInfo: Decodable, Equatable {
    var available: Bool?
    var distro: String?
    var tools: [String]?
}

/// What the bridge reported about the Claude Code harness in the sandbox.
struct HarnessInfo: Decodable, Equatable {
    var available: Bool?
    var loggedIn: Bool?
    var email: String?
    var subscriptionType: String?
    var claudeVersion: String?
}

/// A specific model for one run, or the router's pick.
enum ModelChoice: Hashable {
    case auto
    /// An on-device model (`ModelCard.id`).
    case local(String)
    /// A cloud provider and its model id or alias.
    case cloud(AIProviderKind, String)
    /// Claude Code in the bridge's Linux sandbox, on the Claude subscription (model alias).
    case harness(String)
}

struct ModelOption: Identifiable, Hashable {
    var choice: ModelChoice
    var title: String
    var detail: String
    var engine: AIEngine
    var id: String { String(describing: choice) }
}

struct ModelOptionGroup: Identifiable {
    var title: String
    var options: [ModelOption]
    var id: String { title }
}

/// The AI connection: on-device models, the cloud providers, routing between them, secrets in the Keychain,
/// and streaming requests.
@MainActor
@Observable
final class AIService {
    // Settings live in UserDefaults; access/withMutation keep SwiftUI views observing them.
    var provider: AIProviderKind {
        get { access(keyPath: \.provider); return AIProviderKind(rawValue: UserDefaults.standard.string(forKey: "ai.provider") ?? "") ?? .bridge }
        set { withMutation(keyPath: \.provider) { UserDefaults.standard.set(newValue.rawValue, forKey: "ai.provider") } }
    }
    var routingMode: AIRoutingMode {
        get { access(keyPath: \.routingMode); return AIRoutingMode(rawValue: UserDefaults.standard.string(forKey: "ai.routing") ?? "") ?? .localFirst }
        set { withMutation(keyPath: \.routingMode) { UserDefaults.standard.set(newValue.rawValue, forKey: "ai.routing") } }
    }
    /// The on-device language model (`ModelCard.id`).
    var localModelID: String {
        get { access(keyPath: \.localModelID); return UserDefaults.standard.string(forKey: "ai.localModel") ?? ModelCatalog.appleFoundation.id }
        set { withMutation(keyPath: \.localModelID) { UserDefaults.standard.set(newValue, forKey: "ai.localModel") } }
    }
    var bridgeURL: String {
        get { access(keyPath: \.bridgeURL); return UserDefaults.standard.string(forKey: "ai.bridgeURL") ?? "" }
        set { withMutation(keyPath: \.bridgeURL) { UserDefaults.standard.set(newValue, forKey: "ai.bridgeURL") } }
    }
    var bridgeName: String {
        get { access(keyPath: \.bridgeName); return UserDefaults.standard.string(forKey: "ai.bridgeName") ?? "" }
        set { withMutation(keyPath: \.bridgeName) { UserDefaults.standard.set(newValue, forKey: "ai.bridgeName") } }
    }
    var apiModel: String {
        get { access(keyPath: \.apiModel); return UserDefaults.standard.string(forKey: "ai.apiModel") ?? "claude-opus-5-5" }
        set { withMutation(keyPath: \.apiModel) { UserDefaults.standard.set(newValue, forKey: "ai.apiModel") } }
    }
    var bridgeModel: String {
        get { access(keyPath: \.bridgeModel); return UserDefaults.standard.string(forKey: "ai.bridgeModel") ?? "default" }
        set { withMutation(keyPath: \.bridgeModel) { UserDefaults.standard.set(newValue, forKey: "ai.bridgeModel") } }
    }
    /// A Codex model id, or "default" for the one set in Codex on the bridge computer.
    var codexModel: String {
        get { access(keyPath: \.codexModel); return UserDefaults.standard.string(forKey: "ai.codexModel") ?? "default" }
        set { withMutation(keyPath: \.codexModel) { UserDefaults.standard.set(newValue, forKey: "ai.codexModel") } }
    }
    /// low / medium / high
    var effort: String {
        get { access(keyPath: \.effort); return UserDefaults.standard.string(forKey: "ai.effort") ?? "medium" }
        set { withMutation(keyPath: \.effort) { UserDefaults.standard.set(newValue, forKey: "ai.effort") } }
    }
    /// What the bridge reported about the Claude account it's signed in to.
    var bridgeAccount: String?
    var codexInfo: CodexInfo?
    /// What else the paired bridge offers: Whisper transcription, a Linux sandbox, the Claude Code harness.
    var bridgeWhisper: WhisperInfo?
    var bridgeSandbox: SandboxInfo?
    var bridgeHarness: HarnessInfo?
    /// Agent tools the user allows (Ask AI, Ask Synapse, notes).
    var agentWeb: Bool {
        get { access(keyPath: \.agentWeb); return UserDefaults.standard.object(forKey: "ai.agentWeb") as? Bool ?? true }
        set { withMutation(keyPath: \.agentWeb) { UserDefaults.standard.set(newValue, forKey: "ai.agentWeb") } }
    }
    var agentShell: Bool {
        get { access(keyPath: \.agentShell); return UserDefaults.standard.object(forKey: "ai.agentShell") as? Bool ?? true }
        set { withMutation(keyPath: \.agentShell) { UserDefaults.standard.set(newValue, forKey: "ai.agentShell") } }
    }
    var agentHarness: Bool {
        get { access(keyPath: \.agentHarness); return UserDefaults.standard.object(forKey: "ai.agentHarness") as? Bool ?? true }
        set { withMutation(keyPath: \.agentHarness) { UserDefaults.standard.set(newValue, forKey: "ai.agentHarness") } }
    }
    var lastCheck: String?
    /// The model behind the latest answer.
    var lastAnswer: AIAnswerInfo?
    /// Bumped when the on-device model's availability may have changed (checked on demand; iOS doesn't notify).
    var localCheck = 0

    private(set) var hasBridgeToken = false
    private(set) var hasAPIKey = false

    @ObservationIgnored let apple = AppleFoundationLLM()
    /// Downloadable open-weights models (observable on its own).
    let models = LocalModelManager()
    /// Alpine Linux on the iPhone, for the agent's shell tool.
    let linux = OnDeviceLinux()
    @ObservationIgnored private var mlx: [String: MLXLocalLLM] = [:]

    init() {
        hasBridgeToken = Keychain.get("bridgeToken") != nil
        hasAPIKey = Keychain.get("anthropicAPIKey") != nil
    }

    // MARK: - Models

    /// The on-device language model in use: the chosen downloaded model, else Apple's built-in one.
    var local: LocalLLM { localLLM(localModelID) }

    /// What one on-device request can carry with the model in use.
    var localBudget: LocalBudget { local.budget }

    /// Delete a downloaded model; if it was in use, go back to Apple's model.
    func deleteModel(_ card: ModelCard) {
        models.delete(card)
        mlx[card.id] = nil
        if localModelID == card.id { localModelID = ModelCatalog.appleFoundation.id }
    }

    /// Whether the on-device model can run right now.
    var localReady: Bool {
        _ = localCheck
        return local.unavailableReason == nil
    }

    /// A cloud provider is connected.
    var isConfigured: Bool {
        switch provider {
        case .bridge, .codex: return !bridgeURL.isEmpty && hasBridgeToken
        case .apiKey: return hasAPIKey
        }
    }

    /// Either engine can answer.
    var canAnswer: Bool { isConfigured || localReady }

    /// The cloud model that complex tasks go to.
    var cloudCard: ModelCard {
        switch provider {
        case .bridge:
            return ModelCatalog.claude(bridgeModel, kind: .subscription)
        case .codex:
            let id = codexModel == "default" ? (codexInfo?.defaultModel ?? "default") : codexModel
            let m = codexInfo?.models?.first { $0.id == id }
            return ModelCatalog.codex(id: id, name: m?.name, description: m?.description ?? "", contextWindow: m?.contextWindow)
        case .apiKey:
            return ModelCatalog.claude(apiModel, kind: .api)
        }
    }

    /// "Claude Opus 5.5 · Claude subscription".
    var cloudTitle: String { "\(cloudCard.name) · \(provider.shortTitle)" }

    /// The engine everyday (not complex) work uses right now.
    var everydayEngine: AIEngine { route(complexReason: nil).engine }

    /// Where a request goes.
    func route(complexReason: String?) -> AIRoute {
        AIRouter.route(complexReason: complexReason, mode: routingMode, localReady: localReady, cloudReady: isConfigured)
    }

    /// The model name for an engine ("Apple Foundation Model", "Claude Opus 5.5").
    func modelName(_ engine: AIEngine) -> String {
        engine == .onDevice ? local.card.name : cloudCard.name
    }

    var statusText: String {
        let local = localReady ? "On-device ready" : "On-device off"
        switch provider {
        case .bridge, .codex:
            if !isConfigured { return "\(local) · cloud not connected" }
            return "\(local) · \(cloudCard.name) via \(bridgeName.isEmpty ? "bridge" : bridgeName)"
        case .apiKey:
            return hasAPIKey ? "\(local) · \(cloudCard.name) (API key)" : "\(local) · no API key"
        }
    }

    func pair(url: String, token: String, name: String) {
        var u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while u.hasSuffix("/") { u.removeLast() }
        bridgeURL = u
        bridgeName = name
        Keychain.set(token, for: "bridgeToken")
        hasBridgeToken = true
        if !provider.usesBridge { provider = .bridge }
        bridgeAccount = nil
    }

    func unpair() {
        Keychain.delete("bridgeToken")
        hasBridgeToken = false
        bridgeURL = ""
        bridgeName = ""
        bridgeAccount = nil
        codexInfo = nil
    }

    func setAPIKey(_ key: String) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.isEmpty {
            Keychain.delete("anthropicAPIKey")
            hasAPIKey = false
        } else {
            Keychain.set(k, for: "anthropicAPIKey")
            hasAPIKey = true
        }
    }

    // MARK: - Health

    struct BridgeHealth: Decodable {
        struct Claude: Decodable {
            var loggedIn: Bool?
            var email: String?
            var subscriptionType: String?
            var authMethod: String?
            var version: String?
        }
        var ok: Bool
        var name: String?
        var version: String?
        var claude: Claude?
        var codex: CodexInfo?
        var whisper: WhisperInfo?
        var sandbox: SandboxInfo?
        var harness: HarnessInfo?
    }

    /// Ask the bridge which accounts and models it has.
    func checkBridge() async -> Result<BridgeHealth, AIError> {
        guard let base = URL(string: bridgeURL), let token = Keychain.get("bridgeToken") else {
            return .failure(AIError(message: "Not paired with a bridge."))
        }
        var req = URLRequest(url: base.appendingPathComponent("v1/health"))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                return .failure(AIError(message: code == 401 ? "The bridge rejected the pairing token. Pair again." : "The bridge answered \(code)."))
            }
            let health = try JSONDecoder().decode(BridgeHealth.self, from: data)
            codexInfo = health.codex
            bridgeWhisper = health.whisper
            bridgeSandbox = health.sandbox
            bridgeHarness = health.harness
            if let n = health.name, !n.isEmpty { bridgeName = n }
            if let c = health.claude {
                if c.loggedIn == true {
                    var s = c.email ?? "Claude account"
                    if let plan = c.subscriptionType, !plan.isEmpty { s += " (\(plan.capitalized))" }
                    bridgeAccount = s
                } else {
                    bridgeAccount = nil
                    if provider == .bridge {
                        return .failure(AIError(message: "Claude Code on \(health.name ?? "the bridge") isn't signed in. Run `claude auth login` there."))
                    }
                }
            }
            if provider == .codex && health.codex?.loggedIn != true {
                return .failure(AIError(message: health.codex?.installed == true
                    ? "Codex on \(health.name ?? "the bridge") isn't signed in. Run `codex login` there."
                    : "Codex isn't installed on \(health.name ?? "the bridge"). Install it with `npm i -g @openai/codex`, then run `codex login`."))
            }
            lastCheck = "OK"
            return .success(health)
        } catch {
            lastCheck = error.localizedDescription
            return .failure(AIError(message: "Can't reach the bridge at \(bridgeURL): \(error.localizedDescription)"))
        }
    }

    // MARK: - Streaming

    /// Stream the reply's text from an engine. On-device requests that fail before writing anything move to the cloud
    /// in "On-device first" mode (when a cloud model is connected); `lastAnswer` says what happened.
    func stream(_ request: AIRequest, on engine: AIEngine, fallback: Bool = true) -> AsyncThrowingStream<String, Error> {
        switch engine {
        case .cloud:
            lastAnswer = AIAnswerInfo(engine: .cloud, model: cloudCard.name)
            return cloudStream(request)
        case .onDevice:
            lastAnswer = AIAnswerInfo(engine: .onDevice, model: local.card.name)
            let localStream = local.stream(request)
            guard fallback, routingMode == .localFirst, isConfigured else { return localStream }
            return AsyncThrowingStream { continuation in
                let task = Task { @MainActor in
                    var wrote = false
                    do {
                        for try await chunk in localStream {
                            wrote = true
                            continuation.yield(chunk)
                        }
                        continuation.finish()
                    } catch let error as LocalAIError where !wrote {
                        self.lastAnswer = AIAnswerInfo(engine: .cloud, model: self.cloudCard.name, note: "Sent to the cloud: \(error.shortReason)")
                        do {
                            for try await chunk in self.cloudStream(request) { continuation.yield(chunk) }
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    /// The whole reply at once.
    func complete(_ request: AIRequest, on engine: AIEngine, fallback: Bool = true) async throws -> String {
        var out = ""
        for try await chunk in stream(request, on: engine, fallback: fallback) { out += chunk }
        return out
    }

    private func cloudStream(_ request: AIRequest) -> AsyncThrowingStream<String, Error> {
        cloudStream(request, provider: provider, model: model(for: provider))
    }

    /// The model set for a provider in Settings.
    func model(for provider: AIProviderKind) -> String {
        switch provider {
        case .bridge: return bridgeModel
        case .codex: return codexModel
        case .apiKey: return apiModel
        }
    }

    private func cloudStream(_ request: AIRequest, provider: AIProviderKind, model: String) -> AsyncThrowingStream<String, Error> {
        switch provider {
        case .bridge, .codex:
            guard let base = URL(string: bridgeURL), let token = Keychain.get("bridgeToken") else {
                return Self.failing(AIError(message: "Pair Synapse Bridge in Settings › AI models to use \(provider.shortTitle)."))
            }
            let codex = provider == .codex
            return BridgeClient(baseURL: base, token: token, engine: codex ? "codex" : "claude",
                                model: model, effort: effort,
                                onMeta: { [weak self] model in
                                    guard let self else { return }
                                    let name = codex ? ModelCatalog.displayName(codex: model) : ModelCatalog.displayName(claude: model)
                                    if self.lastAnswer?.engine == .cloud { self.lastAnswer?.model = name }
                                }).stream(request)
        case .apiKey:
            guard let key = Keychain.get("anthropicAPIKey") else {
                return Self.failing(AIError(message: "Add an Anthropic API key in Settings › AI models first."))
            }
            return AnthropicClient(apiKey: key, model: model, effort: effort).stream(request)
        }
    }

    // MARK: - Choosing a model for one run

    /// The bridge's address and token, when paired.
    var bridgeEndpoint: BridgeTools? {
        guard let base = URL(string: bridgeURL), !bridgeURL.isEmpty, let token = Keychain.get("bridgeToken") else { return nil }
        return BridgeTools(base: base, token: token)
    }

    /// An on-device model by card id (Apple's, or a downloaded one).
    func localLLM(_ id: String) -> LocalLLM {
        guard let card = ModelCatalog.downloadable.first(where: { $0.id == id }), models.isDownloaded(card) else { return apple }
        if let m = mlx[id] { return m }
        let m = MLXLocalLLM(card: card, manager: models)
        mlx[id] = m
        return m
    }

    /// Every model usable right now, grouped for a picker.
    var modelGroups: [ModelOptionGroup] {
        _ = localCheck
        var groups: [ModelOptionGroup] = [ModelOptionGroup(title: "", options: [
            ModelOption(choice: .auto, title: "Auto", detail: "\(modelName(everydayEngine)) for everyday work; your cloud model for complex work", engine: everydayEngine),
        ])]
        var local: [ModelOption] = []
        if apple.unavailableReason == nil {
            local.append(ModelOption(choice: .local(apple.card.id), title: apple.card.name, detail: apple.card.specLine, engine: .onDevice))
        }
        for card in ModelCatalog.downloadable where models.isDownloaded(card) && LocalModelManager.unsupportedReason == nil {
            local.append(ModelOption(choice: .local(card.id), title: card.name, detail: card.specLine, engine: .onDevice))
        }
        if !local.isEmpty { groups.append(ModelOptionGroup(title: "On this iPhone", options: local)) }
        let paired = !bridgeURL.isEmpty && hasBridgeToken
        if paired && bridgeAccount != nil {
            groups.append(ModelOptionGroup(title: "Claude subscription", options: AIModelOption.bridge.map { opt in
                let card = ModelCatalog.claude(opt.id, kind: .subscription)
                return ModelOption(choice: .cloud(.bridge, opt.id), title: card.name, detail: card.summary, engine: .cloud)
            }))
        }
        if paired, bridgeHarness?.loggedIn == true {
            groups.append(ModelOptionGroup(title: "Claude Code harness (web + Linux sandbox)", options: AIModelOption.bridge.map { opt in
                let card = ModelCatalog.claude(opt.id, kind: .subscription)
                return ModelOption(choice: .harness(opt.id), title: "\(card.name) · harness",
                                   detail: "Searches the web, reads pages and runs code in the sandbox", engine: .cloud)
            }))
        }
        if paired, codexInfo?.loggedIn == true {
            var codex = [ModelOption(choice: .cloud(.codex, "default"), title: ModelCatalog.displayName(codex: codexInfo?.defaultModel ?? "default"),
                                     detail: "Codex default", engine: .cloud)]
            for m in codexInfo?.models ?? [] where m.id != codexInfo?.defaultModel {
                codex.append(ModelOption(choice: .cloud(.codex, m.id), title: ModelCatalog.displayName(codex: m.id), detail: m.description ?? "", engine: .cloud))
            }
            groups.append(ModelOptionGroup(title: "ChatGPT subscription (Codex)", options: codex))
        }
        if hasAPIKey {
            groups.append(ModelOptionGroup(title: "Anthropic API", options: AIModelOption.api.map {
                ModelOption(choice: .cloud(.apiKey, $0.id), title: $0.title, detail: $0.detail, engine: .cloud)
            }))
        }
        return groups
    }

    /// A fixed model for a choice (Auto resolved by the router), so a multi-step run stays on one model.
    func concrete(_ choice: ModelChoice, complexReason: String? = nil) -> ModelChoice {
        guard choice == .auto else { return choice }
        return route(complexReason: complexReason).engine == .onDevice ? .local(localModelID) : .cloud(provider, model(for: provider))
    }

    /// The engine a choice runs on.
    func engine(for choice: ModelChoice, complexReason: String? = nil) -> AIEngine {
        switch choice {
        case .auto: return route(complexReason: complexReason).engine
        case .local: return .onDevice
        case .cloud, .harness: return .cloud
        }
    }

    /// The model name for a choice.
    func name(for choice: ModelChoice, complexReason: String? = nil) -> String {
        switch choice {
        case .auto: return modelName(engine(for: .auto, complexReason: complexReason))
        case .local(let id): return localLLM(id).card.name
        case .cloud(let p, let m):
            switch p {
            case .codex: return ModelCatalog.displayName(codex: m == "default" ? (codexInfo?.defaultModel ?? "default") : m)
            case .bridge, .apiKey: return ModelCatalog.claude(m, kind: p == .apiKey ? .api : .subscription).name
            }
        case .harness(let m): return ModelCatalog.claude(m, kind: .subscription).name + " · harness"
        }
    }

    /// How much one request may carry with a choice.
    func budget(for choice: ModelChoice, complexReason: String? = nil) -> LocalBudget {
        switch choice {
        case .local(let id): return localLLM(id).budget
        case .cloud, .harness: return .context(tokens: 200_000)
        case .auto: return engine(for: .auto, complexReason: complexReason) == .onDevice ? localBudget : .context(tokens: 200_000)
        }
    }

    /// Stream a reply from a chosen model. Explicit choices never fall back; Auto behaves like `stream(_:on:)`.
    func stream(_ request: AIRequest, choice: ModelChoice, complexReason: String? = nil, fallback: Bool = true) -> AsyncThrowingStream<String, Error> {
        switch choice {
        case .auto:
            return stream(request, on: route(complexReason: complexReason).engine, fallback: fallback)
        case .local(let id):
            let llm = localLLM(id)
            lastAnswer = AIAnswerInfo(engine: .onDevice, model: llm.card.name)
            return llm.stream(request)
        case .cloud(let p, let m):
            lastAnswer = AIAnswerInfo(engine: .cloud, model: name(for: choice))
            return cloudStream(request, provider: p, model: m)
        case .harness(let m):
            lastAnswer = AIAnswerInfo(engine: .cloud, model: name(for: choice))
            guard let tools = bridgeEndpoint else { return Self.failing(AIError(message: "Pair Synapse Bridge first.")) }
            return tools.harnessText(request, model: m) { [weak self] model in
                self?.lastAnswer?.model = ModelCatalog.displayName(claude: model) + " · harness"
            }
        }
    }

    func complete(_ request: AIRequest, choice: ModelChoice, complexReason: String? = nil, fallback: Bool = true) async throws -> String {
        var out = ""
        for try await chunk in stream(request, choice: choice, complexReason: complexReason, fallback: fallback) { out += chunk }
        return out
    }

    static func failing(_ error: Error) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish(throwing: error) }
    }
}

/// Server-sent events: yields the `data:` payload of each event.
enum SSE {
    static func events(_ bytes: URLSession.AsyncBytes) -> AsyncThrowingStream<(event: String, data: String), Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var event = ""
                    var data = ""
                    for try await line in bytes.lines {
                        if line.hasPrefix("event:") {
                            event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            let chunk = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                            data = data.isEmpty ? chunk : data + "\n" + chunk
                            // Each event here is one line of JSON, so emit right away.
                            continuation.yield((event, data))
                            event = ""
                            data = ""
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Talks to Synapse Bridge (`bridge/synapse-bridge.mjs`).
struct BridgeClient {
    var baseURL: URL
    var token: String
    /// "claude" or "codex".
    var engine: String
    var model: String
    var effort: String
    /// Called with the exact model id the bridge reports for the reply.
    var onMeta: @MainActor (String) -> Void = { _ in }

    func stream(_ request: AIRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: baseURL.appendingPathComponent("v1/chat"))
                    req.httpMethod = "POST"
                    req.timeoutInterval = 600
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    var body: [String: Any] = [
                        "system": request.system,
                        "messages": request.messages.map { ["role": $0.role.rawValue, "content": $0.content] },
                        "effort": effort,
                        "engine": engine,
                    ]
                    if model != "default" { body["model"] = model }
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)
                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    guard code == 200 else {
                        var text = ""
                        for try await line in bytes.lines { text += line; if text.count > 2000 { break } }
                        throw AIError(message: code == 401 ? "The bridge rejected the pairing token. Pair again in Settings." :
                                        "Bridge error \(code): \(BridgeClient.message(from: text))")
                    }
                    let onMeta = self.onMeta
                    for try await ev in SSE.events(bytes) {
                        guard let json = try? JSONSerialization.jsonObject(with: Data(ev.data.utf8)) as? [String: Any] else { continue }
                        switch json["type"] as? String {
                        case "meta":
                            if let m = json["model"] as? String { await onMeta(m) }
                        case "delta":
                            if let t = json["text"] as? String { continuation.yield(t) }
                        case "error":
                            throw AIError(message: (json["message"] as? String) ?? "The bridge reported an error.")
                        case "done":
                            continuation.finish()
                            return
                        default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func message(from text: String) -> String {
        if let data = text.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let m = json["error"] as? String ?? json["message"] as? String {
            return m
        }
        return String(text.prefix(300))
    }
}

/// Talks to the Claude API (Messages API, streaming) with the user's API key.
struct AnthropicClient {
    var apiKey: String
    var model: String
    var effort: String

    /// Server-side refusal fallback (beta) is offered for these models on the Claude API.
    private var supportsFallback: Bool {
        model.hasPrefix("claude-opus-5") || model.hasPrefix("claude-sonnet-5-5") || model.hasPrefix("claude-fable-5")
    }

    func stream(_ request: AIRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
                    req.httpMethod = "POST"
                    req.timeoutInterval = 600
                    req.setValue("application/json", forHTTPHeaderField: "content-type")
                    req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    var body: [String: Any] = [
                        "model": model,
                        "max_tokens": 32000,
                        "stream": true,
                        "system": request.system,
                        "messages": request.messages.map { ["role": $0.role.rawValue, "content": $0.content] },
                        "output_config": ["effort": effort],
                    ]
                    if supportsFallback {
                        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
                        body["fallbacks"] = "default"
                    }
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)
                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    guard code == 200 else {
                        var text = ""
                        for try await line in bytes.lines { text += line; if text.count > 4000 { break } }
                        throw AIError(message: AnthropicClient.describe(code: code, body: text))
                    }
                    for try await ev in SSE.events(bytes) {
                        guard let json = try? JSONSerialization.jsonObject(with: Data(ev.data.utf8)) as? [String: Any] else { continue }
                        switch json["type"] as? String {
                        case "content_block_delta":
                            if let delta = json["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                               let t = delta["text"] as? String {
                                continuation.yield(t)
                            }
                        case "message_delta":
                            if let delta = json["delta"] as? [String: Any], delta["stop_reason"] as? String == "refusal" {
                                continuation.yield("\n\n_(Claude declined to continue this request.)_")
                            } else if let delta = json["delta"] as? [String: Any], delta["stop_reason"] as? String == "max_tokens" {
                                continuation.yield("\n\n_(Reply cut off at the length limit.)_")
                            }
                        case "error":
                            let e = (json["error"] as? [String: Any])?["message"] as? String ?? "The Claude API reported an error."
                            throw AIError(message: e)
                        case "message_stop":
                            continuation.finish()
                            return
                        default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func describe(code: Int, body: String) -> String {
        var message = ""
        if let data = body.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = json["error"] as? [String: Any] {
            message = err["message"] as? String ?? ""
        }
        switch code {
        case 401: return "The API key was rejected. Check it in Settings › Claude."
        case 403: return "This API key can't use that model. \(message)"
        case 404: return "Model not found: \(message)"
        case 429: return "Rate limited by the Claude API. Try again in a moment."
        case 529, 503: return "Claude is overloaded right now. Try again shortly."
        default: return "Claude API error \(code). \(message)"
        }
    }
}

/// Minimal Keychain wrapper for the bridge token and API key.
enum Keychain {
    private static let service = "com.everaldtah.synapse"

    static func set(_ value: String, for key: String) {
        delete(key)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(q as CFDictionary)
    }
}
