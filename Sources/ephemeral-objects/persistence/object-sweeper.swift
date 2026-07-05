import Fluent
import Foundation
import NIOFileSystem
import SQLKit
import Vapor

private let cleanupBatchSize: Int = 500
private let maximumCleanupBatches: Int = 10
private let staleUploadAge: TimeInterval = 3_600
private let uploadCleanupGrace: TimeInterval = 300
private let cleanupLockID: Int64 = 7_270_061_337

private struct AdvisoryLockResult: Decodable {
    let acquired: Bool
}

private struct CleanupRow: Decodable {
    let id: String
    let state: String
    let byteSize: Int64?

    enum CodingKeys: String, CodingKey {
        case id
        case state
        case byteSize = "byte_size"
    }
}

actor ObjectSweepController {
    private var task: Task<Void, Never>?

    func start(application: Application, config: app_config) {
        guard task == nil else { return }
        task = Task {
            await run_sweep(application: application, config: config)
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(3_600))
                } catch {
                    break
                }
                await run_sweep(application: application, config: config)
            }
        }
    }

    func stop() async {
        task?.cancel()
        await task?.value
        task = nil
    }
}

struct ObjectSweeperLifecycle: LifecycleHandler {
    let config: app_config
    let controller = ObjectSweepController()

    func didBootAsync(_ application: Application) async throws {
        await controller.start(application: application, config: config)
    }

    func shutdownAsync(_ application: Application) async {
        await controller.stop()
    }
}

private func run_sweep(application: Application, config: app_config) async {
    do {
        try await application.db.transaction { database in
            guard let sql: any SQLDatabase = database as? any SQLDatabase else { return }
            let lock = try await sql.raw(
                "SELECT pg_try_advisory_xact_lock(\(bind: cleanupLockID)) AS acquired"
            ).first(decoding: AdvisoryLockResult.self)
            guard lock?.acquired == true else { return }

            try await clean_database_objects(
                sql: sql,
                directory: config.object_store_directory,
                retentionDays: config.maximum_storage_duration,
                logger: application.logger
            )
            try await clean_orphaned_files(
                database: database,
                directory: config.object_store_directory,
                maximumUploadTime: config.maximum_upload_time,
                logger: application.logger
            )
        }
    } catch {
        application.logger.error("Hourly object reconciliation failed: \(String(reflecting: error))")
    }
}

private func clean_database_objects(
    sql: any SQLDatabase,
    directory: String,
    retentionDays: Int,
    logger: Logger
) async throws {
    let expiration = Calendar(identifier: .gregorian).date(
        byAdding: .day,
        value: -retentionDays,
        to: Date()
    ) ?? Date()
    let pendingCutoff = Date().addingTimeInterval(-staleUploadAge)

    for _ in 0..<maximumCleanupBatches {
        let rows = try await sql.raw(
            """
            SELECT id, state::text AS state, byte_size
            FROM file_objects
            WHERE remaining_downloads <= 0
               OR state = 'deleting'
               OR uploaded_at <= \(bind: expiration)
               OR (state = 'pending' AND uploaded_at <= \(bind: pendingCutoff))
            ORDER BY uploaded_at
            LIMIT \(unsafeRaw: String(cleanupBatchSize))
            FOR UPDATE SKIP LOCKED
            """
        ).all(decoding: CleanupRow.self)
        guard !rows.isEmpty else { break }

        for row in rows {
            try await mark_deleting(id: row.id, sql: sql)
            let finalPath = FilePath(directory).appending(row.id).string
            let temporaryPath = FilePath(directory).appending("\(row.id).uploading").string
            do {
                try remove_if_present(finalPath)
                try remove_if_present(temporaryPath)
                try await sql.raw(
                    "DELETE FROM file_objects WHERE id = \(bind: row.id)"
                ).run()
            } catch {
                logger.error("Unable to delete object \(row.id): \(String(reflecting: error))")
            }
        }
    }

    var cursor: String = ""
    for _ in 0..<maximumCleanupBatches {
        let rows = try await sql.raw(
            """
            SELECT id, state::text AS state, byte_size
            FROM file_objects
            WHERE state = 'available' AND id > \(bind: cursor)
            ORDER BY id
            LIMIT \(unsafeRaw: String(cleanupBatchSize))
            """
        ).all(decoding: CleanupRow.self)
        guard !rows.isEmpty else { break }

        for row in rows {
            cursor = row.id
            let path = FilePath(directory).appending(row.id).string
            if regular_file_size_for_sweep(at: path) != row.byteSize {
                try await sql.raw(
                    "DELETE FROM file_objects WHERE id = \(bind: row.id)"
                ).run()
            }
        }
    }
}

private func clean_orphaned_files(
    database: any Database,
    directory: String,
    maximumUploadTime: Int,
    logger: Logger
) async throws {
    guard let entries: [URL] = try? FileManager.default.contentsOfDirectory(
        at: URL(fileURLWithPath: directory),
        includingPropertiesForKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
        ],
        options: []
    ) else {
        return
    }

    let staleTemporaryFileAge =
        TimeInterval(maximumUploadTime) + uploadCleanupGrace
    var examined: Int = 0
    for entry in entries where examined < cleanupBatchSize * maximumCleanupBatches {
        examined += 1
        let name = entry.lastPathComponent
        let values = try? entry.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        )
        if values?.isSymbolicLink == true {
            do {
                try FileManager.default.removeItem(at: entry)
            } catch {
                logger.error("Unable to remove an orphan symlink: \(String(reflecting: error))")
            }
            continue
        }
        guard values?.isRegularFile == true else { continue }

        if name.hasSuffix(".uploading") {
            guard let modified: Date = values?.contentModificationDate,
                  modified < Date().addingTimeInterval(-staleTemporaryFileAge) else {
                continue
            }
            do {
                try FileManager.default.removeItem(at: entry)
            } catch {
                logger.error("Unable to remove a stale upload: \(String(reflecting: error))")
            }
            continue
        }

        guard let uuid: UUID = UUID(uuidString: name),
              uuid.uuidString.lowercased() == name else {
            do {
                try FileManager.default.removeItem(at: entry)
            } catch {
                logger.error("Unable to remove an invalid orphan file: \(String(reflecting: error))")
            }
            continue
        }
        if try await FileObject.find(name, on: database) == nil {
            do {
                try FileManager.default.removeItem(at: entry)
            } catch {
                logger.error("Unable to remove orphan object \(name): \(String(reflecting: error))")
            }
        }
    }
}

private func mark_deleting(id: String, sql: any SQLDatabase) async throws {
    try await sql.raw(
        "UPDATE file_objects SET state = 'deleting' WHERE id = \(bind: id)"
    ).run()
}

private func remove_if_present(_ path: String) throws {
    if FileManager.default.fileExists(atPath: path) {
        try FileManager.default.removeItem(atPath: path)
    }
}

private func regular_file_size_for_sweep(at path: String) -> Int64? {
    guard let attributes: [FileAttributeKey: Any] = try? FileManager.default.attributesOfItem(atPath: path),
          attributes[.type] as? FileAttributeType == .typeRegular,
          let size: NSNumber = attributes[.size] as? NSNumber else {
        return nil
    }
    return size.int64Value
}
