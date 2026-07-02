extension String {
    func sanitize() throws -> String {
        // Remove percent case from REST API calls
        var sanitized: String = self.removingPercentEncoding ?? ""

        let illegalCharacters: Set<Character> = ["\\", "/", ":", "*", "?", "\"", "<", ">", "|", "\0"]

        sanitized = String(sanitized.compactMap({ illegalCharacters.contains($0) ? nil : $0 }))

        // Remove all whitespace
        sanitized = sanitized.filter { !$0.isWhitespace }

        // Remove directory traversal
        if sanitized.contains("..") {
            sanitized = sanitized
                .split(separator: ".", omittingEmptySubsequences: false)
                .filter { !$0.isEmpty }
                .joined(separator: ".")
        }
        
        if (sanitized.isEmpty || sanitized == ".") {
            throw FilenameError.illegalFilename
        }
        return sanitized
    }
}