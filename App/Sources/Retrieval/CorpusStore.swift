import Foundation
import SQLite3

/// Read-only wrapper around the bundled `corpus.sqlite`.
///
/// The database is shipped in the app bundle and opened with
/// `SQLITE_OPEN_READONLY`: the app cannot mutate the index at runtime, which
/// removes a whole class of bugs (and means the index can be audited by hash).
///
/// Schema (see Scripts/build_index.py):
///   docs(id, doc_key, title, url, license, revision, char_len)
///   chunks(id, doc_id, ordinal, section, title, char_len, text)
///   chunks_fts = FTS5 external-content index over chunks
final class CorpusStore {

    struct Stats {
        let documents: Int
        let chunks: Int
        let builtAt: String
        let sourceSHA256: String
        let license: String
        let fileSize: Int64
    }

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "corpus.store", qos: .userInitiated)

    private(set) var path: String

    init(path: String) throws {
        self.path = path
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let handle { sqlite3_close(handle) }
            throw CorpusError.openFailed(message)
        }
        // 8 MB page cache: enough for the FTS index metadata without bloating RSS.
        sqlite3_exec(handle, "PRAGMA cache_size = -8000; PRAGMA query_only = 1;", nil, nil, nil)
        self.db = handle
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Search

    /// Runs one FTS5 MATCH query and returns passages ordered by `bm25()`.
    /// The expression must come from `QueryBuilder` (quoted terms only).
    func search(expression: String, limit: Int = 40) throws -> [Passage] {
        guard !expression.isEmpty else { return [] }
        return try queue.sync {
            let sql = """
            SELECT c.id, c.doc_id, d.title, d.url, c.ordinal, c.text, bm25(chunks_fts) AS score
            FROM chunks_fts
            JOIN chunks c ON c.id = chunks_fts.rowid
            JOIN docs   d ON d.id = c.doc_id
            WHERE chunks_fts MATCH ?
            ORDER BY score
            LIMIT ?;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw CorpusError.queryFailed(currentError())
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, expression, -1, Self.transient)
            sqlite3_bind_int(statement, 2, Int32(limit))

            var results: [Passage] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let id = Int(sqlite3_column_int64(statement, 0))
                let docID = Int(sqlite3_column_int64(statement, 1))
                let title = Self.text(statement, 2)
                let url = Self.optionalText(statement, 3)
                let ordinal = Int(sqlite3_column_int64(statement, 4))
                let body = Self.text(statement, 5)
                let score = sqlite3_column_double(statement, 6)
                results.append(Passage(id: id, docID: docID, title: title, url: url,
                                       text: body, ordinal: ordinal, bm25: score))
            }
            return results
        }
    }

    /// Title lookup used by the "open source" affordance and by tests.
    func documentTitle(docID: Int) -> String? {
        queue.sync {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT title FROM docs WHERE id = ? LIMIT 1;", -1, &statement, nil) == SQLITE_OK else {
                return nil
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(docID))
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return Self.text(statement, 0)
        }
    }

    // MARK: - Diagnostics

    func stats() throws -> Stats {
        try queue.sync {
            func scalar(_ sql: String) -> String {
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return "" }
                defer { sqlite3_finalize(statement) }
                guard sqlite3_step(statement) == SQLITE_ROW else { return "" }
                return Self.text(statement, 0)
            }
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            return Stats(
                documents: Int(scalar("SELECT count(*) FROM docs")) ?? 0,
                chunks: Int(scalar("SELECT count(*) FROM chunks")) ?? 0,
                builtAt: scalar("SELECT value FROM meta WHERE key = 'built_at_utc'"),
                sourceSHA256: scalar("SELECT value FROM meta WHERE key = 'source_sha256'"),
                license: scalar("SELECT value FROM meta WHERE key = 'license'"),
                fileSize: size
            )
        }
    }

    /// Cheap self-check used by Diagnostics: FTS must be queryable and in sync.
    func integrityCheck() -> String {
        queue.sync {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT count(*) FROM chunks_fts;", -1, &statement, nil) == SQLITE_OK else {
                return "prepare failed: \(currentError())"
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return "step failed: \(currentError())" }
            return "ok (\(sqlite3_column_int64(statement, 0)) fts rows)"
        }
    }

    // MARK: - SQLite helpers

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func currentError() -> String {
        guard let db else { return "no database" }
        return String(cString: sqlite3_errmsg(db))
    }

    private static func text(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: pointer)
    }

    private static func optionalText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return text(statement, index)
    }

    enum CorpusError: LocalizedError {
        case openFailed(String)
        case queryFailed(String)

        var errorDescription: String? {
            switch self {
            case .openFailed(let detail):
                return "corpus.sqlite could not be opened (\(detail)). Rebuild it with Scripts/build_index.py."
            case .queryFailed(let detail):
                return "Corpus query failed: \(detail)"
            }
        }
    }
}
