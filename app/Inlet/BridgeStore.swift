import Foundation
import SQLite3

/// One normalized record produced by the ingest pipeline.
nonisolated struct BridgedMessage: Sendable {
    let id: String
    let appID: String
    let contentHash: String
    let sourceID: String
    let conversationID: String?
    let conversationName: String?
    let sender: String?
    let senderID: String?
    let outgoing: Bool
    let body: String?
    let sentAt: Date?
}

/// The app's only persistent store. Message content lives in `payload`, sealed
/// by `Vault`; the clear columns hold ids, hashes, timestamps and bookkeeping.
nonisolated final class BridgeStore: @unchecked Sendable {
    enum StoreError: Error { case open(String), query(String) }

    static let quarantineAfter = 3
    static let `default`: BridgeStore = {
        do { return try BridgeStore(url: AppPaths.database) } catch {
            DebugLog.write("store: cannot open database (\(error)); falling back to memory")
            return try! BridgeStore(url: nil)
        }
    }()

    private let db: OpaquePointer
    private let lock = NSRecursiveLock()
    private let vault = Vault.shared
    private var cache: [BridgedMessage]?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL?) throws {
        var handle: OpaquePointer?
        let path = url?.path ?? ":memory:"
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let handle else { throw StoreError.open(path) }
        db = handle
        sqlite3_busy_timeout(db, 3000)
        try exec("PRAGMA journal_mode=WAL; PRAGMA secure_delete=ON;")
        try exec("""
            CREATE TABLE IF NOT EXISTS entities (
                id TEXT PRIMARY KEY, app_id TEXT NOT NULL, schema TEXT NOT NULL, source_id TEXT NOT NULL,
                payload BLOB NOT NULL, content_hash TEXT NOT NULL, revision INTEGER NOT NULL DEFAULT 1,
                profile_key TEXT NOT NULL, profile_sha TEXT NOT NULL, sent_at TEXT,
                first_seen TEXT NOT NULL, last_seen TEXT NOT NULL, donated_hash TEXT);
            CREATE TABLE IF NOT EXISTS batches (
                id INTEGER PRIMARY KEY AUTOINCREMENT, received_at TEXT NOT NULL, profile_key TEXT NOT NULL,
                profile_sha TEXT NOT NULL, app_version TEXT, fingerprint TEXT, seen INTEGER NOT NULL,
                inserted INTEGER NOT NULL, updated INTEGER NOT NULL, unchanged INTEGER NOT NULL,
                rejected INTEGER NOT NULL, canary_ok INTEGER NOT NULL, detail TEXT);
            CREATE TABLE IF NOT EXISTS excluded (
                key_hash TEXT PRIMARY KEY, app_id TEXT NOT NULL, label BLOB NOT NULL, excluded_at TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS profile_state (
                profile_key TEXT PRIMARY KEY, status TEXT NOT NULL DEFAULT 'active',
                consecutive_fails INTEGER NOT NULL DEFAULT 0, fingerprint TEXT,
                fingerprint_changes INTEGER NOT NULL DEFAULT 0, last_ok_at TEXT);
            """)
        if let url {
            for suffix in ["", "-wal", "-shm"] { AppPaths.lockDown(URL(fileURLWithPath: url.path + suffix)) }
        }
    }

    deinit { sqlite3_close(db) }

    // MARK: SQLite plumbing

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError.query(String(cString: sqlite3_errmsg(db))) }
    }

    private enum Bind { case text(String?), blob(Data), int(Int) }

    private func run<T>(_ sql: String, _ binds: [Bind] = [], row: ((OpaquePointer) -> T?)? = nil) throws -> [T] {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw StoreError.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        for (i, bind) in binds.enumerated() {
            let n = Int32(i + 1)
            switch bind {
            case .text(let s?): sqlite3_bind_text(stmt, n, s, -1, Self.transient)
            case .text(nil): sqlite3_bind_null(stmt, n)
            case .int(let v): sqlite3_bind_int64(stmt, n, Int64(v))
            case .blob(let d): _ = d.withUnsafeBytes { sqlite3_bind_blob(stmt, n, $0.baseAddress, Int32(d.count), Self.transient) }
            }
        }
        var out: [T] = []
        while true {
            let code = sqlite3_step(stmt)
            if code == SQLITE_ROW { if let row, let value = row(stmt) { out.append(value) } } else if code == SQLITE_DONE { break } else {
                throw StoreError.query(String(cString: sqlite3_errmsg(db)))
            }
        }
        return out
    }

    private static func text(_ stmt: OpaquePointer, _ col: Int32) -> String? {
        sqlite3_column_text(stmt, col).map { String(cString: $0) }
    }

    private static func now() -> String { ISO8601DateFormatter().string(from: Date()) }

    // MARK: Profile health

    func profileStatus(_ key: String) -> String {
        (try? run("SELECT status FROM profile_state WHERE profile_key=?", [.text(key)]) { Self.text($0, 0) })?.first ?? "active"
    }

    /// Returns the resulting status and whether the source's structure fingerprint drifted.
    func recordCanary(_ key: String, ok: Bool, fingerprint: String?) throws -> (status: String, drift: Bool) {
        lock.lock(); defer { lock.unlock() }
        _ = try run("INSERT OR IGNORE INTO profile_state (profile_key) VALUES (?)", [.text(key)]) as [Int]
        let state = try run("SELECT status, consecutive_fails, fingerprint FROM profile_state WHERE profile_key=?", [.text(key)]) {
            (Self.text($0, 0) ?? "active", Int(sqlite3_column_int64($0, 1)), Self.text($0, 2))
        }.first ?? ("active", 0, nil)
        let drift = fingerprint != nil && state.2 != nil && fingerprint != state.2
        let fails = ok ? 0 : state.1 + 1
        let status = fails >= Self.quarantineAfter ? "quarantined" : state.0
        _ = try run("""
            UPDATE profile_state SET status=?, consecutive_fails=?, fingerprint=COALESCE(?, fingerprint),
                fingerprint_changes=fingerprint_changes+?, last_ok_at=CASE WHEN ? THEN ? ELSE last_ok_at END
            WHERE profile_key=?
            """, [.text(status), .int(fails), .text(ok ? fingerprint : nil), .int(drift ? 1 : 0), .int(ok ? 1 : 0), .text(Self.now()), .text(key)]) as [Int]
        return (status, drift)
    }

    func release(_ key: String) throws {
        _ = try run("UPDATE profile_state SET status='active', consecutive_fails=0 WHERE profile_key=?", [.text(key)]) as [Int]
    }

    func profileStates() -> [(key: String, status: String)] {
        (try? run("SELECT profile_key, status FROM profile_state") { (Self.text($0, 0) ?? "", Self.text($0, 1) ?? "") }) ?? []
    }

    // MARK: Entities

    enum UpsertResult: String { case inserted, updated, unchanged }

    func upsert(id: String, appID: String, schema: String, record: [String: Any], profileKey: String, profileSHA: String) throws -> UpsertResult {
        lock.lock(); defer { lock.unlock() }
        let canonical = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes])
        let digest = vault.keyedHash(canonical)
        let existing = try run("SELECT content_hash FROM entities WHERE id=?", [.text(id)]) { Self.text($0, 0) }.first
        let ts = Self.now()
        if existing == digest {
            _ = try run("UPDATE entities SET last_seen=? WHERE id=?", [.text(ts), .text(id)]) as [Int]
            return .unchanged
        }
        let sealed = try vault.seal(canonical)
        let sentAt = record["sentAt"] as? String
        cache = nil
        if existing == nil {
            _ = try run("""
                INSERT INTO entities (id, app_id, schema, source_id, payload, content_hash, profile_key, profile_sha, sent_at, first_seen, last_seen)
                VALUES (?,?,?,?,?,?,?,?,?,?,?)
                """, [.text(id), .text(appID), .text(schema), .text(record["sourceId"] as? String), .blob(sealed), .text(digest),
                      .text(profileKey), .text(profileSHA), .text(sentAt), .text(ts), .text(ts)]) as [Int]
            return .inserted
        }
        // Which fields changed (names only, never values): makes churn in a source diagnosable.
        if let oldSealed = try run("SELECT payload FROM entities WHERE id=?", [.text(id)], row: { stmt -> Data? in
            sqlite3_column_blob(stmt, 0).map { Data(bytes: $0, count: Int(sqlite3_column_bytes(stmt, 0))) }
        }).first, let oldPlain = try? vault.open(oldSealed),
           let old = (try? JSONSerialization.jsonObject(with: oldPlain)) as? [String: Any] {
            let changed = record.keys.filter { "\(old[$0] ?? NSNull())" != "\(record[$0] ?? NSNull())" }.sorted()
            DebugLog.write("update \(profileKey): changed \(changed.joined(separator: ","))")
        }
        _ = try run("""
            UPDATE entities SET payload=?, content_hash=?, revision=revision+1, profile_key=?, profile_sha=?, sent_at=?, last_seen=? WHERE id=?
            """, [.blob(sealed), .text(digest), .text(profileKey), .text(profileSHA), .text(sentAt), .text(ts), .text(id)]) as [Int]
        return .updated
    }

    func logBatch(profileKey: String, profileSHA: String, appVersion: String?, fingerprint: String?, counts: [String: Int], canaryOK: Bool, detail: [String]) throws {
        let detailJSON = detail.isEmpty ? nil : String(data: (try? JSONSerialization.data(withJSONObject: detail)) ?? Data(), encoding: .utf8)
        _ = try run("""
            INSERT INTO batches (received_at, profile_key, profile_sha, app_version, fingerprint, seen, inserted, updated, unchanged, rejected, canary_ok, detail)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
            """, [.text(Self.now()), .text(profileKey), .text(profileSHA), .text(appVersion), .text(fingerprint),
                  .int(counts["seen"] ?? 0), .int(counts["inserted"] ?? 0), .int(counts["updated"] ?? 0),
                  .int(counts["unchanged"] ?? 0), .int(counts["rejected"] ?? 0), .int(canaryOK ? 1 : 0), .text(detailJSON)]) as [Int]
    }

    // MARK: Reading

    private func decode(_ stmt: OpaquePointer) -> BridgedMessage? {
        guard let id = Self.text(stmt, 0), let appID = Self.text(stmt, 1), let hash = Self.text(stmt, 2),
              let bytes = sqlite3_column_blob(stmt, 3) else { return nil }
        let sealed = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 3)))
        guard let plain = try? vault.open(sealed),
              let p = try? JSONSerialization.jsonObject(with: plain) as? [String: Any] else { return nil }
        return BridgedMessage(
            id: id, appID: appID, contentHash: hash, sourceID: p["sourceId"] as? String ?? "",
            conversationID: p["conversationId"] as? String, conversationName: p["conversationName"] as? String,
            sender: p["sender"] as? String, senderID: p["senderId"] as? String, outgoing: p["direction"] as? String == "outgoing",
            body: p["body"] as? String, sentAt: (p["sentAt"] as? String).flatMap(Self.parseDate))
    }

    private static let columns = "id, app_id, content_hash, payload"

    /// Newest first. Decrypted once and cached until the next write.
    func allMessages() throws -> [BridgedMessage] {
        lock.lock(); defer { lock.unlock() }
        if let cache { return cache }
        let rows = try run("SELECT \(Self.columns) FROM entities WHERE schema='messages.message' ORDER BY sent_at DESC") { self.decode($0) }
        cache = rows
        return rows
    }

    /// Records Siri doesn't have yet (or has an older version of), skipping apps the user paused.
    func pending(limit: Int = 500, excludingApps paused: Set<String> = []) throws -> [BridgedMessage] {
        let marks = Array(repeating: "?", count: paused.count).joined(separator: ",")
        let skip = paused.isEmpty ? "" : " AND app_id NOT IN (\(marks))"
        return try run("SELECT \(Self.columns) FROM entities WHERE schema='messages.message' AND donated_hash IS NOT content_hash\(skip) LIMIT \(limit)",
                       paused.sorted().map { .text($0) }) { self.decode($0) }
    }

    func ids(appID: String) -> [String] {
        (try? run("SELECT id FROM entities WHERE app_id=?", [.text(appID)]) { Self.text($0, 0) }) ?? []
    }

    /// Deletes what is older than the user's "Keep" choice. Returns the removed entity ids.
    func prune(appID: String, olderThan cutoff: Date) throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        let limit = ISO8601DateFormatter().string(from: cutoff)
        let ids = try run("SELECT id FROM entities WHERE app_id=? AND sent_at IS NOT NULL AND sent_at < ?", [.text(appID), .text(limit)]) { Self.text($0, 0) }
        guard !ids.isEmpty else { return [] }
        _ = try run("DELETE FROM entities WHERE app_id=? AND sent_at IS NOT NULL AND sent_at < ?", [.text(appID), .text(limit)]) as [Int]
        cache = nil
        return ids
    }

    func messages(ids: [String]) throws -> [BridgedMessage] {
        guard !ids.isEmpty else { return [] }
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        return try run("SELECT \(Self.columns) FROM entities WHERE id IN (\(marks))", ids.map { .text($0) }) { self.decode($0) }
    }

    func recentlyDonated(limit: Int = 8) throws -> [BridgedMessage] {
        Array(try allMessages().lazy.filter { $0.body != nil }.prefix(limit))
    }

    /// Every word must appear in the body, sender or chat name. Runs over decrypted rows in memory.
    func search(_ words: String, limit: Int = 8) throws -> [BridgedMessage] {
        let terms = words.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 1 }
        guard !terms.isEmpty else { return [] }
        return Array(try allMessages().lazy.filter { m in
            let hay = "\(m.body ?? "") \(m.sender ?? "") \(m.conversationName ?? "")".lowercased()
            return terms.allSatisfy { hay.contains($0) }
        }.prefix(limit))
    }

    func counts() throws -> (total: Int, pending: Int) {
        try run("SELECT COUNT(*), COALESCE(SUM(donated_hash IS NOT content_hash), 0) FROM entities WHERE schema='messages.message'") {
            (Int(sqlite3_column_int64($0, 0)), Int(sqlite3_column_int64($0, 1)))
        }.first ?? (0, 0)
    }

    func countsByApp() -> [String: Int] {
        Dictionary(uniqueKeysWithValues: (try? run("SELECT app_id, COUNT(*) FROM entities GROUP BY app_id") {
            (Self.text($0, 0) ?? "", Int(sqlite3_column_int64($0, 1)))
        }) ?? [])
    }

    // MARK: Conversations and exclusions

    func conversation(appID: String, conversationID: String) throws -> [BridgedMessage] {
        try allMessages().filter { $0.appID == appID && $0.conversationID == conversationID }
            .sorted { ($0.sentAt ?? .distantPast) < ($1.sentAt ?? .distantPast) }
    }

    /// Chat ids are never stored in clear: exclusions are matched by keyed hash, the label is sealed.
    private func exclusionKey(_ appID: String, _ conversationID: String) -> String {
        vault.keyedHash(Data("\(appID)\u{1f}\(conversationID)".utf8))
    }

    func isExcluded(appID: String, conversationID: String?) -> Bool {
        guard let conversationID else { return false }
        let key = exclusionKey(appID, conversationID)
        return ((try? run("SELECT 1 FROM excluded WHERE key_hash=?", [.text(key)]) { _ in 1 })?.isEmpty == false)
    }

    /// Stops indexing a chat and deletes what was stored from it. Returns the removed entity ids.
    func exclude(appID: String, conversationID: String, label: String) throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        let ids = try conversation(appID: appID, conversationID: conversationID).map(\.id)
        _ = try run("INSERT OR REPLACE INTO excluded (key_hash, app_id, label, excluded_at) VALUES (?,?,?,?)",
                    [.text(exclusionKey(appID, conversationID)), .text(appID), .blob(try vault.seal(Data(label.utf8))), .text(Self.now())]) as [Int]
        for id in ids { _ = try run("DELETE FROM entities WHERE id=?", [.text(id)]) as [Int] }
        cache = nil
        return ids
    }

    func exclusions() -> [(keyHash: String, appID: String, label: String)] {
        (try? run("SELECT key_hash, app_id, label FROM excluded ORDER BY excluded_at DESC") { stmt -> (String, String, String)? in
            guard let key = Self.text(stmt, 0), let app = Self.text(stmt, 1), let bytes = sqlite3_column_blob(stmt, 2) else { return nil }
            let sealed = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 2)))
            let label = (try? self.vault.open(sealed)).flatMap { String(data: $0, encoding: .utf8) } ?? "Chat"
            return (key, app, label)
        }) ?? []
    }

    func include(keyHash: String) throws {
        _ = try run("DELETE FROM excluded WHERE key_hash=?", [.text(keyHash)]) as [Int]
    }

    // MARK: Donation bookkeeping

    func markDonated(_ messages: [BridgedMessage]) throws {
        lock.lock(); defer { lock.unlock() }
        try exec("BEGIN")
        for m in messages {
            _ = try run("UPDATE entities SET donated_hash=? WHERE id=? AND content_hash=?", [.text(m.contentHash), .text(m.id), .text(m.contentHash)]) as [Int]
        }
        try exec("COMMIT")
    }

    func resetDonations() throws { try exec("UPDATE entities SET donated_hash = NULL") }

    func resetDonations(appID: String) throws {
        _ = try run("UPDATE entities SET donated_hash = NULL WHERE app_id=?", [.text(appID)]) as [Int]
    }

    // MARK: Erasure

    /// Removes stored content for one source (or all of it). `secure_delete` zeroes the freed pages.
    func deleteEverything(appID: String? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        cache = nil
        if let appID {
            _ = try run("DELETE FROM entities WHERE app_id=?", [.text(appID)]) as [Int]
        } else {
            try exec("DELETE FROM entities; DELETE FROM batches; DELETE FROM profile_state; DELETE FROM excluded;")
        }
        try exec("PRAGMA wal_checkpoint(TRUNCATE); VACUUM;")
    }

    private static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
