import Compression
import Foundation

/// The minimal unzip an xlsx needs: central directory walk, stored and
/// deflated entries, nothing else. Not a general zip library on purpose —
/// a statement is tens of kilobytes and every unsupported corner
/// (encryption, zip64, spanning) is refused as "not an xlsx".
enum XLSXArchive {
    /// A statement is ~25 KB. Anything approaching this is not a statement.
    static let maxEntrySize = 16 * 1024 * 1024

    /// A cap on the whole FILE, checked before any structural byte is read.
    /// `[UInt8](data)` below copies the archive, so an unbounded `data`
    /// doubles memory before the central directory has even been located —
    /// the file itself, not anything it claims to decode to, is already the
    /// cost. Four times `maxEntrySize` stays generous for a statement that
    /// is realistically tens of kilobytes while still refusing a file large
    /// enough that doubling it is itself the attack.
    static let maxArchiveSize = 4 * maxEntrySize

    static func entries(_ data: Data) throws -> [String: Data] {
        guard data.count <= maxArchiveSize else { throw PrivatImportError.notAnXLSX }
        let bytes = [UInt8](data)
        guard let eocd = findEndOfCentralDirectory(bytes) else { throw PrivatImportError.notAnXLSX }
        let count = Int(u16(bytes, eocd + 10))
        var offset = Int(u32(bytes, eocd + 16))
        var out: [String: Data] = [:]
        // A whole-archive budget, not just a per-entry one: nothing stops
        // distinct central-directory entries from pointing at the SAME local
        // header, so a handful of small headers can each claim to inflate to
        // maxEntrySize and multiply that out to gigabytes. Checked before any
        // decoding happens, so a hostile archive is refused early rather than
        // after doing the work it was trying to force.
        var totalDecodedSize = 0
        for _ in 0..<count {
            guard offset + 46 <= bytes.count, u32(bytes, offset) == 0x0201_4b50 else {
                throw PrivatImportError.notAnXLSX
            }
            let flags = u16(bytes, offset + 8)
            let method = u16(bytes, offset + 10)
            let compressedSize = Int(u32(bytes, offset + 20))
            let uncompressedSize = Int(u32(bytes, offset + 24))
            let nameLen = Int(u16(bytes, offset + 28))
            let extraLen = Int(u16(bytes, offset + 30))
            let commentLen = Int(u16(bytes, offset + 32))
            let localOffset = Int(u32(bytes, offset + 42))
            guard offset + 46 + nameLen <= bytes.count,
                  let name = String(bytes: bytes[(offset + 46)..<(offset + 46 + nameLen)],
                                    encoding: .utf8),
                  flags & 0x1 == 0,                        // encrypted → refuse
                  uncompressedSize <= maxEntrySize else { throw PrivatImportError.notAnXLSX }

            totalDecodedSize += uncompressedSize
            guard totalDecodedSize <= maxEntrySize else { throw PrivatImportError.notAnXLSX }

            // The LOCAL header's own lengths locate the data — its extra
            // field is allowed to differ from the central directory's.
            guard localOffset + 30 <= bytes.count, u32(bytes, localOffset) == 0x0403_4b50 else {
                throw PrivatImportError.notAnXLSX
            }
            let localNameLen = Int(u16(bytes, localOffset + 26))
            let localExtraLen = Int(u16(bytes, localOffset + 28))
            let start = localOffset + 30 + localNameLen + localExtraLen
            guard start + compressedSize <= bytes.count else { throw PrivatImportError.notAnXLSX }
            let payload = Data(bytes[start..<(start + compressedSize)])

            switch method {
            case 0:
                // A stored entry is defined by having no compression at all,
                // so its declared sizes must agree. Without this, an entry
                // could declare `uncompressedSize = 0` — adding nothing to
                // the whole-archive budget above — while `payload` still
                // retains `compressedSize` bytes. Since distinct
                // central-directory entries may share one local header, a
                // ~4 MB crafted archive could otherwise multiply that into
                // tens of GB retained.
                guard compressedSize == uncompressedSize else { throw PrivatImportError.notAnXLSX }
                out[name] = payload
            case 8: out[name] = try inflate(payload, uncompressedSize: uncompressedSize)
            default: throw PrivatImportError.notAnXLSX
            }
            offset += 46 + nameLen + extraLen + commentLen
        }
        return out
    }

    /// End-of-central-directory record: signature 0x06054b50, somewhere in
    /// the last 64 KB + 22 bytes (the comment can push it back).
    private static func findEndOfCentralDirectory(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 22 else { return nil }
        let floor = max(0, bytes.count - 22 - 65_536)
        var i = bytes.count - 22
        while i >= floor {
            if u32(bytes, i) == 0x0605_4b50 { return i }
            i -= 1
        }
        return nil
    }

    /// Raw DEFLATE (which is what `COMPRESSION_ZLIB` decodes) into a buffer
    /// one byte larger than the directory promised. `compression_decode_buffer`
    /// returns the number of bytes it actually wrote, not an error, when the
    /// destination is undersized — decoding 200 real bytes into a 50-byte
    /// buffer returns 50, not a failure. Sized exactly to `uncompressedSize`,
    /// an entry that decodes to MORE than that would be silently truncated
    /// and reported as a clean, complete entry. The extra byte turns that
    /// case into an over-length write instead: the stream produces
    /// `uncompressedSize + 1` bytes, `written` no longer equals
    /// `uncompressedSize`, and it is refused rather than truncated.
    private static func inflate(_ data: Data, uncompressedSize: Int) throws -> Data {
        guard uncompressedSize > 0 else { return Data() }
        guard !data.isEmpty else { throw PrivatImportError.notAnXLSX }
        let capacity = uncompressedSize + 1
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard written == uncompressedSize else { throw PrivatImportError.notAnXLSX }
        return Data(out.prefix(uncompressedSize))
    }

    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 {
        UInt16(b[i]) | UInt16(b[i + 1]) << 8
    }

    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
}
