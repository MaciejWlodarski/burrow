import Foundation

@MainActor
enum CloudFilesRegressionTests {
    static func runAll() throws {
        try testProviderNames()
        try testBreadcrumbsStartAtProvider()
        try testLocationsAndContainment()
        try testIndexCacheKeepsDatalessFlag()
        // iCloud Drive is listed under Cloud, not duplicated in Favorites.
        try expect(!AppState.shared.favorites.contains { $0.url.path.hasSuffix("com~apple~CloudDocs") })
        print("PASS cloud provider detection and dataless metadata")
    }

    private static func testProviderNames() throws {
        let google = CloudFiles.describe(folderName: "GoogleDrive-me@example.com")
        try expect(google.0 == "Google Drive" && google.1 == "me@example.com")
        let personal = CloudFiles.describe(folderName: "OneDrive-Personal")
        try expect(personal.0 == "OneDrive" && personal.1 == nil)
        let company = CloudFiles.describe(folderName: "OneDrive-Contoso Ltd")
        try expect(company.0 == "OneDrive" && company.1 == "Contoso Ltd")
        let box = CloudFiles.describe(folderName: "Box-Box")
        try expect(box.0 == "Box" && box.1 == nil)
        let dropbox = CloudFiles.describe(folderName: "Dropbox")
        try expect(dropbox.0 == "Dropbox" && dropbox.1 == nil)
        let unknown = CloudFiles.describe(folderName: "SomeSync-work")
        try expect(unknown.0 == "SomeSync" && unknown.1 == "work")
    }

    private static func testBreadcrumbsStartAtProvider() throws {
        let root = URL(fileURLWithPath: "/Users/u/Library/CloudStorage/GoogleDrive-me@example.com", isDirectory: true)
        let clouds = [CloudFiles.Location(url: root, provider: "Google Drive", account: "me@example.com")]
        let names = PathBreadcrumbBar.segments(for: root.appendingPathComponent("My Drive/Work"), volumes: [], clouds: clouds).map(\.name)
        try expect(names == ["Google Drive", "My Drive", "Work"])
        let local = PathBreadcrumbBar.segments(for: URL(fileURLWithPath: "/Users/u/Library/CloudStorage/GoogleDrive-me@example.com2"),
                                               volumes: [], clouds: clouds)
        try expect(local.first?.name == "/" && local.count == 6)
        try expect(CloudFiles.appBundleIdentifier(for: "Google Drive") == "com.google.drivefs")
    }

    private static func testLocationsAndContainment() throws {
        let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BURROW_TEST_ROOT"]!)
            .appendingPathComponent("cloud-home-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        defer { try? fm.removeItem(at: home) }
        let drive = home.appendingPathComponent("Library/CloudStorage/GoogleDrive-me@example.com/My Drive", isDirectory: true)
        try fm.createDirectory(at: drive, withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent("Library/CloudStorage/.hidden"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs"), withIntermediateDirectories: true)

        let found = CloudFiles.locations(home: home)
        try expect(found.map(\.provider) == ["iCloud Drive", "Google Drive"])
        try expect(found[1].account == "me@example.com")

        let file = drive.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: file)
        try expect(CloudFiles.location(containing: file.path, in: found)?.provider == "Google Drive")
        // A sibling whose name only shares a prefix is not inside the location.
        let sibling = home.appendingPathComponent("Library/CloudStorage/GoogleDrive-me@example.com2")
        try expect(CloudFiles.location(containing: sibling.path, in: found) == nil)
        // A symlink into the drive resolves to it, as the "Google Drive" shortcut does.
        let link = home.appendingPathComponent("Drive shortcut")
        try fm.createSymbolicLink(at: link, withDestinationURL: drive)
        try expect(CloudFiles.location(containing: link.path, in: found)?.provider == "Google Drive")
        // Local files are not dataless, and reading them with downloads off works.
        try expect(!CloudFiles.isDataless(path: file.path))
        let text = try CloudFiles.withoutDownloading { try String(contentsOf: file, encoding: .utf8) }
        try expect(text == "x")
    }

    private static func testIndexCacheKeepsDatalessFlag() throws {
        func entry(_ name: String, dataless: Bool) -> IndexedFileEntry {
            IndexedFileEntry(name: name, lowerNameUTF8: Array(name.lowercased().utf8), parentPath: "/tmp", ext: "pdf",
                             charMask: 0, size: 10, mtimeEpoch: 0, isDirectory: false, isSymlink: false,
                             isHidden: false, isDataless: dataless)
        }
        try expect(entry("a.pdf", dataless: true).toFileItem(loadTags: false).isCloudOnly)
        try expect(!entry("b.pdf", dataless: false).toFileItem(loadTags: false).isCloudOnly)
        // Rows must redraw when a download finishes or is removed.
        try expect(entry("a.pdf", dataless: true).toFileItem(loadTags: false) != entry("a.pdf", dataless: false).toFileItem(loadTags: false))
    }
}
