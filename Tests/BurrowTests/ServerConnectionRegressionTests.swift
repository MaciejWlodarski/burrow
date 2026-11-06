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
    }
}
