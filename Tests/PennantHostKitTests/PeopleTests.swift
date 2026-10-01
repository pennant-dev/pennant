import PennantCore
@testable import PennantHostKit
import Foundation
import Network
import XCTest

final class PeopleTests: XCTestCase {
    var paths: HostPaths!

    override func setUp() async throws {
        paths = HostPaths.temporary()
        try paths.ensureDirectories()
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: paths.root) }

    private func service() -> PeopleService {
        PeopleService(paths: paths)
    }

    private func claims(_ provider: SignInProvider, _ subject: String, _ email: String, tenant: String? = nil) -> PeopleService.Claims {
        PeopleService.Claims(identity: LinkedIdentity(provider: provider, subject: subject, email: email, tenantID: tenant), name: "Dana Kim")
    }

    func testStrangersAreTurnedAwayAndInvitesLetOneIn() async throws {
        let people = service()
        do {
            _ = try await people.admit(claims(.google, "g1", "dana@example.com"))
            XCTFail("a stranger got in")
        } catch PeopleService.SignInError.notInvited(let email) {
            XCTAssertEqual(email, "dana@example.com")
        }
        try await people.invite("Dana@Example.com ")
        let dana = try await people.admit(claims(.google, "g1", "dana@example.com"))
        XCTAssertEqual(dana.role, .member)
        let directory = await people.snapshot()
        XCTAssertTrue(directory.invites.isEmpty, "the invite is used up")
        // Next time the same Google account is recognised without an invite, and GitHub with the same email links.
        let again = try await people.admit(claims(.google, "g1", "dana@example.com"))
        XCTAssertEqual(again.id, dana.id)
        let viaGitHub = try await people.admit(claims(.github, "42", "DANA@example.com"))
        XCTAssertEqual(viaGitHub.id, dana.id)
        let linked = await people.person(dana.id)
        XCTAssertEqual(linked?.identities.map(\.provider), [.google, .github])
    }

    func testAnAllowedMicrosoftOrganisationJoinsWithoutAnInvite() async throws {
        let people = service()
        try await people.update(SignInSettings(microsoft: .init(clientID: "app"), allowedTenants: ["tenant-a"]))
        let inOrg = try await people.admit(claims(.microsoft, "oid-1", "sam@northwind.example", tenant: "tenant-a"))
        XCTAssertEqual(inOrg.email, "sam@northwind.example")
        do {
            _ = try await people.admit(claims(.microsoft, "oid-2", "eve@other.com", tenant: "tenant-b"))
            XCTFail("another organisation got in")
        } catch PeopleService.SignInError.notInvited {}
    }

    func testARemovedPersonStaysOut() async throws {
        let people = service()
        try await people.invite("dana@example.com")
        let dana = try await people.admit(claims(.google, "g1", "dana@example.com"))
        try await people.remove(dana.id)
        do {
            _ = try await people.admit(claims(.google, "g1", "dana@example.com"))
            XCTFail("a removed person got back in")
        } catch PeopleService.SignInError.notInvited {}
    }

    func testSignInOnlyOverEncryptedConnections() async throws {
        let people = service()
        try await people.update(SignInSettings(microsoft: .init(clientID: "app")))
        do {
            _ = try await people.begin(.microsoft, redirectURI: "pennant://auth", trusted: false)
            XCTFail("sign-in started from outside the tailnet")
        } catch PeopleService.SignInError.untrustedNetwork {}
        let start = try await people.begin(.microsoft, redirectURI: "pennant://auth", trusted: true)
        guard case .browser(let url, let scheme) = start.step else { return XCTFail("expected a browser step") }
        XCTAssertEqual(scheme, "pennant")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "code_challenge_method" }?.value, "S256")
        XCTAssertEqual(query.first { $0.name == "state" }?.value, start.state)
        XCTAssertEqual(query.first { $0.name == "scope" }?.value, "openid profile email", "signing in asks only who you are")
    }

    func testPasswordsSignInAndGuessingIsSlowedDown() async throws {
        let people = service()
        var owner = try await people.ownerAccount(defaultName: "Maya")
        XCTAssertEqual(owner.role, .owner)
        XCTAssertFalse(owner.canSignIn)
        owner = try await people.updateAccount(owner.id, name: "Maya O", email: "Maya@Example.com")
        XCTAssertEqual(owner.email, "maya@example.com")
        do { _ = try await people.setPassword(owner.id, new: "short", current: nil); XCTFail("weak password") } catch PeopleService.SignInError.weakPassword {}
        owner = try await people.setPassword(owner.id, new: "correct horse battery", current: nil)
        XCTAssertTrue(owner.hasPassword && owner.canSignIn)

        // Never in the clear; the right password works whatever the email's case.
        do { _ = try await people.signIn(email: "maya@example.com", password: "correct horse battery", trusted: false); XCTFail("unencrypted") } catch PeopleService.SignInError.untrustedNetwork {}
        let signedIn = try await people.signIn(email: "MAYA@example.com ", password: "correct horse battery", trusted: true)
        XCTAssertEqual(signedIn.id, owner.id)

        // Changing it elsewhere needs the current one.
        do { _ = try await people.setPassword(owner.id, new: "another good password", current: "nope"); XCTFail("changed without the current password") } catch PeopleService.SignInError.wrongPassword {}

        // Wrong guesses: five free, then locked out (even the right password waits).
        for _ in 0..<5 {
            do { _ = try await people.signIn(email: "maya@example.com", password: "guess", trusted: true); XCTFail("guess worked") } catch PeopleService.SignInError.wrongPassword {}
        }
        do { _ = try await people.signIn(email: "maya@example.com", password: "correct horse battery", trusted: true); XCTFail("not locked") } catch PeopleService.SignInError.lockedOut {}

        // Unknown emails fail the same way; the hash isn't stored where clients can see it.
        do { _ = try await people.signIn(email: "nobody@example.com", password: "x", trusted: true); XCTFail("stranger") } catch PeopleService.SignInError.wrongPassword {}
        let visible = try String(contentsOf: paths.root.appendingPathComponent("people.json"), encoding: .utf8)
        XCTAssertFalse(visible.contains("salt"), "hashes stay out of people.json")
    }

    func testInviteCodesJoinOnceWithAPassword() async throws {
        let people = service()
        try await people.invite("sam@example.com")
        let invites0 = await people.snapshot().invites
        let invite = try XCTUnwrap(invites0.first)
        let code = try XCTUnwrap(invite.displayCode)
        XCTAssertEqual(code.count, 9, "ABCD-EFGH")
        do { _ = try await people.redeem(code: "WRONG123", name: "Sam", password: "a long enough password", trusted: true); XCTFail("wrong code") } catch PeopleService.SignInError.badInviteCode {}
        do { _ = try await people.redeem(code: code, name: "Sam", password: "a long enough password", trusted: false); XCTFail("unencrypted") } catch PeopleService.SignInError.untrustedNetwork {}

        // Typed loosely (lowercase, no dash) it still works, once.
        let sam = try await people.redeem(code: code.lowercased().replacingOccurrences(of: "-", with: ""), name: " Sam Lee ", password: "a long enough password", trusted: true)
        XCTAssertEqual(sam.name, "Sam Lee")
        XCTAssertEqual(sam.email, "sam@example.com")
        XCTAssertEqual(sam.role, .member)
        let invites = await people.snapshot().invites
        XCTAssertTrue(invites.isEmpty)
        do { _ = try await people.redeem(code: code, name: "Sam", password: "a long enough password", trusted: true); XCTFail("used twice") } catch PeopleService.SignInError.badInviteCode {}
        let again = try await people.signIn(email: "sam@example.com", password: "a long enough password", trusted: true)
        XCTAssertEqual(again.id, sam.id)

        // Inviting someone who already has an account is refused; the invite for a new email can be re-issued.
        do { try await people.invite("sam@example.com"); XCTFail("invited an existing account") } catch {}
        try await people.invite("kim@example.com")
        let first = await people.snapshot().invites.first?.code
        try await people.invite("kim@example.com")
        let second = await people.snapshot().invites
        XCTAssertEqual(second.count, 1)
        XCTAssertNotEqual(second.first?.code, first, "a fresh code")
    }

    func testTailscaleAddressesAreRecognised() {
        XCTAssertTrue(PeopleService.isTailscale(.hostPort(host: .ipv4(IPv4Address("100.101.12.7")!), port: 7331)))
        XCTAssertFalse(PeopleService.isTailscale(.hostPort(host: .ipv4(IPv4Address("192.168.1.20")!), port: 7331)))
        XCTAssertFalse(PeopleService.isTailscale(.hostPort(host: .ipv4(IPv4Address("100.128.0.1")!), port: 7331)))
        XCTAssertTrue(PeopleService.isTailscale(.hostPort(host: .ipv6(IPv6Address("fd7a:115c:a1e0::1")!), port: 7331)))
    }

    func testMicrosoftClaimsCheckTheAudienceAndReadTheOrganisation() throws {
        func jwt(_ claims: [String: Any]) -> String {
            let body = try! JSONSerialization.data(withJSONObject: claims)
            return "e30." + body.base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_") + ".sig"
        }
        let good = jwt(["aud": "app", "oid": "o1", "tid": "t1", "preferred_username": "sam@northwind.example", "name": "Sam", "exp": Date().timeIntervalSince1970 + 600])
        let c = try PeopleService.microsoftClaims(["id_token": good], clientID: "app")
        XCTAssertEqual(c.identity.tenantID, "t1")
        XCTAssertEqual(c.identity.email, "sam@northwind.example")
        XCTAssertThrowsError(try PeopleService.microsoftClaims(["id_token": good], clientID: "other-app"))
    }

    func testGoogleRedirectIsTheReversedClientID() {
        XCTAssertEqual(PeopleService.googleRedirect("123-abc.apps.googleusercontent.com"), "com.googleusercontent.apps.123-abc:/oauth2redirect")
    }
}

extension PeopleTests {
    /// The server talks to the host through `any HostAPIDelegate`; the host's sign-in must be what it reaches.
    func testTheServerReachesTheHostsSignInThroughTheProtocol() async throws {
        var config = HostConfig()
        config.workingDirectory = paths.root.path
        config.desktop.pauseOnHumanInput = false
        try JSONCodec.encode(PeopleDirectory(signIn: SignInSettings(microsoft: .init(clientID: "app")))).write(to: paths.root.appendingPathComponent("people.json"))
        let service = try HostService(paths: paths, config: config, desktop: FakeDesktop(), humanInput: NullHumanInput(), provider: ScriptedProvider([]))
        let delegate: any HostAPIDelegate = service
        let options = await delegate.signInOptions()
        XCTAssertEqual(options, [.microsoft])
    }
}
