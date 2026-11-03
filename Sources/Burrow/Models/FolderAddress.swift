import Foundation

/// Parsing only: never probes, mounts, opens a URL, or runs a shell. The existing
/// transactional pane navigator remains the sole authority for directory access.
enum FolderAddress {
    static func resolve(_ input: String, relativeTo current: URL, home: URL) throws -> URL {
        guard !input.isEmpty else { throw Failure(String(localized: "Enter a folder path.")) }
        guard input.utf8.count <= 16_384,
              !input.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw Failure(String(localized: "The path is too long or contains control characters."))
        }
        if input.lowercased().hasPrefix("file:") {
            // Validate original bytes before Foundation can normalize a URL or
            // omit an encoded NUL from its decoded path. Decode exactly once:
            // %2500 names a literal "%00", not a NUL.
            _ = try decodeFileURLComponent(input)
            guard let parts = URLComponents(string: input), parts.scheme?.lowercased() == "file",
                  parts.user == nil, parts.password == nil, parts.port == nil,
                  parts.query == nil, parts.fragment == nil,
                  parts.host == nil || parts.host == "" || parts.host?.lowercased() == "localhost",
                  parts.percentEncodedPath.hasPrefix("/"),
                  let url = parts.url, url.isFileURL else {
                throw Failure(String(localized: "Use a local path or a file:/// address without credentials, query parameters, or a fragment."))
            }
            let path = try decodeFileURLComponent(parts.percentEncodedPath)
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        guard !input.contains("://") else {
            throw Failure(String(localized: "Enter a local path. For a network share, use its mounted folder in /Volumes."))
        }
        let path: String
        if input == "~" { path = home.path }
        else if input.hasPrefix("~/") { path = home.appendingPathComponent(String(input.dropFirst(2))).path }
        else if input.hasPrefix("~") { throw Failure(String(localized: "Use ~ or ~/folder for your own home folder.")) }
        else { path = input }
        return URL(fileURLWithPath: path, isDirectory: true, relativeTo: current).standardizedFileURL
    }

    /// A strict UTF-8 percent decoder rather than URL.path or C-string based
    /// conversion. It sees every original byte, including U+0000, before any URL
    /// normalization. Plain filesystem paths never pass through this decoder.
    private static func decodeFileURLComponent(_ encoded: String) throws -> String {
        let input = Array(encoded.utf8)
        var decoded: [UInt8] = []
        decoded.reserveCapacity(input.count)
        var index = 0
        while index < input.count {
            if input[index] == 0x25 {
                guard index + 2 < input.count,
                      let high = hexDigit(input[index + 1]), let low = hexDigit(input[index + 2]) else {
                    throw Failure(String(localized: "The file:/// address contains invalid percent-encoding."))
                }
                decoded.append(high * 16 + low)
                index += 3
            } else {
                decoded.append(input[index])
                index += 1
            }
        }
        guard let result = String(bytes: decoded, encoding: .utf8),
              !result.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw Failure(String(localized: "The file:/// address contains control characters or invalid UTF-8 encoding."))
        }
        return result
    }

    private static func hexDigit(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
