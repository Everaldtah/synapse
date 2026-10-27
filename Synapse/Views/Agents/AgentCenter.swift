import Foundation
import Observation
import SynapseKit
import UIKit

/// A change waiting for the user's OK (agents set to ask before changes).
struct PendingApproval: Identifiable {
    let id = UUID()
    var call: AgentToolCall
    var agentName: String
    var resume: (_ allowed: Bool, _ allowAll: Bool) -> Void
}

/// The live state of one chat while its agent works.
@MainActor
@Observable
final class AgentSession {
    let id: UUID
    var running = false
    var status = ""
    var steps: [AgentStep] = []
    /// The reply as it streams (hidden while the model is writing tool calls).
    var liveText = ""
    var approval: PendingApproval?
    /// The user tapped "Allow all" for this run.
    var allowAll = false
    /// This run changed the workspace.
    var changed = false
    /// Pages and databases this run created (for "open" chips).
    var touched: Set<UUID> = []
    @ObservationIgnored var task: Task<Void, Never>?

    init(id: UUID) { self.id = id }

    /// Wait for the user to allow or decline a change.
    func ask(_ call: AgentToolCall, agent: AgentProfile) async -> Bool {
        await withCheckedContinuation { continuation in
            approval = PendingApproval(call: call, agentName: agent.name) { [weak self] allowed, all in
                self?.approval = nil
                if all { self?.allowAll = true }
                continuation.resume(returning: allowed)
            }
        }
    }

    func reset() {
        status = ""
        steps = []
        liveText = ""
        allowAll = false
        changed = false
        touched = []
    }
}

/// A file the user picked, waiting to be sent.
struct AgentAttachmentDraft: Identifiable, Hashable {
    var id: UUID { file.id }
    var file: AgentFile
    var url: URL { AgentFileStore.url(for: file) }
}

/// Agents and their chats: persistence, running turns, delegation and undo.
///
/// Storage: `Documents/Synapse/agents/profiles.json` and `chats/<uuid>.json`; files in `Agent Files/`.
@MainActor
@Observable
final class AgentCenter {
    private(set) var profiles: [AgentProfile] = []
    /// Newest first.
    private(set) var conversations: [AgentConversation] = []
    @ObservationIgnored private var sessions: [UUID: AgentSession] = [:]
    /// Pages as they were before a run changed them (nil = the run created it), by answer message id.
    @ObservationIgnored private var undoSnapshots: [UUID: [UUID: Page?]] = [:]
    /// Attachments read this launch, by file id (so later turns can read_source them in full).
    @ObservationIgnored private var sourceCache: [UUID: NotesSource] = [:]

    private let root: URL
    private var chatsDir: URL { root.appendingPathComponent("chats", isDirectory: true) }
    private var profilesURL: URL { root.appendingPathComponent("profiles.json") }

    init() {
        root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Synapse/agents", isDirectory: true)
        try? FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)
        load()
    }

    // MARK: - Profiles

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var saved = (try? Data(contentsOf: profilesURL)).flatMap { try? decoder.decode([AgentProfile].self, from: $0) } ?? []
        // New built-in agents appear after an update; edited ones keep the user's version.
        for preset in AgentPresets.all where !saved.contains(where: { $0.id == preset.id }) {
            saved.insert(preset, at: min(saved.count, AgentPresets.all.firstIndex(of: preset) ?? saved.count))
        }
        profiles = saved
        let files = (try? FileManager.default.contentsOfDirectory(at: chatsDir, includingPropertiesForKeys: nil)) ?? []
        conversations = files.filter { $0.pathExtension == "json" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? decoder.decode(AgentConversation.self, from: $0) } }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func saveProfiles() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(profiles).write(to: profilesURL, options: .atomic)
    }

    func profile(_ id: UUID) -> AgentProfile? { profiles.first { $0.id == id } }

    func save(_ profile: AgentProfile) {
        if let i = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[i] = profile } else { profiles.append(profile) }
        saveProfiles()
    }

    func delete(_ profile: AgentProfile) {
        guard !profile.builtIn else { return }
        profiles.removeAll { $0.id == profile.id }
        saveProfiles()
    }

    /// Put a built-in agent back the way it shipped.
    func reset(_ profile: AgentProfile) {
        guard let original = AgentPresets.all.first(where: { $0.id == profile.id }) else { return }
        save(original)
    }

    func duplicate(_ profile: AgentProfile) -> AgentProfile {
        var copy = profile
        copy.id = UUID()
        copy.name = profile.name + " copy"
        copy.builtIn = false
        copy.createdAt = Date()
        save(copy)
        return copy
    }

    // MARK: - Chats

    func conversation(_ id: UUID) -> AgentConversation? { conversations.first { $0.id == id } }

    func newConversation(agent: UUID) -> UUID {
        let c = AgentConversation(agentID: agent)
        conversations.insert(c, at: 0)
        return c.id
    }

    func update(_ id: UUID, _ change: (inout AgentConversation) -> Void) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        change(&conversations[i])
        conversations[i].updatedAt = Date()
        persist(conversations[i])
    }

    private func persist(_ c: AgentConversation) {
        guard !c.messages.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let url = chatsDir.appendingPathComponent(c.id.uuidString + ".json")
        if let data = try? encoder.encode(c) {
            Task.detached(priority: .utility) { try? data.write(to: url, options: .atomic) }
        }
    }

    func delete(conversation id: UUID) {
        stop(id)
        conversations.removeAll { $0.id == id }
        sessions[id] = nil
        try? FileManager.default.removeItem(at: chatsDir.appendingPathComponent(id.uuidString + ".json"))
    }

    func session(_ id: UUID) -> AgentSession {
        if let s = sessions[id] { return s }
        let s = AgentSession(id: id)
        sessions[id] = s
        return s
    }

    var running: Bool { sessions.values.contains { $0.running } }

    func stop(_ id: UUID) {
        guard let s = sessions[id] else { return }
        s.approval?.resume(false, false)
        s.task?.cancel()
    }

    // MARK: - Undo

    func canUndo(_ messageID: UUID) -> Bool { undoSnapshots[messageID] != nil }

    /// How many pages an undo would put back.
    func undoCount(_ messageID: UUID) -> Int { undoSnapshots[messageID]?.count ?? 0 }

    /// Put back every page the run changed (and remove the ones it created).
    func undo(_ messageID: UUID, in conversationID: UUID, store: WorkspaceStore) {
        guard let before = undoSnapshots.removeValue(forKey: messageID) else { return }
        store.mutate { ws in
            for (id, page) in before { ws.pages[id] = page }
        }
        update(conversationID) { c in
            if let i = c.messages.firstIndex(where: { $0.id == messageID }) { c.messages[i].changedWorkspace = false }
            c.messages.append(AgentChatMessage(role: .assistant, text: "_Undid the changes from that reply (\(before.count) page\(before.count == 1 ? "" : "s"))._"))
        }
    }

    // MARK: - Running a turn

    /// Run limits for a model, by how much its window holds.
    struct Limits {
        var small: Bool
        var steps: Int
        var callsPerReply: Int
        var result: Int
        var context: Int
        var history: Int
    }

    func limits(for budget: LocalBudget, agent: AgentProfile, systemLength: Int) -> Limits {
        let room = max(3_000, budget.prompt - systemLength - 500)
        if budget.prompt <= LocalBudget.apple.prompt {
            return Limits(small: true, steps: min(agent.maxSteps, 4), callsPerReply: 1, result: 800, context: room, history: 2)
        }
        if budget.prompt <= 40_000 {
            return Limits(small: true, steps: min(agent.maxSteps, 8), callsPerReply: 2, result: 1_500, context: room, history: 4)
        }
        return Limits(small: false, steps: agent.maxSteps, callsPerReply: 6, result: budget.prompt >= 300_000 ? 12_000 : 8_000,
                      context: min(room, 500_000), history: 16)
    }

    /// The model a chat runs on: its own choice, else the agent's, else Auto (when the stored one isn't available).
    func choice(for conversation: AgentConversation, agent: AgentProfile, ai: AIService) -> ModelChoice {
        let stored = ModelChoice(key: conversation.model ?? agent.model)
        var c = ai.isAvailable(stored) ? stored : .auto
        if c == .auto && !ai.isConfigured {
            // Agents need more than the on-device window: with no cloud model set, use an API provider the user
            // added (the last one used, else the first with a key). Keyless providers are only used when picked.
            let apis = APIProviderStore.shared
            if let last = apis.lastUsed, apis.isReady(last.provider) {
                c = .api(last.provider, last.model)
            } else if let p = apis.readyProviders.first(where: { apis.hasKey($0.id) }), let m = apis.favoriteModels(for: p.id).first {
                c = .api(p.id, m.id)
            }
        }
        return ai.concrete(c, complexReason: "agent")
    }

    /// Send a message to a chat's agent and run it until it answers.
    func send(_ text: String, attachments: [AgentAttachmentDraft], to id: UUID, ai: AIService, store: WorkspaceStore, app: AppModel) {
        guard let convo = conversation(id), let agent = profile(convo.agentID) else { return }
        let session = self.session(id)
        guard !session.running else { return }
        let user = AgentChatMessage(role: .user, text: text, files: attachments.map(\.file))
        update(id) { c in
            c.messages.append(user)
            if c.title.isEmpty { c.title = AgentConversation.title(from: text.isEmpty ? (attachments.first?.file.name ?? "Files") : text) }
        }
        session.reset()
        session.running = true
        session.status = attachments.isEmpty ? "Thinking…" : "Reading attachments…"
        let background = UIApplication.shared.beginBackgroundTask(withName: "agent") {}

        session.task = Task { @MainActor in
            defer {
                session.running = false
                session.status = ""
                session.liveText = ""
                if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
            }
            // 1. Read the attachments.
            var images: [String] = []
            var newSources: [NotesSource] = []
            for draft in attachments {
                session.status = "Reading \(draft.file.name)…"
                let (source, image) = await self.read(draft, ai: ai, session: session)
                if let source { newSources.append(source); self.sourceCache[draft.file.id] = source }
                if let image { images.append(image) }
            }
            let choice = self.choice(for: self.conversation(id) ?? convo, agent: agent, ai: ai)
            let budget = ai.budget(for: choice)
            let attachmentText = Self.attachmentPrompt(newSources, budget: budget.prompt / 3)
            if !attachmentText.isEmpty {
                self.update(id) { c in
                    if let i = c.messages.firstIndex(where: { $0.id == user.id }) { c.messages[i].attachmentText = attachmentText }
                }
            }

            // 2. The request: system, recent history, the new message.
            let small = budget.prompt <= 40_000
            let system = AgentToolCatalog.system(for: agent, workspaceName: store.name, small: small)
            let previewTools = AgentToolCatalog.appTools(for: agent.capabilities, small: small)
            let limits = self.limits(for: budget, agent: agent, systemLength: system.count + Agent.instructions(tools: previewTools, maxCalls: 1, compact: small).count)
            let all = (self.conversation(id)?.messages ?? []).filter { !$0.failed && !($0.text.isEmpty && $0.files.isEmpty) }
            let history = all.dropLast().suffix(limits.history).map {
                AIMessage(role: $0.role == .user ? .user : .assistant, content: Agent.truncate($0.promptText, limit: max(1_500, limits.context / 6)))
            }
            let current = AIMessage(role: .user, content: (text.isEmpty ? "(See the attached files.)" : text) + (attachmentText.isEmpty ? "" : "\n\n" + attachmentText))
            let request = AIRequest(system: system, messages: Self.alternating(Array(history) + [current]))

            // 3. Tools: every file attached in this chat goes to the shells; read_source covers this launch's attachments.
            let chatFiles = (self.conversation(id)?.messages ?? []).filter { $0.role == .user }.flatMap(\.files)
            let sources = chatFiles.compactMap { self.sourceCache[$0.id] }
            let toolbox = AgentToolbox(agent: agent, ai: ai, store: store, app: app, center: self, session: session, choice: choice,
                                       sources: sources, files: chatFiles.map(AgentFileStore.url(for:)))
            let tools = toolbox.tools(small: limits.small)
            let before = store.workspace.pages
            let answerID = UUID()
            let model = ai.name(for: choice)
            session.status = "\(model) is thinking…"
            do {
                let answer = try await self.loop(request, tools: tools, toolbox: toolbox, choice: choice, limits: limits, images: images, ai: ai, session: session)
                let changes = Self.diff(before, store.workspace.pages)
                if !changes.isEmpty { self.undoSnapshots[answerID] = changes }
                self.update(id) { c in
                    c.messages.append(AgentChatMessage(id: answerID, role: .assistant, text: answer, files: toolbox.produced,
                                                       steps: session.steps.map(Self.record), model: model, changedWorkspace: !changes.isEmpty))
                }
            } catch {
                let changes = Self.diff(before, store.workspace.pages)
                if !changes.isEmpty { self.undoSnapshots[answerID] = changes }
                let stopped = error is CancellationError
                self.update(id) { c in
                    c.messages.append(AgentChatMessage(id: answerID, role: .assistant,
                                                       text: stopped ? "_Stopped._" : "⚠️ " + error.localizedDescription,
                                                       files: toolbox.produced, steps: session.steps.map(Self.record), model: model,
                                                       failed: !stopped, changedWorkspace: !changes.isEmpty))
                }
            }
        }
    }

    /// One agent loop with streaming, steps and approvals reported to `session`.
    private func loop(_ request: AIRequest, tools: [AgentToolSpec], toolbox: AgentToolbox, choice: ModelChoice, limits: Limits,
                      images: [String], ai: AIService, session: AgentSession, stepPrefix: String = "") async throws -> String {
        let firstCount = request.messages.count
        return try await Agent.run(request, tools: tools, maxCalls: limits.steps, resultLimit: limits.result,
                                   callsPerReply: limits.callsPerReply, contextLimit: limits.context, compactTools: limits.small,
                                   complete: { req in
            var out = ""
            let stream: AsyncThrowingStream<String, Error>
            if case .api(let p, let m) = choice {
                // Images go with the first request of the run (each request is sent whole); a browser screenshot
                // goes with the request after the action that took it, when the model can see.
                var sent = req.messages.count == firstCount ? images : []
                if APIProviderStore.shared.supportsVision(provider: p, model: m), let shot = AgentBrowser.shared.takeScreenshot() { sent.append(shot) }
                stream = APIProviderStore.shared.stream(req, provider: p, model: m, images: sent, tools: tools)
            } else {
                stream = ai.stream(req, choice: choice, fallback: false)
            }
            if stepPrefix.isEmpty { session.liveText = "" }
            for try await chunk in stream {
                out += chunk
                if stepPrefix.isEmpty { session.liveText = out.contains("<tool") ? "" : out }
            }
            return out
        }, execute: { call in
            if stepPrefix.isEmpty { session.status = AgentStepsView.title(call) }
            let index = session.steps.lastIndex { $0.call == call && $0.running }
            return try await toolbox.execute(call, limit: limits.result) { line in
                if let index, index < session.steps.count { session.steps[index].inner.append(line) }
            }
        }, event: { event in
            guard stepPrefix.isEmpty else { return }
            switch event {
            case .note(let n): session.status = n
            case .calling(let call): session.steps.append(AgentStep(call: call))
            case .result(let call, let output, let failed):
                if let i = session.steps.lastIndex(where: { $0.call == call && $0.running }) {
                    session.steps[i].output = output
                    session.steps[i].failed = failed
                }
            case .answer: session.liveText = ""
            }
        })
    }

    /// Run another agent on a sub-task (from `ask_agent`): its own model when it has one, else the caller's.
    func runSubagent(_ agent: AgentProfile, task: String, parent: AgentToolbox, progress: @escaping (String) -> Void) async throws -> (answer: String, files: [AgentFile]) {
        let ai = parent.ai
        let stored = ModelChoice(key: agent.model)
        let choice = stored != .auto && ai.isAvailable(stored) ? ai.concrete(stored) : parent.choice
        let budget = ai.budget(for: choice)
        let small = budget.prompt <= 40_000
        let system = AgentToolCatalog.system(for: agent, workspaceName: parent.store.name, small: small)
            + "\n\nAnother agent (\(parent.agent.name)) gave you this task. Do it and reply with the result it needs."
        var limits = self.limits(for: budget, agent: agent, systemLength: system.count + 4_000)
        limits.steps = min(limits.steps, 16)
        let toolbox = AgentToolbox(agent: agent, ai: ai, store: parent.store, app: parent.app, center: self, session: parent.session,
                                   choice: choice, sources: parent.runner.sources, files: parent.runner.files, depth: parent.depth + 1)
        let tools = toolbox.tools(small: limits.small)
        // Its steps show as lines under the ask_agent step.
        let answer = try await Agent.run(AIRequest(system: system, messages: [AIMessage(role: .user, content: task)]), tools: tools,
                                         maxCalls: limits.steps, resultLimit: limits.result, callsPerReply: limits.callsPerReply,
                                         contextLimit: limits.context, compactTools: limits.small, complete: { req in
            try await ai.complete(req, choice: choice, fallback: false)
        }, execute: { call in
            progress(AgentStepsView.title(call))
            return try await toolbox.execute(call, limit: limits.result) { progress("  " + $0) }
        })
        return (answer, toolbox.produced)
    }

    // MARK: - Attachments

    /// Text (and for photos a downscaled JPEG for vision models) from an attached file.
    private func read(_ draft: AgentAttachmentDraft, ai: AIService, session: AgentSession) async -> (NotesSource?, String?) {
        let url = draft.url
        let name = draft.file.name
        do {
            switch draft.file.kind {
            case .audio, .video:
                session.status = "Transcribing \(name)…"
                let text: String
                if ai.bridgeWhisper?.available == true, let bridge = ai.bridgeEndpoint {
                    text = try await bridge.transcribe(url, language: nil) { label, _ in session.status = label }
                } else if let provider = APIProviderStore.shared.transcriptionProviders.first {
                    text = try await APIProviderStore.shared.transcribe(url, provider: provider.id)
                } else {
                    let locale = await Transcriber.defaultLocale() ?? Locale.current
                    text = try await Transcriber.transcribe(url, locale: locale) { label, _ in session.status = label }
                }
                return (NotesSource(name: name, kind: .audio, text: text), nil)
            case .image:
                let ocr = (try? await SourceExtractor.extract(url, bridge: nil).text) ?? ""
                return (NotesSource(name: name, kind: .image, text: ocr.isEmpty ? "(a photo with no readable text)" : ocr), Self.jpegBase64(url))
            default:
                let r = try await SourceExtractor.extract(url, bridge: ai.bridgeEndpoint) { session.status = $0 }
                return (NotesSource(name: name, kind: r.kind, text: r.text), nil)
            }
        } catch {
            return (NotesSource(name: name, kind: .document, text: "(Synapse couldn't read this file: \(error.localizedDescription). The shell can still open it in files/.)"), nil)
        }
    }

    static func jpegBase64(_ url: URL, maxSide: CGFloat = 1_280) -> String? {
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let resized = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return resized.jpegData(compressionQuality: 0.8)?.base64EncodedString()
    }

    /// The attachments as the model sees them, within `budget` characters.
    static func attachmentPrompt(_ sources: [NotesSource], budget: Int) -> String {
        guard !sources.isEmpty else { return "" }
        let each = max(600, budget / sources.count)
        let parts = sources.map { s -> String in
            let body = s.text.count > each ? Agent.truncate(s.text, limit: each) + "\n(Shortened — use read_source for all of it.)" : s.text
            return "=== Attached \(s.kind.label.lowercased()): \(s.name) ===\n\(body)"
        }
        return "ATTACHED FILES (also in files/ for the shell)\n" + parts.joined(separator: "\n\n")
    }

    // MARK: - Helpers

    /// Merge consecutive same-role messages (some providers reject them) and start with the user.
    static func alternating(_ messages: [AIMessage]) -> [AIMessage] {
        var out: [AIMessage] = []
        for m in messages {
            if let last = out.last, last.role == m.role {
                out[out.count - 1].content += "\n\n" + m.content
            } else {
                out.append(m)
            }
        }
        while out.first?.role == .assistant { out.removeFirst() }
        return out
    }

    static func diff(_ before: [UUID: Page], _ after: [UUID: Page]) -> [UUID: Page?] {
        var out: [UUID: Page?] = [:]
        for (id, page) in after where before[id] != page { out[id] = .some(before[id]) }
        for (id, page) in before where after[id] == nil { out[id] = .some(page) }
        return out
    }

    static func record(_ step: AgentStep) -> AgentStepRecord {
        AgentStepRecord(tool: step.call.name, input: step.call.input, attributes: step.call.attributes, output: step.output ?? "",
                        failed: step.failed, inner: step.inner)
    }

    /// A saved message's steps, with ids that stay the same between renders (so expanded rows stay open).
    static func steps(of message: AgentChatMessage) -> [AgentStep] {
        message.steps.enumerated().map { i, r in
            var u = message.id.uuid
            u.14 ^= UInt8((i >> 8) & 0xff)
            u.15 ^= UInt8(i & 0xff)
            return AgentStep(id: UUID(uuid: u), call: r.call, output: r.output, failed: r.failed, inner: r.inner)
        }
    }
}
