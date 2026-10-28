import Foundation
import Security

/// Generic-password items under one service. Nothing clever: the app stores
/// a handful of small secrets (PIN hash, salt, bank tokens).
struct Keychain {
    let service: String
    static let app = Keychain(service: "ua.monitorfinance.app")

    enum Error: Swift.Error { case status(OSStatus) }

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    func set(_ data: Data, for key: String) throws {
        delete(key)
        var q = query(key)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw Error.status(status) }
    }

    func setString(_ s: String, for key: String) throws {
        try set(Data(s.utf8), for: key)
    }

    func get(_ key: String) -> Data? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    func getString(_ key: String) -> String? {
        get(key).flatMap { String(data: $0, encoding: .utf8) }
    }

    func delete(_ key: String) {
        SecItemDelete(query(key) as CFDictionary)
    }

    /// Every item under this service — `-resetState` and tests.
    func wipe() {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service]
        SecItemDelete(q as CFDictionary)
    }

    /// Board #168 — a wipe that spares named keys.
    ///
    /// Read-wipe-restore rather than a query that excludes them, because
    /// `SecItemDelete` has no "everything but these" predicate: the service is
    /// the only handle, and deleting per-key instead would mean this method had
    /// to know every key the app has ever written, including ones removed in a
    /// past version that are still on somebody's phone.
    ///
    /// **The restore is the fragile step and it is deliberately visible.** A
    /// key read back but not written again is gone for good, which for
    /// `privat-email.secret` means a live mailbox nobody can ever read — so the
    /// result says whether every kept key made it, and `resetEverything` uses
    /// that answer rather than assuming.
    @discardableResult
    func wipe(keeping keys: [String]) -> Bool {
        let kept = keys.compactMap { key in getString(key).map { (key, $0) } }
        wipe()
        var restored = true
        for (key, value) in kept {
            do { try setString(value, for: key) } catch { restored = false }
        }
        return restored
    }
}
