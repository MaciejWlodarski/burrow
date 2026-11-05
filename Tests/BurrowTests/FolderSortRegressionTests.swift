import Foundation

/// Per-folder sort with a default, like Explorer's folder views.
struct FolderSortRegressionTests {
    @MainActor func runAll() async throws {
        try testStorePersistsDefaultsAndExceptions()
        try await testPanesUseFolderSortAndFollowChanges()
        try testFolderViewModes()
        print("PASS per-folder sort and view: default, folder exceptions, reset, persistence and live updates across tabs")
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
    @MainActor private func testFolderViewModes() throws {
        let suiteName = "com.burrow.tests.folder-view-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { throw RegressionFailure(description: "no suite") }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let photos = URL(fileURLWithPath: "/tmp/x/Photos"), other = URL(fileURLWithPath: "/tmp/x/Other")
        let store = FolderViewPreferences(defaults: defaults)
        try expect(store.mode(for: other) == .list)
        store.setMode(.icons, for: URL(fileURLWithPath: "/tmp/x/Photos/"))
        store.setMode(.wiztree, for: other)
        try expect(store.mode(for: photos) == .icons && !store.hasCustomMode(for: other))
        let reloaded = FolderViewPreferences(defaults: defaults)
        try expect(reloaded.mode(for: photos) == .icons)
        reloaded.setDefaultMode(.icons)
        try expect(!reloaded.hasCustomMode(for: photos) && reloaded.mode(for: other) == .icons)
        reloaded.setMode(.columns, for: photos)
        reloaded.resetMode(for: photos)
        try expect(FolderViewPreferences(defaults: defaults).mode(for: photos) == .icons)

        // Panes: list and icons follow each folder's view; columns and the disk
        // map stay while browsing; a picked view is remembered per folder.
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BURROW_TEST_ROOT"] ?? NSTemporaryDirectory())
            .appendingPathComponent("folder-view-\(UUID().uuidString)")
        let pictures = root.appendingPathComponent("Pictures"), work = root.appendingPathComponent("Work")
        let nested = pictures.appendingPathComponent("Trip")
        for folder in [nested, work] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let shared = FolderViewPreferences.shared
        defer {
            shared.resetAllFolders()
            shared.setDefaultMode(.list)
            try? FileManager.default.removeItem(at: root)
        }
        let pane = PaneTabState(initialURL: pictures)
        try expect(pane.viewMode == shared.defaultMode)
        pane.chooseViewMode(.icons)
        try expect(shared.mode(for: pictures) == .icons)
        try expect(pane.navigate(to: work) && pane.viewMode == .list)
        try expect(pane.navigate(to: pictures) && pane.viewMode == .icons)
        pane.goBack()
        try expect(pane.currentURL == work.standardizedFileURL && pane.viewMode == .list)
        try expect(PaneTabState(initialURL: pictures).viewMode == .icons)
        pane.chooseViewMode(.columns)
        try expect(pane.navigate(to: pictures) && pane.viewMode == .columns)
        pane.chooseViewMode(.wiztree)
        try expect(pane.navigate(to: nested) && pane.viewMode == .wiztree)
        try expect(shared.mode(for: pictures) == .icons && !shared.hasCustomMode(for: nested))
        pane.chooseViewMode(.list)
        try expect(!shared.hasCustomMode(for: nested))
    }
}
