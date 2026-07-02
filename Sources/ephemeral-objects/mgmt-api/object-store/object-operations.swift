import NIOFileSystem
import Vapor

func save_object(req: Request, config: app_config) async throws -> Response {
    let dir: String = config.object_store_directory
    let dir_path: FilePath = FilePath(dir)
    if !FileManager.default.fileExists(atPath: dir) {
        try await FileSystem.shared.createDirectory(at: dir_path, withIntermediateDirectories: true)
    }
    let id: String = req.id
    guard let fileName: String = req.headers["X-File-Name"].first else {
        return try await FileUploadResponse(id: id, downloadURL: "", message: "Missing file name header.")
            .encodeResponse(status: .badRequest, for: req)
    }
    guard let sanitizedFileName: String = try? fileName.sanitize() else {
        return try await FileUploadResponse(id: id, downloadURL: "", message: "Illegal file name provided.")
            .encodeResponse(status: .badRequest, for: req)
    }
    print(sanitizedFileName)

    var sizeExceeded: Bool = false
    let filePath: String = dir_path.appending(id).string

    defer {
        if sizeExceeded {
            try? FileManager.default.removeItem(atPath: filePath)
        }
    }

    try await FileSystem.shared.withFileHandle(
        forWritingAt: FilePath(filePath)
    ) { fileHandle in
        var byteCount: Int = 0
        try await fileHandle.withBufferedWriter(capacity: .mebibytes(4)) { writer in
            for try await byteBuffer: Request.Body.AsyncIterator.Element in req.body {
                byteCount += byteBuffer.readableBytes
                if Int64(byteCount) > config.maximum_file_size {
                    sizeExceeded = true
                    break
                }
                try await writer.write(contentsOf: byteBuffer)
            }
        }
    }

    if sizeExceeded {
        return try await FileUploadResponse(
            id: id,
            downloadURL: "",
            message: "Files larger than \(config.maximum_file_size) bytes are not accepted."
        )
            .encodeResponse(status: .payloadTooLarge, for: req)
    }

    return try await FileUploadResponse(id: id, downloadURL: "/files/\(id)", message: "")
        .encodeResponse(status: .created, for: req)
}
