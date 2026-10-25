import Foundation
import FoundationModels
import SynapseKit

/// A language model that runs on the iPhone.
@MainActor
protocol LocalLLM: AnyObject {
    var card: ModelCard { get }
    /// How much text one request can carry.
    var budget: LocalBudget { get }
    /// Why the model can't run right now, or nil when it's ready.
    var unavailableReason: String? { get }
    func stream(_ request: AIRequest) -> AsyncThrowingStream<String, Error>
}

/// Why an on-device request failed. Every case except cancellation can be retried in the cloud.
enum LocalAIError: LocalizedError {
    case unavailable(String)
    case tooLong
    case refused
    case unsupportedLanguage
    case busy
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let why): return why
        case .tooLong: return "That's too long for the on-device model. Select less text, or switch to a cloud model."
        case .refused: return "The on-device model declined this request."
        case .unsupportedLanguage: return "The on-device model doesn't support this language."
        case .busy: return "The on-device model is busy. Try again in a moment."
        case .failed(let why): return "The on-device model failed: \(why)"
        }
    }

    /// A short reason for the "sent to the cloud instead" note.
    var shortReason: String {
        switch self {
        case .unavailable: return "on-device model unavailable"
        case .tooLong: return "too long for on-device"
        case .refused: return "on-device model declined"
        case .unsupportedLanguage: return "language not supported on device"
        case .busy: return "on-device model busy"
        case .failed: return "on-device model failed"
        }
    }
}

/// Apple's on-device foundation model (Foundation Models framework, iOS 26).
@MainActor
final class AppleFoundationLLM: LocalLLM {
    var card: ModelCard { ModelCatalog.appleFoundation }
    var budget: LocalBudget { .apple }

    var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This iPhone can't run Apple Intelligence (it needs an iPhone 15 Pro or newer)."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in Settings › Apple Intelligence & Siri to use the on-device model."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still downloading its model. Keep the iPhone on Wi-Fi and charging, then try again."
        case .unavailable:
            return "The on-device model isn't available right now."
        }
    }

    func stream(_ request: AIRequest) -> AsyncThrowingStream<String, Error> {
        if let why = unavailableReason {
            return AsyncThrowingStream { $0.finish(throwing: LocalAIError.unavailable(why)) }
        }
        let instructions = request.system
        let prompt = Self.prompt(request.messages)
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    // Synapse asks for rewrites and summaries of the user's own text, which is what this mode is for.
                    let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
                    let session = LanguageModelSession(model: model, instructions: instructions)
                    var shown = 0
                    for try await snapshot in session.streamResponse(to: prompt, options: GenerationOptions(temperature: 0.4)) {
                        // Snapshots carry the whole reply so far.
                        let full = snapshot.content
                        if full.count > shown {
                            continuation.yield(String(full.dropFirst(shown)))
                            shown = full.count
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let error as LanguageModelSession.GenerationError {
                    continuation.finish(throwing: Self.map(error))
                } catch {
                    continuation.finish(throwing: LocalAIError.failed(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func map(_ error: LanguageModelSession.GenerationError) -> LocalAIError {
        switch error {
        case .exceededContextWindowSize: return .tooLong
        case .guardrailViolation, .refusal: return .refused
        case .unsupportedLanguageOrLocale: return .unsupportedLanguage
        case .rateLimited, .concurrentRequests: return .busy
        case .assetsUnavailable: return .unavailable("Apple Intelligence's model isn't downloaded yet.")
        case .unsupportedGuide, .decodingFailure: return .failed(error.localizedDescription)
        @unknown default: return .failed(error.localizedDescription)
        }
    }

    /// One prompt from a conversation (each request starts a fresh session).
    static func prompt(_ messages: [AIMessage]) -> String {
        guard let last = messages.last else { return "" }
        if messages.count == 1 { return last.content }
        let history = messages.dropLast().map { "<\($0.role.rawValue)>\n\($0.content)\n</\($0.role.rawValue)>" }.joined(separator: "\n")
        return "<conversation_so_far>\n\(history)\n</conversation_so_far>\n\n\(last.content)"
    }
}
