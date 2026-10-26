import SwiftUI
import SynapseKit

/// One step of an agent run, for the steps list.
struct AgentStep: Identifiable, Equatable {
    let id = UUID()
    var call: AgentToolCall
    var output: String?
    var failed = false
    /// Steps the harness took inside a `claude_code` call.
    var inner: [String] = []
    var running: Bool { output == nil }
}

/// Runs the tool-using agent (`Agent.run`) with any model: offers the tools that are set up and allowed, executes
/// calls (web on the iPhone; shell and Claude Code in the bridge's sandbox; the attached sources), and reports steps.
@MainActor
final class AgentRunner {
    let ai: AIService
    let sources: [NotesSource]
    /// Original files, copied into the sandbox the first time a shell or Claude Code call needs them.
    let files: [URL]
    private var uploaded = false
    private var sharedWithPhone = false

    init(ai: AIService, sources: [NotesSource] = [], files: [URL] = []) {
        self.ai = ai
        self.sources = sources
        self.files = files
    }

    var webAvailable: Bool { ai.agentWeb }
    var pcShell: Bool { ai.agentShell && ai.bridgeSandbox?.available == true && ai.bridgeEndpoint != nil }
    var phoneShell: Bool { ai.agentShell && ai.linux.isInstalled }
    var shellAvailable: Bool { pcShell || phoneShell }
    var harnessAvailable: Bool { ai.agentHarness && ai.bridgeHarness?.loggedIn == true && ai.bridgeEndpoint != nil }

    func tools(web: Bool = true) -> [AgentToolSpec] {
        var t: [AgentToolSpec] = []
        if web && webAvailable { t += [.webSearch, .fetchURL] }
        let targets = (phoneShell ? ["iphone"] : []) + (pcShell ? ["pc"] : [])
        if !targets.isEmpty { t.append(.shell(targets: targets)) }
        if harnessAvailable { t.append(.claudeCode) }
        if !sources.isEmpty { t.append(.readSource) }
        return t
    }

    /// Small windows get fewer calls and shorter results.
    func limits(for choice: ModelChoice) -> (calls: Int, result: Int) {
        let prompt = ai.budget(for: choice).prompt
        if prompt <= LocalBudget.apple.prompt { return (3, 1_200) }
        if prompt < 50_000 { return (4, 3_000) }
        return (6, 8_000)
    }

    /// Run a request with tools; `steps` is updated as the agent works.
    func run(_ request: AIRequest, choice: ModelChoice, tools: [AgentToolSpec], steps: Binding<[AgentStep]>) async throws -> String {
        let (calls, result) = limits(for: choice)
        let ai = self.ai
        return try await Agent.run(request, tools: tools, maxCalls: calls, resultLimit: result, complete: { req in
            try await ai.complete(req, choice: choice, fallback: false)
        }, execute: { call in
            let index = steps.wrappedValue.lastIndex { $0.call == call && $0.running }
            return try await self.execute(call, limit: result) { line in
                if let index, index < steps.wrappedValue.count { steps.wrappedValue[index].inner.append(line) }
            }
        }, event: { event in
            switch event {
            case .calling(let call):
                steps.wrappedValue.append(AgentStep(call: call))
            case .result(let call, let output, let failed):
                if let i = steps.wrappedValue.lastIndex(where: { $0.call == call && $0.running }) {
                    steps.wrappedValue[i].output = output
                    steps.wrappedValue[i].failed = failed
                }
            case .answer:
                break
            }
        })
    }

    func execute(_ call: AgentToolCall, limit: Int, progress: @escaping (String) -> Void) async throws -> String {
        switch call.name {
        case AgentToolSpec.webSearch.name:
            return WebSearchParse.format(try await WebTools.search(call.input))
        case AgentToolSpec.fetchURL.name:
            return try await WebTools.fetch(call.input, limit: max(limit * 3, 8_000))
        case "shell":
            // where="iphone" (or no computer sandbox) runs on the phone; otherwise on the computer.
            let onPhone = phoneShell && (call.attributes["where"] == "iphone" || !pcShell)
            if onPhone {
                if !sharedWithPhone { ai.linux.share(files); sharedWithPhone = true }
                progress("Linux on this iPhone")
                return try await ai.linux.run(call.input, timeout: 180)
            }
            guard let bridge = ai.bridgeEndpoint, pcShell else { throw AIError(message: "No Linux shell is set up.") }
            try await uploadFiles(bridge)
            return try await bridge.shell(call.input, timeout: 180).summary
        case AgentToolSpec.claudeCode.name:
            guard let bridge = ai.bridgeEndpoint, harnessAvailable else { throw AIError(message: "The Claude Code harness isn't available.") }
            try await uploadFiles(bridge)
            return try await bridge.harness(prompt: call.input, system: nil, model: "default") { event in
                switch event {
                case .tool(let name, let input): progress("\(name): \(input)")
                case .toolResult(let name, _, let isError): if isError { progress("\(name) failed") }
                default: break
                }
            }
        case AgentToolSpec.readSource.name:
            let wanted = call.input.lowercased()
            guard let source = sources.first(where: { $0.name.lowercased() == wanted })
                    ?? sources.first(where: { $0.name.lowercased().contains(wanted) || wanted.contains($0.name.lowercased()) }) else {
                return "No attached source is called \(call.input). Attached: " + sources.map(\.name).joined(separator: ", ")
            }
            return source.text
        default:
            throw AIError(message: "Unknown tool \(call.name).")
        }
    }

    private func uploadFiles(_ bridge: BridgeTools) async throws {
        guard !uploaded, !files.isEmpty else { return }
        uploaded = true
        for file in files { _ = try? await bridge.upload(file) }
    }
}

/// The steps an agent took: searches, pages read, commands and their output.
struct AgentStepsView: View {
    let steps: [AgentStep]
    @State private var expanded: Set<UUID> = []

    var body: some View {
        if !steps.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(steps) { step in
                    VStack(alignment: .leading, spacing: 4) {
                        Button {
                            if expanded.contains(step.id) { expanded.remove(step.id) } else { expanded.insert(step.id) }
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: Self.symbol(step.call)).frame(width: 18).foregroundStyle(Palette.accent)
                                Text(Self.title(step.call)).font(.caption.weight(.medium)).lineLimit(expanded.contains(step.id) ? nil : 2)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 4)
                                if step.running {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: step.failed ? "exclamationmark.triangle" : (expanded.contains(step.id) ? "chevron.up" : "chevron.down"))
                                        .font(.caption2).foregroundStyle(step.failed ? Color.orange : Color.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        if !step.inner.isEmpty && (step.running || expanded.contains(step.id)) {
                            ForEach(Array(step.inner.suffix(8).enumerated()), id: \.offset) { _, line in
                                Text("↳ " + line).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(2).padding(.leading, 26)
                            }
                        }
                        if expanded.contains(step.id), let output = step.output {
                            Text(String(output.prefix(4_000)))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(UIColor.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
            .padding(10)
            .background(Color(UIColor.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    static func symbol(_ call: AgentToolCall) -> String {
        switch call.name {
        case "web_search": return "magnifyingglass"
        case "fetch_url": return "globe"
        case "shell": return "terminal"
        case "claude_code": return "sparkles.rectangle.stack"
        case "read_source": return "doc.text.magnifyingglass"
        default: return "wrench.and.screwdriver"
        }
    }

    static func title(_ call: AgentToolCall) -> String {
        switch call.name {
        case "web_search": return "Searched the web: \(call.input)"
        case "fetch_url": return "Read \(call.input)"
        case "shell": return "\(call.attributes["where"] == "iphone" ? "iPhone" : "Computer") $ \(call.input)"
        case "claude_code": return "Claude Code: \(call.input)"
        case "read_source": return "Read source: \(call.input)"
        default: return "\(call.name): \(call.input)"
        }
    }
}
