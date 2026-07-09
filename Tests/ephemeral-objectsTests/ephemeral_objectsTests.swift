import Testing
import Vapor
@testable import ephemeral_objects

@Suite("Website routes")
struct WebsiteRouteTests {
    @Test("Home page renders")
    func home() async throws {
        let response = try await request("/")
        #expect(response.status == .ok)
        #expect(response.body.contains("<h1>Share a file</h1>"))
        #expect(response.body.contains(#"<link rel="canonical" href="\#(canonical_public_origin())/">"#))
        #expect(response.body.contains("Upload a file and share it with a temporary download link."))
    }

    @Test("About page renders")
    func about() async throws {
        let response = try await request("/about")
        #expect(response.status == .ok)
        #expect(response.body.contains("<h1>Service information</h1>"))
        #expect(response.body.contains(#"<link rel="canonical" href="\#(canonical_public_origin())/about">"#))
    }

    @Test("Static assets are served")
    func assets() async throws {
        let response = try await request("/css/site.css")
        #expect(response.status == .ok)
        #expect(response.body.contains("--accent"))
    }

    @Test("Unknown pages use the branded 404")
    func notFound() async throws {
        let response = try await request("/this-page-is-gone")
        #expect(response.status == .notFound)
        #expect(response.body.contains("<h1>Page not found</h1>"))
        #expect(response.headers.first(name: "X-Robots-Tag") == "noindex, nofollow, noarchive")
    }

    @Test("Robots policy is served")
    func robots() async throws {
        let response = try await request("/robots.txt")
        #expect(response.status == .ok)
        #expect(response.headers.contentType == .plainText)
        #expect(response.body.contains("User-agent: *"))
        #expect(response.body.contains("Disallow: /files/"))
        #expect(response.body.contains("Disallow: /captcha/"))
        #expect(response.body.contains("User-agent: GPTBot"))
        #expect(response.body.contains("Sitemap: \(canonical_public_origin())/sitemap.xml"))
    }

    @Test("Sitemap only lists public pages")
    func sitemap() async throws {
        let response = try await request("/sitemap.xml")
        #expect(response.status == .ok)
        #expect(response.headers.contentType?.type == "application")
        #expect(response.headers.contentType?.subType == "xml")
        #expect(response.body.contains("<loc>\(canonical_public_origin())/</loc>"))
        #expect(response.body.contains("<loc>\(canonical_public_origin())/about</loc>"))
        #expect(!response.body.contains("/files/"))
    }

    @Test("Canonical origin defaults to localhost")
    func canonicalOriginDefault() {
        #expect(canonical_public_origin(from: nil) == "https://localhost")
        #expect(canonical_public_origin(from: "   ") == "https://localhost")
        #expect(canonical_public_origin(from: "https://files.example.test/") == "https://files.example.test")
    }

    @Test("File not found pages are not indexable")
    func fileNotFound() async throws {
        let response = try await request("/files/not-a-uuid")
        #expect(response.status == .notFound)
        #expect(response.body.contains("<h1>File not found</h1>"))
        #expect(response.headers.first(name: "X-Robots-Tag") == "noindex, nofollow, noarchive")
    }

    private func request(
        _ path: String
    ) async throws -> TestResponse {
        let app = try await Application.make(.testing)
        configure(app)
        register_file_api_calls(
            app: app,
            config: config,
            captchaVerifier: AlwaysValidCaptchaVerifier(),
            captchaEndpoint: "/captcha/test-site-key/"
        )
        register_page_api_calls(
            app: app,
            config: config,
            capConfig: CapConfiguration(
                siteKey: "test-site-key",
                secret: "test-secret",
                publicEndpoint: "/captcha/test-site-key/",
                verificationEndpoint: "http://127.0.0.1/siteverify"
            )
        )

        do {
            let eventLoop = app.eventLoopGroup.next()
            let request = Request(
                application: app,
                method: .GET,
                url: URI(path: path),
                headers: HTTPHeaders(),
                collectedBody: nil,
                on: eventLoop
            )
            let response = try await app.responder.respond(to: request).get()
            let buffer = try await response.body.collect(on: eventLoop).get()
            let result = TestResponse(
                status: response.status,
                headers: response.headers,
                body: buffer.map { String(buffer: $0) } ?? ""
            )
            try await app.asyncShutdown()
            return result
        } catch {
            try await app.asyncShutdown()
            throw error
        }
    }
}

private struct TestResponse {
    let status: HTTPResponseStatus
    let headers: HTTPHeaders
    let body: String
}

private struct AlwaysValidCaptchaVerifier: CaptchaVerifying {
    func verify(token: String, for request: Request) async throws -> Bool {
        true
    }
}
