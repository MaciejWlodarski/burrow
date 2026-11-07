import Foundation

struct NetworkVolumeGroupingRegressionTests {
    private static func server(_ value: String) -> NetworkServerIdentity? {
        NetworkServerIdentity.parse(remountURL: URL(string: value))
    }
    private static func volume(_ path: String, _ endpoint: String?, network: Bool = true,
                               total: Int64? = nil, free: Int64? = nil) -> VolumeInfoItem {
        VolumeInfoItem(name: "Same share", url: URL(fileURLWithPath: path), totalBytes: total,
                       freeBytes: free, isRemovable: true, isNetwork: network,
                       networkServer: endpoint.flatMap(server))
    }
    static func runAll() throws {
        let first = server("smb://alice:secret@NAS.example./Photos?token=hidden#private")
        let second = server("smb://bob@nas.example:445/Documents")
        try expect(first != nil && first == second)
        try expect(first?.title == "nas.example")
        try expect(first?.id == "smb://nas.example")
        try expect(server("smb://nas.example:1445/Photos") != first)
        try expect(server("afp://nas.example/Photos") != first)
        try expect(server("smb://192.0.2.2/Photos") != first)
        try expect(server("file:///Volumes/Photos") == nil)
        try expect(server("smb:///Photos") == nil)
        try expect(server("smb://bad%20host/Photos") == nil)
        try expect(server("smb://host:0/share") == nil)
        try expect(server("smb://host:65536/share") == nil)
        try expect(server("smb://host:-1/share") == nil)
        try expect(server("https://example.com:443/share") == server("https://example.com/share"))
        try expect(server("smb://[2001:db8::1]/share") != nil)
        let a = volume("/Volumes/Photos", "smb://NAS.example/A")
        let b = volume("/Volumes/Documents", "smb://nas.example/B")
        let other = volume("/Volumes/Photos-1", "smb://other.internal/A")
        let unknown = volume("/Volumes/Unknown", nil)
        let anotherUnknown = volume("/Volumes/Unknown-2", nil)
        let local = volume("/", nil, network: false, total: 100, free: 40)
        let items = [b, local, unknown, other, a, anotherUnknown]
        let grouped = VolumeSidebarGroups.build(from: items)
        try expect(grouped.localVolumes.map(\.id) == ["/"])
        try expect(grouped.networkServers.count == 4)
        let nas = grouped.networkServers.first { $0.title == "nas.example" }
        try expect(nas?.volumes.map(\.id) == ["/Volumes/Documents", "/Volumes/Photos"])
        try expect(grouped.networkServers.filter { !$0.isServerKnown }.count == 2)
        let reversed = VolumeSidebarGroups.build(from: Array(items.reversed()))
        try expect(grouped.networkServers.map(\.id) == reversed.networkServers.map(\.id))
        try expect(grouped.networkServers.flatMap(\.volumes).map(\.id) == reversed.networkServers.flatMap(\.volumes).map(\.id))
        try expect(local.usedFraction == 0.6)
        try expect(volume("/fake", nil, total: 100, free: 0).usedFraction == 1)
        try expect(volume("/fake", nil, total: 100).usedFraction == nil)
        try expect(volume("/fake", nil, free: 0).usedFraction == nil)
        try expect(volume("/fake", nil, total: 0, free: 0).usedFraction == nil)
        try expect(volume("/fake", nil, total: 100, free: 101).usedFraction == nil)
        try expect(volume("/fake", nil, total: -1, free: -1).freeBytes == nil)
        // Snapshot transitions regroup only known mounted shares; failure retains last good inventory.
        var state = VolumeInventoryState()
        state.apply(.success(VolumeSnapshot(items: [a, b])))
        let stableID = VolumeSidebarGroups.build(from: state.items).networkServers.first?.id
        state.apply(.failure)
        try expect(VolumeSidebarGroups.build(from: state.items).networkServers.first?.volumes.count == 2)
        state.apply(.success(VolumeSnapshot(items: [b])))
        try expect(VolumeSidebarGroups.build(from: state.items).networkServers.first?.id == stableID)
        state.apply(.success(VolumeSnapshot(items: [])))
        try expect(VolumeSidebarGroups.build(from: state.items).networkServers.isEmpty)
        // Saved drives that are not mounted join their server's group, or make one.
        let photos = NetworkShare(address: "smb://alice@nas.example/Photos")!
        let music = NetworkShare(address: "smb://nas.example/Music")!
        let offsite = NetworkShare(address: "afp://backup.example/Archive")!
        let mountedPhotos = VolumeInfoItem(name: "Photos", url: URL(fileURLWithPath: "/Volumes/Photos"),
                                           totalBytes: nil, freeBytes: nil, isRemovable: true,
                                           networkShare: NetworkShare(address: "smb://bob@NAS.example/photos"))
        try expect(mountedPhotos.isNetwork && mountedPhotos.networkServer?.id == "smb://nas.example")
        let withSaved = VolumeSidebarGroups.build(from: [mountedPhotos, local],
                                                  saved: [photos, music, offsite, music]).networkServers
        try expect(withSaved.map(\.id) == ["server:afp://backup.example", "server:smb://nas.example"])
        try expect(withSaved[1].volumes.map(\.id) == ["/Volumes/Photos"])
        try expect(withSaved[1].disconnectedShares.map(\.name) == ["Music"])
        try expect(withSaved[0].volumes.isEmpty && withSaved[0].isServerKnown)
        try expect(withSaved[0].disconnectedShares.map(\.name) == ["Archive"])
        try expect(VolumeSidebarGroups.build(from: [local], saved: []).networkServers.isEmpty)
        print("PASS network server grouping, sanitized endpoints, unknown capacity and inventory transitions")
    }
}
