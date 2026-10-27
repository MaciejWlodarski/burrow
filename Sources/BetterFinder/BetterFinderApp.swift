import SwiftUI
import AppKit

@main
struct BetterFinderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var fileOps = FileOperationsManager.shared

    var body: some Scene {
        WindowGroup("BetterFinder", id: "main") {
            MainWindowView()
                // Folders opened from outside reuse this window (AppDelegate adds a tab)
                // instead of SwiftUI spawning a new window per event.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1200, height: 760)
        .commands {
            // App Settings (Cmd+,)
            CommandGroup(replacing: .appSettings) {
                Button("Ustawienia…") {
                    appState.showSettingsSheet = true
                }
                .keyboardShortcut(",", modifiers: [.command])
            }

            // File Menu Additions
            CommandGroup(replacing: .newItem) {
                Button("Nowa karta") {
                    appState.addNewTab()
                }
                .keyboardShortcut("t", modifiers: [.command])

                Button("Otwórz ponownie zamkniętą kartę") { appState.reopenClosedTab() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(appState.recentlyClosedTabs.isEmpty)

                Button("Nowy folder…") {
                    appState.showNewFolderSheet = true
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button("Nowy plik…") {
                    appState.showNewFileSheet = true
                }
                .keyboardShortcut("n", modifiers: [.command, .option])

                Divider()

                Button("Zamknij kartę") {
                    if appState.isDualPane && appState.activePaneSide == .right {
                        appState.toggleDualPane()
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

                Button("Wytnij pliki") {
                    if !routeTextAction(#selector(NSText.cut(_:))), canUseFileCommands { fileOps.cutItems(appState.activeTab.selectedItems) }
                }
                .keyboardShortcut("x", modifiers: [.command])

                Button("Kopiuj pliki") {
                    if !routeTextAction(#selector(NSText.copy(_:))), canUseFileCommands { fileOps.copyItems(appState.activeTab.selectedItems) }
                }
                .keyboardShortcut("c", modifiers: [.command])

                Button("Wklej / Przenieś tutaj") {
                    if !routeTextAction(#selector(NSText.paste(_:))), canUseFileCommands {
                        fileOps.paste(into: appState.activeTab.currentURL)
                    }
                }
                .keyboardShortcut("v", modifiers: [.command])

                Button("Przenieś tutaj") {
                    if canUseFileCommands { fileOps.paste(into: appState.activeTab.currentURL, forceMove: true) }
                }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(!canUseFileCommands)

                Button("Zaznacz wszystko") {
                    if !routeTextAction(#selector(NSText.selectAll(_:))), canUseFileCommands { appState.activeTab.selectAll() }
                }
                .keyboardShortcut("a", modifiers: [.command])

                Divider()

                Button("Kopiuj pełną ścieżkę") {
                    let sel = appState.activeTab.selectedItems
                    if sel.isEmpty {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(appState.activeTab.currentURL.path, forType: .string)
                    } else {
                        fileOps.copyPaths(sel)
                    }
                }
                .keyboardShortcut("c", modifiers: [.command, .option])

                Button("Duplikuj zaznaczone") {
                    guard canUseFileCommands else { return }
                    // Duplication runs detached; reload the originating pane once copies exist.
                    let pane = appState.activeTab
                    fileOps.duplicateItems(pane.selectedItems) { [weak pane] _ in pane?.reloadDirectory() }
                }
                .keyboardShortcut("d", modifiers: [.command])
                .disabled(!canUseFileCommands || appState.activeTab.selectedItems.isEmpty || fileOps.isBusy)

                Button("Przenieś do Kosza") {
                    if routeTextAction(#selector(NSResponder.deleteToBeginningOfLine(_:))) { return }
                    guard canUseFileCommands else { return }
                    fileOps.moveToTrash(appState.activeTab.selectedItems)
                    appState.activeTab.reloadDirectory()
                }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(!isEditingText && (!canUseFileCommands || appState.activeTab.selectedItems.isEmpty || fileOps.isBusy))

                // emptySystemTrash asks for confirmation before deleting anything.
                Button("Opróżnij Kosz…") {
                    guard canUseFileCommands else { return }
                    fileOps.emptySystemTrash { appState.activeTab.reloadDirectory() }
                }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
                .disabled(!canUseFileCommands || fileOps.isBusy)
            }

            // fsearch & Navigation Menu
            CommandMenu("Przejdź") {
                Button("Szukaj plików i folderów") {
                    appState.focusSearchFieldTrigger += 1
                }
                .keyboardShortcut("f", modifiers: [.command])

                Button("Szybkie wyszukiwanie…") {
                    appState.showQuickFSearchModal.toggle()
                }
                .keyboardShortcut("p", modifiers: [.command])

                Divider()

                Button("Edytuj pasek ścieżki") {
                    appState.activeTab.requestPathEditing()
                }
                .keyboardShortcut("l", modifiers: [.command])

                Button("Idź do folderu…") { appState.activeTab.requestPathEditing() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Button("Folder domowy") {
                    appState.activeTab.navigate(to: FileManager.default.homeDirectoryForCurrentUser)
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Odśwież") { appState.activeTab.refresh() }
                    .keyboardShortcut("r", modifiers: [.command])

                Button("Wstecz") {
                    appState.activeTab.goBack()
                }
                .keyboardShortcut("[", modifiers: [.command])
                .disabled(appState.activeTab.historyBack.isEmpty)

                Button("Dalej") {
                    appState.activeTab.goForward()
                }
                .keyboardShortcut("]", modifiers: [.command])
                .disabled(appState.activeTab.historyForward.isEmpty)

                Button("Folder nadrzędny") {
                    appState.activeTab.goUp()
                }
                .keyboardShortcut(.upArrow, modifiers: [.command])

                Button("Otwórz zaznaczony element") {
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

                Button("Przebuduj indeks plików") {
                    FSearchIndex.shared.startIndexing()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }

            // View Menu Additions
            CommandGroup(after: .toolbar) {
                Button(appState.showSidebar ? "Ukryj pasek boczny" : "Pokaż pasek boczny") { appState.showSidebar.toggle() }
                    .keyboardShortcut("s", modifiers: [.command, .control])
                Divider()
                Button("Widok listy") {
                    appState.activeTab.viewMode = .list
                }
                .keyboardShortcut("1", modifiers: [.command])

                Button("Widok ikon") {
                    appState.activeTab.viewMode = .icons
                }
                .keyboardShortcut("2", modifiers: [.command])

                Button("Widok kolumn") {
                    appState.activeTab.viewMode = .columns
                }
                .keyboardShortcut("3", modifiers: [.command])

                Button("Mapa dysku") {
                    appState.activeTab.viewMode = .wiztree
                }
                .keyboardShortcut("4", modifiers: [.command])

                Divider()

                Button("Przełącz widok dwupanelowy") {
                    appState.toggleDualPane()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Button("Pokaż/ukryj terminal") {
                    appState.showTerminalDrawer.toggle()
                }
                .keyboardShortcut("`", modifiers: [.control])

                Button("Pokaż/ukryj pliki ukryte") {
                    appState.activeTab.showHiddenFiles.toggle()
                    appState.activeTab.refresh()
                }
                .keyboardShortcut(".", modifiers: [.command, .shift])

                Button("Pokaż/ukryj inspektor") {
                    appState.showInspector.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command])

                Button("Szybki podgląd (Quick Look)") {
                    appState.toggleQuickLook()
                }
                .keyboardShortcut("y", modifiers: [.command])
            }
            CommandGroup(after: .windowArrangement) {
                Button("Następna karta") { appState.selectAdjacentTab(offset: 1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                    .disabled(appState.tabs.count < 2)
                Button("Poprzednia karta") { appState.selectAdjacentTab(offset: -1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                    .disabled(appState.tabs.count < 2)
            }
        }
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
    #if BETTERFINDER_TESTING
    /// Direct-delegate integration harness: captures reply without terminating its process.
    var terminationReplyForTesting: ((Bool) -> Void)?
    #endif

    func applicationWillFinishLaunching(_ notification: Notification) {
        // "Show in Finder" from other apps when BetterFinder is the NSFileViewer.
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
        #if BETTERFINDER_TESTING
        let capturedReplyForTesting = terminationReplyForTesting
        #endif
        let decision = TerminalApplicationLifecycle.shared.beginTermination { [weak self, weak sender] completed in
            #if BETTERFINDER_TESTING
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
        alert.messageText = "Nie można jeszcze zamknąć aplikacji"
        alert.informativeText = "Nie potwierdzono zakończenia wszystkich poleceń terminala w ciągu 5 sekund. Anulowano zamykanie aplikacji. Przerywanie poleceń trwa nadal; możesz ponownie wybrać Zakończ. Wymuszenie zamknięcia nie gwarantuje zakończenia procesów."
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
