import Foundation

/// The update check must never offer an older, draft or malformed release.
enum UpdateCheckerRegressionTests {
    static func runAll() throws {
        try expect(UpdateChecker.isVersion("0.1.2", newerThan: "0.1.1"))
        try expect(UpdateChecker.isVersion("0.1.10", newerThan: "0.1.9"))
        try expect(UpdateChecker.isVersion("v1.0", newerThan: "0.9.9"))
        try expect(!UpdateChecker.isVersion("0.1.1", newerThan: "0.1.1"))
        try expect(!UpdateChecker.isVersion("0.1", newerThan: "0.1.0"))
        try expect(!UpdateChecker.isVersion("0.1.0", newerThan: "0.1.1"))

        func release(_ fields: [String: Any]) -> UpdateChecker.Release? {
            UpdateChecker.parseLatest(try! JSONSerialization.data(withJSONObject: fields))
        }
        let page = "https://github.com/MaciejWlodarski/burrow/releases/tag/v0.1.2"
        try expect(release(["tag_name": "v0.1.2", "html_url": page]) == .init(version: "0.1.2", pageURL: URL(string: page)!))
        try expect(release(["tag_name": "v0.1.2", "html_url": page, "draft": true]) == nil)
        try expect(release(["tag_name": "v0.1.2", "html_url": page, "prerelease": true]) == nil)
        try expect(release(["tag_name": "v0.1.2-beta", "html_url": page]) == nil)
        // Only GitHub pages are opened from the alert.
        try expect(release(["tag_name": "v0.1.2", "html_url": "https://example.com/burrow"]) == nil)
        try expect(UpdateChecker.parseLatest(Data("not json".utf8)) == nil)
        print("PASS update check compares versions and accepts only published GitHub releases")
    }
}
