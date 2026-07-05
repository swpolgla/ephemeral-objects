import Fluent
import SQLKit

struct CreateFileObject: AsyncMigration {
    func prepare(on database: any Database) async throws {
        let state = try await database.enum("file_object_state")
            .case("pending")
            .case("available")
            .case("deleting")
            .create()

        try await database.schema(FileObject.schema)
            .field("id", .string, .identifier(auto: false))
            .field("original_filename", .string, .required)
            .field("file_extension", .string)
            .field("content_type", .string, .required)
            .field("byte_size", .int64, .required)
            .field("sha256", .string, .required)
            .field("uploaded_at", .datetime, .required)
            .field("remaining_downloads", .int, .required)
            .field("state", state, .required)
            .unique(on: "id")
            .create()

        if let sql: any SQLDatabase = database as? any SQLDatabase {
            try await sql.raw(
                "CREATE INDEX file_objects_cleanup_idx ON file_objects (state, uploaded_at)"
            ).run()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema(FileObject.schema).delete()
        try await database.enum("file_object_state").delete()
    }
}
