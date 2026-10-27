import Foundation

/// A model offered by an API provider.
public struct APIModelInfo: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var contextTokens: Int?
    /// Supports OpenAI-style tool calling (Synapse's agent works without it, through its text protocol).
    public var tools: Bool?
    /// Accepts images.
    public var vision: Bool?
    /// A few words ("best reasoning", "fastest").
    public var note: String

    public init(_ id: String, context: Int? = nil, tools: Bool? = nil, vision: Bool? = nil, note: String = "") {
        self.id = id
        self.contextTokens = context
        self.tools = tools
        self.vision = vision
        self.note = note
    }

    /// "openai/gpt-oss-120b:free" → "gpt-oss-120b".
    public var shortName: String {
        var s = id
        if let slash = s.lastIndex(of: "/") { s = String(s[s.index(after: slash)...]) }
        if s.hasSuffix(":free") { s = String(s.dropLast(5)) }
        if s.hasSuffix("-free") { s = String(s.dropLast(5)) }
        return s
    }
}

/// An OpenAI-compatible chat API (`POST {baseURL}/chat/completions`, `GET {baseURL}/models`).
public struct APIProviderInfo: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// May contain `{placeholder}`s (Cloudflare's `{account_id}`).
    public var baseURL: String
    public var placeholders: [String]
    /// Where to get a key; nil when none is needed.
    public var keyURL: String?
    /// Works without a key (with tighter limits).
    public var keyOptional: Bool
    /// Has a free tier (otherwise "bring your own key").
    public var isFree: Bool
    /// One line on the free tier or pricing.
    public var terms: String
    /// When the terms were checked.
    public var verified: String
    /// `GET /models` works.
    public var listsModels: Bool
    /// Only list models whose id ends with this (OpenRouter's ":free").
    public var freeSuffix: String?
    /// `POST /audio/transcriptions` model, when the provider has free Whisper.
    public var transcriptionModel: String?
    public var models: [APIModelInfo]
    public var extraHeaders: [String: String]
    /// Added by the user.
    public var custom: Bool

    public init(id: String, name: String, baseURL: String, placeholders: [String] = [], keyURL: String?, keyOptional: Bool = false,
                isFree: Bool = true, terms: String, verified: String = "2026-10-26", listsModels: Bool = true, freeSuffix: String? = nil,
                transcriptionModel: String? = nil, models: [APIModelInfo], extraHeaders: [String: String] = [:], custom: Bool = false) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.placeholders = placeholders
        self.keyURL = keyURL
        self.keyOptional = keyOptional
        self.isFree = isFree
        self.terms = terms
        self.verified = verified
        self.listsModels = listsModels
        self.freeSuffix = freeSuffix
        self.transcriptionModel = transcriptionModel
        self.models = models
        self.extraHeaders = extraHeaders
        self.custom = custom
    }

    public var needsKey: Bool { keyURL != nil && !keyOptional }
}

/// Providers Synapse knows. Free tiers checked against each provider's docs (and live `/models` calls) on 2026-10-26;
/// they change often, so the app also fetches each provider's current model list.
public enum APIProviderCatalog {
    public static let free: [APIProviderInfo] = [
        APIProviderInfo(
            id: "groq", name: "Groq", baseURL: "https://api.groq.com/openai/v1", keyURL: "https://console.groq.com/keys",
            terms: "Free plan, no card. Per-model daily limits (e.g. gpt-oss-120b ≈1K requests/day). Very fast.",
            transcriptionModel: "whisper-large-v3-turbo",
            models: [
                APIModelInfo("openai/gpt-oss-120b", context: 131_072, tools: true, vision: false, note: "Best reasoning on Groq"),
                APIModelInfo("qwen/qwen3.8-27b", context: 131_072, tools: true, vision: true, note: "Vision and tools (preview)"),
                APIModelInfo("llama-3.3-70b-versatile", context: 131_072, tools: true, vision: false, note: "Solid general chat"),
                APIModelInfo("llama-3.1-8b-instant", context: 131_072, tools: true, vision: false, note: "Fastest small model"),
                APIModelInfo("minimaxai/minimax-m2.7", context: 196_608, tools: true, vision: false, note: "Agentic coding (preview)"),
            ]),
        APIProviderInfo(
            id: "gemini", name: "Google Gemini (AI Studio)", baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
            keyURL: "https://aistudio.google.com/apikey",
            terms: "Free tier per project, no card; daily limits shown in AI Studio (reset midnight PT). 1M-token context.",
            models: [
                APIModelInfo("gemini-3.8-flash", context: 1_048_576, tools: true, vision: true, note: "Best free frontier model"),
                APIModelInfo("gemini-3.6-flash", context: 1_048_576, tools: true, vision: true, note: "Previous Flash, good fallback"),
                APIModelInfo("gemini-3.5-flash-lite", context: 1_048_576, tools: true, vision: true, note: "Fastest, lightest Gemini"),
                APIModelInfo("gemini-3-flash-preview", context: 1_048_576, tools: true, vision: true, note: "Preview, stricter limits"),
            ]),
        APIProviderInfo(
            id: "nvidia", name: "NVIDIA NIM", baseURL: "https://integrate.api.nvidia.com/v1",
            keyURL: "https://build.nvidia.com/settings/api-keys",
            terms: "Free developer key (rate limited, about 40 requests/min). 80+ open models: GLM, Kimi, DeepSeek, Nemotron.",
            models: [
                APIModelInfo("z-ai/glm-5.3", context: 1_048_576, tools: true, vision: false, note: "Top agentic and coding model"),
                APIModelInfo("moonshotai/kimi-k2.6", context: 262_144, tools: true, vision: true, note: "Strong long tool chains"),
                APIModelInfo("deepseek-ai/deepseek-v4.1-flash", context: 1_048_576, tools: true, note: "Fast reasoning"),
                APIModelInfo("nvidia/nemotron-3.5-super-vl-120b-a12b", context: 1_048_576, tools: true, vision: true, note: "Vision and video"),
                APIModelInfo("minimaxai/minimax-m3.1-flash", context: 1_048_576, tools: true, vision: true, note: "Fast long-context agent"),
                APIModelInfo("google/gemma-4-31b-it", context: 262_144, tools: true, vision: true, note: "Dependable mid-size"),
            ]),
        APIProviderInfo(
            id: "openrouter", name: "OpenRouter (free models)", baseURL: "https://openrouter.ai/api/v1",
            keyURL: "https://openrouter.ai/settings/keys",
            terms: "Models ending in :free cost nothing: 20 requests/min, 50/day (1,000/day after buying 10 credits once). The free list rotates.",
            freeSuffix: ":free",
            models: [
                APIModelInfo("nvidia/nemotron-3-ultra-550b-a55b:free", context: 1_000_000, tools: true, vision: false, note: "Largest free reasoning model"),
                APIModelInfo("google/gemma-4-31b-it:free", context: 262_144, tools: true, vision: true, note: "Reliable vision all-rounder"),
                APIModelInfo("thinkingmachines/inkling:free", context: 1_048_576, tools: true, vision: true, note: "Text, image and audio input"),
                APIModelInfo("nvidia/nemotron-3.5-super-vl:free", context: 1_000_000, tools: true, vision: true, note: "Vision, long context"),
                APIModelInfo("poolside/laguna-s-2.1:free", context: 262_144, tools: true, vision: false, note: "Coding agent"),
                APIModelInfo("openrouter/free", context: 200_000, tools: true, vision: true, note: "Picks a free model for you"),
            ], extraHeaders: ["HTTP-Referer": "https://github.com/Everaldtah/synapse", "X-Title": "Synapse"]),
        APIProviderInfo(
            id: "mistral", name: "Mistral AI", baseURL: "https://api.mistral.ai/v1", keyURL: "https://console.mistral.ai/api-keys",
            terms: "Free mode is the default (no card, phone verification); monthly allowance shown on the account's Limits page.",
            models: [
                APIModelInfo("mistral-small-latest", context: 262_144, tools: true, vision: true, note: "Fast, multimodal"),
                APIModelInfo("mistral-medium-latest", context: 262_144, tools: true, vision: true, note: "Stronger, still free"),
                APIModelInfo("codestral-latest", context: 128_000, tools: true, vision: false, note: "Code"),
            ]),
        APIProviderInfo(
            id: "cloudflare", name: "Cloudflare Workers AI", baseURL: "https://api.cloudflare.com/client/v4/accounts/{account_id}/ai/v1",
            placeholders: ["account_id"], keyURL: "https://dash.cloudflare.com/profile/api-tokens",
            terms: "10,000 Neurons a day free on the Workers Free plan. Needs your account ID and an API token with Workers AI access.",
            listsModels: false,
            models: [
                APIModelInfo("@cf/openai/gpt-oss-120b", context: 128_000, tools: true, vision: false, note: "Best free-plan reasoning"),
                APIModelInfo("@cf/google/gemma-4-26b-a4b-it", context: 256_000, tools: true, vision: true, note: "Vision, cheap on Neurons"),
                APIModelInfo("@cf/meta/llama-4-scout-17b-16e-instruct", context: 131_000, tools: true, vision: true, note: "Multilingual vision"),
                APIModelInfo("@cf/zai-org/glm-4.7-flash", context: 131_072, tools: true, vision: false, note: "Cheap agentic coder"),
            ]),
        APIProviderInfo(
            id: "zai", name: "Z.ai (GLM Flash)", baseURL: "https://api.z.ai/api/paas/v4", keyURL: "https://z.ai/manage-apikey/apikey-list",
            terms: "GLM-4.7-Flash and GLM-4.6V-Flash are free (about one request at a time).",
            models: [
                APIModelInfo("glm-4.7-flash", context: 200_000, tools: true, vision: false, note: "Free hybrid thinker"),
                APIModelInfo("glm-4.6v-flash", context: 128_000, vision: true, note: "Free vision model"),
            ]),
        APIProviderInfo(
            id: "cohere", name: "Cohere (trial key)", baseURL: "https://api.cohere.ai/compatibility/v1",
            keyURL: "https://dashboard.cohere.com/api-keys",
            terms: "Free trial key: 1,000 calls a month, 20 chat requests a minute.", listsModels: false,
            transcriptionModel: "cohere-transcribe-03-2026",
            models: [
                APIModelInfo("command-a-plus-05-2026", context: 128_000, tools: true, vision: true, note: "Flagship agentic model"),
                APIModelInfo("command-a-03-2025", context: 256_000, tools: true, vision: false, note: "Long-context RAG and tools"),
                APIModelInfo("command-a-reasoning-08-2025", context: 256_000, vision: false, note: "Reasoning"),
            ]),
        APIProviderInfo(
            id: "ovh", name: "OVHcloud AI Endpoints", baseURL: "https://oai.endpoints.kepler.ai.cloud.ovh.net/v1", keyURL: nil,
            terms: "No key or account: 2 requests a minute per model. Free Whisper transcription too.",
            transcriptionModel: "whisper-large-v3-turbo",
            models: [
                APIModelInfo("gpt-oss-120b", context: 131_072, tools: true, vision: false, note: "Best keyless reasoning"),
                APIModelInfo("Qwen3.8-27B", context: 262_144, tools: true, note: "Tool calls work"),
                APIModelInfo("Qwen3.5-397B-A17B", context: 262_144, vision: false, note: "Largest keyless model"),
                APIModelInfo("Mistral-Small-3.2-24B-Instruct-2506", context: 131_072, vision: true, note: "Small multimodal"),
            ]),
        APIProviderInfo(
            id: "llm7", name: "LLM7.io", baseURL: "https://api.llm7.io/v1", keyURL: "https://dash.llm7.io", keyOptional: true,
            terms: "Works without a key; a free token gives 60 requests/min and 100K tokens a day.",
            models: [
                APIModelInfo("gpt-oss:20b", context: 128_000, tools: true, vision: false, note: "Default free reasoning"),
                APIModelInfo("minimax-m2.7", context: 180_000, tools: true, vision: false, note: "Agentic coding"),
                APIModelInfo("nemotron-3-nano:30b", context: 1_000_000, tools: true, vision: false, note: "Long context, fast"),
            ]),
        APIProviderInfo(
            id: "kilo", name: "Kilo AI Gateway", baseURL: "https://api.kilo.ai/api/gateway", keyURL: "https://kilo.ai", keyOptional: true,
            terms: "Free models need no key: 200 requests an hour. Some free models may log prompts.",
            freeSuffix: ":free",
            models: [
                APIModelInfo("kilo-auto/free", context: 256_000, tools: true, vision: false, note: "Picks a free model"),
                APIModelInfo("nvidia/nemotron-3-ultra-550b-a55b:free", context: 1_000_000, tools: true, vision: false, note: "Biggest free reasoning"),
                APIModelInfo("nvidia/nemotron-3.5-super-vl:free", context: 1_000_000, tools: true, vision: true, note: "Vision and video"),
            ]),
        APIProviderInfo(
            id: "requesty", name: "Requesty (free models)", baseURL: "https://router.requesty.ai/v1", keyURL: "https://app.requesty.ai",
            terms: "Free plan, no card: 200 requests a day across its free models.",
            models: [
                APIModelInfo("nvidia/nemotron-3-ultra-550b-a55b", context: 1_048_576, tools: true, vision: false, note: "Best free reasoning"),
                APIModelInfo("google/gemma-4-31b-it", context: 262_144, tools: true, vision: true, note: "Free vision"),
                APIModelInfo("nvidia/nemotron-3-super-120b-a12b", context: 1_048_576, tools: true, vision: false, note: "Balanced"),
            ]),
        APIProviderInfo(
            id: "vercel", name: "Vercel AI Gateway", baseURL: "https://ai-gateway.vercel.sh/v1",
            keyURL: "https://vercel.com/d?to=%2F%5Bteam%5D%2F%7E%2Fai-gateway%2Fapi-keys",
            terms: "$5 of free credit every 30 days on its free-tier models (ends once you buy credits).",
            models: [
                APIModelInfo("nvidia/nemotron-3.5-lightning-free", context: 1_000_000, tools: true, vision: false, note: "$0 model, fast"),
                APIModelInfo("reflection/beam-free", context: 1_048_576, tools: true, vision: false, note: "$0 reasoning"),
                APIModelInfo("poolside/laguna-s-2.1-free", context: 256_000, tools: true, vision: false, note: "$0 coding"),
            ]),
        APIProviderInfo(
            id: "sambanova", name: "SambaNova Cloud", baseURL: "https://api.sambanova.ai/v1", keyURL: "https://cloud.sambanova.ai",
            terms: "Free while no payment method is linked: about 20 requests a day per model.",
            models: [
                APIModelInfo("gpt-oss-120b", context: 131_072, vision: false, note: "Fast reasoning"),
                APIModelInfo("MiniMax-M3.1-Flash", context: 1_048_576, note: "Long context"),
                APIModelInfo("DeepSeek-V3.2", context: 32_768, vision: false, note: "General chat"),
            ]),
        APIProviderInfo(
            id: "ollama", name: "Ollama Cloud", baseURL: "https://ollama.com/v1", keyURL: "https://ollama.com/settings/keys",
            terms: "Free plan: one request at a time and a monthly allowance on its starter models.",
            models: [
                APIModelInfo("gpt-oss:120b", vision: false, note: "Starter model"),
                APIModelInfo("nemotron-3-ultra", vision: false, note: "Starter model"),
            ]),
        APIProviderInfo(
            id: "pollinations", name: "Pollinations (keyless)", baseURL: "https://text.pollinations.ai/openai", keyURL: nil,
            terms: "Legacy keyless endpoint, one small model, best effort.", listsModels: false,
            models: [APIModelInfo("openai", tools: true, vision: false, note: "Small open model")]),
    ]

    /// Paid providers that work the same way with your own key.
    public static let byok: [APIProviderInfo] = [
        APIProviderInfo(
            id: "xai", name: "xAI Grok", baseURL: "https://api.x.ai/v1", keyURL: "https://console.x.ai", isFree: false,
            terms: "Paid (no free tier as of October 2026). Models are listed from your account.", models: []),
        APIProviderInfo(
            id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com/v1", keyURL: "https://platform.deepseek.com/api_keys", isFree: false,
            terms: "Paid, low prices.",
            models: [APIModelInfo("deepseek-chat", context: 128_000, tools: true, vision: false, note: "General"),
                     APIModelInfo("deepseek-reasoner", context: 128_000, vision: false, note: "Reasoning")]),
        APIProviderInfo(
            id: "moonshot", name: "Moonshot Kimi", baseURL: "https://api.moonshot.ai/v1", keyURL: "https://platform.moonshot.ai/console/api-keys",
            isFree: false, terms: "Paid ($1 minimum top-up).", models: []),
        APIProviderInfo(
            id: "cerebras", name: "Cerebras", baseURL: "https://api.cerebras.ai/v1", keyURL: "https://cloud.cerebras.ai", isFree: false,
            terms: "$5, 30-day trial with a card; then paid. Extremely fast.", models: []),
        APIProviderInfo(
            id: "together", name: "Together AI", baseURL: "https://api.together.xyz/v1", keyURL: "https://api.together.ai/settings/api-keys",
            isFree: false, terms: "Paid ($5 minimum).", models: []),
        APIProviderInfo(
            id: "fireworks", name: "Fireworks AI", baseURL: "https://api.fireworks.ai/inference/v1", keyURL: "https://fireworks.ai/account/api-keys",
            isFree: false, terms: "Paid (small one-time credit).", models: []),
        APIProviderInfo(
            id: "huggingface", name: "Hugging Face Inference", baseURL: "https://router.huggingface.co/v1", keyURL: "https://huggingface.co/settings/tokens",
            isFree: false, terms: "PRO accounts get $2 a month; free accounts $0.", models: []),
        APIProviderInfo(
            id: "dashscope", name: "Alibaba Qwen (Model Studio)", baseURL: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
            keyURL: "https://bailian.console.alibabacloud.com/?apiKey=1", isFree: false,
            terms: "One-time 1M free tokens per model for 90 days (Singapore region), then paid.", models: []),
        APIProviderInfo(
            id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1", keyURL: "https://platform.openai.com/api-keys", isFree: false,
            terms: "Paid.", transcriptionModel: "whisper-1", models: []),
    ]

    public static let all: [APIProviderInfo] = free + byok

    public static func provider(_ id: String) -> APIProviderInfo? { all.first { $0.id == id } }

    /// A blank provider for any OpenAI-compatible server (LM Studio, Ollama or vLLM on your computer, a company gateway…).
    public static func custom(name: String, baseURL: String) -> APIProviderInfo {
        APIProviderInfo(id: "custom-" + ShortID.make(), name: name, baseURL: baseURL, keyURL: nil, keyOptional: true, isFree: true,
                        terms: "Your own OpenAI-compatible server.", verified: "", models: [], custom: true)
    }
}

/// The OpenAI Chat Completions wire format, shared by every provider above.
public enum OpenAICompat {
    /// `{account_id}` → the user's value, trailing slashes removed.
    public static func baseURL(_ template: String, values: [String: String]) -> String {
        var s = template
        for (k, v) in values { s = s.replacingOccurrences(of: "{\(k)}", with: v.trimmingCharacters(in: .whitespacesAndNewlines)) }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// The JSON body for a chat request. `images` are base64 JPEGs added to the last user message; `tools` is a JSON
    /// array of function definitions (`NativeToolCalls.schemas`) for models that call functions natively.
    public static func body(_ request: AIRequest, model: String, stream: Bool = true, maxTokens: Int? = nil, images: [String] = [],
                            tools: Data? = nil) -> [String: Any] {
        var messages: [[String: Any]] = []
        if !request.system.isEmpty { messages.append(["role": "system", "content": request.system]) }
        let lastUser = request.messages.lastIndex { $0.role == .user }
        for (i, m) in request.messages.enumerated() {
            if i == lastUser, !images.isEmpty {
                var parts: [[String: Any]] = [["type": "text", "text": m.content]]
                for img in images { parts.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(img)"]]) }
                messages.append(["role": "user", "content": parts])
            } else {
                messages.append(["role": m.role.rawValue, "content": m.content])
            }
        }
        var body: [String: Any] = ["model": model, "messages": messages, "stream": stream]
        if let maxTokens { body["max_tokens"] = maxTokens }
        if let tools, let list = try? JSONSerialization.jsonObject(with: tools) as? [Any], !list.isEmpty {
            body["tools"] = list
            body["tool_choice"] = "auto"
        }
        return body
    }

    /// One parsed `data:` line of a streaming reply.
    public struct Chunk: Equatable, Sendable {
        public var text: String = ""
        /// Reasoning some models stream separately (`reasoning_content` / `reasoning`); not part of the answer.
        public var reasoning: String = ""
        public var done = false
        public var error: String?
        /// "length" when the reply hit the token limit.
        public var finishReason: String?
        /// Native function calls (models that answer that way instead of with `<tool>` text).
        public var toolCalls: [NativeToolCalls.Delta] = []
        public init() {}
    }

    /// Parse one SSE line ("data: {…}", "data: [DONE]", blank or comment lines → nil).
    public static func chunk(line raw: String) -> Chunk? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        var c = Chunk()
        if payload == "[DONE]" { c.done = true; return c }
        guard let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { return nil }
        if let err = json["error"] {
            c.error = (err as? [String: Any])?["message"] as? String ?? (err as? String) ?? "The provider reported an error."
            return c
        }
        guard let choice = (json["choices"] as? [[String: Any]])?.first else { return c }
        let delta = choice["delta"] as? [String: Any] ?? choice["message"] as? [String: Any] ?? [:]
        c.text = delta["content"] as? String ?? ""
        c.reasoning = delta["reasoning_content"] as? String ?? delta["reasoning"] as? String ?? ""
        c.finishReason = choice["finish_reason"] as? String
        c.toolCalls = NativeToolCalls.deltas(delta["tool_calls"])
        return c
    }

    /// The text of a non-streaming reply.
    public static func text(fromResponse data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (json["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any] else { return nil }
        let text = message["content"] as? String
        var calls = NativeToolCalls.Accumulator()
        calls.add(NativeToolCalls.deltas(message["tool_calls"]))
        if calls.isEmpty { return text }
        return [text ?? "", calls.markup].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// `GET /models` → model infos (context from `context_length` / `context_window` when given).
    public static func models(from data: Data, freeSuffix: String? = nil) -> [APIModelInfo] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let list: [[String: Any]]
        if let d = json as? [String: Any] {
            list = d["data"] as? [[String: Any]] ?? d["models"] as? [[String: Any]] ?? []
        } else {
            list = json as? [[String: Any]] ?? []
        }
        var out: [APIModelInfo] = []
        for m in list {
            guard var id = m["id"] as? String ?? m["name"] as? String else { continue }
            if id.hasPrefix("models/") { id = String(id.dropFirst(7)) }   // Gemini lists "models/gemini-…"
            if let s = freeSuffix, !id.hasSuffix(s) { continue }
            let ctx = m["context_length"] as? Int ?? m["context_window"] as? Int ?? m["max_context_length"] as? Int
            let lower = id.lowercased()
            // Skip models that can't chat (embeddings, speech, images, moderation).
            if ["embed", "bge-", "whisper", "tts", "dall-e", "moderation", "rerank", "-image", "flux", "stable-diffusion", "guard"].contains(where: lower.contains) { continue }
            out.append(APIModelInfo(id, context: ctx))
        }
        return out.sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }

    /// A readable error for a failed request.
    public static func errorMessage(code: Int, body: String, provider: String) -> String {
        var message = ""
        if let json = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] {
            if let e = json["error"] as? [String: Any] { message = e["message"] as? String ?? "" }
            else if let e = json["error"] as? String { message = e }
            else if let m = json["message"] as? String { message = m }
            else if let d = json["detail"] as? String { message = d }
        }
        if message.isEmpty { message = String(body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240)) }
        switch code {
        case 401, 403: return "\(provider) rejected the API key (\(code)). Check it in Settings › API providers.\(message.isEmpty ? "" : " \(message)")"
        case 402: return "\(provider) says this model needs credit or a paid plan. \(message)"
        case 404: return "\(provider) doesn't have that model (or the address is wrong). \(message)"
        case 413: return "The request is too long for this model on \(provider). \(message)"
        case 429: return "\(provider)'s free limit is used up for now (429). Try again later or pick another model. \(message)"
        case 500...599: return "\(provider) had a server error (\(code)). Try again in a moment. \(message)"
        default: return "\(provider) error \(code). \(message)"
        }
    }
}
