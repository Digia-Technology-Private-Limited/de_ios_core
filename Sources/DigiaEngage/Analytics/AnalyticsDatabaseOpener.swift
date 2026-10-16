import Foundation

private let log = DigiaLogger("analytics")

/// Locates, protects and opens the analytics SQLite database, recreating it
/// when SQLite reports the file corrupt.
///
/// Knows nothing about the queue's contents; ``SQLiteQueueStore`` owns the
/// schema.
final class AnalyticsDatabaseOpener {
    static let directoryName = "tech.digia.engage"
    static let fileName = "tech.digia.engage.analytics.db"

    private let resolvePath: () throws -> String
    private var path: String?

    /// [resolvePath] defaults to `Application Support/tech.digia.engage/`.
    init(resolvePath: @escaping () throws -> String = AnalyticsDatabaseOpener.defaultPath) {
        self.resolvePath = resolvePath
    }

    /// Opens the database in WAL mode with `synchronous=FULL`, so a committed
    /// event survives power loss. Throws when the path cannot be resolved or
    /// the file cannot be opened; recreates the file once if it is corrupt.
    func open() throws -> SQLiteConnection {
        let path = try self.path ?? resolvePath()
        self.path = path
        do {
            return try configuredConnection(at: path)
        } catch let error as SQLiteError where error.isCorruption {
            log.w("Analytics database corrupt — recreating it (\(error))")
            Self.deleteFiles(at: path)
            return try configuredConnection(at: path)
        }
    }

    /// Deletes the database and its journal files. Call only after the
    /// connection is closed.
    func wipe() {
        if let path { Self.deleteFiles(at: path) }
    }

    private func configuredConnection(at path: String) throws -> SQLiteConnection {
        let connection = try SQLiteConnection.open(path: path)
        do {
            // WAL first: it is what makes FULL cheap enough per commit.
            try connection.execute("PRAGMA journal_mode = WAL")
            try connection.execute("PRAGMA synchronous = FULL")
            try connection.execute("PRAGMA busy_timeout = 3000")
        } catch {
            connection.close()
            throw error
        }
        Self.protect(path)
        return connection
    }

    /// `completeUntilFirstUserAuthentication` lets background pushes and
    /// dispatch write while the device is locked after first unlock; a host
    /// app defaulting to `complete` would otherwise make SQLite fail with
    /// `SQLITE_CANTOPEN`/`SQLITE_IOERR`. Applied to the companions too: they
    /// exist only once the connection has written.
    private static func protect(_ path: String) {
        for (suffix, file) in [("db", path), ("wal", path + "-wal"), ("shm", path + "-shm")]
        where FileManager.default.fileExists(atPath: file) {
            do {
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: file
                )
            } catch {
                log.w("Analytics file protection not applied (\(suffix)): \(describe(error))")
            }
        }
    }

    /// Domain and code only: a file error's description names the full path.
    private static func describe(_ error: Error) -> String {
        let error = error as NSError
        return "\(error.domain) \(error.code)"
    }

    private static func deleteFiles(at path: String) {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    /// `Application Support/tech.digia.engage/`: protectable, excluded from
    /// backup, not user-visible. Throws rather than falling back to the temp
    /// directory, which iOS may purge while events wait in it.
    static func defaultPath() throws -> String {
        let fileManager = FileManager.default
        let support = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        var directory = support.appendingPathComponent(directoryName, isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        // Also for a directory created by an earlier version without them.
        do {
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: directory.path
            )
        } catch {
            log.w("Analytics directory protection not applied: \(describe(error))")
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try directory.setResourceValues(values)
        } catch {
            log.w("Analytics directory not excluded from backup: \(describe(error))")
        }
        return directory.appendingPathComponent(fileName).path
    }
}
