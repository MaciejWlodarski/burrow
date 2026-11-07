import Foundation

struct ServerConnectionRegressionTests {
    static func runAll() throws {
        func url(_ input: String) -> String? { ServerAddress.url(from: input)?.absoluteString }
        // A server name alone, or with a share, means SMB, as in Finder.
        try expect(url("nas.local") == "smb://nas.local")
        try expect(url("  192.168.1.20/Photos \n") == "smb://192.168.1.20/Photos")
        try expect(url("\\\\nas\\Photos") == "smb://nas/Photos")
        try expect(url("afp://mac.local/Share") == "afp://mac.local/Share")
        try expect(url("SMB://NAS/Share") != nil)
        try expect(url("https://dav.example.com/files") == "https://dav.example.com/files")
        try expect(url("smb://nas/My Share") == "smb://nas/My%20Share")
        try expect(url("") == nil)
        try expect(url("   ") == nil)
        try expect(url("file:///Volumes/x") == nil)
        try expect(url("ssh://host") == nil)
        try expect(url("smb:///share") == nil)

        // Only addresses are remembered, never a password; newest first, no duplicates.
        let suite = "com.burrow.tests.recent-servers.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw RegressionFailure(description: "recent servers defaults") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let recents = RecentServers(defaults: defaults)
        recents.add(URL(string: "smb://alice:secret@nas/Photos")!)
        try expect(recents.all == ["smb://alice@nas/Photos"])
        recents.add(URL(string: "afp://mac/Share")!)
        recents.add(URL(string: "smb://alice@NAS/Photos")!)
        try expect(recents.all == ["smb://alice@NAS/Photos", "afp://mac/Share"])
        for index in 0..<20 { recents.add(URL(string: "smb://host\(index)")!) }
        try expect(recents.all.count == RecentServers.limit)
        try expect(recents.all.first == "smb://host19")
        recents.remove("smb://host19")
        try expect(recents.all.first == "smb://host18")
        recents.clear()
        try expect(recents.all.isEmpty)

        // A saved drive keeps a user name but never a password, query or fragment,
        // and needs a share: a server alone is chosen from when it is mounted.
        let share = NetworkShare(address: "smb://alice:secret@NAS.local/Photos/2024?token=x#y")
        try expect(share?.address == "smb://alice@NAS.local/Photos/2024")
        try expect(share?.name == "2024")
        try expect(share?.server.title == "nas.local")
        try expect(NetworkShare(address: "smb://nas.local") == nil)
        try expect(NetworkShare(address: "smb://nas.local/") == nil)
        try expect(NetworkShare(address: "file:///Volumes/Photos") == nil)
        try expect(NetworkShare(address: "smb://bob@nas.local:445/photos")?.id == NetworkShare(address: "smb://NAS.local/Photos")?.id)
        try expect(NetworkShare(address: "afp://nas.local/Photos")?.id != NetworkShare(address: "smb://nas.local/Photos")?.id)

        let savedSuite = "com.burrow.tests.saved-shares.\(UUID().uuidString)"
        guard let savedDefaults = UserDefaults(suiteName: savedSuite) else { throw RegressionFailure(description: "saved shares defaults") }
        defer { savedDefaults.removePersistentDomain(forName: savedSuite) }
        let saved = SavedNetworkShares(defaults: savedDefaults)
        try expect(saved.all.isEmpty)
        try expect(saved.keepsNewShares)
        try expect(!saved.reconnectsAtLaunch)
        saved.add(share!)
        saved.add(NetworkShare(address: "afp://mac.local/Share")!)
        // The same share again replaces its address in place.
        saved.add(NetworkShare(address: "smb://bob@nas.local/photos/2024")!)
        try expect(saved.all.map(\.address) == ["smb://bob@nas.local/photos/2024", "afp://mac.local/Share"])
        try expect(!(savedDefaults.stringArray(forKey: SavedNetworkShares.defaultsKey) ?? []).joined().contains("secret"))
        // Entries edited by hand into something unusable or duplicated are skipped.
        savedDefaults.set(["smb://nas.local", "nonsense", "afp://mac.local/Share", "AFP://MAC.local/share"],
                          forKey: SavedNetworkShares.defaultsKey)
        try expect(saved.all.map(\.address) == ["afp://mac.local/Share"])
        saved.remove(NetworkShare(address: "afp://mac.local/share")!)
        try expect(saved.all.isEmpty)
        saved.keepsNewShares = false
        saved.reconnectsAtLaunch = true
        try expect(!saved.keepsNewShares && saved.reconnectsAtLaunch)

        // The reachability check knows each protocol's port and skips Bonjour names.
        func endpoint(_ address: String) -> String? {
            ServerReachability.endpoint(for: URL(string: address)!).map { "\($0.host):\($0.port)" }
        }
        try expect(endpoint("smb://nas.local/Photos") == "nas.local:445")
        try expect(endpoint("afp://mac.local/Share") == "mac.local:548")
        try expect(endpoint("nfs://10.0.0.2/export") == "10.0.0.2:2049")
        try expect(endpoint("https://dav.example.com/files") == "dav.example.com:443")
        try expect(endpoint("smb://nas.local:1445/Photos") == "nas.local:1445")
        try expect(endpoint("smb://[2001:db8::1]/share") == "2001:db8::1:445")
        try expect(endpoint("smb://NAS._smb._tcp.local/Photos") == nil)
        try expect(endpoint("vnc://mac.local") == nil)
    }
}
