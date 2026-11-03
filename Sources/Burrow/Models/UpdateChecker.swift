import Foundation

/// Asks GitHub for the latest release, at most once a day and only when the
/// user allows it. Only the version number is fetched; nothing about the user
/// or their files is sent.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    struct Release: Equatable, Identifiable {
        let version: String
        let pageURL: URL
        var id: String { version }
    }

    /// What a check shown to the user found.
    enum Outcome: Equatable, Identifiable {
        case available(Release)
        case upToDate(String)
        case failed
        var id: String {
            switch self {
            case .available(let release): return "available-\(release.version)"
            case .upToDate(let version): return "current-\(version)"
            case .failed: return "failed"
            }
        }
    }

    static let homebrewCommand = "brew upgrade --cask burrow"
    static let releasesPage = URL(string: "https://github.com/MaciejWlodarski/burrow/releases/latest")!
    private static let latestReleaseAPI = URL(string: "https://api.github.com/repos/MaciejWlodarski/burrow/releases/latest")!
    private static let automaticKey = "bf.updates.automaticChecks"
    private static let lastCheckKey = "bf.updates.lastCheck"

    /// A newer release found by any check; shown in the status bar.
    @Published private(set) var available: Release?
    /// A result to present in an alert.
    @Published var presented: Outcome?
    @Published private(set) var isChecking = false

    private let defaults: UserDefaults
    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? AppState.preferences
    }

    var automaticChecksEnabled: Bool {
        get { defaults.object(forKey: Self.automaticKey) as? Bool ?? true }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Self.automaticKey)
            if newValue { checkIfDue() }
        }
    }

    /// Quiet check: finding nothing new shows nothing.
    func checkIfDue() {
        #if !BURROW_TESTING
        guard automaticChecksEnabled else { return }
        let last = defaults.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 24 * 60 * 60 else { return }
        Task { await check(showingResult: false) }
        #endif
    }

    /// Help › Check for Updates: always reports the outcome.
    func checkNow() {
        Task { await check(showingResult: true) }
    }

    private func check(showingResult: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        var request = URLRequest(url: Self.latestReleaseAPI, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Burrow/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let latest = Self.parseLatest(data) else {
            if showingResult { presented = .failed }
            return
        }
        defaults.set(Date(), forKey: Self.lastCheckKey)
        if Self.isVersion(latest.version, newerThan: currentVersion) {
            available = latest
            if showingResult { presented = .available(latest) }
        } else {
            available = nil
            if showingResult { presented = .upToDate(currentVersion) }
        }
    }

    nonisolated static func parseLatest(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["draft"] as? Bool != true, json["prerelease"] as? Bool != true,
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
              page.host == "github.com" else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard !version.isEmpty, version.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        return Release(version: version, pageURL: page)
    }

    /// Numeric comparison of dotted versions: 0.1.10 is newer than 0.1.9.
    nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            let trimmed = version.hasPrefix("v") ? String(version.dropFirst()) : version
            return trimmed.split(separator: ".").map { Int($0) ?? 0 }
        }
        let lhs = parts(candidate), rhs = parts(current)
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }
}
