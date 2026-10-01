import PennantCore
@testable import PennantHostKit
import Foundation
import XCTest

final class CloudflareAccessTests: XCTestCase {
    let edge = HostConfig.API.Edge(hostname: "pennant.example.com", teamDomain: "acme.cloudflareaccess.com", audience: "aud-123", allowedEmailDomains: ["example.com"])

    private func claims(_ overrides: [String: Any] = [:]) -> [String: Any] {
        var c: [String: Any] = ["iss": "https://acme.cloudflareaccess.com", "aud": ["aud-123"], "email": "Maya@Example.com",
                                "exp": Date().addingTimeInterval(3600).timeIntervalSince1970, "nbf": Date().addingTimeInterval(-60).timeIntervalSince1970, "type": "app"]
        for (k, v) in overrides { c[k] = v }
        return c
    }

    func testOnlyThisApplicationsTokensForAllowedPeopleGetIn() async throws {
        let signer = try TeamsTests.Signer()
        let jwks = signer.jwks
        let asked = LockedURLs()
        let verifier = CloudflareAccessVerifier { url in asked.add(url); return jwks }

        let email = try await verifier.verify(try signer.token(claims()), edge: edge)
        XCTAssertEqual(email, "maya@example.com", "emails compare lowercased")
        XCTAssertEqual(asked.all.first?.absoluteString, "https://acme.cloudflareaccess.com/cdn-cgi/access/certs")

        let refused: [(String, [String: Any])] = [
            ("another application", ["aud": ["someone-else"]]),
            ("another team", ["iss": "https://evil.cloudflareaccess.com"]),
            ("expired", ["exp": Date().addingTimeInterval(-3600).timeIntervalSince1970]),
            ("another domain", ["email": "mallory@elsewhere.com"]),
            ("no email", ["email": ""]),
        ]
        for (why, override) in refused {
            do { _ = try await verifier.verify(try signer.token(claims(override)), edge: edge); XCTFail("accepted: \(why)") } catch {}
        }
        do { _ = try await verifier.verify(nil, edge: edge); XCTFail("no token accepted") } catch {}
        let other = try TeamsTests.Signer()
        do { _ = try await verifier.verify(try other.token(claims()), edge: edge); XCTFail("a token signed by someone else was accepted") } catch {}
    }

    func testTheHandoffOnlyReturnsToThePennantApp() async throws {
        let paths = HostPaths.temporary()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try paths.ensureDirectories()
        var config = HostConfig()
        config.api = .init(port: 0, listenOnNetwork: false, advertiseBonjour: false, tlsPort: 0, edge: edge)
        let host = try HostService(paths: paths, config: config)
        // No token: refused with a page, not a redirect.
        let bare = await host.edgeRequest(WebhookServer.Request(method: "GET", path: "/access/handoff", headers: [:], body: Data(), query: "return=pennant%3A%2F%2Faccess"))
        XCTAssertEqual(bare.status, 403)
        let elsewhere = await host.edgeRequest(WebhookServer.Request(method: "GET", path: "/nope", headers: [:], body: Data()))
        XCTAssertEqual(elsewhere.status, 404)
    }
}

final class LockedURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func add(_ u: URL) { lock.withLock { urls.append(u) } }
    var all: [URL] { lock.withLock { urls } }
}
