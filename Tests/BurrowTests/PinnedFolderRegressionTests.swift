import Foundation

@MainActor struct PinnedFolderRegressionTests {
    static func runAll() throws {
        let rawPath = "/Volumes/Disconnected/Work/"
        let row = SidebarLocationItem(bookmarkPath: rawPath, title: "Work", iconName: "bookmark.fill",
            url: URL(fileURLWithPath: rawPath, isDirectory: true), isCustomBookmark: true)
        try expect(row.id == rawPath)
        var raw: Any? = ["/Volumes/Disconnected/Work", "/local/B", "/local/B"]
        var writes = 0
        let store = PinnedFolderStore(read: { raw }, write: { raw = $0; writes += 1 })
        try expect(store.paths.count == 3 && store.displayedPaths.count == 2 && writes == 0)
        try expect(store.add("/local/C"))
        try expect(store.remove("/local/B"))
        try expect(store.paths == ["/Volumes/Disconnected/Work", "/local/C"])
        let reload = PinnedFolderStore(read: { raw }, write: { _ in writes += 1 })
        try expect(reload.paths == store.paths && writes == 2)
        try expect(reload.remove("/absent") && writes == 2)
        for malformed: Any in [42, ["/good", 42] as [Any], ["relative"], ["/bad\0path"],
            Array(repeating: "/x", count: PinnedFolderStore.maximumCount + 1),
            ["/" + String(repeating: "a", count: PinnedFolderStore.maximumPathBytes)],
            Array(repeating: "/" + String(repeating: "b", count: 8192), count: 200)] {
            var attemptedWrites = 0
            let invalid = PinnedFolderStore(read: { malformed }, write: { _ in attemptedWrites += 1 })
            try expect(invalid.state == .protected && invalid.notice != nil)
            try expect(!invalid.add("/new") && !invalid.remove("/good") && attemptedWrites == 0)
        }
        let rejectedRaw = ["/keep"]
        let rejected = PinnedFolderStore(read: { rejectedRaw }, write: { _ in })
        try expect(!rejected.add("/dropped"))
        try expect(rejected.paths == rejectedRaw && rejected.notice != nil)
        let absent = PinnedFolderStore(read: { nil }, write: { _ in })
        let empty = PinnedFolderStore(read: { [String]() }, write: { _ in })
        try expect(absent.state == .missing && empty.state == .valid)
        raw = "later corruption"
        try expect(!store.add("/new") && writes == 2 && (raw as? String) == "later corruption")

        // Test the real explicit-add boundary separately, only against isolated fixtures.
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BURROW_TEST_ROOT"]!)
        let file = root.appendingPathComponent("pin-ordinary-file-\(UUID().uuidString)")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let before = AppState.shared.customBookmarks.map(\.id)
        AppState.shared.addBookmark(for: file)
        AppState.shared.addBookmark(for: URL(string: "https://example.invalid/remote")!)
        try expect(AppState.shared.customBookmarks.map(\.id) == before)
        print("PASS offline pin membership, protected storage and explicit-add validation")
    }
}
