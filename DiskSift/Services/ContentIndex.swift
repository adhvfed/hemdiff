import Foundation
import SQLite3

enum FileOrder: String, CaseIterable, Sendable {
    case size = "Size", name = "Name", modified = "Modified", path = "Location"

    func precedes(_ lhs: ContentItem, _ rhs: ContentItem) -> Bool {
        switch self {
        case .size:
            if lhs.allocatedBytes != rhs.allocatedBytes { return lhs.allocatedBytes > rhs.allocatedBytes }
        case .modified:
            if lhs.modifiedAt != rhs.modifiedAt { return (lhs.modifiedAt ?? .distantPast) > (rhs.modifiedAt ?? .distantPast) }
        case .name:
            let comparison = lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent)
            if comparison != .orderedSame { return comparison == .orderedAscending }
        case .path: break
        }
        return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
    }
}

struct ContentPage: Sendable {
    let items: [ContentItem]
    let count: Int
}

/// A scan-owned SQLite file keeps a complete inventory without retaining every path in RAM.
/// Connections stay on their calling thread; published indexes are opened by separate readers.
final class ContentIndex {
    private var database: OpaquePointer?
    private var insertStatement: OpaquePointer?
    let path: String
    private let encoder = JSONEncoder()

    init(path: String, create: Bool = false) throws {
        self.path = path
        let flags = create ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE : SQLITE_OPEN_READWRITE
        guard sqlite3_open_v2(path, &database, flags, nil) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        sqlite3_busy_timeout(database, 3_000)
        if create {
            try execute("PRAGMA journal_mode=DELETE; CREATE TABLE files(path TEXT PRIMARY KEY, name TEXT, kind TEXT, bytes INTEGER, modified REAL, item BLOB); BEGIN TRANSACTION;")
            guard sqlite3_prepare_v2(database, "INSERT OR REPLACE INTO files VALUES(?,?,?,?,?,?)", -1, &insertStatement, nil) == SQLITE_OK else { throw failure() }
        }
    }

    deinit {
        sqlite3_finalize(insertStatement)
        sqlite3_close(database)
    }

    static func temporary() throws -> ContentIndex {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DiskSift/Indexes", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try ContentIndex(path: directory.appendingPathComponent("\(UUID().uuidString).sqlite").path, create: true)
    }

    func discard() {
        sqlite3_finalize(insertStatement)
        insertStatement = nil
        sqlite3_close(database)
        database = nil
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-journal")
    }

    func append(_ item: ContentItem) throws {
        guard let statement = insertStatement else { throw failure() }
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        bind(item.path, to: statement, at: 1)
        bind(item.url.lastPathComponent, to: statement, at: 2)
        bind(item.kind.rawValue, to: statement, at: 3)
        sqlite3_bind_int64(statement, 4, item.allocatedBytes)
        sqlite3_bind_double(statement, 5, item.modifiedAt?.timeIntervalSince1970 ?? 0)
        let data = try encoder.encode(item)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 6, $0.baseAddress, Int32(data.count), transient) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    func finish() throws {
        try execute("COMMIT; CREATE INDEX by_size ON files(bytes DESC, path); CREATE INDEX by_kind ON files(kind, bytes DESC); CREATE INDEX by_name ON files(name COLLATE NOCASE, path);")
        sqlite3_finalize(insertStatement)
        insertStatement = nil
    }

    func page(kinds: Set<ContentKind>, search: String, order: FileOrder, offset: Int, limit: Int = 250) throws -> ContentPage {
        let types = kinds.map(\.rawValue).sorted()
        let filter = (types.isEmpty ? "1" : "kind IN (\(types.map { _ in "?" }.joined(separator: ",")))")
            + " AND instr(lower(path),lower(?)) > 0"
        let ordering: String
        switch order {
        case .size: ordering = "bytes DESC, path"
        case .name: ordering = "name COLLATE NOCASE, path"
        case .modified: ordering = "modified DESC, path"
        case .path: ordering = "path COLLATE NOCASE"
        }
        let values = types + [search]
        let countRows = try rows("SELECT count(*) FROM files WHERE \(filter)", values: values) { Int(sqlite3_column_int64($0, 0)) }
        let items = try rows("SELECT item FROM files WHERE \(filter) ORDER BY \(ordering) LIMIT \(max(1, limit)) OFFSET \(max(0, offset))", values: values, decode)
        return ContentPage(items: items, count: countRows.first ?? 0)
    }

    func remove(paths: [String]) throws {
        try execute("BEGIN TRANSACTION")
        do {
            for path in paths { _ = try rows("DELETE FROM files WHERE path = ?", values: [path]) { _ in 0 } }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    func inventory() throws -> ContentInventory {
        let summaries = try rows("SELECT kind, count(*), sum(bytes) FROM files GROUP BY kind ORDER BY sum(bytes) DESC", values: []) { statement -> ContentSummary in
            let kind = ContentKind(rawValue: String(cString: sqlite3_column_text(statement, 0))) ?? .other
            return ContentSummary(kind: kind, count: Int(sqlite3_column_int64(statement, 1)), allocatedBytes: sqlite3_column_int64(statement, 2))
        }
        var result = ContentInventory(summaries: summaries)
        result.indexPath = path
        for index in result.summaries.indices {
            result.summaries[index].largestItems = try page(kinds: [result.summaries[index].kind], search: "", order: .size, offset: 0, limit: 100).items
        }
        return result
    }

    private var transient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }
    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) {
        _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func rows<T>(_ sql: String, values: [String], _ read: (OpaquePointer) throws -> T) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() { bind(value, to: statement, at: Int32(index + 1)) }
        var result: [T] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw failure() }
            result.append(try read(statement))
        }
    }
    private func decode(_ statement: OpaquePointer) throws -> ContentItem {
        guard let bytes = sqlite3_column_blob(statement, 0) else { throw failure() }
        return try JSONDecoder().decode(ContentItem.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
    }
    private func failure() -> NSError { NSError(domain: "DiskSift.ContentIndex", code: Int(sqlite3_errcode(database)), userInfo: [NSLocalizedDescriptionKey: "The file index could not be read or updated."]) }
}
