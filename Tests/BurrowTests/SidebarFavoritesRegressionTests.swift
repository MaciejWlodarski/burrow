import Foundation

@MainActor struct SidebarFavoritesRegressionTests {
    static func runAll() throws {
        typealias Entry = SidebarFavoritesStore.Entry
        let defaults = [Entry(path: "/home", title: "Dom", iconName: "house.fill"),
                        Entry(path: "/home/.Trash", title: "Kosz", iconName: "trash.fill")]
        var raw: Any?
        let legacy = ["/offline/share", "/home", "/home/", "/offline/share", "/work"]
        var writes = 0
        let store = SidebarFavoritesStore(defaults: defaults, read: { raw }, readLegacy: { legacy },
            write: { raw = $0; writes += 1 })
        try expect(store.notice == nil && writes == 1)
        try expect(store.items.map(\.path) == ["/home", "/home/.Trash", "/offline/share", "/work"])
        try expect(store.items[1].iconName == "trash.fill")
        try expect(store.move("/offline/share", before: "/home"))
        try expect(store.items.first?.path == "/offline/share")
        try expect(store.rename("/home", title: "Mój dom"))
        try expect(store.move("/home", by: 1))
        let snapshot = store.items
        let reload = SidebarFavoritesStore(defaults: [], read: { raw }, readLegacy: { "invalid legacy ignored" }, write: { _ in writes += 1 })
        try expect(reload.items == snapshot && reload.notice == nil)
        let oldWrites = writes
        try expect(store.add("/home") && writes == oldWrites)
        try expect(store.add("/home/") && writes == oldWrites)
        try expect(!store.move("/absent", before: nil))
        try expect(!store.move("/home", before: "/absent"))
        try expect(!store.move("/home", by: Int.max))
        try expect(!store.rename("/home", title: "\n"))
        try expect(store.items == snapshot && writes == oldWrites)
        for entry in snapshot { try expect(store.remove(entry.path)) }
        let empty = SidebarFavoritesStore(defaults: defaults, read: { raw }, readLegacy: { legacy }, write: { _ in writes += 1 })
        try expect(empty.items.isEmpty && empty.notice == nil)
        let emptyData = raw as! Data
        raw = "external corruption"
        try expect(!store.add("/new") && store.notice != nil && (raw as? String) == "external corruption")

        for bad: Any in [42, Data("{}".utf8), Data("{\"version\":2,\"items\":[]}".utf8),
            Data("{\"version\":1,\"items\":[{\"path\":\"relative\",\"title\":\"X\",\"iconName\":\"folder\"}]}".utf8)] {
            var badWrites = 0
            let protected = SidebarFavoritesStore(defaults: defaults, read: { bad }, readLegacy: { legacy }, write: { _ in badWrites += 1 })
            try expect(protected.notice != nil && protected.items.isEmpty && !protected.add("/new") && badWrites == 0)
        }
        for badLegacy: Any in [42, ["relative"], ["/valid", 3] as [Any]] {
            var attempts = 0
            let protected = SidebarFavoritesStore(defaults: defaults, read: { nil }, readLegacy: { badLegacy }, write: { _ in attempts += 1 })
            try expect(protected.notice != nil && attempts == 0)
        }
        var controlRaw: Any?
        let controlLegacy = ["/offline/line\nbreak"]
        let control = SidebarFavoritesStore(defaults: [], read: { controlRaw }, readLegacy: { controlLegacy }, write: { controlRaw = $0 })
        try expect(control.notice == nil && control.items.first?.path == controlLegacy[0])
        try expect(control.items.first?.title == "linebreak")
        // Legacy paths fit the old byte cap, but the new JSON overhead exceeds it.
        let largeLegacy = (0..<128).map { "/" + String($0) + "/" + String(repeating: "a", count: 8180) }
        var largeWrites = 0
        let large = SidebarFavoritesStore(defaults: defaults, read: { nil }, readLegacy: { largeLegacy }, write: { _ in largeWrites += 1 })
        try expect(large.notice != nil && large.items.isEmpty && largeWrites == 0)
        let refusedSeed = SidebarFavoritesStore(defaults: defaults, read: { nil }, readLegacy: { nil }, write: { _ in })
        try expect(refusedSeed.notice != nil && refusedSeed.items.isEmpty)
        let refusedMutation = SidebarFavoritesStore(defaults: defaults, read: { emptyData }, readLegacy: { nil }, write: { _ in })
        try expect(!refusedMutation.add("/offline") && refusedMutation.items.isEmpty && refusedMutation.notice != nil)
        // Existing persisted empty list wins over changed defaults and all legacy data.
        try expect(empty.items.isEmpty)
        print("PASS unified manual favorites migration, ordering, empty state and protected persistence")
    }
}
