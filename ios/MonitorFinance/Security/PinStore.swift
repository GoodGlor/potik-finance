import CryptoKit
import Foundation
import Security

/// The PIN is never stored — only SHA-256(salt + pin) and a per-install salt,
/// both in Keychain. Lockout bookkeeping lives in UserDefaults (it is not a
/// secret; it only has to survive a relaunch).
final class PinStore {
    static let maxFailures = 5
    static let baseLockout: TimeInterval = 30

    private let keychain: Keychain
    private let defaults: UserDefaults
    private let now: () -> Date

    enum Failure: Swift.Error { case noEntropy(OSStatus) }

    private enum Key {
        static let hash = "pin.hash", salt = "pin.salt"
        static let failed = "pin.failed", round = "pin.round", lockedUntil = "pin.lockedUntil"
    }

    init(keychain: Keychain = .app, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.keychain = keychain
        self.defaults = defaults
        self.now = now
    }

    var isSet: Bool { keychain.get(Key.hash) != nil }

    var failedAttempts: Int { defaults.integer(forKey: Key.failed) }

    var lockedUntil: Date? {
        let t = defaults.double(forKey: Key.lockedUntil)
        guard t > 0 else { return nil }
        let until = Date(timeIntervalSince1970: t)
        if until <= now() {
            defaults.removeObject(forKey: Key.lockedUntil)
            return nil
        }
        return until
    }

    func set(_ pin: String) throws {
        var saltBytes = [UInt8](repeating: 0, count: 16)
        // Unchecked, a failure here leaves the salt as sixteen zero bytes —
        // the same salt on every install, which is the one thing it exists
        // to prevent. Refuse to set a PIN rather than set a weak one.
        let status = SecRandomCopyBytes(kSecRandomDefault, saltBytes.count, &saltBytes)
        guard status == errSecSuccess else { throw Failure.noEntropy(status) }
        let salt = Data(saltBytes)
        try keychain.set(salt, for: Key.salt)
        try keychain.setString(Self.digest(pin, salt: salt), for: Key.hash)
        resetLockout()
    }

    /// False during a lockout without touching the counters; otherwise
    /// compares the digest and updates failures / lockout.
    func verify(_ pin: String) -> Bool {
        if lockedUntil != nil { return false }
        guard let salt = keychain.get(Key.salt), let stored = keychain.getString(Key.hash) else { return false }
        if Self.digest(pin, salt: salt) == stored {
            resetLockout()
            return true
        }
        let failed = failedAttempts + 1
        if failed >= Self.maxFailures {
            let round = defaults.integer(forKey: Key.round) + 1
            let seconds = Self.baseLockout * pow(2, Double(round - 1))
            defaults.set(round, forKey: Key.round)
            defaults.set(0, forKey: Key.failed)
            defaults.set(now().addingTimeInterval(seconds).timeIntervalSince1970, forKey: Key.lockedUntil)
        } else {
            defaults.set(failed, forKey: Key.failed)
        }
        return false
    }

    func clear() {
        keychain.delete(Key.hash)
        keychain.delete(Key.salt)
        resetLockout()   // already clears the round counter
    }

    private func resetLockout() {
        defaults.removeObject(forKey: Key.failed)
        defaults.removeObject(forKey: Key.round)
        defaults.removeObject(forKey: Key.lockedUntil)
    }

    private static func digest(_ pin: String, salt: Data) -> String {
        SHA256.hash(data: salt + Data(pin.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
