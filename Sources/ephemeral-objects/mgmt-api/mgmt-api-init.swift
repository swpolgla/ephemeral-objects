import Foundation
import NIOCore
import NIOFileSystem
import Vapor

struct FileUpload: Content {
    var file: Data
}


func register_rest_api_calls(app: Application) {

    let files: any RoutesBuilder = app.grouped("files")

    files.get { req in
        return "MISSING FILE HASH PARAMETER"
    }

    files.get(":hash") { req in
        let hash: String = req.parameters.get("hash")!
        return "FILES - \(hash)"
    }

    files.on(.POST, body: .stream) { req async throws -> HTTPStatus in
        let dir = "/tmp/ephemeral"
        let dir_path = FilePath(dir)
        if !FileManager.default.fileExists(atPath: dir) {
            try await FileSystem.shared.createDirectory(at: dir_path, withIntermediateDirectories: true, permissions: .ownerReadWrite)
        }

        let fileHandle = try await req.application.fileio.openFile(
            path: "/tmp/ephemeral/\(req.id)",
            mode: .write,
            flags: .allowFileCreation(),
            eventLoop: req.eventLoop
        ).get()
        defer { try? fileHandle.close() }
        var offset: Int64 = 0
        for try await buffer in req.body {
            try await req.application.fileio.write(
                fileHandle: fileHandle,
                toOffset: offset,
                buffer: buffer,
                eventLoop: req.eventLoop
            ).get()
            offset += Int64(buffer.readableBytes)
        }
        // for try await part in req.body {
        //     fileHandle?.seekToEndOfFile()
        //     fileHandle?.write(Data(buffer: part))
        //     print("Wrote \(part.readableBytes)")
        //     fileHandle.
        // }
        // try fileHandle?.close()

        // // Prep output file
        // let file_destination_path = "/tmp/ephemeral/\(req.id)"
        // let file_path: FilePath = FilePath(file_destination_path)
        // let fileHandle: WriteFileHandle = try await FileSystem.shared.openFile(
        //     forWritingAt: file_path,
        //     options: .newFile(replaceExisting: true)
        //     )
        // defer {
        //     Task {
        //         try? await fileHandle.close()
        //     }
        // }

        // // req.body.data will be nil. You must drain chunks sequentially:
        // req.body.drain { part in
        //     switch part {
        //     case .buffer(let buffer):
        //         // Process or write each incoming chunk to disk/S3 here
        //         print("Received chunk of \(buffer.readableBytes) bytes")
        //         // try await fileHandle.write(
        //         //     contentsOf: part,
        //         //     toOffset: currentOffset
        //         // )
        //         req.application.fileio.write(fileHandle: fileHandle, toOffset: Int64, buffer: ByteBuffer, eventLoop: any EventLoop)

        //     case .error(let error):
        //         print("Streaming error: \(error)")
        //     case .end:
        //         print("Streaming finished")
        //     }
        //     return req.eventLoop.makeSucceededFuture(())
        // }
        return .ok
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
