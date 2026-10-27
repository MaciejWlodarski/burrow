import AppKit

struct CommandColdStartRegressionTests {
    /// Must be first in the process, before any test initializes NSApplication.
    /// Exercise the exact production lookup, not an injected nil stand-in.
    @MainActor func runBeforeApplicationInitialization() throws {
        try expect(NSApp == nil)
        try expect(!FinderCommandRouting.isEditingText)
        try expect(!FinderCommandRouting.canUseFileCommands)
        try expect(!FinderCommandRouting.routeTextAction(#selector(NSText.copy(_:))))
        try expect(!FinderCommandRouting.routeTextAction(#selector(NSText.paste(_:))))
        try expect(NSApp == nil)
        print("PASS production command predicates/routing are safe before NSApplication initialization and do not initialize it")
    }
}
