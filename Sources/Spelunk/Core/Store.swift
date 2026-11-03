import Foundation
import SQLite3

/// Per-repository persistent state in one SQLite database (WAL, so several windows can share it).
///
/// - `results`: content-addressed outputs that do not depend on which review asked for them (Claude
///   tiers per hunk content, rule-question answers, attachment results). Rows record when they were
///   last used and are pruned after a while.
/// - `review_state`: per-review user state (viewed marks, notes, overview, groups), keyed by a
///   resolved review identity (a PR number, a jj change id, a commit), never by a relative name.
/// - `drafts`: pending review comments, stamped with the pull request and commit they were written for.
/// - `jobs`: finished Claude asks and traces.
/// - `items`: code paths and bookmarks, one row each, ordered by position.
actor Store {
    private var db: OpaquePointer?
    let url: URL

    private static let lock = NSLock()
    nonisolated(unsafe) private static var open: [String: Store] = [:]

    static func shared(for root: URL) -> Store {
        lock.lock(); defer { lock.unlock() }
        if let s = open[root.path] { return s }
        let s = Store(url: AppPaths.support(for: root).appendingPathComponent("spelunk.sqlite"))
        open[root.path] = s
        return s
    }

    init(url: URL) {
        self.url = url
        var handle: OpaquePointer?
        if sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK {
            db = handle
            Store.configure(handle)
        } else {
            Log.debug("store: cannot open \(url.path)")
            sqlite3_close(handle)
        }
    }

    private static let migrations: [String] = [
        """
        CREATE TABLE results (task TEXT NOT NULL, key TEXT NOT NULL, value BLOB NOT NULL, model TEXT,
                              updated REAL NOT NULL, used REAL NOT NULL, PRIMARY KEY (task, key));
        CREATE INDEX results_used ON results(used);
        CREATE TABLE review_state (review TEXT NOT NULL, kind TEXT NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL,
                                   updated REAL NOT NULL, PRIMARY KEY (review, kind, key));
        CREATE TABLE drafts (id TEXT PRIMARY KEY, review TEXT NOT NULL, pr INTEGER, commit_id TEXT, value TEXT NOT NULL,
                             created REAL NOT NULL);
        CREATE INDEX drafts_review ON drafts(review);
        CREATE TABLE jobs (id TEXT PRIMARY KEY, value TEXT NOT NULL, created REAL NOT NULL);
        """,
        """
        CREATE TABLE items (kind TEXT NOT NULL, id TEXT NOT NULL, value TEXT NOT NULL, position REAL NOT NULL,
                            PRIMARY KEY (kind, id));
        """,
    ]

    /// Runs outside actor isolation from `init`; the handle is not shared yet.
    private static func configure(_ db: OpaquePointer?) {
        sqlite3_busy_timeout(db, 3000)
        sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;", nil, nil, nil)
        var version: Int32 = 0
        var st: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &st, nil) == SQLITE_OK, sqlite3_step(st) == SQLITE_ROW {
            version = sqlite3_column_int(st, 0)
        }
        sqlite3_finalize(st)
        for (i, sql) in migrations.enumerated() where Int32(i) >= version {
            sqlite3_exec(db, "BEGIN", nil, nil, nil)
            if sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, sqlite3_exec(db, "PRAGMA user_version = \(i + 1)", nil, nil, nil) == SQLITE_OK {
                sqlite3_exec(db, "COMMIT", nil, nil, nil)
            } else {
                Log.debug("store: migration \(i + 1) failed: \(String(cString: sqlite3_errmsg(db)))")
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                return
            }
        }
    }

    // MARK: Statement helpers

    enum Value: Sendable {
        case text(String), blob(Data), real(Double), int(Int64), null
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    @discardableResult
    private func exec(_ sql: String, _ args: [Value] = []) -> Bool {
        guard let db else { return false }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
            Log.debug("store: \(String(cString: sqlite3_errmsg(db))) in \(sql.prefix(80))")
            return false
        }
        defer { sqlite3_finalize(st) }
        bind(st, args)
        return sqlite3_step(st) == SQLITE_DONE
    }

    private func query(_ sql: String, _ args: [Value] = [], _ row: (OpaquePointer?) -> Void) {
        guard let db else { return }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
            Log.debug("store: \(String(cString: sqlite3_errmsg(db))) in \(sql.prefix(80))")
            return
        }
        defer { sqlite3_finalize(st) }
        bind(st, args)
        while sqlite3_step(st) == SQLITE_ROW { row(st) }
    }

    private func bind(_ st: OpaquePointer?, _ args: [Value]) {
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case .text(let s): sqlite3_bind_text(st, idx, s, -1, Self.transient)
            case .blob(let d): _ = d.withUnsafeBytes { sqlite3_bind_blob(st, idx, $0.baseAddress, Int32(d.count), Self.transient) }
            case .real(let r): sqlite3_bind_double(st, idx, r)
            case .int(let n): sqlite3_bind_int64(st, idx, n)
            case .null: sqlite3_bind_null(st, idx)
            }
        }
    }

    private static func text(_ st: OpaquePointer?, _ i: Int32) -> String {
        sqlite3_column_text(st, i).map { String(cString: $0) } ?? ""
    }

    private static func blob(_ st: OpaquePointer?, _ i: Int32) -> Data {
        let n = Int(sqlite3_column_bytes(st, i))
        guard n > 0, let p = sqlite3_column_blob(st, i) else { return Data() }
        return Data(bytes: p, count: n)
    }

    private func transaction(_ body: () -> Void) {
        exec("BEGIN IMMEDIATE")
        body()
        exec("COMMIT")
    }

    private var now: Double { Date().timeIntervalSince1970 }

    // MARK: Results

    /// Values for the given keys of one task; marks them used.
    func results(task: String, keys: [String]) -> [String: Data] {
        var out: [String: Data] = [:]
        let t = now
        for chunk in stride(from: 0, to: keys.count, by: 500).map({ Array(keys[$0..<min($0 + 500, keys.count)]) }) {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let args = [Value.text(task)] + chunk.map { .text($0) }
            query("SELECT key, value FROM results WHERE task = ? AND key IN (\(marks))", args) { st in
                out[Self.text(st, 0)] = Self.blob(st, 1)
            }
            exec("UPDATE results SET used = ? WHERE task = ? AND key IN (\(marks))", [.real(t)] + args)
        }
        return out
    }

    func putResults(task: String, _ entries: [(key: String, value: Data)], model: String? = nil) {
        let t = now
        transaction {
            for e in entries {
                exec("INSERT INTO results(task, key, value, model, updated, used) VALUES (?,?,?,?,?,?) " +
                     "ON CONFLICT(task, key) DO UPDATE SET value = excluded.value, model = excluded.model, updated = excluded.updated, used = excluded.used",
                     [.text(task), .text(e.key), .blob(e.value), model.map { .text($0) } ?? .null, .real(t), .real(t)])
            }
        }
    }

    func deleteResults(task: String, keys: [String]) {
        transaction { for k in keys { exec("DELETE FROM results WHERE task = ? AND key = ?", [.text(task), .text(k)]) } }
    }

    /// Drops results nobody has used for `days`.
    func prune(days: Double = 90) {
        exec("DELETE FROM results WHERE used < ?", [.real(now - days * 86_400)])
    }

    // MARK: Review state

    struct StateRow: Sendable { var kind: String; var key: String; var value: String }

    func reviewState(_ review: String) -> [StateRow] {
        var out: [StateRow] = []
        query("SELECT kind, key, value FROM review_state WHERE review = ?", [.text(review)]) { st in
            out.append(StateRow(kind: Self.text(st, 0), key: Self.text(st, 1), value: Self.text(st, 2)))
        }
        return out
    }

    func hasReviewState(_ review: String) -> Bool {
        var found = false
        query("SELECT 1 FROM review_state WHERE review = ? LIMIT 1", [.text(review)]) { _ in found = true }
        return found
    }

    /// Upserts rows with a value and deletes rows whose value is nil.
    func applyReviewState(_ review: String, _ changes: [(kind: String, key: String, value: String?)]) {
        guard !changes.isEmpty else { return }
        let t = now
        transaction {
            for c in changes {
                if let v = c.value {
                    exec("INSERT INTO review_state(review, kind, key, value, updated) VALUES (?,?,?,?,?) " +
                         "ON CONFLICT(review, kind, key) DO UPDATE SET value = excluded.value, updated = excluded.updated",
                         [.text(review), .text(c.kind), .text(c.key), .text(v), .real(t)])
                } else {
                    exec("DELETE FROM review_state WHERE review = ? AND kind = ? AND key = ?", [.text(review), .text(c.kind), .text(c.key)])
                }
            }
        }
    }

    // MARK: Drafts

    func drafts(_ review: String) -> [Data] {
        var out: [Data] = []
        query("SELECT value FROM drafts WHERE review = ? ORDER BY created", [.text(review)]) { st in out.append(Data(Self.text(st, 0).utf8)) }
        return out
    }

    func putDraft(id: String, review: String, pr: Int?, commit: String?, value: Data) {
        exec("INSERT INTO drafts(id, review, pr, commit_id, value, created) VALUES (?,?,?,?,?,?) " +
             "ON CONFLICT(id) DO UPDATE SET value = excluded.value, pr = excluded.pr, commit_id = excluded.commit_id",
             [.text(id), .text(review), pr.map { .int(Int64($0)) } ?? .null, commit.map { .text($0) } ?? .null,
              .text(String(decoding: value, as: UTF8.self)), .real(now)])
    }

    func deleteDrafts(_ ids: [String]) {
        transaction { for id in ids { exec("DELETE FROM drafts WHERE id = ?", [.text(id)]) } }
    }

    // MARK: Items

    func items(_ kind: String) -> [Data] {
        var out: [Data] = []
        query("SELECT value FROM items WHERE kind = ? ORDER BY position", [.text(kind)]) { st in out.append(Data(Self.text(st, 0).utf8)) }
        return out
    }

    /// Writes changed items and deletes removed ones in one transaction.
    func syncItems(_ kind: String, upsert: [(id: String, value: Data, position: Double)], delete: [String]) {
        transaction {
            for u in upsert {
                exec("INSERT INTO items(kind, id, value, position) VALUES (?,?,?,?) " +
                     "ON CONFLICT(kind, id) DO UPDATE SET value = excluded.value, position = excluded.position",
                     [.text(kind), .text(u.id), .text(String(decoding: u.value, as: UTF8.self)), .real(u.position)])
            }
            for id in delete { exec("DELETE FROM items WHERE kind = ? AND id = ?", [.text(kind), .text(id)]) }
        }
    }

    // MARK: Jobs

    func jobs(limit: Int = 60) -> [Data] {
        var out: [Data] = []
        query("SELECT value FROM jobs ORDER BY created DESC LIMIT ?", [.int(Int64(limit))]) { st in out.append(Data(Self.text(st, 0).utf8)) }
        return out.reversed()
    }

    func putJob(id: String, value: Data, created: Date) {
        exec("INSERT INTO jobs(id, value, created) VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET value = excluded.value",
             [.text(id), .text(String(decoding: value, as: UTF8.self)), .real(created.timeIntervalSince1970)])
    }

    func deleteJobs(_ ids: [String]) {
        transaction { for id in ids { exec("DELETE FROM jobs WHERE id = ?", [.text(id)]) } }
    }
}
