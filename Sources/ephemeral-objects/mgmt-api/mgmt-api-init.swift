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

        try await FileSystem.shared.withFileHandle(
            forWritingAt: FilePath("\(dir)/\(req.id)")
        ) { fileHandle in
            let offsetBox = OffsetBox()

            req.body.drain { chunk -> EventLoopFuture<Void> in
                let promise = req.eventLoop.makePromise(of: Void.self)

                Task {
                    switch chunk {
                    case .buffer(let byteBuffer):
                        let chunkSize = Int64(byteBuffer.readableBytes)
                        let writeOffset = offsetBox.getAndIncrement(by: chunkSize)
                        try await fileHandle.write(
                            contentsOf: byteBuffer.readableBytesView,
                            toAbsoluteOffset: writeOffset
                        )
                    case .error(let error):
                        promise.fail(error)
                    case .end:
                        promise.succeed()
                    }

                }

                return promise.futureResult
            }
        }

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

private final class OffsetBox: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.vapor.upload.offset")
    private var value: Int64 = 0
    
    func getAndIncrement(by amount: Int64) -> Int64 {
        queue.sync {
            let current = value
            value += amount
            return current
        }
    }
}
