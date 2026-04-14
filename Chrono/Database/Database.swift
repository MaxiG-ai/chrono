import Foundation

/// Central database manager. Owns the SQLite connection and serializes all
/// access through a single dispatch queue. Callers should interact via
/// `write { db in ... }` and `read { db in ... }` blocks.
///
/// Rationale for the serial-queue approach: SQLite in WAL mode can handle
/// concurrent readers, but for simplicity and correctness we serialize all
/// access. The app's query volume is trivial (user-driven taps) and this
/// removes an entire class of concurrency bugs.
final class Database: @unchecked Sendable {
    static let shared: Database = {
        do {
            return try Database(path: Database.defaultPath())
        } catch {
            // If we can't open the database at startup, the app cannot function.
            // Surface the error immediately rather than running in a broken state.
            fatalError("Failed to open database: \(error)")
        }
    }()

    private let connection: SQLiteConnection
    private let queue: DispatchQueue

    init(path: String) throws {
        self.connection = try SQLiteConnection(path: path)
        self.queue = DispatchQueue(label: "app.chrono.Chrono.db", qos: .userInitiated)
        try queue.sync {
            try Migrations.run(on: connection)
        }
    }

    /// Location of the production database. Lives in Application Support per spec.
    static func defaultPath() throws -> String {
        let fm = FileManager.default
        let dir = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        // Explicit subdirectory to keep the WAL / SHM siblings grouped.
        let chronoDir = dir.appendingPathComponent("Chrono", isDirectory: true)
        if !fm.fileExists(atPath: chronoDir.path) {
            try fm.createDirectory(at: chronoDir, withIntermediateDirectories: true)
        }
        return chronoDir.appendingPathComponent("chrono.db").path
    }

    // MARK: - Access primitives

    func write<T>(_ block: (SQLiteConnection) throws -> T) throws -> T {
        try queue.sync {
            try connection.transaction {
                try block(connection)
            }
        }
    }

    func read<T>(_ block: (SQLiteConnection) throws -> T) throws -> T {
        try queue.sync {
            try block(connection)
        }
    }

    /// Merge WAL into the main database file before taking a backup copy.
    func checkpoint() throws {
        try queue.sync {
            try connection.execute("PRAGMA wal_checkpoint(TRUNCATE);")
        }
    }

    // MARK: - Async wrappers for SwiftUI

    func writeAsync<T: Sendable>(_ block: @Sendable @escaping (SQLiteConnection) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let value = try self.connection.transaction {
                        try block(self.connection)
                    }
                    cont.resume(returning: value)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    func readAsync<T: Sendable>(_ block: @Sendable @escaping (SQLiteConnection) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    cont.resume(returning: try block(self.connection))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}
