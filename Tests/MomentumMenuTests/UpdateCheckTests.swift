import XCTest
@testable import M4Core

/// Check for Updates: one fixed request, only `tag_name` read, and every
/// failure reported as `.failed` with nothing retried.
final class UpdateCheckTests: XCTestCase {

    private static func reply(_ status: Int, _ body: String) -> UpdateCheck.Fetch {
        { request in
            (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    private static func release(_ tag: String) -> String { #"{"tag_name": "\#(tag)", "name": "ignored", "draft": false}"# }

    private struct RunRow {
        let name: String
        var app = "2.4.0"
        var status = 200
        var body: String?
        var throwing = false
        let outcome: UpdateCheck.Outcome
    }

    private static let runRows: [RunRow] = [
        RunRow(name: "newer patch", body: release("v2.4.1"), outcome: .available(version: "2.4.1")),
        RunRow(name: "newer minor", body: release("v2.5.0"), outcome: .available(version: "2.5.0")),
        RunRow(name: "newer major", body: release("v3.0.0"), outcome: .available(version: "3.0.0")),
        RunRow(name: "two-digit minor beats one digit", app: "2.9.0", body: release("v2.10.0"),
               outcome: .available(version: "2.10.0")),
        RunRow(name: "tag without the v", body: release("2.5.0"), outcome: .available(version: "2.5.0")),
        RunRow(name: "same version", body: release("v2.4.0"), outcome: .upToDate),
        RunRow(name: "older release", body: release("v2.3.9"), outcome: .upToDate),
        RunRow(name: "app ahead of GitHub", app: "2.10.0", body: release("v2.9.9"), outcome: .upToDate),
        RunRow(name: "pre-release suffix", body: release("v2.5.0-beta"), outcome: .failed),
        RunRow(name: "two parts", body: release("v2.5"), outcome: .failed),
        RunRow(name: "four parts", body: release("v2.5.0.1"), outcome: .failed),
        RunRow(name: "signed part", body: release("v2.+5.0"), outcome: .failed),
        RunRow(name: "empty tag", body: release(""), outcome: .failed),
        RunRow(name: "no tag_name", body: #"{"name": "v2.5.0"}"#, outcome: .failed),
        RunRow(name: "not JSON", body: "<html>rate limited</html>", outcome: .failed),
        RunRow(name: "empty body", body: "", outcome: .failed),
        RunRow(name: "rate limited", status: 403, body: release("v2.5.0"), outcome: .failed),
        RunRow(name: "not found", status: 404, body: release("v2.5.0"), outcome: .failed),
        RunRow(name: "redirect refused", status: 301, body: release("v2.5.0"), outcome: .failed),
        RunRow(name: "offline", throwing: true, outcome: .failed),
        RunRow(name: "app version unreadable", app: "unknown", body: release("v2.5.0"), outcome: .failed),
        RunRow(name: "leading zero", body: release("v2.05.0"), outcome: .failed),
        RunRow(name: "zero parts are fine", app: "0.0.9", body: release("v0.1.0"), outcome: .available(version: "0.1.0")),
        RunRow(name: "too big for Int", body: release("v99999999999999999999.0.0"), outcome: .failed),
        RunRow(name: "capital V", body: release("V2.5.0"), outcome: .failed),
        RunRow(name: "spaces", body: release(" v2.5.0"), outcome: .failed),
        RunRow(name: "null tag", body: #"{"tag_name": null}"#, outcome: .failed),
        RunRow(name: "number tag", body: #"{"tag_name": 250}"#, outcome: .failed),
        RunRow(name: "no content", status: 204, body: "", outcome: .failed),
        RunRow(name: "server error", status: 500, body: release("v2.5.0"), outcome: .failed),
    ]

    func testTheOutcomeFollowsTheTag() async {
        for row in Self.runRows {
            let fetch: UpdateCheck.Fetch = row.throwing
                ? { @Sendable _ in throw URLError(.notConnectedToInternet) }
                : Self.reply(row.status, row.body ?? "")
            let outcome = await UpdateCheck.run(appVersion: row.app, fetch: fetch)
            XCTAssertEqual(outcome, row.outcome, row.name)
        }
    }

    /// One request per press, and a failure is not retried.
    func testEachCheckSendsExactlyOneRequest() async {
        for row in Self.runRows where row.app == "2.4.0" {
            let count = Counter()
            _ = await UpdateCheck.run(appVersion: row.app) { request in
                await count.add()
                if row.throwing { throw URLError(.timedOut) }
                return try await Self.reply(row.status, row.body ?? "")(request)
            }
            let sent = await count.value
            XCTAssertEqual(sent, 1, row.name)
        }
    }

    private actor Counter {
        var value = 0
        func add() { value += 1 }
    }

    func testTheRequestIsTheOneFixedURL() {
        let request = UpdateCheck.request(appVersion: "2.4.0")
        XCTAssertEqual(request.url?.absoluteString,
                       "https://api.github.com/repos/agrmohit/momentum-menu/releases/latest")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "MomentumMenu/2.4.0")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
        XCTAssertEqual(request.timeoutInterval, 10)
        XCTAssertNil(request.httpBody)
    }

    func testTheLiveSessionCapsTheWholeCheck() {
        XCTAssertEqual(UpdateCheck.liveConfiguration().timeoutIntervalForResource, 15)
    }

    /// The live fetch, served by `StubGitHub` instead of the network: GitHub
    /// answers with a redirect to a host that would report a newer release.
    /// Following it would make a second request and say 9.9.9 is available.
    func testTheLiveFetchSendsOneRequestAndRefusesRedirects() async {
        let configuration = UpdateCheck.liveConfiguration()
        configuration.protocolClasses = [StubGitHub.self]
        StubGitHub.seen.removeAll()
        let outcome = await UpdateCheck.run(appVersion: "2.4.0", fetch: UpdateCheck.fetch(using: configuration))
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(StubGitHub.seen, [UpdateCheck.latestRelease.absoluteString])
    }

    /// Redirects the fixed URL elsewhere; anywhere else answers a 9.9.9 release.
    private final class StubGitHub: URLProtocol {
        nonisolated(unsafe) static var seen: [String] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        override func startLoading() {
            let url = request.url!
            Self.seen.append(url.absoluteString)
            if url == UpdateCheck.latestRelease {
                let elsewhere = URL(string: "https://example.com/latest")!
                let moved = HTTPURLResponse(url: url, statusCode: 301, httpVersion: nil,
                                            headerFields: ["Location": elsewhere.absoluteString])!
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: elsewhere), redirectResponse: moved)
                client?.urlProtocol(self, didReceive: moved, cacheStoragePolicy: .notAllowed)
            } else {
                let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                client?.urlProtocol(self, didReceive: ok, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(UpdateCheckTests.release("v9.9.9").utf8))
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    func testTheReleasePageIsBuiltFromTheVersion() {
        let rows: [(String, String)] = [
            ("2.5.0", "https://github.com/agrmohit/momentum-menu/releases/tag/v2.5.0"),
            ("10.0.12", "https://github.com/agrmohit/momentum-menu/releases/tag/v10.0.12"),
        ]
        for (version, page) in rows {
            XCTAssertEqual(UpdateCheck.releasePage(for: version).absoluteString, page, version)
        }
    }
}
