import Foundation

/// Where collections are kept. One JSON document per name. The FastAPI client
/// conforms to this later; views never learn which one they are talking to.
protocol Repository {
    func load<T: Decodable>(_ name: String, as type: T.Type) throws -> T?
    func save<T: Encodable>(_ value: T, as name: String) throws
    /// Deleting a document is not the same as never writing one: an optional
    /// that becomes nil must erase what it wrote, or the next launch reads
    /// the stale copy back and resurrects it.
    func remove(_ name: String) throws
    /// Move a document that EXISTS and does not decode out of the way, under
    /// `<name>.corrupt`. Board #68.
    ///
    /// Reporting a corrupt file is not enough on its own: every load in
    /// `AppStore.init` falls back to the seed, and the next `persist()` then
    /// writes that seed over the file it could not read. The report would name
    /// a loss that had already been made permanent one write later. Renaming
    /// it first is what leaves something to recover from — the bytes are
    /// still there, and a build that can read them again would find them.
    ///
    /// One quarantine per name: a second corrupt file replaces the first,
    /// rather than growing a pile in a directory nobody sweeps.
    func quarantine(_ name: String) throws
    func wipe() throws
}

extension Repository {
    /// The suffix a quarantined document carries. Here rather than at each
    /// call site so `MemoryRepository` and `FileRepository` cannot drift, and
    /// so a test can name one without spelling the convention itself.
    static func quarantineName(_ name: String) -> String { name + ".corrupt" }
}

final class FileRepository: Repository {
    let directory: URL

    init(directory: URL) { self.directory = directory }

    /// Application Support/MonitorFinance — backed up, not user-visible.
    static func standard() -> FileRepository {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return FileRepository(directory: base.appendingPathComponent("MonitorFinance", isDirectory: true))
    }

    private func url(_ name: String) -> URL {
        directory.appendingPathComponent(name).appendingPathExtension("json")
    }

    func load<T: Decodable>(_ name: String, as type: T.Type) throws -> T? {
        let u = url(name)
        guard FileManager.default.fileExists(atPath: u.path) else { return nil }
        return try SeedLoader.decoder.decode(T.self, from: Data(contentsOf: u))
    }

    func save<T: Encodable>(_ value: T, as name: String) throws {
        // Encrypted at rest: unreadable if the phone is powered off and taken.
        //
        // NOT `.complete`, deliberately. That level makes files unreadable
        // whenever the phone is locked, which makes background sync impossible
        // — a locked phone cannot write — and background sync is a decision the
        // owner made. This level is what banking apps ship.
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try SeedLoader.encoder.encode(value).write(
            to: url(name),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func remove(_ name: String) throws {
        let u = url(name)
        guard FileManager.default.fileExists(atPath: u.path) else { return }
        try FileManager.default.removeItem(at: u)
    }

    func quarantine(_ name: String) throws {
        let from = url(name)
        guard FileManager.default.fileExists(atPath: from.path) else { return }
        let to = url(Self.quarantineName(name))
        // `replaceItemAt` needs a destination that exists; `moveItem` refuses
        // one that does. Remove first, so a second bad launch replaces the
        // first quarantine instead of throwing and leaving the file in place
        // for `persist()` to overwrite — which is the whole failure this
        // method exists to prevent.
        try? FileManager.default.removeItem(at: to)
        try FileManager.default.moveItem(at: from, to: to)
    }

    func wipe() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }
}

/// For unit tests and previews.
final class MemoryRepository: Repository {
    /// **Locked, because board #132 moved persisting off the main actor.**
    ///
    /// `FileRepository` needed nothing — it holds only a `let directory` and
    /// every call is a filesystem syscall. This one is a mutable dictionary,
    /// and the tests that use it read `files` from the main thread while a
    /// debounced persist may be writing from another. That is a data race in
    /// the test target, which is exactly where it would be blamed on anything
    /// but itself.
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    var files: [String: Data] {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); defer { lock.unlock() }; storage = newValue }
    }

    func load<T: Decodable>(_ name: String, as type: T.Type) throws -> T? {
        lock.lock()
        let data = storage[name]
        lock.unlock()
        guard let data else { return nil }
        return try SeedLoader.decoder.decode(T.self, from: data)
    }

    func save<T: Encodable>(_ value: T, as name: String) throws {
        // Encoded OUTSIDE the lock: encoding is the expensive half and holding
        // a lock across it would serialise the very work #132 moved off the
        // main actor to make concurrent.
        let data = try SeedLoader.encoder.encode(value)
        lock.lock(); defer { lock.unlock() }
        storage[name] = data
    }

    func remove(_ name: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[name] = nil
    }

    func quarantine(_ name: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard let data = storage[name] else { return }
        storage[Self.quarantineName(name)] = data
        storage[name] = nil
    }

    func wipe() throws {
        lock.lock(); defer { lock.unlock() }
        storage.removeAll()
    }
}
