import Foundation

/// Per-folder sort with a default, like Explorer's folder views.
struct FolderSortRegressionTests {
    @MainActor func runAll() async throws {
        try testStorePersistsDefaultsAndExceptions()
        try await testPanesUseFolderSortAndFollowChanges()
        print("PASS per-folder sort: default, folder exceptions, reset, persistence and live updates across tabs")
    }

    @MainActor private func testStorePersistsDefaultsAndExceptions() throws {
        let suiteName = "com.burrow.tests.folder-sort-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { throw RegressionFailure(description: "no suite") }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let downloads = URL(fileURLWithPath: "/tmp/x/Downloads")
        let other = URL(fileURLWithPath: "/tmp/x/Other")
        let byDate = FolderSort(field: .dateModified, ascending: false, foldersOnTop: true)

        let store = FolderSortPreferences(defaults: defaults)
        try expect(store.sort(for: other) == .standard)
        store.setSort(byDate, for: URL(fileURLWithPath: "/tmp/x/Downloads/"))
        try expect(store.sort(for: downloads) == byDate && store.hasCustomSort(for: downloads))
        try expect(store.sort(for: other) == .standard)
        // Setting a folder back to the default makes it follow the default again.
        store.setSort(.standard, for: other)
        try expect(!store.hasCustomSort(for: other))

        let reloaded = FolderSortPreferences(defaults: defaults)
        try expect(reloaded.sort(for: downloads) == byDate)
        let bySize = FolderSort(field: .size, ascending: false, foldersOnTop: false)
        reloaded.setDefaultSort(bySize)
        try expect(reloaded.sort(for: other) == bySize && reloaded.sort(for: downloads) == byDate)
        // A new default equal to an exception absorbs it.
        reloaded.setDefaultSort(byDate)
        try expect(!reloaded.hasCustomSort(for: downloads))
        reloaded.setSort(bySize, for: downloads)
        reloaded.resetSort(for: downloads)
        try expect(reloaded.sort(for: downloads) == byDate)
        try expect(FolderSortPreferences(defaults: defaults).defaultSort == byDate)
    }

    @MainActor private func testPanesUseFolderSortAndFollowChanges() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BURROW_TEST_ROOT"] ?? NSTemporaryDirectory())
            .appendingPathComponent("folder-sort-\(UUID().uuidString)")
        let downloads = root.appendingPathComponent("Downloads"), work = root.appendingPathComponent("Work")
        for folder in [downloads, work] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (index, name) in ["a.txt", "b.txt", "c.txt"].enumerated() {
                let file = folder.appendingPathComponent(name)
                try Data(repeating: 1, count: 10 * (index + 1)).write(to: file)
                // a is newest, c is oldest.
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000 - Double(index) * 1000)],
                                                      ofItemAtPath: file.path)
            }
        }
        let store = FolderSortPreferences.shared
        defer {
            store.resetAllFolders()
            store.setDefaultSort(.standard)
            try? FileManager.default.removeItem(at: root)
        }
        func settle() async throws { try await Task.sleep(nanoseconds: 50_000_000) }

        let pane = PaneTabState(initialURL: downloads)
        try expect(pane.currentSort == .standard)
        pane.setSort(FolderSort(field: .dateModified, ascending: true, foldersOnTop: true))
        try expect(pane.displayedItems.map(\.name) == ["c.txt", "b.txt", "a.txt"])
        try expect(store.hasCustomSort(for: downloads))

        // Other folders keep the default; coming back restores the folder's sort.
        try expect(pane.navigate(to: work))
        try expect(pane.currentSort == .standard && pane.displayedItems.map(\.name) == ["a.txt", "b.txt", "c.txt"])
        try expect(pane.navigate(to: downloads))
        try expect(pane.sortField == .dateModified && pane.displayedItems.map(\.name) == ["c.txt", "b.txt", "a.txt"])

        // Another tab on Downloads follows a change; a tab on Work follows the default.
        let workTab = PaneTabState(initialURL: work)
        let downloadsTab = PaneTabState(initialURL: downloads)
        try expect(downloadsTab.sortField == .dateModified)
        pane.setSort(FolderSort(field: .size, ascending: false, foldersOnTop: true))
        try await settle()
        try expect(downloadsTab.displayedItems.map(\.name) == ["c.txt", "b.txt", "a.txt"] && downloadsTab.sortField == .size)
        store.setDefaultSort(FolderSort(field: .name, ascending: false, foldersOnTop: true))
        try await settle()
        try expect(workTab.displayedItems.map(\.name) == ["c.txt", "b.txt", "a.txt"])
        try expect(pane.sortField == .size)

        // Resetting the folder returns it to the default.
        store.resetSort(for: downloads)
        try await settle()
        try expect(pane.currentSort == store.defaultSort && downloadsTab.currentSort == store.defaultSort)

        // Sorting whole-index search results leaves the folder's sort alone.
        pane.searchScope = .wholeIndex
        pane.searchQuery = "zzz-no-match"
        pane.setSort(FolderSort(field: .kind, ascending: true, foldersOnTop: true))
        try expect(!store.hasCustomSort(for: downloads))
        pane.clearSearch()
    }
}
