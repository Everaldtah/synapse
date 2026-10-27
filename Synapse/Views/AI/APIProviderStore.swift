import Foundation
import Observation
import SynapseKit

/// The OpenAI-compatible API providers: `APIProviderCatalog` plus the user's own servers. Keys live in the Keychain
/// ("apikey.<id>"); account values, starred models and fetched model lists in UserDefaults. Requests go through
/// `OpenAICompatibleClient`.
@MainActor
@Observable
final class APIProviderStore {
    static let shared = APIProviderStore()

    // Stored mirrors of what's persisted, so views observe changes.
    /// The user's own servers ("api.custom").
    private var custom: [APIProviderInfo]
    /// Providers with a key in the Keychain.
    private var keyed: Set<String>
    /// "<id>.<name>" → value ("api.placeholder.<id>.<name>").
    private var placeholderValues: [String: String]
    /// Live `GET /models` results ("api.models.<id>").
    private var fetched: [String: [APIModelInfo]]
    /// Starred model ids per provider, in the order starred ("api.favorites").
    private var favorites: [String: [String]]

    private init() {
        let d = UserDefaults.standard
        let custom = d.data(forKey: "api.custom").flatMap { try? JSONDecoder().decode([APIProviderInfo].self, from: $0) } ?? []
        let all = APIProviderCatalog.all + custom
        var values: [String: String] = [:]
        var lists: [String: [APIModelInfo]] = [:]
        for p in all {
            for name in p.placeholders {
                if let v = d.string(forKey: "api.placeholder.\(p.id).\(name)") { values["\(p.id).\(name)"] = v }
            }
            if p.listsModels, let data = d.data(forKey: "api.models.\(p.id)"),
               let models = try? JSONDecoder().decode([APIModelInfo].self, from: data), !models.isEmpty {
                lists[p.id] = models
            }
        }
        self.custom = custom
        keyed = Set(all.map(\.id).filter { Keychain.get("apikey.\($0)") != nil })
        placeholderValues = values
        fetched = lists
        favorites = d.data(forKey: "api.favorites").flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:]
    }

    // MARK: - Providers

    /// The catalog (free first, then bring-your-own-key), then the user's own servers.
    var providers: [APIProviderInfo] { APIProviderCatalog.all + custom }

    func provider(_ id: String) -> APIProviderInfo? {
        APIProviderCatalog.provider(id) ?? custom.first { $0.id == id }
    }

    /// Key present (or not needed) and every placeholder filled.
    func isReady(_ id: String) -> Bool {
        guard let p = provider(id) else { return false }
        return notReadyReason(p) == nil
    }

    /// Ready providers, in catalog order.
    var readyProviders: [APIProviderInfo] { providers.filter { isReady($0.id) } }

    /// Why a provider can't be used yet; nil when it's ready.
    func notReadyReason(_ p: APIProviderInfo) -> String? {
        if p.needsKey && !hasKey(p.id) { return "\(Self.shortName(p)) needs an API key. Add it in Settings › API providers." }
        if let missing = missingPlaceholders(p).first {
            return "\(Self.shortName(p)) needs your \(Self.label(forPlaceholder: missing)). Add it in Settings › API providers."
        }
        return nil
    }

    /// Placeholders (like Cloudflare's "account_id") the user hasn't filled in.
    func missingPlaceholders(_ p: APIProviderInfo) -> [String] {
        p.placeholders.filter { placeholderValue($0, for: p.id).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// The provider's base URL with its placeholders filled.
    func resolvedBaseURL(_ p: APIProviderInfo) -> String {
        var values: [String: String] = [:]
        for name in p.placeholders { values[name] = placeholderValue(name, for: p.id) }
        return OpenAICompat.baseURL(p.baseURL, values: values)
    }

    // MARK: - Keys and account values

    func hasKey(_ id: String) -> Bool { keyed.contains(id) }

    /// Save a key in the Keychain; "" deletes it.
    func setKey(_ key: String, for id: String) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.isEmpty {
            Keychain.delete("apikey.\(id)")
            keyed.remove(id)
        } else {
            Keychain.set(k, for: "apikey.\(id)")
            keyed.insert(id)
        }
    }

    private func apiKey(_ id: String) -> String? {
        keyed.contains(id) ? Keychain.get("apikey.\(id)") : nil
    }

    func placeholderValue(_ name: String, for id: String) -> String {
        placeholderValues["\(id).\(name)"] ?? ""
    }

    func setPlaceholder(_ name: String, _ value: String, for id: String) {
        let key = "api.placeholder.\(id).\(name)"
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            placeholderValues["\(id).\(name)"] = nil
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            placeholderValues["\(id).\(name)"] = value
            UserDefaults.standard.set(value, forKey: key)
        }
    }

    /// "account_id" → "account ID".
    nonisolated static func label(forPlaceholder name: String) -> String {
        name.split(separator: "_").map { $0.lowercased() == "id" ? "ID" : String($0) }.joined(separator: " ")
    }

    // MARK: - Models

    /// The live model list when one was fetched (catalog models first, with their notes), else the catalog's.
    func models(for id: String) -> [APIModelInfo] {
        guard let p = provider(id) else { return [] }
        guard let live = fetched[id], !live.isEmpty else { return p.models }
        let liveByID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [APIModelInfo] = []
        for var m in p.models {
            if let l = liveByID[m.id] {
                if m.contextTokens == nil, let c = l.contextTokens, c > 0 { m.contextTokens = c }
                out.append(m)
            } else if let suffix = p.freeSuffix, !m.id.hasSuffix(suffix) {
                // Hidden by the suffix filter rather than gone (OpenRouter's "openrouter/free" router).
                out.append(m)
            }
        }
        let known = Set(p.models.map(\.id))
        out += live.filter { !known.contains($0.id) }
        return out
    }

    /// A live list was fetched for this provider.
    func hasLiveModels(_ id: String) -> Bool { fetched[id] != nil }

    /// The starred models; with none starred, the catalog's picks (or the first six fetched).
    func favoriteModels(for id: String) -> [APIModelInfo] {
        let list = models(for: id)
        let starred = favorites[id] ?? []
        guard starred.isEmpty else {
            let byID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            return starred.map { byID[$0] ?? APIModelInfo($0) }
        }
        let picks = Set(provider(id)?.models.map(\.id) ?? [])
        let defaults = list.filter { picks.contains($0.id) }
        return defaults.isEmpty ? Array(list.prefix(6)) : defaults
    }

    func isFavorite(_ model: String, provider id: String) -> Bool {
        favorites[id]?.contains(model) ?? false
    }

    func toggleFavorite(_ model: String, provider id: String) {
        var list = favorites[id] ?? []
        if let i = list.firstIndex(of: model) { list.remove(at: i) } else { list.append(model) }
        favorites[id] = list.isEmpty ? nil : list
        Self.save(favorites, "api.favorites")
    }

    /// Fetch and cache the provider's live model list. Providers without `GET /models` return their catalog models.
    @discardableResult
    func refreshModels(_ id: String) async throws -> [APIModelInfo] {
        guard let p = provider(id) else { throw AIError(message: "That API provider isn't set up any more.") }
        guard p.listsModels else { return p.models }
        let list: [APIModelInfo]
        do {
            list = try await OpenAICompatibleClient.fetchModels(baseURL: resolvedBaseURL(p), apiKey: apiKey(id), extraHeaders: p.extraHeaders,
                                                                freeSuffix: p.freeSuffix, providerName: Self.shortName(p))
        } catch {
            if p.needsKey && !hasKey(id) { throw AIError(message: "Add your \(Self.shortName(p)) API key to load its models.") }
            throw error
        }
        guard !list.isEmpty else {
            throw AIError(message: "\(Self.shortName(p)) listed no chat models\(p.freeSuffix.map { " ending in \($0)" } ?? "") right now.")
        }
        fetched[id] = list
        Self.save(list, "api.models.\(id)")
        return models(for: id)
    }

    // MARK: - Requests

    /// One tiny request ("Reply with OK."); "OK · 0.8 s · gpt-oss-120b" on success.
    func test(_ id: String, model: String?) async -> Result<String, AIError> {
        guard let p = provider(id) else { return .failure(AIError(message: "That API provider isn't set up any more.")) }
        guard let model = model ?? favoriteModels(for: id).first?.id else {
            return .failure(AIError(message: p.listsModels ? "No models yet. Refresh the model list first." : "\(p.name) has no models."))
        }
        let client: OpenAICompatibleClient
        switch makeClient(id, model: model) {
        case .success(let c): client = c
        case .failure(let e): return .failure(e)
        }
        let start = Date()
        do {
            let request = AIRequest(system: "", messages: [AIMessage(role: .user, content: "Reply with OK.")])
            for try await _ in client.stream(request) {}
            let seconds = String(format: "%.1f", Date().timeIntervalSince(start))
            return .success("OK · \(seconds) s · \(APIModelInfo(model).shortName)")
        } catch let error as AIError {
            return .failure(error)
        } catch {
            return .failure(AIError(message: error.localizedDescription))
        }
    }

    /// Stream a reply from a provider's model. Fails with an `AIError` when the provider isn't ready.
    func stream(_ request: AIRequest, provider id: String, model: String, images: [String] = []) -> AsyncThrowingStream<String, Error> {
        switch makeClient(id, model: model) {
        case .failure(let error):
            return AsyncThrowingStream { $0.finish(throwing: error) }
        case .success(let client):
            if lastUsed?.provider != id || lastUsed?.model != model { lastUsed = (id, model) }
            return client.stream(request, images: images)
        }
    }

    /// Speech to text with a provider's free Whisper-style model.
    func transcribe(_ file: URL, provider id: String) async throws -> String {
        guard let p = provider(id), let model = p.transcriptionModel else {
            throw AIError(message: "\(provider(id)?.name ?? "That provider") doesn't offer transcription.")
        }
        if let why = notReadyReason(p) { throw AIError(message: why) }
        return try await OpenAICompatibleClient.transcribe(file: file, baseURL: resolvedBaseURL(p), apiKey: apiKey(id), model: model,
                                                           providerName: Self.shortName(p))
    }

    /// Ready providers with a transcription model.
    var transcriptionProviders: [APIProviderInfo] { readyProviders.filter { $0.transcriptionModel != nil } }

    private func makeClient(_ id: String, model: String) -> Result<OpenAICompatibleClient, AIError> {
        guard let p = provider(id) else { return .failure(AIError(message: "That API provider isn't set up any more. Pick another model.")) }
        if let why = notReadyReason(p) { return .failure(AIError(message: why)) }
        return .success(OpenAICompatibleClient(baseURL: resolvedBaseURL(p), apiKey: apiKey(id), model: model,
                                               providerName: Self.shortName(p), extraHeaders: p.extraHeaders))
    }

    // MARK: - Names and limits

    /// "gpt-oss-120b · Groq".
    func displayName(provider id: String, model: String) -> String {
        "\(APIModelInfo(model).shortName) · \(provider(id).map { Self.shortName($0) } ?? id)"
    }

    /// The model's known context window, else 32K.
    func contextTokens(provider id: String, model: String) -> Int {
        if let c = info(id, model)?.contextTokens, c > 0 { return c }
        return 32_768
    }

    func supportsVision(provider id: String, model: String) -> Bool {
        info(id, model)?.vision == true
    }

    private func info(_ id: String, _ model: String) -> APIModelInfo? {
        models(for: id).first { $0.id == model } ?? provider(id)?.models.first { $0.id == model }
    }

    /// The provider's name without its parenthetical ("OpenRouter (free models)" → "OpenRouter").
    nonisolated static func shortName(_ p: APIProviderInfo) -> String {
        guard let r = p.name.range(of: " (") else { return p.name }
        return String(p.name[..<r.lowerBound])
    }

    /// 131_072 → "128K", 128_000 → "128K", 1_048_576 → "1M".
    nonisolated static func compactTokens(_ tokens: Int) -> String {
        for (decimal, binary, unit) in [(1_000_000.0, 1_048_576.0, "M"), (1_000.0, 1_024.0, "K")] where Double(tokens) >= decimal {
            let d = Double(tokens) / decimal, b = Double(tokens) / binary
            if d == d.rounded() { return "\(Int(d))\(unit)" }
            if b == b.rounded() { return "\(Int(b))\(unit)" }
            return unit == "M" ? String(format: "%.1fM", d) : "\(Int(d.rounded()))K"
        }
        return "\(tokens)"
    }

    // MARK: - Your own servers

    /// Add an OpenAI-compatible server (LM Studio, Ollama, vLLM…). Keyless unless `key` is given.
    @discardableResult
    func addCustom(name: String, baseURL: String, key: String) -> APIProviderInfo {
        var url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") { url.removeLast() }
        if url.hasSuffix("/chat/completions") { url.removeLast("/chat/completions".count) }
        if !url.contains("://") { url = "http://" + url }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = APIProviderCatalog.custom(name: trimmedName.isEmpty ? (URL(string: url)?.host ?? "My server") : trimmedName, baseURL: url)
        custom.append(p)
        Self.save(custom, "api.custom")
        setKey(key, for: p.id)
        return p
    }

    func removeCustom(_ id: String) {
        guard let p = custom.first(where: { $0.id == id }) else { return }
        custom.removeAll { $0.id == id }
        Self.save(custom, "api.custom")
        setKey("", for: id)
        for name in p.placeholders { setPlaceholder(name, "", for: id) }
        fetched[id] = nil
        UserDefaults.standard.removeObject(forKey: "api.models.\(id)")
        if favorites.removeValue(forKey: id) != nil { Self.save(favorites, "api.favorites") }
        if lastUsed?.provider == id { lastUsed = nil }
    }

    // MARK: - Defaults

    /// The provider and model used last, for defaults.
    var lastUsed: (provider: String, model: String)? {
        get {
            access(keyPath: \.lastUsed)
            let d = UserDefaults.standard
            guard let p = d.string(forKey: "api.lastUsed.provider"), let m = d.string(forKey: "api.lastUsed.model") else { return nil }
            return (p, m)
        }
        set {
            withMutation(keyPath: \.lastUsed) {
                let d = UserDefaults.standard
                if let newValue {
                    d.set(newValue.provider, forKey: "api.lastUsed.provider")
                    d.set(newValue.model, forKey: "api.lastUsed.model")
                } else {
                    d.removeObject(forKey: "api.lastUsed.provider")
                    d.removeObject(forKey: "api.lastUsed.model")
                }
            }
        }
    }

    private static func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }
}
