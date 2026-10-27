import Foundation

/// The system Trash is a Finder-owned location, not a normal transfer target.
/// Identity is the exact configured path, never the editable sidebar title/icon.
enum SystemTrashNavigation {
    enum Outcome: Equatable { case navigated, openedInFinder, failedToOpenFinder }

    static func isSystemTrash(_ url: URL, systemTrashURL: URL) -> Bool {
        url.isFileURL && systemTrashURL.isFileURL
            && url.standardizedFileURL.path == systemTrashURL.standardizedFileURL.path
    }

    @discardableResult
    static func open(_ url: URL, systemTrashURL: URL,
                     openInFinder: (URL) -> Bool, navigate: (URL) -> Void) -> Outcome {
        guard isSystemTrash(url, systemTrashURL: systemTrashURL) else {
            navigate(url)
            return .navigated
        }
        return openInFinder(systemTrashURL) ? .openedInFinder : .failedToOpenFinder
    }
}
