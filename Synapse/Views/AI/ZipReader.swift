import Compression
import Foundation

/// Reads entries from a ZIP archive (Office, OpenDocument, EPUB, iWork files and plain .zip). Stored and DEFLATE
/// entries; no ZIP64 or encryption, which document formats don't use.
struct ZipReader {
    struct Entry {
        var name: String
        var method: UInt16
        var compressedSize: Int
        var size: Int
        var localOffset: Int
        var isDirectory: Bool { name.hasSuffix("/") }
    }

    let data: Data
    let entries: [Entry]

    init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .alwaysMapped))
    }

    init(data: Data) throws {
        self.data = data
        entries = try Self.readDirectory(data)
    }

    var names: [String] { entries.map(\.name) }

    func read(_ name: String) -> Data? {
        entries.first { $0.name == name }.flatMap(read)
    }

    func read(_ entry: Entry) -> Data? {
        let o = entry.localOffset
        guard o + 30 <= data.count, Self.u32(data, o) == 0x04034b50 else { return nil }
        let start = o + 30 + Int(Self.u16(data, o + 26)) + Int(Self.u16(data, o + 28))
        guard start + entry.compressedSize <= data.count else { return nil }
        let raw = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + entry.compressedSize))
        switch entry.method {
        case 0:
            return raw
        case 8:
            return Self.inflate(raw, size: entry.size)
        default:
            return nil
        }
    }

    func text(_ name: String) -> String? {
        read(name).map { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: Format

    static func readDirectory(_ data: Data) throws -> [Entry] {
        // The end-of-central-directory record is in the last 64 KB + 22 bytes.
        let n = data.count
        guard n >= 22 else { throw AIError(message: "Not a ZIP file.") }
        var eocd = -1
        var i = n - 22
        let floor = max(0, n - 65_557)
        while i >= floor {
            if u32(data, i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw AIError(message: "Not a ZIP file (no directory).") }
        let count = Int(u16(data, eocd + 10))
        var p = Int(u32(data, eocd + 16))
        var out: [Entry] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            guard p + 46 <= n, u32(data, p) == 0x02014b50 else { break }
            let nameLength = Int(u16(data, p + 28))
            let extra = Int(u16(data, p + 30))
            let comment = Int(u16(data, p + 32))
            guard p + 46 + nameLength <= n else { break }
            let nameData = data.subdata(in: (data.startIndex + p + 46)..<(data.startIndex + p + 46 + nameLength))
            out.append(Entry(name: String(decoding: nameData, as: UTF8.self), method: u16(data, p + 10),
                             compressedSize: Int(u32(data, p + 20)), size: Int(u32(data, p + 24)),
                             localOffset: Int(u32(data, p + 42))))
            p += 46 + nameLength + extra + comment
        }
        return out
    }

    static func u16(_ d: Data, _ i: Int) -> UInt16 {
        let s = d.startIndex + i
        return UInt16(d[s]) | UInt16(d[s + 1]) << 8
    }

    static func u32(_ d: Data, _ i: Int) -> UInt32 {
        let s = d.startIndex + i
        return UInt32(d[s]) | UInt32(d[s + 1]) << 8 | UInt32(d[s + 2]) << 16 | UInt32(d[s + 3]) << 24
    }

    /// Raw DEFLATE (Apple's COMPRESSION_ZLIB is RFC 1951 without the zlib header, as ZIP uses).
    static func inflate(_ raw: Data, size: Int) -> Data? {
        guard size > 0 else { return Data() }
        guard size < 512 * 1024 * 1024 else { return nil }
        var out = Data(count: size)
        let written = out.withUnsafeMutableBytes { dst -> Int in
            raw.withUnsafeBytes { src -> Int in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress, let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(d, size, s, raw.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        out.count = written
        return out
    }
}
