import Fluent
import Foundation
import NIOFileSystem
import SQLKit
import Vapor

private struct DownloadRecord: Codable, Sendable {
    let id: String
    let originalFilename: String
    let contentType: String
    let byteSize: Int64
    let sha256: String
    let remainingDownloads: Int

    enum CodingKeys: String, CodingKey {
        case id
        case originalFilename = "original_filename"
        case contentType = "content_type"
        case byteSize = "byte_size"
        case sha256
        case remainingDownloads = "remaining_downloads"
    }
}

func download_object(req: Request, config: app_config) async throws -> Response {
    guard req.headers.first(name: .range) == nil else {
        let response = Response(status: .rangeNotSatisfiable)
        response.headers.replaceOrAdd(name: .acceptRanges, value: "none")
        return response
    }

    guard let rawID: String = req.parameters.get("id"),
          let uuid: UUID = UUID(uuidString: rawID),
          uuid.uuidString.lowercased() == rawID else {
        return try await file_not_found(req: req)
    }

    let cutoff = Calendar(identifier: .gregorian).date(
        byAdding: .day,
        value: -config.maximum_storage_duration,
        to: Date()
    ) ?? Date()

    guard let record: DownloadRecord = try await claim_download(
        id: rawID,
        cutoff: cutoff,
        directory: config.object_store_directory,
        database: req.db
    ) else {
        return try await file_not_found(req: req)
    }

    let path = FilePath(config.object_store_directory).appending(record.id).string
    req.headers.remove(name: .ifNoneMatch)

    do {
        let response = try await req.fileio.asyncStreamFile(at: path) { _ in
            if record.remainingDownloads == 0 {
                await delete_object(
                    id: record.id,
                    path: path,
                    database: req.db,
                    logger: req.logger
                )
            }
        }
        response.headers.replaceOrAdd(name: .contentType, value: record.contentType)
        response.headers.replaceOrAdd(name: .contentLength, value: String(record.byteSize))
        response.headers.replaceOrAdd(
            name: .contentDisposition,
            value: content_disposition(filename: record.originalFilename)
        )
        response.headers.replaceOrAdd(name: .eTag, value: "\"\(record.sha256)\"")
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        response.headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        response.headers.replaceOrAdd(name: .acceptRanges, value: "none")
        return response
    } catch {
        try? await restore_download(id: record.id, database: req.db)
        throw error
    }
}

private func claim_download(
    id: String,
    cutoff: Date,
    directory: String,
    database: any Database
) async throws -> DownloadRecord? {
    try await database.transaction { transaction in
        guard let sql: any SQLDatabase = transaction as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "The database does not support SQL locking.")
        }

        guard let record: DownloadRecord = try await sql.raw(
            """
            SELECT id, original_filename, content_type, byte_size, sha256, remaining_downloads
            FROM file_objects
            WHERE id = \(bind: id)
              AND state = 'available'
              AND uploaded_at > \(bind: cutoff)
              AND remaining_downloads > 0
            FOR UPDATE
            """
        ).first(decoding: DownloadRecord.self) else {
            return nil
        }

        let path: String = FilePath(directory).appending(id).string
        guard regular_file_size(at: path) == record.byteSize else {
            try await sql.raw(
                "UPDATE file_objects SET state = 'deleting' WHERE id = \(bind: id)"
            ).run()
            return nil
        }

        try await sql.raw(
            """
            UPDATE file_objects
            SET remaining_downloads = remaining_downloads - 1
            WHERE id = \(bind: id)
            """
        ).run()

        return DownloadRecord(
            id: record.id,
            originalFilename: record.originalFilename,
            contentType: record.contentType,
            byteSize: record.byteSize,
            sha256: record.sha256,
            remainingDownloads: record.remainingDownloads - 1
        )
    }
}

private func restore_download(id: String, database: any Database) async throws {
    guard let sql: any SQLDatabase = database as? any SQLDatabase else { return }
    try await sql.raw(
        """
        UPDATE file_objects
        SET remaining_downloads = remaining_downloads + 1
        WHERE id = \(bind: id) AND state = 'available'
        """
    ).run()
}

func delete_object(
    id: String,
    path: String,
    database: any Database,
    logger: Logger
) async {
    do {
        if let object: FileObject = try await FileObject.find(id, on: database) {
            object.state = .deleting
            try await object.update(on: database)
        }

        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }
        try await FileObject.find(id, on: database)?.delete(on: database)
    } catch {
        logger.error("Object cleanup failed for id \(id): \(String(reflecting: error))")
    }
}

private func regular_file_size(at path: String) -> Int64? {
    guard let attributes: [FileAttributeKey : Any] = try? FileManager.default.attributesOfItem(atPath: path),
          attributes[.type] as? FileAttributeType == .typeRegular,
          let size: NSNumber = attributes[.size] as? NSNumber else {
        return nil
    }
    return size.int64Value
}

private func content_disposition(filename: String) -> String {
    let fallbackScalars = filename.unicodeScalars.map { scalar -> Character in
        guard scalar.isASCII,
              scalar.value >= 0x20,
              scalar.value != 0x22,
              scalar.value != 0x5c else {
            return "_"
        }
        return Character(String(scalar))
    }
    let fallback = String(fallbackScalars)
    let encoded = filename.utf8.map { byte -> String in
        let isUnreserved =
            (byte >= 0x41 && byte <= 0x5a)
            || (byte >= 0x61 && byte <= 0x7a)
            || (byte >= 0x30 && byte <= 0x39)
            || [0x2d, 0x2e, 0x5f, 0x7e].contains(byte)
        return isUnreserved ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
    }.joined()
    return "attachment; filename=\"\(fallback)\"; filename*=UTF-8''\(encoded)"
}

private func file_not_found(req: Request) async throws -> Response {
    let view: View = try await req.view.render(
        "file-not-found",
        PageContext(
            title: "Page not found",
            description: "This link may have expired, or the page may have moved.",
            activePage: ""
        )
    )

    let response: Response = Response(
        status: .notFound,
        body: .init(buffer: view.data)
    )
    response.headers.contentType = .html
    return response
}
