import Fluent
import FluentPostgresDriver
import Foundation
import Vapor

func configure_database(_ app: Application) throws {
    let hostname = Environment.get("DATABASE_HOST") ?? "127.0.0.1"
    let port = Environment.get("DATABASE_PORT").flatMap(Int.init) ?? 5432
    let username = Environment.get("DATABASE_USER") ?? "ephemeral"
    let database = Environment.get("DATABASE_NAME") ?? "ephemeral"

    guard let passwordFile = Environment.get("DATABASE_PASSWORD_FILE"),
          !passwordFile.isEmpty else {
        throw DatabaseConfigurationError.missingPasswordFile
    }

    let password = try String(contentsOfFile: passwordFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !password.isEmpty else {
        throw DatabaseConfigurationError.emptyPassword
    }

    app.databases.use(
        .postgres(
            configuration: .init(
                hostname: hostname,
                port: port,
                username: username,
                password: password,
                database: database,
                tls: .disable
            )
        ),
        as: .psql
    )
    app.migrations.add(CreateFileObject())
}

enum DatabaseConfigurationError: Error {
    case missingPasswordFile
    case emptyPassword
}
