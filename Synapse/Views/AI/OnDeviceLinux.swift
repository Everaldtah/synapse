import CryptoKit
import Foundation
import LinuxCore
import Observation

/// Alpine Linux on the iPhone (iSH: an x86 emulator with a Linux syscall layer, GPL-3.0, from TermForge). The root
/// filesystem (107 MB) is downloaded once from TermForge's releases, converted to iSH's format and booted on demand.
/// The agent's `shell` tool runs here with where="iphone": offline, private, slower than the computer's sandbox.
@MainActor
@Observable
final class OnDeviceLinux {
    enum State: Equatable {
        case notInstalled
        case downloading(Double)
        case importing
        case booting
        case ready
        case failed(String)
    }

    /// Built by TermForge's scripts/build-rootfs.sh (Alpine 3.20 x86: bash, python3, git, ripgrep, apk).
    struct RootfsPin {
        let name = "alpine-x86"
        let url = URL(string: "https://github.com/Everaldtah/termforge/releases/download/rootfs-alpine-x86/alpine-x86.tar.gz")!
        let sha256 = "8d7a36ce70500b7e9917c7e9adf2bced1b8b0c88053037018e069f3520c05a0c"
        let bytes: Int64 = 106_800_000
    }

    private(set) var state: State = .notInstalled {
        didSet { onProgress?(stateLabel) }
    }
    private(set) var bootMs: Double?
    /// Progress lines for whoever is waiting (an agent's step).
    @ObservationIgnored private var onProgress: ((String) -> Void)?
    let pin = RootfsPin()
    @ObservationIgnored let runtime = LinuxRuntime.shared

    private var rootsDir: URL {
        URL.applicationSupportDirectory.appending(path: "Linux", directoryHint: .isDirectory)
    }
    private var fakefsDir: URL { rootsDir.appendingPathComponent(pin.name, isDirectory: true) }
    private var marker: URL { fakefsDir.appendingPathComponent(".synapse-installed") }
    /// Shared with the guest at `LinuxRuntime.hostMountPoint`; attached files go in files/.
    var shareDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Synapse/linux", isDirectory: true)
    }

    var isInstalled: Bool {
        (try? String(contentsOf: marker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == pin.sha256
    }

    var isReady: Bool { state == .ready }

    var stateLabel: String {
        switch state {
        case .notInstalled: return isInstalled ? "Linux is installed" : "Linux isn't installed"
        case .downloading(let f): return "Downloading Linux… \(Int(f * 100))%"
        case .importing: return "Unpacking Linux…"
        case .booting: return "Starting Linux…"
        case .ready: return "Linux is running"
        case .failed(let why): return "Linux failed: \(why)"
        }
    }

    /// Install (first time), boot and wait; throws when that fails. Progress lines go to `progress`.
    func ensureReady(progress: ((String) -> Void)? = nil) async throws {
        if state == .ready { return }
        onProgress = progress
        defer { onProgress = nil }
        await start()
        if case .failed(let why) = state { throw AIError(message: why) }
        guard state == .ready else { throw AIError(message: "Linux on this iPhone isn't ready.") }
    }

    /// An interactive bash on the share folder (the Terminal). Linux is installed and started first if needed.
    func openShell() async throws -> Shell {
        try await ensureReady()
        let session = try runtime.startSession(argv: ["/bin/bash", "-l"],
                                               env: ["HOME": "/root", "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                                                     "TERM": "dumb", "LANG": "C.UTF-8", "PS1": "\\w $ "],
                                               cwd: LinuxRuntime.hostMountPoint, cols: 60, rows: 30)
        return Shell(session: session)
    }

    /// One interactive shell: its screen text (terminal escapes stripped) and a way to type into it.
    @MainActor
    @Observable
    final class Shell {
        private(set) var text = ""
        private(set) var exitCode: Int32?
        @ObservationIgnored private let session: LinuxSession

        init(session: LinuxSession) {
            self.session = session
            session.onOutput = { [weak self] data in
                let chunk = String(decoding: data, as: UTF8.self)
                Task { @MainActor in self?.append(chunk) }
            }
            session.onExit = { [weak self] code in
                Task { @MainActor in self?.exitCode = code }
            }
        }

        var isRunning: Bool { exitCode == nil }

        private func append(_ chunk: String) {
            text += Self.plain(chunk)
            if text.count > 160_000 { text = String(text.suffix(100_000)) }
        }

        func send(_ line: String) { session.write(Data((line + "\n").utf8)) }
        func interrupt() { session.write(Data([0x03])) }
        func close() { session.hangup() }

        /// Drop terminal control sequences (colours, cursor moves, titles) and bells; keep the text.
        static func plain(_ s: String) -> String {
            var t = s
            for pattern in ["\u{1B}\\[[0-9;?]*[ -/]*[@-~]", "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)", "\u{1B}[()][A-Za-z0-9]", "\u{1B}[=>78]", "\u{1B}."] {
                t = t.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            }
            t = t.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\u{07}", with: "")
            while t.contains("\u{08}") {
                t = t.replacingOccurrences(of: "[^\n]\u{08}", with: "", options: .regularExpression).replacingOccurrences(of: "^\u{08}", with: "", options: .regularExpression)
            }
            return t
        }
    }

    init() {
        if isInstalled { state = .notInstalled }
    }

    /// Download (if needed), import and boot.
    func start() async {
        switch state {
        case .ready, .downloading, .importing, .booting: return
        default: break
        }
        do {
            try FileManager.default.createDirectory(at: rootsDir, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var dir = rootsDir
            try? dir.setResourceValues(values)
            if !isInstalled {
                state = .downloading(0)
                let tarball = try await download()
                state = .importing
                if FileManager.default.fileExists(atPath: fakefsDir.path) { try FileManager.default.removeItem(at: fakefsDir) }
                let (rt, dir) = (runtime, fakefsDir)
                try await Task.detached(priority: .userInitiated) { try rt.importRootfs(tarGz: tarball, into: dir) }.value
                try pin.sha256.write(to: marker, atomically: true, encoding: .utf8)
                try? FileManager.default.removeItem(at: tarball)
            }
            try boot()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func download() async throws -> URL {
        let (tmp, response) = try await Downloader.download(pin.url) { [weak self] fraction in
            Task { @MainActor in
                guard let self, case .downloading(let f) = self.state, fraction - f >= 0.02 || fraction >= 1 else { return }
                self.state = .downloading(fraction)
            }
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AIError(message: "Linux download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)).")
        }
        state = .downloading(1)
        let digest = try Self.sha256(of: tmp)
        guard digest == pin.sha256 else {
            try? FileManager.default.removeItem(at: tmp)
            throw AIError(message: "The Linux download was corrupted (checksum mismatch). Try again.")
        }
        let dest = rootsDir.appendingPathComponent("\(pin.name).tar.gz")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    private func boot() throws {
        guard !runtime.booted else { state = .ready; return }
        state = .booting
        try FileManager.default.createDirectory(at: shareDir.appendingPathComponent("files"), withIntermediateDirectories: true)
        let t0 = Date()
        try runtime.boot(fakefsDir: fakefsDir, hostDir: shareDir, temporaryDir: FileManager.default.temporaryDirectory)
        bootMs = Date().timeIntervalSince(t0) * 1000
        state = .ready
    }

    /// Put files where the guest sees them (files/ under the share).
    func share(_ files: [URL]) {
        let dir = shareDir.appendingPathComponent("files", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in files {
            let dest = dir.appendingPathComponent(f.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: f, to: dest)
        }
    }

    /// Run a bash command in the share folder; returns its output for the model.
    func run(_ command: String, timeout: TimeInterval = 120) async throws -> String {
        if state != .ready { await start() }
        guard state == .ready else { throw AIError(message: "Linux on this iPhone isn't ready.") }
        let rt = runtime
        return try await withCheckedThrowingContinuation { continuation in
            let box = OutputBox()
            do {
                let exec = try rt.exec(argv: ["/bin/bash", "-lc", command],
                                       env: ["HOME": "/root", "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "TERM": "dumb", "LANG": "C.UTF-8"],
                                       cwd: LinuxRuntime.hostMountPoint,
                                       stdout: { box.out.append($0) }, stderr: { box.err.append($0) },
                                       completion: { code in continuation.resume(returning: box.summary(code: code)) })
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak exec] in exec?.kill(signal: 9) }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Output collected on LinuxCore's serial queue.
    private final class OutputBox: @unchecked Sendable {
        var out = Data()
        var err = Data()

        func summary(code: Int32) -> String {
            var parts: [String] = []
            let o = String(decoding: out.prefix(200_000), as: UTF8.self)
            let e = String(decoding: err.prefix(50_000), as: UTF8.self)
            if !o.isEmpty { parts.append(o) }
            if !e.isEmpty { parts.append("[stderr]\n" + e) }
            if code != 0 { parts.append("[exit code \(code)]") }
            return parts.isEmpty ? "(no output)" : parts.joined(separator: "\n")
        }
    }

    /// A download that reports progress (URLSession's async download has none).
    private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let progress: (Double) -> Void
        private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
        private var expected: Int64

        private init(progress: @escaping (Double) -> Void, expected: Int64) {
            self.progress = progress
            self.expected = expected
        }

        static func download(_ url: URL, expected: Int64 = 106_800_000, progress: @escaping (Double) -> Void) async throws -> (URL, URLResponse) {
            let d = Downloader(progress: progress, expected: expected)
            let session = URLSession(configuration: .default, delegate: d, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            return try await withCheckedThrowingContinuation { c in
                d.continuation = c
                session.downloadTask(with: url).resume()
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expected
            progress(min(0.99, Double(totalBytesWritten) / Double(max(1, total))))
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            // The file is deleted when this returns: keep it.
            let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tar.gz")
            do {
                try FileManager.default.moveItem(at: location, to: kept)
                if let response = downloadTask.response { continuation?.resume(returning: (kept, response)); continuation = nil }
            } catch {
                continuation?.resume(throwing: error)
                continuation = nil
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { continuation?.resume(throwing: error); continuation = nil }
            else if let c = continuation { c.resume(throwing: AIError(message: "The Linux download ended early.")); continuation = nil }
        }
    }

    nonisolated static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
