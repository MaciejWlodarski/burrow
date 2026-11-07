import Foundation
import NetFS
import Network

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

/// Shares kept in the sidebar while disconnected, like mapped drives on
/// Windows, in the order they were added. Only sanitized addresses are kept.
struct SavedNetworkShares {
    static let defaultsKey = "bf.servers.saved"
    /// Whether Connect to Server keeps a newly mounted share in the sidebar.
    static let keepNewSharesKey = "bf.servers.keepInSidebar"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var all: [NetworkShare] {
        var seen = Set<String>()
        return (defaults.stringArray(forKey: Self.defaultsKey) ?? [])
            .compactMap(NetworkShare.init(address:))
            .filter { seen.insert($0.id).inserted }
    }

    /// Adds the share, or updates the address of the same share saved before.
    func add(_ share: NetworkShare) {
        var list = all
        if let index = list.firstIndex(where: { $0.id == share.id }) {
            list[index] = share
        } else {
            list.append(share)
        }
        defaults.set(list.map(\.address), forKey: Self.defaultsKey)
    }

    func remove(_ share: NetworkShare) {
        defaults.set(all.filter { $0.id != share.id }.map(\.address), forKey: Self.defaultsKey)
    }

    var keepsNewShares: Bool {
        get { defaults.object(forKey: Self.keepNewSharesKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.keepNewSharesKey) }
    }

    /// Whether saved drives connect at launch, without a sign-in dialog. Off by default.
    static let reconnectAtLaunchKey = "bf.servers.reconnectAtLaunch"
    var reconnectsAtLaunch: Bool {
        get { defaults.bool(forKey: Self.reconnectAtLaunchKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.reconnectAtLaunchKey) }
    }
}

/// A quick TCP check before mounting a saved drive. The system's mount call can
/// wait a long time for a server that is off or on another network; this answers
/// within a few seconds instead.
enum ServerReachability {
    static let timeout: Duration = .seconds(8)

    /// The port a share's protocol listens on, or nil when it cannot be checked
    /// (a Bonjour service name, which only the system resolves to a host and port).
    static func endpoint(for url: URL) -> (host: String, port: UInt16)? {
        guard let scheme = url.scheme?.lowercased(), var host = url.host, !host.isEmpty,
              !host.contains("._") else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        let defaults: [String: UInt16] = ["smb": 445, "cifs": 445, "afp": 548, "nfs": 2049,
                                          "ftp": 21, "http": 80, "webdav": 80, "dav": 80,
                                          "https": 443, "davs": 443]
        if let port = url.port { return (1...65535).contains(port) ? (host, UInt16(port)) : nil }
        return defaults[scheme].map { (host, $0) }
    }

    /// False when nothing answers on the share's port before the timeout.
    /// Shares that cannot be checked count as reachable and go to the mount.
    static func isReachable(_ url: URL) async -> Bool {
        guard let endpoint = endpoint(for: url), let port = NWEndpoint.Port(rawValue: endpoint.port) else { return true }
        let probe = Probe(NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: .tcp))
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in probe.start(continuation) }
        } onCancel: {
            probe.finish(false)
        }
    }

    /// One connection attempt that answers exactly once: when it connects, is
    /// refused, times out or the task is cancelled. All state lives on `queue`.
    private final class Probe: @unchecked Sendable {
        private let queue = DispatchQueue(label: "com.burrow.server-probe")
        private let connection: NWConnection
        private var continuation: CheckedContinuation<Bool, Never>?
        private var answer: Bool?

        init(_ connection: NWConnection) { self.connection = connection }

        func start(_ continuation: CheckedContinuation<Bool, Never>) {
            queue.async { [self] in
                if let answer { continuation.resume(returning: answer); return }
                self.continuation = continuation
                connection.stateUpdateHandler = { [self] state in
                    switch state {
                    case .ready: settle(true)
                    // Waiting means refused or no route; failed is final either way.
                    case .waiting, .failed: settle(false)
                    default: break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + .seconds(Int(ServerReachability.timeout.components.seconds))) { [self] in
                    settle(false)
                }
            }
        }

        func finish(_ value: Bool) { queue.async { [self] in settle(value) } }

        private func settle(_ value: Bool) {
            guard answer == nil else { return }
            answer = value
            connection.stateUpdateHandler = nil
            connection.cancel()
            continuation?.resume(returning: value)
            continuation = nil
        }
    }
}

enum ServerConnectionError: LocalizedError {
    case failed(Int32)
    /// Nothing answered on the share's port (see ServerReachability).
    case unreachable(server: String)

    var errorDescription: String? {
        switch self {
        case .unreachable(let server):
            return String(localized: "\(server) cannot be reached. Check that the server is on and on this network.")
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
    /// Without `allowUI` no sign-in dialog appears: only a password already in
    /// the keychain is used, and a share that needs one fails instead.
    func mount(_ url: URL, allowUI: Bool = true) async throws -> URL? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL?, Error>) in
            let openOptions = NSMutableDictionary()
            openOptions["UIOption"] = allowUI ? "AllowUI" : "NoUI" // kNAUIOptionKey: kNAUIOptionAllowUI / kNAUIOptionNoUI
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
