import SwiftUI
import AppKit

@main
struct BurrowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var fileOps = FileOperationsManager.shared

    var body: some Scene {
        WindowGroup("Burrow", id: "main") {
            MainWindowView()
                // Folders opened from outside reuse this window (AppDelegate adds a tab)
                // instead of SwiftUI spawning a new window per event.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1200, height: 760)
        .commands {
            // File Menu Additions
            CommandGroup(replacing: .newItem) {
                Button("New Tab") {
                    appState.addNewTab()
                }
                .keyboardShortcut("t", modifiers: [.command])

                Button("Reopen Closed Tab") { appState.reopenClosedTab() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(appState.recentlyClosedTabs.isEmpty)

                Button("New Folder…") {
                    appState.showNewFolderSheet = true
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button("New File…") {
                    appState.showNewFileSheet = true
                }
                .keyboardShortcut("n", modifiers: [.command, .option])

                Divider()

                Button("Close Tab") {
                    if appState.isDualPane && appState.activePaneSide == .right {
                        // The right pane's last tab closes the pane itself.
                        if appState.rightTabs.count > 1 { appState.closeTab(appState.activeRightTabId) } else { appState.toggleDualPane() }
                    } else if appState.tabs.count > 1 {
                        appState.closeTab(appState.activeTabId)
                    } else {
                        NSApp?.keyWindow?.performClose(nil)
                    }
                }
                .keyboardShortcut("w", modifiers: [.command])
            }

            // Undo / Redo File Operations
            CommandGroup(replacing: .undoRedo) {
                Button(fileOps.undoLabel) {
                    if isEditingText { NSApp?.keyWindow?.firstResponder?.undoManager?.undo() }
                    else { fileOps.undoLastOperation() }
                }
                .keyboardShortcut("z", modifiers: [.command])
                .disabled(!isEditingText && (!fileOps.canUndo || fileOps.isBusy))

                Button(fileOps.redoLabel) {
                    if isEditingText { NSApp?.keyWindow?.firstResponder?.undoManager?.redo() }
                    else { fileOps.redoLastOperation() }
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!isEditingText && (!fileOps.canRedo || fileOps.isBusy))
            }

            // Edit / File Operations Menu
            CommandGroup(replacing: .pasteboard) {
                Divider()

                Button("Cut Files") {
                    if !routeTextAction(#selector(NSText.cut(_:))), canUseFileCommands { fileOps.cutItems(appState.activeTab.selectedItems) }
                }
                .keyboardShortcut("x", modifiers: [.command])

                Button("Copy Files") {
                    if !routeTextAction(#selector(NSText.copy(_:))), canUseFileCommands { fileOps.copyItems(appState.activeTab.selectedItems) }
                }
                .keyboardShortcut("c", modifiers: [.command])

                Button("Paste or Move Here") {
                    if !routeTextAction(#selector(NSText.paste(_:))), canUseFileCommands {
                        fileOps.paste(into: appState.activeTab.currentURL)
                    }
                }
                .keyboardShortcut("v", modifiers: [.command])

                Button("Move Here") {
                    if canUseFileCommands { fileOps.paste(into: appState.activeTab.currentURL, forceMove: true) }
                }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(!canUseFileCommands)

                Button("Select All") {
                    if !routeTextAction(#selector(NSText.selectAll(_:))), canUseFileCommands { appState.activeTab.selectAll() }
                }
                .keyboardShortcut("a", modifiers: [.command])

                Divider()

                Button("Copy Full Path") {
                    let sel = appState.activeTab.selectedItems
                    if sel.isEmpty {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(appState.activeTab.currentURL.path, forType: .string)
                    } else {
                        fileOps.copyPaths(sel)
                    }
                }
                .keyboardShortcut("c", modifiers: [.command, .option])

                Button("Duplicate Selected") {
                    guard canUseFileCommands else { return }
                    // Duplication runs detached; reload the originating pane once copies exist.
                    let pane = appState.activeTab
                    fileOps.duplicateItems(pane.selectedItems) { [weak pane] _ in pane?.reloadDirectory() }
                }
                .keyboardShortcut("d", modifiers: [.command])
                .disabled(!canUseFileCommands || appState.activeTab.selectedItems.isEmpty || fileOps.isBusy)

                Button("Move to Trash") {
                    if routeTextAction(#selector(NSResponder.deleteToBeginningOfLine(_:))) { return }
                    guard canUseFileCommands else { return }
                    fileOps.moveToTrash(appState.activeTab.selectedItems)
                }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(!isEditingText && (!canUseFileCommands || appState.activeTab.selectedItems.isEmpty || fileOps.isBusy))

                // emptySystemTrash asks for confirmation before deleting anything.
                Button("Empty Trash…") {
                    guard canUseFileCommands else { return }
                    fileOps.emptySystemTrash { appState.activeTab.reloadDirectory() }
                }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
                .disabled(!canUseFileCommands || fileOps.isBusy)
            }

            // fsearch & Navigation Menu
            CommandMenu("Go") {
                Button("Search Files and Folders") {
                    appState.focusSearchFieldTrigger += 1
                }
                .keyboardShortcut("f", modifiers: [.command])

                Button("Quick Search…") {
                    appState.showQuickFSearchModal.toggle()
                }
                .keyboardShortcut("p", modifiers: [.command])

                Divider()

                Button("Edit Path Bar") {
                    appState.activeTab.requestPathEditing()
                }
                .keyboardShortcut("l", modifiers: [.command])

                Button("Go to Folder…") { appState.activeTab.requestPathEditing() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Button("Home") {
                    appState.activeTab.navigate(to: FileManager.default.homeDirectoryForCurrentUser)
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Refresh") { appState.activeTab.refresh() }
                    .keyboardShortcut("r", modifiers: [.command])

                Button("Back") {
                    appState.activeTab.goBack()
                }
                .keyboardShortcut("[", modifiers: [.command])
                .disabled(appState.activeTab.historyBack.isEmpty)

                Button("Forward") {
                    appState.activeTab.goForward()
                }
                .keyboardShortcut("]", modifiers: [.command])
                .disabled(appState.activeTab.historyForward.isEmpty)

                Button("Enclosing Folder") {
                    appState.activeTab.goUp()
                }
                .keyboardShortcut(.upArrow, modifiers: [.command])

                Button("Open Selected Item") {
                    if let item = appState.activeTab.primarySelectedItem {
                        if item.isDirectory && item.fileExtension.lowercased() != "app" {
                            appState.activeTab.navigate(to: item.url)
                        } else {
                            NSWorkspace.shared.open(item.url)
                        }
                    }
                }
                .keyboardShortcut(.downArrow, modifiers: [.command])
                .disabled(appState.activeTab.selectedItems.isEmpty)

                Divider()

                Button("Rebuild File Index") {
                    FSearchIndex.shared.startIndexing()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }

            // View Menu Additions
            CommandGroup(after: .toolbar) {
                Button(appState.showSidebar ? String(localized: "Hide Sidebar") : String(localized: "Show Sidebar")) { appState.showSidebar.toggle() }
                    .keyboardShortcut("s", modifiers: [.command, .control])
                Divider()
                Button("as List") {
                    appState.activeTab.viewMode = .list
                }
                .keyboardShortcut("1", modifiers: [.command])

                Button("as Icons") {
                    appState.activeTab.viewMode = .icons
                }
                .keyboardShortcut("2", modifiers: [.command])

                Button("as Columns") {
                    appState.activeTab.viewMode = .columns
                }
                .keyboardShortcut("3", modifiers: [.command])

                Button("Disk Map") {
                    appState.activeTab.viewMode = .wiztree
                }
                .keyboardShortcut("4", modifiers: [.command])

                Divider()

                Button("Toggle Dual Pane") {
                    appState.toggleDualPane()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Button("Show/Hide Terminal") {
                    appState.showTerminalDrawer.toggle()
                }
                .keyboardShortcut("`", modifiers: [.control])

                Button("Show/Hide Hidden Files") {
                    appState.activeTab.showHiddenFiles.toggle()
                    appState.activeTab.refresh()
                }
                .keyboardShortcut(".", modifiers: [.command, .shift])

                Button("Show/Hide Inspector") {
                    appState.showInspector.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command])

                Button("Quick Look") {
                    appState.toggleQuickLook()
                }
                .keyboardShortcut("y", modifiers: [.command])
            }
            CommandGroup(after: .windowArrangement) {
                Button("Show Next Tab") { appState.selectAdjacentTab(offset: 1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                    .disabled(appState.tabs(on: appState.isDualPane ? appState.activePaneSide : .left).count < 2)
                Button("Show Previous Tab") { appState.selectAdjacentTab(offset: -1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                    .disabled(appState.tabs(on: appState.isDualPane ? appState.activePaneSide : .left).count < 2)
            }
            CommandGroup(replacing: .help) {
                Button("Burrow Guide") { Self.openProjectPage("blob/main/docs/GUIDE.md") }
                Button("Release Notes") { Self.openProjectPage("releases") }
                Button("Check for Updates…") { UpdateChecker.shared.checkNow() }
                Divider()
                Button("Full Disk Access…") { appState.showFullDiskAccessSheet = true }
                Divider()
                Button("Report an Issue…") { Self.openProjectPage("issues/new/choose") }
                Button("Burrow on GitHub") { Self.openProjectPage("") }
            }
        }

        // Settings… (⌘,) opens this window; other entry points set showSettingsSheet.
        Settings {
            FSearchSettingsSheetView(appState: AppState.shared)
        }
    }

    private static func openProjectPage(_ path: String) {
        guard let url = URL(string: "https://github.com/MaciejWlodarski/burrow/" + path) else { return }
        NSWorkspace.shared.open(url)
    }

    private var canUseFileCommands: Bool { FinderCommandRouting.canUseFileCommands }

    private var isEditingText: Bool { FinderCommandRouting.isEditingText }

    private func routeTextAction(_ action: Selector) -> Bool {
        FinderCommandRouting.routeTextAction(action)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?
    private var quitFailureAlert: NSAlert?
    #if BURROW_TESTING
    /// Direct-delegate integration harness: captures reply without terminating its process.
    var terminationReplyForTesting: ((Bool) -> Void)?
    #endif

    func applicationWillFinishLaunching(_ notification: Notification) {
        // "Show in Finder" from other apps when Burrow is the NSFileViewer.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleRevealEvent(_:withReply:)),
            forEventClass: AEEventClass(kAEMiscStandards), andEventID: AEEventID(kAEMakeObjectsVisible))
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        ExternalOpenRouter.open(urls)
    }

    @objc private func handleRevealEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let direct = event.paramDescriptor(forKeyword: keyDirectObject) else { return }
        var urls: [URL] = []
        if direct.numberOfItems > 0 {
            for index in 1...direct.numberOfItems {
                if let url = direct.atIndex(index)?.fileURLValue { urls.append(url) }
            }
        } else if let url = direct.fileURLValue {
            urls.append(url)
        }
        ExternalOpenRouter.open(urls)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard FinderCommandRouting.shouldRouteFileKeyEvent(event) else { return event }
            let appState = AppState.shared
            if appState.showQuickFSearchModal || appState.showNewFileSheet ||
               appState.showNewFolderSheet || appState.showCompareSheet ||
               appState.showSettingsSheet {
                return event
            }

            let tab = appState.activeTab

            // Spacebar (keyCode 49) -> Toggle Quick Look
            if event.keyCode == 49 && event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
                if !tab.selectedPaths.isEmpty {
                    appState.toggleQuickLook()
                    return nil
                }
            }

            // Right Arrow (124) / Left Arrow (123) in List View -> Expand / Collapse folder tree inline
            if tab.viewMode == .list && (event.keyCode == 124 || event.keyCode == 123) &&
               event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
                if let item = tab.primarySelectedItem, item.isDirectory {
                    let expand = (event.keyCode == 124)
                    if expand != tab.isExpanded(item.path) {
                        tab.toggleFolderExpansion(for: item)
                        return nil
                    }
                }
            }

            // Down Arrow (125) / Up Arrow (126) -> Move selection in file list
            if (event.keyCode == 125 || event.keyCode == 126) &&
               event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
                tab.moveSelection(by: event.keyCode == 125 ? 1 : -1, extending: event.modifierFlags.contains(.shift))
                return nil
            }

            // Home (115) / End (119) -> first / last item; Page Up (116) / Page Down (121) -> jump a page.
            if [115, 119, 116, 121].contains(event.keyCode) &&
               event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
                let extending = event.modifierFlags.contains(.shift)
                switch event.keyCode {
                case 115: tab.selectBoundary(last: false, extending: extending)
                case 119: tab.selectBoundary(last: true, extending: extending)
                default: tab.moveSelection(by: event.keyCode == 121 ? 15 : -15, extending: extending)
                }
                return nil
            }

            // Return (36) or keypad Enter (76) -> rename
            if (event.keyCode == 36 || event.keyCode == 76) && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
               let item = tab.primarySelectedItem {
                tab.renamingItemPath = item.path
                return nil
            }
            if event.keyCode == 53 && !tab.searchQuery.isEmpty {
                tab.clearSearch()
                return nil
            }
            if event.keyCode == 48 && event.modifierFlags.contains(.control) {
                appState.selectAdjacentTab(offset: event.modifierFlags.contains(.shift) ? -1 : 1)
                return nil
            }
            // Type-to-select: printable characters without command modifiers.
            if event.modifierFlags.intersection([.command, .option, .control, .function]).isEmpty,
               let characters = event.characters, !characters.isEmpty,
               characters.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(.punctuationCharacters).union(.symbols).contains($0) }),
               tab.typeSelect(characters) {
                return nil
            }
            return event
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        dismissQuitFailure(nil)
        #if BURROW_TESTING
        let capturedReplyForTesting = terminationReplyForTesting
        #endif
        let decision = TerminalApplicationLifecycle.shared.beginTermination { [weak self, weak sender] completed in
            #if BURROW_TESTING
            if let capture = capturedReplyForTesting {
                capture(completed)
                return
            }
            #endif
            // AppKit remains responsive while the owned workers cancel and reap.
            sender?.reply(toApplicationShouldTerminate: completed)
            if !completed { self?.showQuitFailure() }
        }
        switch decision {
        case .now: return .terminateNow
        case .later: return .terminateLater
        }
    }

    private func showQuitFailure() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Burrow can’t quit yet")
        alert.informativeText = String(localized: "Terminal commands did not confirm they had stopped within 5 seconds. Quitting was canceled. Command cancellation is still in progress; you can choose Quit again. Forcing quit does not guarantee that the processes end.")
        let button = alert.addButton(withTitle: "OK")
        button.target = self
        button.action = #selector(dismissQuitFailure(_:))
        quitFailureAlert = alert
        // A modeless alert also works when no document window remains. Never block
        // the main actor: worker completions must still release their leases.
        alert.window.center()
        alert.window.makeKeyAndOrderFront(nil)
    }

    @objc private func dismissQuitFailure(_ sender: Any?) {
        quitFailureAlert?.window.close()
        quitFailureAlert = nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.flushSessionState()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }
}
