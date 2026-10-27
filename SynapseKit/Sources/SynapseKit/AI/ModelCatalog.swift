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
    /// Downloadable models: the Hugging Face repo with MLX weights.
    public var repoID: String
    /// Downloadable models: end-of-turn tokens beyond the config's own.
    public var stopTokens: [String]
    /// Downloadable models: the context Synapse runs them with on the iPhone (memory-bound, not the model's maximum).
    public var runContextTokens: Int
    /// Languages it writes well (Translate menu names); nil means all of them.
    public var languages: Set<String>?

    public init(id: String, name: String, maker: String, kind: Kind, parameters: String, quantization: String = "",
                size: String, downloadBytes: Int64 = 0, contextWindow: String, maxOutput: String = "", summary: String,
                goodAt: [String], limits: [String], requirements: String = "", repoID: String = "", stopTokens: [String] = [],
                runContextTokens: Int = 0, languages: Set<String>? = nil) {
        self.repoID = repoID
        self.stopTokens = stopTokens
        self.runContextTokens = runContextTokens
        self.languages = languages
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

    /// OpenAI's Whisper large-v3-turbo, run by Synapse Bridge on the computer's GPU.
    public static let whisperTurbo = ModelCard(
        id: "bridge.whisper",
        name: "Whisper large-v3 turbo",
        maker: "OpenAI (open weights)",
        kind: .subscription,
        parameters: "809 million parameters",
        quantization: "16-bit",
        size: "1.6 GB, on your computer (runs on its GPU)",
        contextWindow: "Any length (30-second windows)",
        summary: "Accurate transcription on your computer",
        goodAt: ["Accents, noisy rooms and technical vocabulary", "99 languages, detected automatically", "Fast on an NVIDIA GPU"],
        limits: ["Needs the bridge computer on", "No speaker labels"],
        requirements: "Synapse Bridge with Python, openai-whisper and the model downloaded"
    )

    /// Claude Code on the Claude subscription, inside the bridge's Linux sandbox.
    public static let claudeCodeHarness = ModelCard(
        id: "bridge.harness",
        name: "Claude Code harness",
        maker: "Anthropic",
        kind: .subscription,
        parameters: notPublished,
        size: "Claude subscription, running in a Linux sandbox on your computer",
        contextWindow: "1M tokens",
        maxOutput: "128K tokens",
        summary: "Claude with web search, web pages and a Linux shell",
        goodAt: ["Research with sources", "Running code on your files: data, conversions, charts",
                 "Multi-step tasks the on-device models hand it"],
        limits: ["Slower: it plans and uses tools", "Counts against your Claude plan", "Needs the bridge computer on"],
        requirements: "Synapse Bridge sandbox with Claude Code signed in (one-time sign-in)"
    )

    /// Every on-device language model Synapse can use (more are added as they ship).
    public static var onDeviceModels: [ModelCard] { [appleFoundation] + downloadable }

    /// Whether a card is a model Synapse downloads (rather than one built into iOS).
    public static func isDownloadable(_ card: ModelCard) -> Bool { !card.repoID.isEmpty }

    /// What Synapse lets a downloaded model hold at once on the iPhone. Apps get about 6 GB on the iPhone 16 Pro Max and
    /// 17 Pro Max alike, so the KV cache is capped well below each model's maximum.
    public static let runContext = 8_192

    static let downloadRequirements = "iPhone 16 Pro Max or newer (8 GB RAM or more). Keep Synapse open while it downloads; it's stored on this iPhone, not in iCloud backups."

    /// Open-weights models Synapse downloads from Hugging Face (mlx-community 4-bit builds) and runs with MLX on the GPU.
    /// Sizes are the weight files; parameters and context windows are the model makers' figures.
    public static let downloadable: [ModelCard] = [synapseAlpha] + openModels

    /// Synapse's own model: Qwen3.5-2B fine-tuned on Synapse's prompts, tools and note formats. Its hybrid attention keeps
    /// the memory cache small (6 of 24 layers attend over the whole window), so it runs with twice the context of the
    /// others. 16,000 tokens keeps the prompt budget under the Agents tab's 40,000-character line for small models.
    public static let synapseAlpha = ModelCard(
        id: "mlx.synapse-alpha-1.0",
        name: "Synapse Alpha 1.0",
        maker: "Synapse (fine-tuned from Alibaba's Qwen3.5-2B)",
        kind: .onDevice,
        parameters: "2 billion parameters",
        quantization: "4-bit",
        size: "1.1 GB download",
        downloadBytes: 1_079_466_994,
        contextWindow: "262K tokens (16K on iPhone)",
        maxOutput: "4,096 tokens a reply",
        summary: "Made for Synapse: transcripts, notes, research and agents on this iPhone",
        goodAt: [
            "Meeting, lecture and summary notes from recordings, documents and photos, in Synapse's formats",
            "Cleaning up speech-recognition transcripts: mis-heard names and words, punctuation, paragraphs",
            "Editor actions, Ask with [[page]] citations, and link suggestions for the graph",
            "Using Synapse's tools: web search and pages, the terminal, and the Agents tab's pages, graph and files",
        ],
        limits: [
            "Alpha: trained on generated Synapse data, so check important facts",
            "Still a small model: use a cloud model for hard reasoning, long code or deep research",
            "Speech is turned into text by Apple's transcriber or Whisper; this model works on that text",
        ],
        requirements: downloadRequirements,
        repoID: "evraldtah/Synapse-Alpha-1.0-4bit",
        stopTokens: ["<|im_end|>"],
        runContextTokens: 16_000
    )

    static let openModels: [ModelCard] = [
        ModelCard(
            id: "mlx.qwen3-4b-instruct-2507",
            name: "Qwen3 4B Instruct",
            maker: "Alibaba Qwen",
            kind: .onDevice,
            parameters: "4.0 billion parameters",
            quantization: "4-bit",
            size: "2.3 GB download",
            downloadBytes: 2_277_297_844,
            contextWindow: "262K tokens (8K on iPhone)",
            maxOutput: "About 2,700 tokens a reply",
            summary: "Best all-round local model: twice the context of Apple's, stronger reasoning",
            goodAt: [
                "Meeting notes, summaries and action items from longer text in one pass",
                "Answering questions over several pages",
                "Rewriting and translating in 100+ languages",
                "Following detailed instructions",
            ],
            limits: [
                "2.3 GB of storage and about 3.5 GB of memory while it runs",
                "Slower than Apple's built-in model; replies take a few seconds to start",
                "Still small: check facts, and use the cloud for hard reasoning or code",
            ],
            requirements: downloadRequirements,
            repoID: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
            stopTokens: ["<|im_end|>"],
            runContextTokens: runContext
        ),
        ModelCard(
            id: "mlx.llama-3.2-3b-instruct",
            name: "Llama 3.2 3B Instruct",
            maker: "Meta",
            kind: .onDevice,
            parameters: "3.2 billion parameters",
            quantization: "4-bit",
            size: "1.8 GB download",
            downloadBytes: 1_824_807_894,
            contextWindow: "128K tokens (8K on iPhone)",
            maxOutput: "About 2,700 tokens a reply",
            summary: "Steady summariser and rewriter",
            goodAt: [
                "Summaries, rewrites and tone changes",
                "Reliable, plain output with no reasoning mode to manage",
            ],
            limits: [
                "8 languages (English, German, French, Italian, Portuguese, Hindi, Spanish, Thai)",
                "Weaker than Qwen3 4B at multi-step reasoning",
            ],
            requirements: downloadRequirements,
            repoID: "mlx-community/Llama-3.2-3B-Instruct-4bit",
            stopTokens: ["<|eot_id|>"],
            runContextTokens: runContext,
            languages: ["English", "German", "French", "Italian", "Portuguese", "Hindi", "Spanish"]
        ),
        ModelCard(
            id: "mlx.phi-4-mini-instruct",
            name: "Phi-4 mini Instruct",
            maker: "Microsoft",
            kind: .onDevice,
            parameters: "3.8 billion parameters",
            quantization: "4-bit",
            size: "2.2 GB download",
            downloadBytes: 2_177_574_851,
            contextWindow: "128K tokens (8K on iPhone)",
            maxOutput: "About 2,700 tokens a reply",
            summary: "Strongest small reasoner: maths, logic, structured answers",
            goodAt: [
                "Reasoning-heavy questions, maths and step-by-step answers",
                "Structured output: tables, lists, outlines",
            ],
            limits: [
                "Less natural prose than Qwen3 for notes and rewrites",
                "About 24 languages",
            ],
            requirements: downloadRequirements,
            repoID: "mlx-community/Phi-4-mini-instruct-4bit",
            stopTokens: ["<|end|>"],
            runContextTokens: runContext,
            languages: ["English", "Spanish", "French", "German", "Italian", "Portuguese", "Dutch", "Japanese", "Korean",
                        "Chinese (Simplified)", "Arabic", "Russian", "Turkish", "Polish"]
        ),
        ModelCard(
            id: "mlx.qwen3-1.7b",
            name: "Qwen3 1.7B",
            maker: "Alibaba Qwen",
            kind: .onDevice,
            parameters: "1.7 billion parameters",
            quantization: "4-bit",
            size: "1.0 GB download",
            downloadBytes: 982_341_391,
            contextWindow: "32K tokens (8K on iPhone)",
            maxOutput: "About 2,700 tokens a reply",
            summary: "Small and fast, with a bigger window than Apple's model",
            goodAt: [
                "Quick summaries and rewrites of longer text",
                "Low storage and memory use",
            ],
            limits: [
                "The least capable here: keep tasks simple",
                "Synapse turns its thinking mode off so replies come straight away",
            ],
            requirements: downloadRequirements,
            repoID: "mlx-community/Qwen3-1.7B-4bit",
            stopTokens: ["<|im_end|>"],
            runContextTokens: runContext
        ),
    ]

    /// The budget for an on-device model card.
    public static func budget(for card: ModelCard) -> LocalBudget {
        isDownloadable(card) ? .context(tokens: card.runContextTokens, languages: card.languages) : .apple
    }

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
