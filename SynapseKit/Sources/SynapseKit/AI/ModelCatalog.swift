import Foundation

/// What Synapse shows about a model in the model switcher: where it runs, how big it is, and what it's good at.
public struct ModelCard: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        /// Runs on the iPhone.
        case onDevice
        /// Runs on a subscription through Synapse Bridge (Claude Code or Codex on your computer).
        case subscription
        /// Runs on the Anthropic API with your key.
        case api
    }

    public var id: String
    public var name: String
    public var maker: String
    public var kind: Kind
    /// "≈3 billion", or "Not published".
    public var parameters: String
    /// "2-bit", "4-bit", or "".
    public var quantization: String
    /// Download or install size.
    public var size: String
    /// Bytes to download, for models Synapse downloads itself (0 otherwise).
    public var downloadBytes: Int64
    public var contextWindow: String
    public var maxOutput: String
    /// Short line for list rows.
    public var summary: String
    public var goodAt: [String]
    public var limits: [String]
    /// Devices and settings it needs.
    public var requirements: String

    public init(id: String, name: String, maker: String, kind: Kind, parameters: String, quantization: String = "",
                size: String, downloadBytes: Int64 = 0, contextWindow: String, maxOutput: String = "", summary: String,
                goodAt: [String], limits: [String], requirements: String = "") {
        self.id = id
        self.name = name
        self.maker = maker
        self.kind = kind
        self.parameters = parameters
        self.quantization = quantization
        self.size = size
        self.downloadBytes = downloadBytes
        self.contextWindow = contextWindow
        self.maxOutput = maxOutput
        self.summary = summary
        self.goodAt = goodAt
        self.limits = limits
        self.requirements = requirements
    }

    /// "≈3B · 2-bit · built in" for list rows.
    public var specLine: String {
        var parts: [String] = []
        if parameters != ModelCatalog.notPublished { parts.append(parameters) }
        if !quantization.isEmpty { parts.append(quantization) }
        parts.append(contextWindow + " context")
        return parts.joined(separator: " · ")
    }
}

public enum ModelCatalog {
    static let notPublished = "Not published"

    // MARK: On this iPhone

    /// Apple's on-device foundation model (Foundation Models framework). Figures from Apple's 2025 foundation model
    /// tech report: about 3 billion parameters, 2-bit quantization-aware training, a 4,096-token window.
    public static let appleFoundation = ModelCard(
        id: "apple.foundation",
        name: "Apple Foundation Model",
        maker: "Apple",
        kind: .onDevice,
        parameters: "≈3 billion parameters",
        quantization: "2-bit",
        size: "Built into iOS with Apple Intelligence — nothing to download",
        contextWindow: "4,096 tokens",
        maxOutput: "Shares the 4,096-token window",
        summary: "Built in, free, private, works offline",
        goodAt: [
            "Summaries, key points and action items",
            "Rewriting: shorter, longer, simpler, fixing grammar, changing tone",
            "Meeting notes from transcripts (long ones in parts)",
            "Short drafts, outlines and brainstorming",
            "Everything stays on the iPhone and works without a connection",
        ],
        limits: [
            "Small window: about 5,000 words in and out together, so long pages are trimmed or sent to the cloud",
            "Little world knowledge — not for facts you'd look up",
            "Weak at maths, code and multi-step reasoning",
            "Fewer languages than the cloud models",
        ],
        requirements: "iPhone 15 Pro or newer (your target: iPhone 16 Pro Max and up) with Apple Intelligence turned on"
    )

    /// Apple's on-device speech-to-text model (SpeechAnalyzer / SpeechTranscriber, iOS 26).
    public static let appleSpeech = ModelCard(
        id: "apple.speech",
        name: "Apple SpeechTranscriber",
        maker: "Apple",
        kind: .onDevice,
        parameters: notPublished,
        size: "Downloaded by iOS once per language and shared by all apps (Apple doesn't publish the size)",
        contextWindow: "Unlimited audio length",
        summary: "On-device transcription for long recordings",
        goodAt: [
            "Long recordings: meetings, lectures, voice memos",
            "Fast — much quicker than real time on the A18 Pro and A19 Pro",
            "Punctuation and casing, private and offline",
        ],
        limits: [
            "One language per recording",
            "No speaker labels (who said what)",
            "Names and jargon can be misheard; the notes step corrects obvious ones from context",
        ],
        requirements: "iOS 26; the language model downloads the first time you transcribe in that language"
    )

    /// Every on-device language model Synapse can use (more are added as they ship).
    public static var onDeviceModels: [ModelCard] { [appleFoundation] + downloadable }

    /// Open-weights models Synapse downloads and runs with MLX. Empty until the MLX runtime is in the app.
    public static var downloadable: [ModelCard] = []

    // MARK: Claude (subscription via Claude Code, or the API)

    /// Claude Code model aliases. `default` is whatever the plan uses.
    public static func claude(_ alias: String, kind: ModelCard.Kind) -> ModelCard {
        let via = kind == .api ? "Anthropic API key" : "Claude subscription via Claude Code"
        switch alias {
        case "opus", "claude-opus-5-5":
            return ModelCard(id: kind == .api ? "claude-opus-5-5" : "opus", name: "Claude Opus 5.5", maker: "Anthropic", kind: kind,
                             parameters: notPublished, size: via, contextWindow: "1M tokens", maxOutput: "128K tokens",
                             summary: "Most capable everyday Claude — the default",
                             goodAt: ["Complex reasoning and analysis", "Long documents and whole-workspace questions",
                                      "Coding, planning and careful writing"],
                             limits: ["Slower than Sonnet and Haiku", "Uses more of your plan's limits"])
        case "sonnet", "claude-sonnet-5-5":
            return ModelCard(id: kind == .api ? "claude-sonnet-5-5" : "sonnet", name: "Claude Sonnet 5.5", maker: "Anthropic", kind: kind,
                             parameters: notPublished, size: via, contextWindow: "1M tokens", maxOutput: "128K tokens",
                             summary: "Fast and capable",
                             goodAt: ["Most writing and analysis at good speed", "Long context at lower cost than Opus"],
                             limits: ["A step below Opus on the hardest problems"])
        case "haiku", "claude-haiku-5-5":
            return ModelCard(id: kind == .api ? "claude-haiku-5-5" : "haiku", name: "Claude Haiku 5.5", maker: "Anthropic", kind: kind,
                             parameters: notPublished, size: via, contextWindow: "1M tokens", maxOutput: "128K tokens",
                             summary: "Fastest and cheapest Claude",
                             goodAt: ["Quick rewrites, summaries and extraction", "High-volume simple tasks"],
                             limits: ["Less depth on complex reasoning"])
        case "claude-fable-5-1", "fable":
            return ModelCard(id: kind == .api ? "claude-fable-5-1" : "fable", name: "Claude Fable 5.1", maker: "Anthropic", kind: kind,
                             parameters: notPublished, size: via, contextWindow: "1M tokens", maxOutput: "128K tokens",
                             summary: "Anthropic's most capable model",
                             goodAt: ["The hardest reasoning and long, multi-step work"],
                             limits: ["Slowest; replies can take minutes", "Highest cost per token"])
        default:
            return ModelCard(id: "default", name: "Claude Code default", maker: "Anthropic", kind: kind,
                             parameters: notPublished, size: via, contextWindow: "1M tokens", maxOutput: "128K tokens",
                             summary: "Whatever model your Claude plan uses by default",
                             goodAt: ["Complex reasoning, long documents and whole-workspace questions"],
                             limits: ["Counts against your plan's usage limits"])
        }
    }

    // MARK: Codex (ChatGPT subscription via Codex CLI)

    public static func codex(id: String, name: String? = nil, description: String = "", contextWindow: Int? = nil) -> ModelCard {
        let ctx = contextWindow.map { $0 >= 1_000_000 ? "\($0 / 1_000_000)M tokens" : "\($0 / 1_000)K tokens" } ?? "Large"
        return ModelCard(id: id, name: displayName(codex: name ?? id), maker: "OpenAI", kind: .subscription,
                         parameters: notPublished, size: "ChatGPT subscription via Codex on your computer",
                         contextWindow: ctx, summary: description.isEmpty ? "OpenAI model through Codex" : description,
                         goodAt: ["Complex reasoning, code and long documents", "A second opinion from a different model family"],
                         limits: ["Counts against your ChatGPT plan's Codex limits", "Codex is an agent; Synapse runs it with tools off"])
    }

    /// "gpt-5.4-mini" → "GPT-5.4 Mini".
    public static func displayName(codex id: String) -> String {
        if id == "default" { return "Codex default" }
        var parts = id.split(separator: "-").map(String.init)
        guard !parts.isEmpty else { return id }
        if parts[0].lowercased() == "gpt", parts.count > 1 {
            parts[0] = "GPT-" + parts[1]
            parts.remove(at: 1)
        }
        return parts.enumerated().map { $0.offset == 0 ? $0.element : $0.element.capitalized }.joined(separator: " ")
    }

    /// "claude-opus-5-5" → "Claude Opus 5.5"; other ids are returned as they are.
    public static func displayName(claude id: String) -> String {
        guard id.hasPrefix("claude-") else { return id }
        let parts = id.dropFirst(7).split(separator: "-").map(String.init)
        guard let family = parts.first else { return id }
        let version = parts.dropFirst().prefix { $0.allSatisfy(\.isNumber) && $0.count <= 2 }.joined(separator: ".")
        return "Claude \(family.capitalized)" + (version.isEmpty ? "" : " \(version)")
    }
}
