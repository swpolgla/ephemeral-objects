import Foundation
import NIOCore
import NIOFileSystem
import Vapor

struct FileUpload: Content {
    var file: Data
}

struct FileUploadResponse: Content {
    let id: String
    let downloadURL: String
}


func register_rest_api_calls(app: Application) {

    let files: any RoutesBuilder = app.grouped("files")

    files.get { req in
        return "MISSING FILE HASH PARAMETER"
    }

    files.get(":hash") { req in
        let hash: String = req.parameters.get("hash")!
        let file: String = "/tmp/ephemeral/\(hash)"
        if !FileManager.default.fileExists(atPath: file) {
            return Response(status: .notFound, body: "The requested file hash does not exist.")
        }
        return try await req.fileio.asyncStreamFile(at: "/tmp/ephemeral/\(hash)")
    }

    files.on(.POST, body: .stream) { req async throws -> Response in
        let dir: String = "/tmp/ephemeral"
        let dir_path: FilePath = FilePath(dir)
        if !FileManager.default.fileExists(atPath: dir) {
            try await FileSystem.shared.createDirectory(at: dir_path, withIntermediateDirectories: true, permissions: .ownerReadWrite)
        }

        var sizeExceeded: Bool = false
        let id: String = req.id
        let filePath: String = "\(dir)/\(id)"

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
                    if byteCount > 1024 * 1024 * 1024 {
                        sizeExceeded = true
                        break
                    }
                    try await writer.write(contentsOf: byteBuffer)
                }
            }
        }

        if sizeExceeded {
            // return Response(status: .payloadTooLarge, body: "Files larger than 1GiB are not accepted.")
            return try await FileUploadResponse(id: id, downloadURL: "").encodeResponse(status: .payloadTooLarge, for: req)
        }

        return try await FileUploadResponse(id: id, downloadURL: "/files/\(id)").encodeResponse(status: .created, for: req)
    }

    app.get { req async throws -> View in
        try await req.view.render(
            "home",
            PageContext(
                title: "Private file sharing, made temporary",
                description: "Share files simply with private links designed to disappear.",
                activePage: "home"
            )
        )
    }

    app.get("about") { req async throws -> View in
        try await req.view.render(
            "about",
            PageContext(
                title: "About Ephemeral",
                description: "A calmer, privacy-minded way to share files without keeping them forever.",
                activePage: "about"
            )
        )
    }

    app.get(.catchall) { req async throws -> Response in
        let view = try await req.view.render(
            "not-found",
            PageContext(
                title: "Page not found",
                description: "This link may have expired, or the page may have moved.",
                activePage: ""
            )
        )
        let response = Response(
            status: .notFound,
            body: .init(buffer: view.data)
        )
        response.headers.contentType = .html
        return response
    }
}

struct PageContext: Encodable {
    let title: String
    let description: String
    let activePage: String
}
