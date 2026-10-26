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

    private(set) var state: State = .notInstalled
    private(set) var bootMs: Double?
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
        let (tmp, response) = try await URLSession.shared.download(from: pin.url)
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

    nonisolated static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
