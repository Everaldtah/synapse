import Foundation

/// Where one AI request runs.
public enum AIEngine: String, Codable, Sendable {
    /// The on-device model (Apple Intelligence). Free, private, offline, and small: about a 4,096-token window.
    case onDevice
    /// The cloud model picked in Settings: Claude subscription, Codex, or an Anthropic API key.
    case cloud
}

/// How Synapse picks between the on-device model and the cloud.
public enum AIRoutingMode: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Everyday work on device; complex work, and anything the device model can't do, in the cloud.
    case localFirst
    /// Never leave the device. Complex work runs locally with trimmed context.
    case localOnly
    /// Always the cloud (Synapse's original behaviour).
    case cloudOnly

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .localFirst: return "On-device first"
        case .localOnly: return "On-device only"
        case .cloudOnly: return "Cloud only"
        }
    }

    public var detail: String {
        switch self {
        case .localFirst: return "Transcripts, notes and writing run on this iPhone. Complex tasks go to the cloud."
        case .localOnly: return "Nothing leaves this iPhone. Complex tasks run on device with less context."
        case .cloudOnly: return "Every request goes to the cloud model."
        }
    }
}

/// The decision for one request.
public struct AIRoute: Equatable, Sendable {
    public var engine: AIEngine
    /// Why the request went where it did (shown in the UI).
    public var reason: String
    /// Whether the task is beyond the on-device model (long input, many pages, deep reasoning).
    public var complex: Bool

    public init(engine: AIEngine, reason: String, complex: Bool) {
        self.engine = engine
        self.reason = reason
        self.complex = complex
    }
}

/// How much text one on-device request can carry, in characters (English runs at roughly 3.5–4 characters a token).
public struct LocalBudget: Equatable, Sendable {
    /// Instructions + prompt for tasks with short replies (summaries, action items).
    public var prompt: Int
    /// Input for rewrites, which reply with about as much text as they're given.
    public var rewrite: Int
    /// Page context sent along with a selection.
    public var pageContext: Int
    /// Workspace sources for Ask.
    public var ask: Int
    /// Languages it writes well, by the names in the Translate menu; nil means all of them.
    public var languages: Set<String>?

    public init(prompt: Int, rewrite: Int, pageContext: Int, ask: Int, languages: Set<String>? = nil) {
        self.prompt = prompt
        self.rewrite = rewrite
        self.pageContext = pageContext
        self.ask = ask
        self.languages = languages
    }

    /// Apple's on-device model: a 4,096-token window shared by prompt and reply.
    public static let apple = LocalBudget(prompt: AIRouter.localPromptBudget, rewrite: AIRouter.localRewriteBudget,
                                          pageContext: AIRouter.localPageContext, ask: AIRouter.localAskBudget,
                                          languages: AIRouter.localLanguages)

    /// A downloaded model run with a `tokens` context (prompt + reply), at a conservative 3.5 characters a token.
    public static func context(tokens: Int, languages: Set<String>? = nil) -> LocalBudget {
        let chars = Int(Double(tokens) * 3.5)
        return LocalBudget(prompt: chars * 7 / 10, rewrite: chars * 4 / 10, pageContext: chars / 4, ask: chars / 2, languages: languages)
    }
}

/// Picks the engine for each request. Pure logic, so it is unit-tested on Linux.
public enum AIRouter {
    /// Characters of instructions + prompt the on-device model takes in one request. Its window is about 4,096 tokens
    /// shared with the reply, and English runs at roughly 3.5–4 characters a token.
    public static let localPromptBudget = 7_000
    /// Rewrites reply with about as much text as they were given, so they get half the window.
    public static let localRewriteBudget = 4_000
    /// Page context sent along with an on-device request.
    public static let localPageContext = 2_500
    /// Workspace sources for Ask when it runs on device.
    public static let localAskBudget = 5_000

    /// Languages the on-device model writes well (Apple Intelligence languages). Others go to the cloud.
    public static let localLanguages: Set<String> = [
        "English", "Spanish", "French", "German", "Italian", "Portuguese", "Dutch", "Japanese", "Korean",
        "Chinese (Simplified)", "Turkish",
    ]

    /// Words in a free-form instruction that signal work for a bigger model.
    static let complexSignals = [
        "analy", "reason", "step by step", "prove", "proof", "derive", "calculate", "code", "debug", "refactor",
        "algorithm", "research", "compare", "evaluate", "critique", "strategy", "plan for", "architecture",
        "legal", "contract", "financial", "diagnos", "in depth", "in-depth", "detailed report", "essay",
    ]

    /// Whether an editor action is too much for the on-device model.
    /// - Parameters:
    ///   - inputCharacters: the selection (or the page when there's no selection).
    ///   - extraCharacters: anything else the prompt must carry, such as the page titles for link suggestions.
    ///   - budget: what the on-device model in use can take.
    public static func complexity(of action: AIAction, inputCharacters: Int, extraCharacters: Int = 0,
                                  instruction: String = "", language: String = "", budget: LocalBudget = .apple) -> String? {
        let rewrites: Set<AIAction> = [.improve, .fixGrammar, .shorter, .longer, .simplify, .toneProfessional, .toneCasual,
                                       .toneFriendly, .toneConfident, .translate, .continueWriting]
        let limit = rewrites.contains(action) ? budget.rewrite : budget.prompt
        if inputCharacters + extraCharacters > limit {
            return "Too long for the on-device model"
        }
        switch action {
        case .suggestLinks where extraCharacters > budget.prompt / 2:
            return "Many pages to compare"
        case .translate where !language.isEmpty && !(budget.languages ?? [language]).contains(language):
            return "\(language) isn't an on-device language"
        case .custom:
            let lower = instruction.lowercased()
            if complexSignals.contains(where: { lower.contains($0) }) { return "Needs deeper reasoning" }
            if instruction.count > 600 { return "Long instructions" }
        default:
            break
        }
        return nil
    }

    /// The engine for a request given its complexity and what is set up.
    /// - Parameters:
    ///   - complexReason: from `complexity(of:…)`, or your own reason; nil for everyday work.
    ///   - localReady: the on-device model is available right now.
    ///   - cloudReady: a cloud provider is connected.
    public static func route(complexReason: String?, mode: AIRoutingMode, localReady: Bool, cloudReady: Bool) -> AIRoute {
        let complex = complexReason != nil
        switch mode {
        case .cloudOnly:
            return AIRoute(engine: .cloud, reason: "Cloud only", complex: complex)
        case .localOnly:
            return AIRoute(engine: .onDevice, reason: complexReason.map { "\($0) — kept on device" } ?? "On device", complex: complex)
        case .localFirst:
            if !localReady {
                return AIRoute(engine: cloudReady ? .cloud : .onDevice, reason: "On-device model unavailable", complex: complex)
            }
            if let complexReason, cloudReady {
                return AIRoute(engine: .cloud, reason: complexReason, complex: true)
            }
            return AIRoute(engine: .onDevice, reason: complex ? "\(complexReason!) — no cloud model connected" : "Everyday task", complex: complex)
        }
    }

    /// Ask (questions over many pages) is the one task that is always complex.
    public static let askComplexReason = "Questions across your workspace"
}
