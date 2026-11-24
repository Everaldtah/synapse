import Foundation
import UniformTypeIdentifiers
import SynapseKit

/// Talks to any OpenAI-compatible API (`POST {baseURL}/chat/completions`, streaming): the providers in
/// `APIProviderCatalog` and the user's own servers. Reasoning is dropped, so only the answer streams.
struct OpenAICompatibleClient {
    /// Placeholders already filled, no trailing slash (e.g. "https://api.groq.com/openai/v1").
    var baseURL: String
    /// Sent as `Authorization: Bearer` when set.
    var apiKey: String?
    var model: String
    /// For error messages ("Groq rejected the API key").
    var providerName: String
    var extraHeaders: [String: String] = [:]
    /// Leave nil unless needed: some reasoning models reject `max_tokens`.
    var maxTokens: Int? = nil
    /// Function definitions (JSON) to offer natively; calls come back as `<tool>` text.
    var tools: Data? = nil

    /// Stream the reply's text. `images` are base64 JPEGs for the last user message.
    func stream(_ request: AIRequest, images: [String] = []) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let url = URL(string: Self.trimmed(baseURL) + "/chat/completions") else {
                        throw AIError(message: "\(providerName)'s address isn't a valid URL: \(baseURL)")
                    }
                    try await AIConsent.ensure(key: url.host ?? providerName, service: providerName)
                    var req = Self.request(url, apiKey: apiKey, extraHeaders: extraHeaders, timeout: 600)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    let body = OpenAICompat.body(request, model: model, stream: true, maxTokens: maxTokens, images: images, tools: tools)
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)
                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    guard code == 200 else {
                        throw AIError(message: OpenAICompat.errorMessage(code: code, body: try await Self.head(bytes), provider: providerName))
                    }
                    var filter = ThinkTagFilter()
                    var calls = NativeToolCalls.Accumulator()
                    var sawChunk = false
                    var cutOff = false
                    // A server that ignores `stream: true` answers with one plain JSON body instead.
                    var plain = ""
                    for try await line in bytes.lines {
                        guard let chunk = OpenAICompat.chunk(line: line) else {
                            if !sawChunk, plain.count < 1_000_000, !line.hasPrefix(":"), !line.hasPrefix("event:"), !line.hasPrefix("id:") {
                                plain += line + "\n"
                            }
                            continue
                        }
                        sawChunk = true
                        if let error = chunk.error { throw AIError(message: "\(providerName): \(error)") }
                        if chunk.done { break }
                        if !chunk.text.isEmpty {
                            let shown = filter.feed(chunk.text)
                            if !shown.isEmpty { continuation.yield(shown) }
                        }
                        if chunk.finishReason == "length" { cutOff = true }
                        calls.add(chunk.toolCalls)
                    }
                    if !sawChunk, !plain.isEmpty {
                        let data = Data(plain.utf8)
                        if let text = OpenAICompat.text(fromResponse: data) {
                            let shown = filter.feed(text)
                            if !shown.isEmpty { continuation.yield(shown) }
                        } else if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let err = json["error"] {
                            let message = (err as? [String: Any])?["message"] as? String ?? (err as? String) ?? "The provider reported an error."
                            throw AIError(message: "\(providerName): \(message)")
                        }
                    }
                    let rest = filter.finish()
                    if !rest.isEmpty { continuation.yield(rest) }
                    // Native function calls become Synapse's <tool> text, so the agent loop can run them.
                    if !calls.isEmpty { continuation.yield("\n" + calls.markup) }
                    if cutOff { continuation.yield("\n\n_(Reply cut off at the length limit.)_") }
                    continuation.finish()
                } catch let error as URLError where error.code != .cancelled {
                    continuation.finish(throwing: AIError(message: Self.unreachable(providerName, error)))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Models

    /// `GET {baseURL}/models`. `freeSuffix` keeps only ids ending with it (OpenRouter's ":free").
    static func fetchModels(baseURL: String, apiKey: String?, extraHeaders: [String: String] = [:], freeSuffix: String? = nil,
                            providerName: String? = nil) async throws -> [APIModelInfo] {
        guard let url = URL(string: trimmed(baseURL) + "/models") else { throw AIError(message: "That address isn't a valid URL: \(baseURL)") }
        let name = providerName ?? url.host ?? "The server"
        let req = request(url, apiKey: apiKey, extraHeaders: extraHeaders, timeout: 20)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                throw AIError(message: OpenAICompat.errorMessage(code: code, body: String(decoding: data.prefix(4_096), as: UTF8.self), provider: name))
            }
            return OpenAICompat.models(from: data, freeSuffix: freeSuffix)
        } catch let error as URLError where error.code != .cancelled {
            throw AIError(message: unreachable(name, error))
        }
    }

    // MARK: - Transcription

    /// Speech to text with `POST {baseURL}/audio/transcriptions` (Whisper-style multipart upload).
    static func transcribe(file: URL, baseURL: String, apiKey: String?, model: String, providerName: String? = nil) async throws -> String {
        guard let url = URL(string: trimmed(baseURL) + "/audio/transcriptions") else { throw AIError(message: "That address isn't a valid URL: \(baseURL)") }
        let name = providerName ?? url.host ?? "The server"
        try await AIConsent.ensure(key: url.host ?? name, service: name, detail: "This recording is sent to be transcribed.")
        let boundary = "synapse-\(UUID().uuidString)"
        var req = request(url, apiKey: apiKey, extraHeaders: [:], timeout: 900)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let audio = try Data(contentsOf: file, options: .mappedIfSafe)
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        var body = Data()
        for (field, value) in [("model", model), ("response_format", "json")] {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(BridgeTools.headerSafe(file.lastPathComponent))\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        do {
            let (data, resp) = try await URLSession.shared.upload(for: req, from: body)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                if code == 413 {
                    throw AIError(message: "The recording is too big for \(name) (most transcription APIs take up to 25 MB). Transcribe on the iPhone instead.")
                }
                throw AIError(message: OpenAICompat.errorMessage(code: code, body: String(decoding: data.prefix(4_096), as: UTF8.self), provider: name))
            }
            let text: String
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                text = json["text"] as? String ?? ""
            } else {
                text = String(decoding: data, as: UTF8.self)   // a server that answered in plain text
            }
            let out = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if out.isEmpty { throw TranscriptionError.empty }
            return out
        } catch let error as URLError where error.code != .cancelled {
            throw AIError(message: unreachable(name, error))
        }
    }

    // MARK: - Helpers

    private static func request(_ url: URL, apiKey: String?, extraHeaders: [String: String], timeout: TimeInterval) -> URLRequest {
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        for (name, value) in extraHeaders { req.setValue(value, forHTTPHeaderField: name) }
        return req
    }

    private static func trimmed(_ base: String) -> String {
        var s = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Up to ~4 KB of a failed response's body.
    private static func head(_ bytes: URLSession.AsyncBytes) async throws -> String {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= 4_096 { break }
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func unreachable(_ name: String, _ error: URLError) -> String {
        error.code == .timedOut ? "\(name) didn't answer in time. Try again, or pick another model."
            : "Can't reach \(name): \(error.localizedDescription)"
    }
}
