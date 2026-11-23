import Foundation

/// Check for Updates: asks GitHub for the latest release's tag and compares
/// it with the running version. The app's only network call. It runs when
/// the user presses the button, never on its own, and is never retried.
public enum UpdateCheck {
    public enum Outcome: Equatable {
        case upToDate
        /// `version` is the newer release, e.g. "2.5.0".
        case available(version: String)
        /// Offline, timed out, rate limited, redirected or an unreadable reply.
        case failed
    }

    /// Sends one request and returns the reply. Injected so tests need no network.
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// The one URL the app ever requests. GitHub skips drafts and pre-releases here.
    static let latestRelease = URL(string: "https://api.github.com/repos/agrmohit/momentum-menu/releases/latest")!

    /// `appVersion`: the running app's "major.minor.patch".
    public static func run(appVersion: String, fetch: Fetch = fetchOnce) async -> Outcome {
        guard let current = version(appVersion),
              let (data, response) = try? await fetch(request(appVersion: appVersion)),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let latest = latestVersion(in: data) else { return .failed }
        return current.lexicographicallyPrecedes(latest)
            ? .available(version: latest.map(String.init).joined(separator: "."))
            : .upToDate
    }

    /// The release page for a version `run` reported. Built from the parsed
    /// numbers, so nothing GitHub sent ends up in the URL.
    public static func releasePage(for version: String) -> URL {
        URL(string: "https://github.com/agrmohit/momentum-menu/releases/tag/v\(version)")!
    }

    /// GitHub rejects a request without a User-Agent. It carries the app's
    /// name and version only. No cookies and no cache.
    static func request(appVersion: String) -> URLRequest {
        var request = URLRequest(url: latestRelease, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                 timeoutInterval: 10)
        request.httpShouldHandleCookies = false
        request.setValue("MomentumMenu/\(appVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        return request
    }

    /// Only `tag_name` is read; the rest of the reply is ignored.
    static func latestVersion(in data: Data) -> [Int]? {
        struct Release: Decodable { let tag_name: String }
        guard let release = try? JSONDecoder().decode(Release.self, from: data) else { return nil }
        return version(String(release.tag_name.trimmingPrefix("v")))
    }

    /// "2.4.0" as [2, 4, 0]. Exactly three plain numbers without leading
    /// zeros, or nil: "2.05.0" would build a release page that does not exist.
    static func version(_ text: String) -> [Int]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        // Int alone would also take "+1" and "-1".
        let numbers = parts.compactMap { part -> Int? in
            guard part.allSatisfy({ ("0"..."9").contains($0) }), part == "0" || !part.hasPrefix("0") else { return nil }
            return Int(part)
        }
        return parts.count == 3 && numbers.count == 3 ? numbers : nil
    }

    /// The fetch the app uses: the network, with the rules below.
    public static let fetchOnce = fetch(using: liveConfiguration())

    /// Ephemeral, so nothing is stored. The request's 10 s is an idle limit;
    /// this caps the whole check, so a trickling reply cannot hang it.
    static func liveConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 15
        return configuration
    }

    /// A fresh session per check that refuses redirects, so the request never
    /// leaves the one URL: a redirect comes back as a 3xx and fails the check.
    static func fetch(using configuration: URLSessionConfiguration) -> Fetch {
        { request in
            let session = URLSession(configuration: configuration)
            defer { session.finishTasksAndInvalidate() }
            return try await session.data(for: request, delegate: RefuseRedirects())
        }
    }

    final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }
}
