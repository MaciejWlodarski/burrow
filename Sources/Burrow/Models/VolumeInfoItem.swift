import Foundation

/// Sanitized endpoint identity only. Never retain remount credentials or share URLs.
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

public struct VolumeInfoItem: Identifiable, Sendable {
    public var id: String { url.path }
    public let name: String
    public let url: URL
    public let totalBytes: Int64?
    public let freeBytes: Int64?
    public let isRemovable: Bool
    public let isNetwork: Bool
    public let networkServer: NetworkServerIdentity?

    public init(name: String, url: URL, totalBytes: Int64?, freeBytes: Int64?,
                isRemovable: Bool, isNetwork: Bool = false,
                networkServer: NetworkServerIdentity? = nil) {
        self.name = name; self.url = url
        self.totalBytes = totalBytes.flatMap { $0 >= 0 ? $0 : nil }
        self.freeBytes = freeBytes.flatMap { $0 >= 0 ? $0 : nil }
        self.isRemovable = isRemovable
        self.isNetwork = isNetwork || networkServer != nil
        self.networkServer = networkServer
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
}

/// Pure grouping: no DNS lookups, probing, mounting, or filesystem existence checks.
public struct VolumeSidebarGroups: Sendable {
    public let localVolumes: [VolumeInfoItem]
    public let networkServers: [NetworkVolumeGroup]

    public static func build(from items: [VolumeInfoItem]) -> VolumeSidebarGroups {
        var groups: [String: [VolumeInfoItem]] = [:]
        var local: [VolumeInfoItem] = []
        for item in items {
            if item.isNetwork {
                let key = item.networkServer.map { "server:" + $0.id } ?? "unknown:" + item.id
                groups[key, default: []].append(item)
            } else { local.append(item) }
        }
        let servers = groups.map { key, values in
            let shares = values.sorted { $0.id < $1.id }
            let server = shares.first?.networkServer
            return NetworkVolumeGroup(id: key, title: server?.title ?? "Serwer nieznany",
                                      volumes: shares, isServerKnown: server != nil)
        }.sorted { $0.id < $1.id }
        return VolumeSidebarGroups(localVolumes: local.sorted { $0.id < $1.id }, networkServers: servers)
    }
}
