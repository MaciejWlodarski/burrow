import Foundation
import Darwin

/// Classify structured errors only. Localized text varies by OS/language.
enum DirectoryNavigationFailure {
    static func isPermissionDenied(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        // Underlying error graphs can cycle; never follow an unbounded chain.
        for _ in 0..<8 {
            guard let value = current else { return false }
            if value.domain == NSPOSIXErrorDomain,
               value.code == Int(EACCES) || value.code == Int(EPERM) { return true }
            if value.domain == NSCocoaErrorDomain,
               value.code == CocoaError.fileReadNoPermission.rawValue { return true }
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
}
