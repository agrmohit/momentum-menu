import Foundation

/// Checks GitHub for a newer release.
///
/// This reads the repository's latest *release*, not its commits, so it only
/// reports something once a release is actually published. Until then, and
/// while the repository is private, GitHub answers 404 — which is reported as
/// such rather than swallowed, because a silent update check is worse than
/// none at all.
@MainActor
final class UpdateChecker: ObservableObject {
    static let repository = "andr3-santos/momentum-menu"

    enum Status: Equatable {
        case idle
        case checking
        case upToDate(latest: String)
        case updateAvailable(latest: String)
        case unavailable(reason: String)

        var message: String {
            switch self {
            case .idle: return "Not checked yet."
            case .checking: return "Checking…"
            case .upToDate(let latest): return "Up to date (latest release \(latest))."
            case .updateAvailable(let latest): return "Version \(latest) is available."
            case .unavailable(let reason): return reason
            }
        }
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var lastChecked: Date?

    private struct Release: Decodable {
        let tagName: String
        enum CodingKeys: String, CodingKey { case tagName = "tag_name" }
    }

    func check() async {
        guard status != .checking else { return }
        status = .checking

        guard let url = URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest") else {
            status = .unavailable(reason: "Bad update URL.")
            return
        }

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            lastChecked = Date()

            switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200:
                let release = try JSONDecoder().decode(Release.self, from: data)
                let latest = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
                status = latest == Preferences.shortVersion
                    ? .upToDate(latest: latest)
                    : .updateAvailable(latest: latest)
            case 404:
                status = .unavailable(reason: "No published releases, or the repository is private.")
            case 403, 429:
                status = .unavailable(reason: "GitHub rate limit reached. Try again later.")
            case let code:
                status = .unavailable(reason: "GitHub returned HTTP \(code).")
            }
        } catch {
            lastChecked = Date()
            status = .unavailable(reason: error.localizedDescription)
        }
    }
}
