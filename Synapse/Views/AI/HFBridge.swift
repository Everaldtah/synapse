import Foundation
import HuggingFace
import MLXLMCommon
import Tokenizers

// The only file that imports Tokenizers: it and MLXLMCommon both define `Tokenizer` and `TokenizerError`.

/// Where downloaded models live: Application Support (iOS may purge Caches), excluded from iCloud backups.
/// Layout is the Hugging Face cache's: `models--org--repo/{blobs,snapshots}`.
enum ModelFiles {
    static var root: URL {
        URL.applicationSupportDirectory.appending(path: "Models/hub", directoryHint: .isDirectory)
    }

    static func prepareRoot() throws {
        var url = root
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    static func directory(_ repoID: String) -> URL? {
        HuggingFace.Repo.ID(rawValue: repoID).map { HubCache(cacheDirectory: root).repoDirectory(repo: $0, kind: .model) }
    }

    /// Set once every file has arrived, so a half-finished download never counts.
    static func isDownloaded(_ repoID: String) -> Bool {
        guard UserDefaults.standard.bool(forKey: "mlx.done." + repoID), let dir = directory(repoID) else { return false }
        return FileManager.default.fileExists(atPath: dir.path)
    }

    static func markDownloaded(_ repoID: String) {
        UserDefaults.standard.set(true, forKey: "mlx.done." + repoID)
    }

    /// Bytes on disk (regular files only: snapshots are symlinks into blobs).
    static func bytes(_ repoID: String) -> Int64 {
        guard let dir = directory(repoID),
              let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        while let url = e.nextObject() as? URL {
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += Int64(v?.fileSize ?? 0) }
        }
        return total
    }

    static func delete(_ repoID: String) {
        UserDefaults.standard.removeObject(forKey: "mlx.done." + repoID)
        if let dir = directory(repoID) { try? FileManager.default.removeItem(at: dir) }
    }

    /// Free space for a download, in bytes (nil when unknown).
    static func freeSpace() -> Int64? {
        let url = URL.applicationSupportDirectory
        return (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }
}

/// Downloads model snapshots from Hugging Face into `ModelFiles.root`. Once a model is downloaded it loads offline.
struct HubDownloader: MLXLMCommon.Downloader {
    func download(id: String, revision: String?, matching patterns: [String], useLatest: Bool,
                  progressHandler: @Sendable @escaping (Progress) -> Void) async throws -> URL {
        guard let repo = HuggingFace.Repo.ID(rawValue: id) else { throw URLError(.badURL) }
        let client = HubClient(cache: HubCache(cacheDirectory: ModelFiles.root))
        return try await client.downloadSnapshot(of: repo, revision: revision ?? "main", matching: patterns,
                                                 localFilesOnly: !useLatest && ModelFiles.isDownloaded(id),
                                                 progressHandler: { @MainActor progress in progressHandler(progress) })
    }
}

/// swift-transformers' tokenizer behind MLX's tokenizer protocol.
struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] { upstream.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

/// Loads a model folder's tokenizer with swift-transformers.
struct TransformersLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        // Not strict: newer releases name their class in ways swift-transformers 1.3.5 doesn't list (Qwen3.5's
        // "Qwen3_5Tokenizer", mlx-community's "TokenizersBackend"). The tokenizer itself is described by
        // tokenizer.json, so an unknown name falls back to the BPE model those Qwen tokenizers are, instead of failing.
        TokenizerBridge(upstream: try await AutoTokenizer.from(modelFolder: directory, strict: false))
    }
}
