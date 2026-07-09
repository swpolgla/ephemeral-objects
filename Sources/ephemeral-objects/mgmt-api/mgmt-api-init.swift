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

private struct DownloadCaptchaForm: Content {
    let captchaToken: String
}

func register_file_api_calls(
    app: Application,
    config: app_config,
    captchaVerifier: any CaptchaVerifying,
    captchaEndpoint: String
) {
    let files: any RoutesBuilder = app.grouped("files")
    let uploadLimiter: UploadLimiter = UploadLimiter(limit: config.maximum_concurrent_uploads)

    files.get(":id") { req in
        try await download_landing_page(
            req: req,
            config: config,
            captchaEndpoint: captchaEndpoint
        )
    }

    files.on(.POST, ":id", "download", body: .collect) { req async throws -> Response in
        let form = try req.content.decode(DownloadCaptchaForm.self)
        let token: String = form.captchaToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
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

        return try await download_object(req: req, config: config)
    }

    files.get(":id", "download") { req in
        req.redirect(to: "/files/\(req.parameters.get("id") ?? "")")
    }

    files.on(.HEAD, ":id") { _ in
        Response(status: .methodNotAllowed)
    }

    files.on(.POST, body: .stream) { req async throws -> Response in
        guard let token: String = req.headers["X-Captcha-Token"].first?
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
    let publicOrigin: String = canonical_public_origin()

    app.get("health") { req async throws in
        _ = try await FileObject.query(on: req.db).limit(1).all()
        return Response(status: .ok, body: "ok")
    }

    app.get("robots.txt") { _ in
        let response = Response(
            status: .ok,
            body: .init(string: robots_txt(publicOrigin: publicOrigin))
        )
        response.headers.contentType = .plainText
        response.headers.replaceOrAdd(name: .cacheControl, value: "public, max-age=3600")
        return response
    }

    app.get("sitemap.xml") { _ in
        let response = Response(
            status: .ok,
            body: .init(string: sitemap_xml(publicOrigin: publicOrigin))
        )
        response.headers.contentType = HTTPMediaType(type: "application", subType: "xml")
        response.headers.replaceOrAdd(name: .cacheControl, value: "public, max-age=3600")
        return response
    }

    app.get { req async throws -> View in
        try await req.view.render(
            "home",
            HomePageContext(
                title: "Temporary file sharing",
                description: "Upload a file and share it with a temporary download link. No account is required.",
                activePage: "home",
                canonicalURL: canonical_url(publicOrigin: publicOrigin, path: "/"),
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
                canonicalURL: canonical_url(publicOrigin: publicOrigin, path: "/about"),
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
        response.headers.replaceOrAdd(name: "X-Robots-Tag", value: "noindex, nofollow, noarchive")
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
    let canonicalURL: String
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
    let canonicalURL: String
    let maximumFileSizeLabel: String
    let storageDurationLabel: String
    let downloadLimitLabel: String
}

func canonical_public_origin() -> String {
    canonical_public_origin(from: Environment.get("PUBLIC_ORIGIN"))
}

func canonical_public_origin(from configuredOrigin: String?) -> String {
    let configured = configuredOrigin?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

    guard let configured: String, !configured.isEmpty else {
        return "https://localhost"
    }
    return configured
}

func canonical_url(publicOrigin: String, path: String) -> String {
    "\(publicOrigin)\(path)"
}

func robots_txt(publicOrigin: String) -> String {
    """
    User-agent: *
    Allow: /
    Disallow: /files/
    Disallow: /captcha/
    Disallow: /health

    User-agent: GPTBot
    Disallow: /

    User-agent: CCBot
    Disallow: /

    Sitemap: \(canonical_url(publicOrigin: publicOrigin, path: "/sitemap.xml"))

    """
}

func sitemap_xml(publicOrigin: String) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
        <url>
            <loc>\(canonical_url(publicOrigin: publicOrigin, path: "/"))</loc>
        </url>
        <url>
            <loc>\(canonical_url(publicOrigin: publicOrigin, path: "/about"))</loc>
        </url>
    </urlset>

    """
}

func unitLabel(_ value: Int, singular: String) -> String {
    "\(value) \(value == 1 ? singular : "\(singular)s")"
}

func binaryByteCountLabel(_ bytes: Int64) -> String {
    let units: [String] = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
    var value = Double(bytes)
    var unitIndex: Int = 0

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
