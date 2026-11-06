import Foundation
import NetFS

/// Turns what someone types into "Connect to Server" into a mountable URL, as
/// Finder does: a bare host or host/share means SMB.
enum ServerAddress {
    static let schemes: Set<String> = ["smb", "afp", "nfs", "ftp", "http", "https", "webdav", "cifs", "vnc"]

    static func url(from input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("\\\\") {
            // A Windows path, \\server\share.
            text = "smb://" + text.dropFirst(2).replacingOccurrences(of: "\\", with: "/")
        } else if !text.contains("://") {
            text = "smb://" + text
        }
        guard let url = URL(string: text) ?? URL(string: text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""),
              let scheme = url.scheme?.lowercased(), schemes.contains(scheme),
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// The address as it is stored and shown: no password, ever.
    static func display(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        components.password = nil
        return components.string ?? url.absoluteString
    }
}

/// Servers connected to before, newest first. Only addresses are kept;
/// passwords stay in the keychain, where the system's sign-in dialog puts them.
struct RecentServers {
    static let defaultsKey = "bf.servers.recent"
    static let limit = 10
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var all: [String] { defaults.stringArray(forKey: Self.defaultsKey) ?? [] }

    func add(_ url: URL) {
        let address = ServerAddress.display(url)
        var list = all.filter { $0.caseInsensitiveCompare(address) != .orderedSame }
        list.insert(address, at: 0)
        defaults.set(Array(list.prefix(Self.limit)), forKey: Self.defaultsKey)
    }

    func remove(_ address: String) {
        defaults.set(all.filter { $0 != address }, forKey: Self.defaultsKey)
    }

    func clear() { defaults.removeObject(forKey: Self.defaultsKey) }
}

enum ServerConnectionError: LocalizedError {
    case failed(Int32)

    var errorDescription: String? {
        switch self {
        case .failed(let code):
            switch code {
            case EAUTH, EACCES, EPERM: return String(localized: "The server did not accept the user name or password.")
            case ENOENT: return String(localized: "The shared folder was not found on the server.")
            case EHOSTUNREACH, ENETUNREACH, ETIMEDOUT, ECONNREFUSED, EHOSTDOWN:
                return String(localized: "The server cannot be reached. Check the address and the network.")
            default:
                let reason = String(cString: strerror(code))
                return String(localized: "Could not connect to the server: \(reason) (\(code)).")
            }
        }
    }
}

/// Mounts a server share with NetFS. The system asks for the user name and
/// password, offers to keep them in the keychain, and lets the user pick a
/// share when the address names only the server, as Finder does.
@MainActor
final class ServerMount {
    private var requestID: AsyncRequestID?

    /// The folder the share was mounted at, or nil when the user cancelled.
    func mount(_ url: URL) async throws -> URL? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL?, Error>) in
            let openOptions = NSMutableDictionary()
            openOptions["UIOption"] = "AllowUI" // kNAUIOptionKey: kNAUIOptionAllowUI
            let mountOptions = NSMutableDictionary()
            mountOptions["AllowSubMounts"] = true // kNetFSAllowSubMountsKey: mount a folder inside a share
            var request: AsyncRequestID?
            let status = NetFSMountURLAsync(url as CFURL, nil, nil, nil, openOptions, mountOptions, &request, .main) { status, _, mountPoints in
                MainActor.assumeIsolated {
                    self.requestID = nil
                    let paths = (mountPoints as? [String]) ?? []
                    switch status {
                    case 0:
                        continuation.resume(returning: paths.first.map { URL(fileURLWithPath: $0, isDirectory: true) })
                    case EEXIST:
                        // Already mounted: open the folder it is mounted at.
                        continuation.resume(returning: paths.first.map { URL(fileURLWithPath: $0, isDirectory: true) }
                                            ?? Self.existingMount(of: url))
                    case ECANCELED, Int32(-128): // the user closed the sign-in dialog (userCanceledErr)
                        continuation.resume(returning: nil)
                    default:
                        continuation.resume(throwing: ServerConnectionError.failed(status))
                    }
                }
            }
            if status != 0 {
                continuation.resume(throwing: ServerConnectionError.failed(status))
            } else {
                requestID = request
            }
        }
    }

    func cancel() {
        if let requestID { NetFSMountURLCancel(requestID) }
        requestID = nil
    }

    /// The mounted volume whose remount address names the same server and share.
    nonisolated static func existingMount(of url: URL) -> URL? {
        let keys: [URLResourceKey] = [.volumeURLForRemountingKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        let wanted = (url.host?.lowercased(), url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased())
        return volumes.first { volume in
            guard let remount = try? volume.resourceValues(forKeys: [.volumeURLForRemountingKey]).volumeURLForRemounting else { return false }
            let share = remount.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
            return remount.host?.lowercased() == wanted.0 && (wanted.1.isEmpty || share == wanted.1)
        }
    }
}
