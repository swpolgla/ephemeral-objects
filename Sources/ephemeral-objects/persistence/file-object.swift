import Fluent
import Foundation

enum FileObjectState: String, Codable, Sendable {
    case pending
    case available
    case deleting
}

final class FileObject: Model, @unchecked Sendable {
    static let schema: String = "file_objects"

    @ID(custom: "id", generatedBy: .user)
    var id: String?

    @Field(key: "original_filename")
    var originalFilename: String

    @OptionalField(key: "file_extension")
    var fileExtension: String?

    @Field(key: "content_type")
    var contentType: String

    @Field(key: "byte_size")
    var byteSize: Int64

    @Field(key: "sha256")
    var sha256: String

    @Field(key: "uploaded_at")
    var uploadedAt: Date

    @Field(key: "remaining_downloads")
    var remainingDownloads: Int

    @Enum(key: "state")
    var state: FileObjectState

    init() {}

    init(
        id: String,
        originalFilename: String,
        fileExtension: String?,
        contentType: String,
        byteSize: Int64,
        sha256: String,
        uploadedAt: Date,
        remainingDownloads: Int,
        state: FileObjectState
    ) {
        self.id = id
        self.originalFilename = originalFilename
        self.fileExtension = fileExtension
        self.contentType = contentType
        self.byteSize = byteSize
        self.sha256 = sha256
        self.uploadedAt = uploadedAt
        self.remainingDownloads = remainingDownloads
        self.state = state
    }
}
