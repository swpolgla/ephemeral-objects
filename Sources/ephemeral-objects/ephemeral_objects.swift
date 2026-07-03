// The Swift Programming Language
// https://docs.swift.org/swift-book
import Vapor
import Leaf

let config: app_config = read_config_file(
    path: Environment.get("APP_CONFIG_PATH") ?? "config.json"
)

@main
struct ephemeral_objects {
    static func main() async throws {

        let capConfig: CapConfiguration = read_cap_configuration()
        let app: Application = try await Application.make(.detect())

        do {
            _ = config
            configure(app)
            register_file_api_calls(
                app: app,
                config: config,
                captchaVerifier: CapCaptchaVerifier(config: capConfig)
            )
            register_page_api_calls(app: app, capConfig: capConfig)

            try await app.execute()
            try await app.asyncShutdown()
        } catch {
            try await app.asyncShutdown()
            throw error
        }
    }
}

func configure(_ app: Application) {
    let uiDirectory: String = app.directory.workingDirectory
        + "Sources/ephemeral-objects/mgmt-ui/"

    app.directory.viewsDirectory = uiDirectory + "Views/"
    app.directory.publicDirectory = uiDirectory + "Public/"
    app.views.use(.leaf)
    app.http.client.configuration.timeout = .init(
        connect: .seconds(3),
        read: .seconds(3)
    )
    app.middleware.use(
        FileMiddleware(
            publicDirectory: app.directory.publicDirectory,
            cachePolicy: .cacheUpToDuration(.seconds(3_600))
        )
    )
}
