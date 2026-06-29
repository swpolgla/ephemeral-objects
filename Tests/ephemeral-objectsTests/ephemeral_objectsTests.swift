import Testing
import Vapor
@testable import ephemeral_objects

@Suite("Website routes")
struct WebsiteRouteTests {
    @Test("Home page renders")
    func home() async throws {
        let response = try await request("/")
        #expect(response.status == .ok)
        #expect(response.body.contains("Send the file."))
    }

    @Test("About page renders")
    func about() async throws {
        let response = try await request("/about")
        #expect(response.status == .ok)
        #expect(response.body.contains("The internet remembers enough already."))
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
        #expect(response.body.contains("This page has already disappeared."))
    }

    @Test("File upload endpoint accepts POST requests")
    func fileUploadEndpoint() async throws {
        let response = try await request("/files", method: .POST)
        #expect(response.status == .ok)
        #expect(response.body == "FILES POST 5")
    }

    private func request(
        _ path: String,
        method: HTTPMethod = .GET
    ) async throws -> TestResponse {
        let app = try await Application.make(.testing)
        configure(app)
        register_rest_api_calls(app: app)

        do {
            let eventLoop = app.eventLoopGroup.next()
            var headers = HTTPHeaders()
            var collectedBody: ByteBuffer?
            if method == .POST {
                headers.add(
                    name: .contentType,
                    value: "multipart/form-data; boundary=ephemeral-test"
                )
                var body = ByteBufferAllocator().buffer(capacity: 160)
                body.writeString(
                    "--ephemeral-test\r\n"
                    + "Content-Disposition: form-data; name=\"file\"; filename=\"test.txt\"\r\n"
                    + "Content-Type: text/plain\r\n\r\n"
                    + "hello\r\n"
                    + "--ephemeral-test--\r\n"
                )
                collectedBody = body
            }
            let request = Request(
                application: app,
                method: method,
                url: URI(path: path),
                headers: headers,
                collectedBody: collectedBody,
                on: eventLoop
            )
            let response = try await app.responder.respond(to: request).get()
            let buffer = try await response.body.collect(on: eventLoop).get()
            let result = TestResponse(
                status: response.status,
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
    let body: String
}
