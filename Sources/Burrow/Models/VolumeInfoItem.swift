import Foundation

/// Sanitized endpoint identity only. Never retain remount credentials.
public struct NetworkServerIdentity: Hashable, Sendable {
    public let id: String
    public let title: String

    public static func parse(remountURL: URL?) -> NetworkServerIdentity? {
        guard let remountURL, remountURL.absoluteString.utf8.count <= 16_384,
              let parts = URLComponents(url: remountURL, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(),
              ["smb", "afp", "nfs", "http", "https", "dav", "davs", "ftp"].contains(scheme),
              var host = parts.host?.lowercased(), !host.isEmpty else { return nil }
        // A trailing DNS root dot and ASCII case do not change the endpoint.
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, host.utf8.count <= 253,
              host.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || ".-:[]%_".unicodeScalars.contains($0)
              }) else { return nil }
        let defaultPorts = ["smb": 445, "afp": 548, "nfs": 2049,
                            "http": 80, "https": 443, "dav": 80, "davs": 443, "ftp": 21]
        if let port = parts.port, !(1...65535).contains(port) { return nil }
        let port = parts.port.flatMap { $0 == defaultPorts[scheme] ? nil : $0 }
        let endpoint = host + (port.map { ":\($0)" } ?? "")
        return NetworkServerIdentity(id: scheme + "://" + endpoint, title: endpoint)
    }
}

/// The address of one share on a server, as kept for a saved network drive.
/// A password, query or fragment is never kept; the keychain holds the password.
public struct NetworkShare: Identifiable, Hashable, Sendable {
    /// The address to mount again, e.g. `smb://alice@nas.local/Photos`.
    public let address: String
    public let server: NetworkServerIdentity
    /// The share and any folder inside it, without the leading slash.
    public let sharePath: String

    /// Same server endpoint and share path, whatever the user name or case of the host.
    public var id: String { server.id + "/" + sharePath.lowercased() }
    public var name: String { sharePath.split(separator: "/").last.map(String.init) ?? sharePath }
    public var url: URL? { URL(string: address) }

    public init?(url: URL?) {
        guard let url, url.absoluteString.utf8.count <= 16_384,
              let server = NetworkServerIdentity.parse(remountURL: url),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // A server alone is not a drive: the share is chosen when it is mounted.
        guard !path.isEmpty else { return nil }
        parts.password = nil
        parts.query = nil
        parts.fragment = nil
        guard let address = parts.string else { return nil }
        self.address = address
        self.server = server
        self.sharePath = path
    }

    public init?(address: String) { self.init(url: URL(string: address)) }
}

public struct VolumeInfoItem: Identifiable, Sendable {
    public var id: String { url.path }
    public let name: String
    public let url: URL
    public let totalBytes: Int64?
    public let freeBytes: Int64?
    public let isRemovable: Bool
    public let isNetwork: Bool
    public let networkServer: NetworkServerIdentity?
    /// The share this volume mounts, when the system reports its address.
    public let networkShare: NetworkShare?

    public init(name: String, url: URL, totalBytes: Int64?, freeBytes: Int64?,
                isRemovable: Bool, isNetwork: Bool = false,
                networkServer: NetworkServerIdentity? = nil,
                networkShare: NetworkShare? = nil) {
        self.name = name; self.url = url
        self.totalBytes = totalBytes.flatMap { $0 >= 0 ? $0 : nil }
        self.freeBytes = freeBytes.flatMap { $0 >= 0 ? $0 : nil }
        self.isRemovable = isRemovable
        let server = networkServer ?? networkShare?.server
        self.isNetwork = isNetwork || server != nil
        self.networkServer = server
        self.networkShare = networkShare
    }
    public var usedFraction: Double? {
        guard let totalBytes, let freeBytes, totalBytes > 0, freeBytes <= totalBytes else { return nil }
        return Double(totalBytes - freeBytes) / Double(totalBytes)
    }
}

public struct NetworkVolumeGroup: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let volumes: [VolumeInfoItem]
    public let isServerKnown: Bool
    /// Saved drives on this server that are not mounted now.
    public var disconnectedShares: [NetworkShare] = []
}

/// Pure grouping: no DNS lookups, probing, mounting, or filesystem existence checks.
public struct VolumeSidebarGroups: Sendable {
    public let localVolumes: [VolumeInfoItem]
    public let networkServers: [NetworkVolumeGroup]

    public static func build(from items: [VolumeInfoItem], saved: [NetworkShare] = []) -> VolumeSidebarGroups {
        var groups: [String: [VolumeInfoItem]] = [:]
        var local: [VolumeInfoItem] = []
        for item in items {
            if item.isNetwork {
                let key = item.networkServer.map { "server:" + $0.id } ?? "unknown:" + item.id
                groups[key, default: []].append(item)
            } else { local.append(item) }
        }
        let mountedShareIDs = Set(items.compactMap { $0.networkShare?.id })
        var disconnected: [String: [NetworkShare]] = [:]
        var savedServers: [String: NetworkServerIdentity] = [:]
        var seenSaved = Set<String>()
        for share in saved where !mountedShareIDs.contains(share.id) && seenSaved.insert(share.id).inserted {
            let key = "server:" + share.server.id
            disconnected[key, default: []].append(share)
            savedServers[key] = share.server
        }
        let keys = Set(groups.keys).union(disconnected.keys)
        let servers = keys.map { key in
            let shares = (groups[key] ?? []).sorted { $0.id < $1.id }
            let server = shares.first?.networkServer ?? savedServers[key]
            let offline = (disconnected[key] ?? []).sorted { $0.id < $1.id }
            return NetworkVolumeGroup(id: key, title: server?.title ?? String(localized: "Unknown Server"),
                                      volumes: shares, isServerKnown: server != nil,
                                      disconnectedShares: offline)
        }.sorted { $0.id < $1.id }
        return VolumeSidebarGroups(localVolumes: local.sorted { $0.id < $1.id }, networkServers: servers)
    }
}
