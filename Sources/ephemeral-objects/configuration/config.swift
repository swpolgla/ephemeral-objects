import Foundation

struct app_config: Codable, Sendable {
    let object_store_directory: String
    let maximum_file_size: Int64 // Bytes
    let maximum_storage_duration: Int // Days
    let maximum_downloads: Int
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
