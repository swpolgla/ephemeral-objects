import Foundation
import Fluent
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
    let uploadLimiter = UploadLimiter(limit: config.maximum_concurrent_uploads)

    files.get(":id") { req in
        try await download_object(req: req, config: config)
    }

    files.on(.HEAD, ":id") { _ in
        Response(status: .methodNotAllowed)
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

        return try await save_object(req: req, config: config, limiter: uploadLimiter)
    }

}

func register_page_api_calls(
    app: Application,
    config: app_config,
    capConfig: CapConfiguration
) {
    app.get("health") { req async throws in
        _ = try await FileObject.query(on: req.db).limit(1).all()
        return Response(status: .ok, body: "ok")
    }

    app.get { req async throws -> View in
        try await req.view.render(
            "home",
            HomePageContext(
                title: "Share a file",
                description: "Upload a file and receive a temporary download link.",
                activePage: "home",
                captchaEndpoint: capConfig.publicEndpoint,
                maximumFileSize: config.maximum_file_size,
                maximumFileSizeLabel: binaryByteCountLabel(config.maximum_file_size),
                storageDurationLabel: unitLabel(config.maximum_storage_duration, singular: "day"),
                downloadLimitLabel: unitLabel(config.maximum_downloads, singular: "download")
            )
        )
    }

    app.get("about") { req async throws -> View in
        try await req.view.render(
            "about",
            ServiceInfoPageContext(
                title: "Service information",
                description: "File limits, retention, downloads, and security information for Ephemeral.",
                activePage: "about",
                maximumFileSizeLabel: binaryByteCountLabel(config.maximum_file_size),
                storageDurationLabel: unitLabel(config.maximum_storage_duration, singular: "day"),
                downloadLimitLabel: unitLabel(config.maximum_downloads, singular: "download")
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
    let maximumFileSize: Int64
    let maximumFileSizeLabel: String
    let storageDurationLabel: String
    let downloadLimitLabel: String
}

struct ServiceInfoPageContext: Encodable {
    let title: String
    let description: String
    let activePage: String
    let maximumFileSizeLabel: String
    let storageDurationLabel: String
    let downloadLimitLabel: String
}

private func unitLabel(_ value: Int, singular: String) -> String {
    "\(value) \(value == 1 ? singular : "\(singular)s")"
}

private func binaryByteCountLabel(_ bytes: Int64) -> String {
    let units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
    var value = Double(bytes)
    var unitIndex = 0

    while value >= 1024, unitIndex < units.count - 1 {
        value /= 1024
        unitIndex += 1
    }

    let formattedValue = value.rounded() == value
        ? String(format: "%.0f", value)
        : String(format: "%.2f", value)
            .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)

    return "\(formattedValue) \(units[unitIndex])"
}
