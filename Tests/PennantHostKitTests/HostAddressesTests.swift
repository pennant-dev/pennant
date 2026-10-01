import PennantCore
@testable import PennantClientKit
@testable import PennantHostKit
import Foundation
import XCTest

/// A phone paired at home finds the host away from home: the host tells it its Tailscale name, and the phone tries
/// every address it knows, trusting only the certificate it pinned.
final class HostAddressesTests: XCTestCase {
    let fingerprint = String(repeating: "ab", count: 32)

    func testTailscaleStatusGivesTheNameAndAddressesOnlyWhileRunning() {
        let running = Data("""
        {"BackendState":"Running","Self":{"DNSName":"studio.tail1234.ts.net.","TailscaleIPs":["fd7a:115c:a1e0::1","100.101.102.103"]}}
        """.utf8)
        XCTAssertEqual(TailscaleSelf.parse(running), TailscaleSelf.Info(dnsName: "studio.tail1234.ts.net", addresses: ["100.101.102.103", "fd7a:115c:a1e0::1"]))
        let stopped = Data(#"{"BackendState":"Stopped","Self":{"DNSName":"studio.tail1234.ts.net.","TailscaleIPs":[]}}"#.utf8)
        XCTAssertNil(TailscaleSelf.parse(stopped))
        XCTAssertNil(TailscaleSelf.parse(Data("not json".utf8)))
    }

    func testTheHostsAddressesSurviveTheWire() throws {
        var info = HostInfo(hostName: "Studio", version: "1", startedAt: Date(), mode: .everyday, inferenceEndpoint: "", inferenceModel: "", inferenceReachable: true, databasePath: "", activeTaskCount: 0, connectedClients: 0)
        info.addresses = ["studio.tail1234.ts.net", "192.168.1.20"]
        let back = try JSONDecoder().decode(HostInfo.self, from: JSONEncoder().encode(info))
        XCTAssertEqual(back.addresses, ["studio.tail1234.ts.net", "192.168.1.20"])
    }

    func testTheConnectCodeRoundTripsAndRefusesSomethingElse() throws {
        var e = HostEndpoint(host: "studio.tail1234.ts.net", port: 7331, name: "Studio", tlsPort: 7332, fingerprint: fingerprint)
        e.alternates = ["100.101.102.103", "192.168.1.20"]
        let url = try XCTUnwrap(e.connectURL)
        XCTAssertTrue(url.absoluteString.hasPrefix("pennant://connect?"))
        let back = try XCTUnwrap(HostEndpoint(connectURL: url))
        XCTAssertEqual(back.host, "studio.tail1234.ts.net")
        XCTAssertEqual(back.port, 7331)
        XCTAssertEqual(back.tlsPort, 7332)
        XCTAssertEqual(back.fingerprint, fingerprint)
        XCTAssertEqual(back.name, "Studio")
        XCTAssertEqual(back.alternates, ["100.101.102.103", "192.168.1.20"])
        XCTAssertNil(HostEndpoint(connectURL: URL(string: "https://connect?host=x")!), "another scheme")
        XCTAssertNil(HostEndpoint(connectURL: URL(string: "pennant://connect?port=7331")!), "no host")
        XCTAssertNil(HostEndpoint(connectURL: URL(string: "pennant://connect?host=x&fp=nothex")!), "not a fingerprint")
    }

    @MainActor
    func testOtherAddressesAreTriedOnlyForAPinnedHostAndCarryItsPin() {
        let home = "192.168.77.\(Int.random(in: 2...250))"
        var endpoint = HostEndpoint(host: home, port: 7331, name: "Studio")
        endpoint.alternates = ["studio-\(UUID().uuidString.prefix(6)).tail1234.ts.net", home]
        let session = HostSession(transport: WebSocketTransport(), endpoint: endpoint, displayName: "Test", platform: "iOS")
        defer { for e in session.candidateEndpoints() { HostPins.forget(e) }; HostPins.forget(endpoint) }

        // Never connected securely: only the address it was paired with, so nothing can downgrade elsewhere.
        XCTAssertEqual(session.candidateEndpoints().map(\.host), [home])

        HostPins.set(fingerprint, for: endpoint)
        let all = session.candidateEndpoints()
        XCTAssertEqual(all.map(\.host), [home, endpoint.alternates![0]], "each address once, the paired one first")
        XCTAssertEqual(HostPins.pin(for: all[1]), fingerprint, "the Tailscale name must show the same certificate")
    }
}
