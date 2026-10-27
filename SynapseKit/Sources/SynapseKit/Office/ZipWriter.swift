import Foundation

/// Writes a ZIP archive with STORED (uncompressed) entries: what an Office package needs, with no zlib. Names are
/// UTF-8 (general-purpose bit 11) and every entry gets the same fixed timestamp, so the same input gives the same bytes.
public struct ZipWriter: Sendable {
    private struct Entry: Sendable {
        var name: [UInt8]
        var crc: UInt32
        var size: Int
        var offset: Int
    }

    private var body = Data()
    private var entries: [Entry] = []

    /// 2026-01-01 00:00 in MS-DOS format.
    static let dosTime: UInt16 = 0
    static let dosDate: UInt16 = UInt16((2026 - 1980) << 9 | 1 << 5 | 1)

    public init() {}

    /// Number of entries added so far.
    public var count: Int { entries.count }

    /// Add a file. Entries are written in the order they're added.
    public mutating func add(_ name: String, data: Data) {
        let nameBytes = Array(name.utf8)
        let crc = Self.crc32(data)
        let entry = Entry(name: nameBytes, crc: crc, size: data.count, offset: body.count)
        var h = Data()
        h.reserveCapacity(30 + nameBytes.count)
        Self.put32(&h, 0x04034b50)
        Self.put16(&h, 20)          // version needed to extract
        Self.put16(&h, 0x0800)      // UTF-8 names
        Self.put16(&h, 0)           // stored
        Self.put16(&h, Self.dosTime)
        Self.put16(&h, Self.dosDate)
        Self.put32(&h, crc)
        Self.put32(&h, UInt32(truncatingIfNeeded: data.count))
        Self.put32(&h, UInt32(truncatingIfNeeded: data.count))
        Self.put16(&h, UInt16(truncatingIfNeeded: nameBytes.count))
        Self.put16(&h, 0)           // extra length
        h.append(contentsOf: nameBytes)
        body.append(h)
        body.append(data)
        entries.append(entry)
    }

    /// Add a UTF-8 text file.
    public mutating func add(_ name: String, text: String) {
        add(name, data: Data(text.utf8))
    }

    /// The finished archive. Throws if it would need ZIP64 (over 4 GB or 65,535 entries).
    public func finish() throws -> Data {
        guard entries.count < 0xFFFF else { throw OfficeError(message: "Too many files for a ZIP archive.") }
        var directory = Data()
        for e in entries {
            Self.put32(&directory, 0x02014b50)
            Self.put16(&directory, 20)      // made by: MS-DOS, spec 2.0
            Self.put16(&directory, 20)      // needed to extract
            Self.put16(&directory, 0x0800)
            Self.put16(&directory, 0)
            Self.put16(&directory, Self.dosTime)
            Self.put16(&directory, Self.dosDate)
            Self.put32(&directory, e.crc)
            Self.put32(&directory, UInt32(truncatingIfNeeded: e.size))
            Self.put32(&directory, UInt32(truncatingIfNeeded: e.size))
            Self.put16(&directory, UInt16(truncatingIfNeeded: e.name.count))
            Self.put16(&directory, 0)       // extra
            Self.put16(&directory, 0)       // comment
            Self.put16(&directory, 0)       // disk number
            Self.put16(&directory, 0)       // internal attributes
            Self.put32(&directory, 0)       // external attributes
            Self.put32(&directory, UInt32(truncatingIfNeeded: e.offset))
            directory.append(contentsOf: e.name)
        }
        guard body.count + directory.count < 0xFFFF_FFFF else { throw OfficeError(message: "The file is too large (over 4 GB).") }
        var out = body
        out.append(directory)
        Self.put32(&out, 0x06054b50)
        Self.put16(&out, 0)                 // this disk
        Self.put16(&out, 0)                 // directory's disk
        Self.put16(&out, UInt16(entries.count))
        Self.put16(&out, UInt16(entries.count))
        Self.put32(&out, UInt32(directory.count))
        Self.put32(&out, UInt32(body.count))
        Self.put16(&out, 0)                 // comment length
        return out
    }

    // MARK: CRC-32

    /// CRC-32 (IEEE 802.3, the one ZIP uses).
    public static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for byte in raw {
                crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    private static func put16(_ d: inout Data, _ v: UInt16) {
        d.append(UInt8(v & 0xFF))
        d.append(UInt8(v >> 8))
    }

    private static func put32(_ d: inout Data, _ v: UInt32) {
        d.append(UInt8(v & 0xFF))
        d.append(UInt8((v >> 8) & 0xFF))
        d.append(UInt8((v >> 16) & 0xFF))
        d.append(UInt8(v >> 24))
    }
}
