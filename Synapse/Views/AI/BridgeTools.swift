import Foundation
import SynapseKit

/// The bridge's tool endpoints: the Linux sandbox (shell, files, any-file-to-text), Whisper transcription on the
/// computer's GPU, and the Claude Code harness. See bridge/README.md for the wire format.
struct BridgeTools {
    let base: URL
    let token: String

    struct ShellResult: Decodable {
        var stdout: String
        var stderr: String
        var exitCode: Int?
        var timedOut: Bool?
        var durationMs: Int?

        /// What a model sees.
        var summary: String {
            var parts: [String] = []
            if !stdout.isEmpty { parts.append(stdout) }
            if !stderr.isEmpty { parts.append("[stderr]\n" + stderr) }
            if timedOut == true { parts.append("[timed out]") }
            if let code = exitCode, code != 0 { parts.append("[exit code \(code)]") }
            return parts.isEmpty ? "(no output, exit code \(exitCode ?? 0))" : parts.joined(separator: "\n")
        }
    }

    /// A step the harness took, for the steps list.
    enum HarnessEvent {
        case model(String)
        case text(String)
        case tool(name: String, input: String)
        case toolResult(name: String, output: String, isError: Bool)
    }

    // MARK: Requests

    private func request(_ path: String, method: String = "POST", timeout: TimeInterval = 600) -> URLRequest {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }

    /// Headers must be ASCII; keep the name readable and the extension intact.
    static func headerSafe(_ name: String) -> String {
        let mapped = name.unicodeScalars.map { $0.isASCII && $0.value >= 32 && $0 != "\"" ? String($0) : "_" }.joined()
        return mapped.isEmpty ? "file" : mapped
    }

    private func fileRequest(_ path: String, file: URL, timeout: TimeInterval = 900) throws -> URLRequest {
        var req = request(path, timeout: timeout)
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        req.httpBodyStream = InputStream(url: file)
        req.setValue(String(size), forHTTPHeaderField: "Content-Length")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.headerSafe(file.lastPathComponent), forHTTPHeaderField: "X-Filename")
        return req
    }

    private func json<T: Decodable>(_ req: URLRequest, as type: T.Type) async throws -> T {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw AIError(message: Self.failure(code: code, body: data)) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func failure(code: Int, body: Data) -> String {
        let text = String(data: body, encoding: .utf8) ?? ""
        let message = BridgeClient.message(from: text)
        switch code {
        case 401: return "The bridge rejected the pairing token. Pair again in Settings."
        case 404: return "The bridge on your computer is older than this app. Update it (git pull) and restart it."
        case 429: return "The bridge is busy with another task. Try again in a moment."
        case 503: return message.isEmpty ? "That isn't set up on the bridge computer yet." : message
        default: return "Bridge error \(code): \(message)"
        }
    }

    // MARK: Sandbox

    /// Run a bash command in the sandbox (as an unprivileged user, in the work folder; attached files are in files/).
    func shell(_ command: String, timeout: Int = 120) async throws -> ShellResult {
        var req = request("v1/shell", timeout: TimeInterval(timeout + 15))
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["command": command, "timeout": timeout])
        return try await json(req, as: ShellResult.self)
    }

    /// Copy a file into the sandbox's files/ folder; returns its path there.
    func upload(_ file: URL) async throws -> String {
        struct Saved: Decodable { var path: String }
        return try await json(try fileRequest("v1/files", file: file), as: Saved.self).path
    }

    /// Download a file from the sandbox workspace (a path relative to it, as the shell sees it) into `folder`;
    /// returns the saved file (named as in the sandbox, made unique in `folder`).
    func download(_ path: String, into folder: URL) async throws -> URL {
        var comps = URLComponents(url: base.appendingPathComponent("v1/files"), resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "path", value: path)]
        guard let url = comps?.url else { throw AIError(message: "Bad file path.") }
        var req = request("v1/files", method: "GET", timeout: 600)
        req.url = url
        let (tmp, resp) = try await URLSession.shared.download(for: req)
        let http = resp as? HTTPURLResponse
        guard http?.statusCode == 200 else {
            let body = (try? Data(contentsOf: tmp)) ?? Data()
            throw AIError(message: Self.failure(code: http?.statusCode ?? 0, body: body))
        }
        let name = (http?.value(forHTTPHeaderField: "X-Filename")?.removingPercentEncoding).flatMap { $0.isEmpty ? nil : $0 }
            ?? (path as NSString).lastPathComponent
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = AgentFileStore.uniqueURL(in: folder, name: name)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    /// Any file to text with the sandbox's converters (pandoc, LibreOffice, pdftotext, tesseract…).
    func extract(_ file: URL) async throws -> (text: String, method: String) {
        struct Extracted: Decodable { var text: String; var method: String? }
        let r = try await json(try fileRequest("v1/extract", file: file, timeout: 300), as: Extracted.self)
        return (r.text, r.method ?? "bridge")
    }

    // MARK: Whisper

    /// Transcribe with Whisper on the computer. Paragraphs break at pauses, like the on-device transcriber.
    func transcribe(_ file: URL, language: String?, progress: @escaping @MainActor (String, Double?) -> Void) async throws -> String {
        var req = try fileRequest("v1/transcribe", file: file, timeout: 3_600)
        if let language { req.setValue(language, forHTTPHeaderField: "X-Language") }
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        await progress("Uploading to your computer…", nil)
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            var body = Data()
            for try await b in bytes { body.append(b); if body.count > 4_000 { break } }
            throw AIError(message: Self.failure(code: code, body: body))
        }
        var duration = 0.0
        var model = "Whisper"
        var segments: [SourceText.Segment] = []
        for try await ev in SSE.events(bytes) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(ev.data.utf8)) as? [String: Any] else { continue }
            switch obj["type"] as? String {
            case "info":
                duration = obj["duration"] as? Double ?? 0
                model = "Whisper \(obj["model"] as? String ?? "") on \((obj["device"] as? String) == "cuda" ? "the GPU" : "the CPU")"
                await progress("Transcribing with \(model)…", 0)
            case "segment":
                let s = SourceText.Segment(start: obj["start"] as? Double ?? 0, end: obj["end"] as? Double ?? 0, text: obj["text"] as? String ?? "")
                segments.append(s)
                await progress("Transcribing with \(model)…", duration > 0 ? min(1, s.end / duration) : nil)
            case "error":
                throw AIError(message: obj["message"] as? String ?? "Whisper failed on the computer.")
            case "done":
                let text = SourceText.paragraphs(segments)
                if text.isEmpty { throw TranscriptionError.empty }
                return text
            default:
                break
            }
        }
        let text = SourceText.paragraphs(segments)
        if text.isEmpty { throw AIError(message: "The bridge closed the connection before the transcript finished.") }
        return text
    }

    // MARK: Claude Code harness

    /// Run a task with Claude Code in the sandbox (Claude subscription; web search, web fetch, Linux tools).
    /// Returns the final answer; `onEvent` sees each step.
    func harness(prompt: String, system: String?, model: String, maxTurns: Int = 12,
                 onEvent: @escaping @MainActor (HarnessEvent) -> Void) async throws -> String {
        try await AIConsent.ensure(
            key: "bridge.claude", service: "Claude Code on your computer",
            detail: "Synapse Bridge on your computer passes it to Claude Code, which sends it to Anthropic under your own Claude account.")
        var req = request("v1/harness", timeout: 1_900)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        var body: [String: Any] = ["prompt": prompt, "model": model, "maxTurns": maxTurns, "timeout": 900]
        if let system { body["system"] = system }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            var data = Data()
            for try await b in bytes { data.append(b); if data.count > 4_000 { break } }
            throw AIError(message: Self.failure(code: code, body: data))
        }
        var text = ""
        for try await ev in SSE.events(bytes) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(ev.data.utf8)) as? [String: Any] else { continue }
            switch obj["type"] as? String {
            case "meta":
                if let m = obj["model"] as? String { await onEvent(.model(m)) }
            case "text":
                if let t = obj["text"] as? String {
                    text += t
                    await onEvent(.text(t))
                }
            case "tool":
                await onEvent(.tool(name: obj["name"] as? String ?? "tool", input: obj["input"] as? String ?? ""))
            case "tool_result":
                await onEvent(.toolResult(name: obj["name"] as? String ?? "tool", output: obj["output"] as? String ?? "",
                                          isError: obj["isError"] as? Bool ?? false))
            case "error":
                throw AIError(message: obj["message"] as? String ?? "The harness failed.")
            case "done":
                let result = (obj["result"] as? String) ?? ""
                return result.isEmpty ? text : result
            default:
                break
            }
        }
        return text
    }

    /// The harness as a plain text engine (the final answer, streamed once it's ready).
    func harnessText(_ request: AIRequest, model: String, onModel: @escaping @MainActor (String) -> Void) -> AsyncThrowingStream<String, Error> {
        let prompt = AppleFoundationLLM.prompt(request.messages)
        let system = request.system
        let tools = self
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let answer = try await tools.harness(prompt: prompt, system: system, model: model) { event in
                        if case .model(let m) = event { onModel(m) }
                    }
                    continuation.yield(answer)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
