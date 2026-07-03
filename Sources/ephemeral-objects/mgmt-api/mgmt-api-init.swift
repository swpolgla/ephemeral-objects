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
    let message: String
}

private struct CaptchaErrorResponse: Content {
    let message: String
}

func register_file_api_calls(
    app: Application,
    config: app_config,
    captchaVerifier: any CaptchaVerifying
) {
    let files: any RoutesBuilder = app.grouped("files")

    files.get(":hash") { req in
        let hash: String = req.parameters.get("hash")!
        let file_path: FilePath = FilePath(config.object_store_directory).appending(hash)
        let file: String = file_path.string
        if !FileManager.default.fileExists(atPath: file) {
            return Response(status: .notFound, body: "The requested file hash does not exist.")
        }
        return try await req.fileio.asyncStreamFile(at: file)
    }

    files.on(.POST, body: .stream) { req async throws -> Response in
        guard let token = req.headers["X-Captcha-Token"].first?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            return try await CaptchaErrorResponse(message: "A CAPTCHA token is required.")
                .encodeResponse(status: .badRequest, for: req)
        }

        let isValid: Bool
        do {
            isValid = try await captchaVerifier.verify(token: token, for: req)
        } catch {
            req.logger.error("Cap verification failed: \(error)")
            return try await CaptchaErrorResponse(
                message: "CAPTCHA verification is temporarily unavailable."
            )
                .encodeResponse(status: .serviceUnavailable, for: req)
        }

        guard isValid else {
            return try await CaptchaErrorResponse(
                message: "The CAPTCHA token is invalid or has expired."
            )
                .encodeResponse(status: .forbidden, for: req)
        }

        return try await save_object(req: req, config: config)
    }

}

func register_page_api_calls(app: Application, capConfig: CapConfiguration) {
    app.get("health") { _ in
        Response(status: .ok, body: "ok")
    }

    app.get { req async throws -> View in
        try await req.view.render(
            "home",
            HomePageContext(
                title: "Private file sharing, made temporary",
                description: "Share files simply with private links designed to disappear.",
                activePage: "home",
                captchaEndpoint: capConfig.publicEndpoint
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
        let view: View = try await req.view.render(
            "not-found",
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
}

struct PageContext: Encodable {
    let title: String
    let description: String
    let activePage: String
}

struct HomePageContext: Encodable {
    let title: String
    let description: String
    let activePage: String
    let captchaEndpoint: String
}
