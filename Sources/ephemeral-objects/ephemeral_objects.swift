// The Swift Programming Language
// https://docs.swift.org/swift-book
import Vapor
import Leaf

@main
struct ephemeral_objects {
    static func main() async throws {

        let app: Application = try await Application.make(.detect())

        do {
            configure(app)
            register_rest_api_calls(app: app)

            try await app.execute()
            try await app.asyncShutdown()
        } catch {
            try await app.asyncShutdown()
            throw error
        }
    }
}

func configure(_ app: Application) {
    let uiDirectory = app.directory.workingDirectory
        + "Sources/ephemeral-objects/mgmt-ui/"

    app.directory.viewsDirectory = uiDirectory + "Views/"
    app.directory.publicDirectory = uiDirectory + "Public/"
    app.views.use(.leaf)
    app.middleware.use(
        FileMiddleware(
            publicDirectory: app.directory.publicDirectory,
            cachePolicy: .cacheUpToDuration(.seconds(3_600))
        )
    )
}
