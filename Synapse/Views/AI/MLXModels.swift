import Foundation
import Observation
import UIKit
import os
import MLX
import MLXLLM
import MLXLMCommon
import SynapseKit

/// Downloads, stores and loads the open-weights models that run with MLX on the iPhone's GPU.
/// One model is kept in memory at a time; it's released on a memory warning and reloaded on the next request.
@MainActor
@Observable
final class LocalModelManager {
    enum State: Equatable {
        case notDownloaded
        case downloading(Double)
        case downloaded
        case failed(String)
    }

    private(set) var states: [String: State] = [:]
    /// The model currently in memory.
    private(set) var loadedID: String?
    /// A model is being read into memory (the first request after launch or a switch).
    private(set) var loading = false

    @ObservationIgnored private var container: ModelContainer?
    @ObservationIgnored private var downloads: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var memoryObserver: NSObjectProtocol?

    /// Why downloaded models can't run here, or nil when they can.
    static var unsupportedReason: String? {
        #if targetEnvironment(simulator)
        return "Downloaded models need a real iPhone: MLX runs on the GPU."
        #else
        return nil
        #endif
    }

    init() {
        for card in ModelCatalog.downloadable {
            states[card.id] = ModelFiles.isDownloaded(card.repoID) ? .downloaded : .notDownloaded
        }
        memoryObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.unload() }
        }
    }

    func state(_ card: ModelCard) -> State { states[card.id] ?? .notDownloaded }
    func isDownloaded(_ card: ModelCard) -> Bool { state(card) == .downloaded }

    // MARK: Downloads

    func download(_ card: ModelCard) {
        guard downloads[card.id] == nil else { return }
        if let free = ModelFiles.freeSpace(), free < card.downloadBytes + 500_000_000 {
            states[card.id] = .failed("Not enough storage: \(card.name) needs \(Self.format(card.downloadBytes)), \(Self.format(free)) is free.")
            return
        }
        states[card.id] = .downloading(0)
        UIApplication.shared.isIdleTimerDisabled = true
        let id = card.id
        downloads[id] = Task { @MainActor in
            defer {
                downloads[id] = nil
                if downloads.isEmpty { UIApplication.shared.isIdleTimerDisabled = false }
            }
            do {
                try ModelFiles.prepareRoot()
                _ = try await HubDownloader().download(id: card.repoID, revision: "main",
                                                       matching: ["*.safetensors", "*.json", "*.jinja"], useLatest: true) { progress in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor in
                        if case .downloading = self.states[id] { self.states[id] = .downloading(fraction) }
                    }
                }
                try Task.checkCancellation()
                ModelFiles.markDownloaded(card.repoID)
                states[id] = .downloaded
            } catch {
                if Task.isCancelled || error is CancellationError {
                    ModelFiles.delete(card.repoID)
                    states[id] = .notDownloaded
                } else {
                    states[id] = .failed("Download failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func cancelDownload(_ card: ModelCard) {
        downloads[card.id]?.cancel()
    }

    func delete(_ card: ModelCard) {
        cancelDownload(card)
        if loadedID == card.id { unload() }
        ModelFiles.delete(card.repoID)
        states[card.id] = .notDownloaded
    }

    func bytesOnDisk(_ card: ModelCard) -> Int64 { ModelFiles.bytes(card.repoID) }

    // MARK: Memory

    /// The model, loaded into memory (from disk only; it never downloads here).
    func container(for card: ModelCard) async throws -> ModelContainer {
        if loadedID == card.id, let container { return container }
        if let why = Self.unsupportedReason { throw LocalAIError.unavailable(why) }
        guard isDownloaded(card) else { throw LocalAIError.unavailable("Download \(card.name) in the model switcher first.") }
        unload()
        let available = Int64(os_proc_available_memory())
        let needed = card.downloadBytes + 1_200_000_000
        if available > 0 && available < needed {
            throw LocalAIError.unavailable("Not enough free memory for \(card.name) (\(Self.format(available)) free, it needs about \(Self.format(needed))). Close other apps or pick a smaller model.")
        }
        loading = true
        defer { loading = false }
        // A small buffer cache keeps MLX well under the app's memory limit.
        Memory.cacheLimit = 20 * 1024 * 1024
        let configuration = ModelConfiguration(id: card.repoID, extraEOSTokens: Set(card.stopTokens))
        let loaded = try await LLMModelFactory.shared.loadContainer(from: HubDownloader(), using: TransformersLoader(),
                                                                    configuration: configuration)
        container = loaded
        loadedID = card.id
        return loaded
    }

    func unload() {
        container = nil
        loadedID = nil
        Memory.clearCache()
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// A downloaded open-weights model as a `LocalLLM`.
@MainActor
final class MLXLocalLLM: LocalLLM {
    let card: ModelCard
    private let manager: LocalModelManager

    init(card: ModelCard, manager: LocalModelManager) {
        self.card = card
        self.manager = manager
    }

    var budget: LocalBudget { ModelCatalog.budget(for: card) }

    var unavailableReason: String? {
        if let why = LocalModelManager.unsupportedReason { return why }
        switch manager.state(card) {
        case .downloaded: return nil
        case .downloading(let f): return "\(card.name) is still downloading (\(Int(f * 100))%)."
        case .notDownloaded, .failed: return "Download \(card.name) in the model switcher first."
        }
    }

    func stream(_ request: AIRequest) -> AsyncThrowingStream<String, Error> {
        if let why = unavailableReason {
            return AsyncThrowingStream { $0.finish(throwing: LocalAIError.unavailable(why)) }
        }
        let instructions = request.system
        let prompt = AppleFoundationLLM.prompt(request.messages)
        let card = self.card
        let manager = self.manager
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    let container = try await manager.container(for: card)
                    let session = ChatSession(container, instructions: instructions,
                                              generateParameters: GenerateParameters(maxTokens: 1_500, maxKVSize: card.runContextTokens,
                                                                                     temperature: 0.5),
                                              additionalContext: ["enable_thinking": false])
                    var filter = ThinkTagFilter()
                    for try await chunk in session.streamResponse(to: prompt) {
                        let text = filter.feed(chunk)
                        if !text.isEmpty { continuation.yield(text) }
                    }
                    let rest = filter.finish()
                    if !rest.isEmpty { continuation.yield(rest) }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let error as LocalAIError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: Task.isCancelled ? CancellationError() : LocalAIError.failed(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
