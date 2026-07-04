import Crypto
import Fluent
import Foundation
import NIOFileSystem
import Vapor

actor UploadLimiter {
    private var available: Int

    init(limit: Int) {
        self.available = limit
    }

    func acquire() -> Bool {
        guard available > 0 else { return false }
        available -= 1
        return true
    }

    func release() {
        available += 1
    }
}

private struct StoredUpload: Sendable {
    let byteSize: Int64
    let sha256: String
}

private enum UploadError: Error {
    case empty
    case tooLarge
    case timedOut
}

func save_object(
    req: Request,
    config: app_config,
    limiter: UploadLimiter
) async throws -> Response {
    guard await limiter.acquire() else {
        return try await FileUploadResponse(
            id: "",
            downloadURL: "",
            message: "The service is handling too many uploads. Please try again shortly."
        ).encodeResponse(status: .tooManyRequests, for: req)
    }

    do {
        let response = try await save_object_unlimited(req: req, config: config)
        await limiter.release()
        return response
    } catch {
        await limiter.release()
        throw error
    }
}

private func save_object_unlimited(req: Request, config: app_config) async throws -> Response {
    let filenameValues = req.headers["X-File-Name"]
    guard filenameValues.count == 1,
          let decodedFilename = filenameValues[0].removingPercentEncoding,
          filenameValues[0].isEmpty == false,
          decodedFilename.unicodeScalars.allSatisfy({
              !CharacterSet.controlCharacters.contains($0)
          }),
          !decodedFilename.contains("/"),
          !decodedFilename.contains("\\"),
          !decodedFilename.contains("\0"),
          let filename = try? decodedFilename.sanitize(),
          filename.utf8.count <= 255 else {
        return try await upload_error(
            "A single valid file name header is required.",
            status: .badRequest,
            for: req
        )
    }

    if declared_size_exceeds_limit(req: req, maximum: config.maximum_file_size) {
        return try await upload_error(
            "Files larger than \(config.maximum_file_size) bytes are not accepted.",
            status: .payloadTooLarge,
            for: req
        )
    }

    let directory = config.object_store_directory
    let directoryPath = FilePath(directory)
    if !FileManager.default.fileExists(atPath: directory) {
        try await FileSystem.shared.createDirectory(
            at: directoryPath,
            withIntermediateDirectories: true
        )
    }

    let id = UUID().uuidString.lowercased()
    let temporaryPath = directoryPath.appending("\(id).uploading").string
    let finalPath = directoryPath.appending(id).string
    let contentType = validated_content_type(req.headers.contentType)
    let fileExtension = extracted_extension(from: filename)
    var metadataCreated = false
    var finalCreated = false

    do {
        let stored = try await withThrowingTaskGroup(of: StoredUpload.self) { group in
            group.addTask {
                try await stream_upload(
                    req: req,
                    path: temporaryPath,
                    maximumSize: config.maximum_file_size
                )
            }
            group.addTask {
                try await Task.sleep(for: .seconds(config.maximum_upload_time))
                throw UploadError.timedOut
            }

            guard let result = try await group.next() else {
                throw Abort(.internalServerError)
            }
            group.cancelAll()
            return result
        }

        let object = FileObject(
            id: id,
            originalFilename: filename,
            fileExtension: fileExtension,
            contentType: contentType,
            byteSize: stored.byteSize,
            sha256: stored.sha256,
            uploadedAt: Date(),
            remainingDownloads: config.maximum_downloads,
            state: .pending
        )
        try await object.create(on: req.db)
        metadataCreated = true

        try FileManager.default.moveItem(atPath: temporaryPath, toPath: finalPath)
        finalCreated = true

        object.state = .available
        try await object.update(on: req.db)

        return try await FileUploadResponse(
            id: id,
            downloadURL: "/files/\(id)",
            message: ""
        ).encodeResponse(status: .created, for: req)
    } catch UploadError.empty {
        try? FileManager.default.removeItem(atPath: temporaryPath)
        return try await upload_error("Empty files are not accepted.", status: .badRequest, for: req)
    } catch UploadError.tooLarge {
        try? FileManager.default.removeItem(atPath: temporaryPath)
        return try await upload_error(
            "Files larger than \(config.maximum_file_size) bytes are not accepted.",
            status: .payloadTooLarge,
            for: req
        )
    } catch UploadError.timedOut {
        try? FileManager.default.removeItem(atPath: temporaryPath)
        return try await upload_error("The upload timed out.", status: .requestTimeout, for: req)
    } catch {
        try? FileManager.default.removeItem(atPath: temporaryPath)
        if finalCreated {
            try? FileManager.default.removeItem(atPath: finalPath)
        }
        if metadataCreated {
            try? await FileObject.find(id, on: req.db)?.delete(on: req.db)
        }
        req.logger.error("Upload persistence failed: \(String(reflecting: error))")
        return try await upload_error(
            "The upload could not be stored.",
            status: .internalServerError,
            for: req
        )
    }
}

private func stream_upload(
    req: Request,
    path: String,
    maximumSize: Int64
) async throws -> StoredUpload {
    try await FileSystem.shared.withFileHandle(
        forWritingAt: FilePath(path),
        options: .newFile(replaceExisting: false)
    ) { fileHandle in
        var byteCount: Int64 = 0
        var hasher = SHA256()

        try await fileHandle.withBufferedWriter(capacity: .mebibytes(4)) { writer in
            for try await byteBuffer in req.body {
                try Task.checkCancellation()
                let readable = Int64(byteBuffer.readableBytes)
                let (nextCount, overflow) = byteCount.addingReportingOverflow(readable)
                guard !overflow, nextCount <= maximumSize else {
                    throw UploadError.tooLarge
                }
                byteCount = nextCount
                hasher.update(data: Data(byteBuffer.readableBytesView))
                try await writer.write(contentsOf: byteBuffer)
            }
        }

        guard byteCount > 0 else { throw UploadError.empty }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return StoredUpload(byteSize: byteCount, sha256: digest)
    }
}

private func declared_size_exceeds_limit(req: Request, maximum: Int64) -> Bool {
    let candidates = [
        req.headers.first(name: .contentLength),
        req.headers["X-File-Size"].count == 1 ? req.headers["X-File-Size"][0] : nil,
    ]
    return candidates.compactMap { $0 }.contains { value in
        guard let size = Int64(value), size >= 0 else { return false }
        return size > maximum
    }
}

private func validated_content_type(_ mediaType: HTTPMediaType?) -> String {
    guard let mediaType else { return HTTPMediaType.binary.serialize() }
    let value = mediaType.serialize()
    guard value.utf8.count <= 255,
          value.unicodeScalars.allSatisfy({
              $0.isASCII && !CharacterSet.controlCharacters.contains($0)
          }),
          !mediaType.type.isEmpty,
          !mediaType.subType.isEmpty else {
        return HTTPMediaType.binary.serialize()
    }
    return value
}

private func extracted_extension(from filename: String) -> String? {
    guard let dot = filename.lastIndex(of: "."),
          dot != filename.startIndex,
          filename.index(after: dot) != filename.endIndex else {
        return nil
    }
    return String(filename[filename.index(after: dot)...])
}

private func upload_error(
    _ message: String,
    status: HTTPResponseStatus,
    for req: Request
) async throws -> Response {
    try await FileUploadResponse(id: "", downloadURL: "", message: message)
        .encodeResponse(status: status, for: req)
}
