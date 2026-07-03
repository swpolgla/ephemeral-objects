import Foundation
import Vapor

struct app_config: Codable, Sendable {
    let object_store_directory: String
    let maximum_file_size: Int64 // Bytes
    let maximum_storage_duration: Int // Days
    let maximum_downloads: Int
}

struct CapConfiguration: Sendable {
    let siteKey: String
    let secret: String
    let publicEndpoint: String
    let verificationEndpoint: String
}

func read_config_file(path: String) -> app_config {
    do {
        let configURL: URL = URL(fileURLWithPath: path)
        let configData: Data = try Data(contentsOf: configURL)
        return try JSONDecoder().decode(app_config.self, from: configData)
    } catch {
        fatalError("Unable to read config file at '\(path)': \(error)")
    }
}

func read_cap_configuration() -> CapConfiguration {
    guard let siteKey = Environment.get("CAP_SITE_KEY")?.trimmingCharacters(in: .whitespacesAndNewlines),
          !siteKey.isEmpty else {
        fatalError("CAP_SITE_KEY must contain the Cap site key.")
    }

    guard let secretFile = Environment.get("CAP_SECRET_FILE"), !secretFile.isEmpty else {
        fatalError("CAP_SECRET_FILE must point to the Cap site secret.")
    }

    do {
        let secret = try String(contentsOfFile: secretFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else {
            fatalError("The Cap site secret at '\(secretFile)' is empty.")
        }

        let internalBaseURL = Environment.get("CAP_INTERNAL_URL") ?? "http://cap:3000"
        return CapConfiguration(
            siteKey: siteKey,
            secret: secret,
            publicEndpoint: "/captcha/\(siteKey)/",
            verificationEndpoint: "\(internalBaseURL)/siteverify"
        )
    } catch {
        fatalError("Unable to read the Cap site secret at '\(secretFile)': \(error)")
    }
}
