import Vapor

protocol CaptchaVerifying: Sendable {
    func verify(token: String, for request: Request) async throws -> Bool
}

struct CapCaptchaVerifier: CaptchaVerifying {
    private let secret: String
    private let verificationEndpoint: URI

    init(config: CapConfiguration) {
        self.secret = config.secret
        self.verificationEndpoint = URI(string: config.verificationEndpoint)
    }

    func verify(token: String, for request: Request) async throws -> Bool {
        let response: ClientResponse = try await request.client.post(
            verificationEndpoint,
            content: CapVerificationRequest(secret: secret, response: token)
        )
        guard response.status == .ok else {
            throw CapVerificationError.unexpectedResponse
        }

        return try response.content.decode(CapVerificationResponse.self).success
    }
}

private struct CapVerificationRequest: Content {
    let secret: String
    let response: String
}

private struct CapVerificationResponse: Content {
    let success: Bool
}

private enum CapVerificationError: Error {
    case unexpectedResponse
}
