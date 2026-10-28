import CryptoKit
import Foundation

/// RFC 4122 version 5 UUIDs — SHA-1 over namespace bytes + name bytes.
///
/// Foundation has no v5. It exists here because `scripts/build_ios_seed.py`
/// already derives ids with `uuid.uuid5`, and a transaction fetched twice must
/// come back with the same id or a re-fetch duplicates it. `UUIDv5Tests` pins
/// this against Python's own answers.
///
/// SHA-1 is used because the RFC says so, not because it is a security
/// choice — hence `Insecure.SHA1`, which is the correct API for exactly this.
enum UUIDv5 {
    /// The namespace `scripts/build_ios_seed.py` calls `NAMESPACE`.
    static let appNamespace = UUID(uuidString: "6F1C2A6E-5B7E-4D0C-9A1E-2B3C4D5E6F70")!

    static func make(namespace: UUID, name: String) -> UUID {
        var input = Data(withUnsafeBytes(of: namespace.uuid) { Array($0) })
        input.append(contentsOf: Array(name.utf8))

        var digest = Array(Insecure.SHA1.hash(data: input).prefix(16))
        digest[6] = (digest[6] & 0x0F) | 0x50   // version 5
        digest[8] = (digest[8] & 0x3F) | 0x80   // RFC 4122 variant

        var raw: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &raw) { $0.copyBytes(from: digest) }
        return UUID(uuid: raw)
    }
}
