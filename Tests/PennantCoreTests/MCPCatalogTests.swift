import PennantCore
import XCTest

final class MCPCatalogTests: XCTestCase {
    func testCatalogIsPopulated() {
        XCTAssertGreaterThanOrEqual(MCPCatalog.entries.count, 25)
        for category in MCPCatalog.categories {
            XCTAssertFalse(MCPCatalog.search("", category: category).isEmpty, "no entries in \(category)")
        }
    }

    func testIDsAreUnique() {
        let ids = MCPCatalog.entries.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate ids: \(Dictionary(grouping: ids, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted())")
        for id in ids {
            XCTAssertEqual(id, id.lowercased(), "\(id) should be lowercase")
            XCTAssertFalse(id.contains(" "), "\(id) should not contain spaces")
        }
    }

    func testEveryEntryHasAnAddressOrACommand() {
        for e in MCPCatalog.entries {
            if e.builtin != nil {
                XCTAssertNil(e.url, "\(e.id): a built-in connector has no server address")
                XCTAssertNil(e.command, "\(e.id): a built-in connector runs no command")
                XCTAssertNotNil(e.oauthServer, "\(e.id): a built-in connector needs its OAuth endpoints")
            } else if let command = e.command {
                XCTAssertFalse(command.isEmpty, "\(e.id): empty command")
                if e.alternateAuth == nil {
                    XCTAssertNil(e.url, "\(e.id): local entries should not carry a URL")
                } else {
                    // A local entry's alternate is the remote server, so it needs an address too.
                    XCTAssertEqual(e.url.flatMap { URL(string: $0) }?.scheme, "https", "\(e.id): the alternate route needs an https URL")
                }
            } else {
                let url = e.url.flatMap { URL(string: $0) }
                XCTAssertNotNil(url, "\(e.id): url is missing or unparseable")
                XCTAssertEqual(url?.scheme, "https", "\(e.id): remote servers must use https")
                XCTAssertTrue(e.arguments.isEmpty && e.environment.isEmpty, "\(e.id): remote entries carry no command line")
            }
        }
    }

    func testMakeConfigSucceedsWithPlaceholderValues() throws {
        for e in MCPCatalog.entries {
            let config = try XCTUnwrap(e.makeConfig(values: e.sampleValues), "\(e.id): makeConfig failed")
            XCTAssertEqual(config.catalogID, e.id)
            XCTAssertEqual(config.name, e.name)
            if case .oauth(let scopes, let id, _) = config.auth, case .oauth(_, let entryID, _) = e.auth {
                XCTAssertEqual(id, entryID)
                for s in scopes { XCTAssertFalse(s.contains("{"), "\(e.id): unfilled placeholder in scope \(s)") }
            } else {
                XCTAssertEqual(config.auth, e.auth)
            }
            if let o = config.oauthServer {
                for s in [o.authorizeURL, o.tokenURL] + Array(o.tokenHeaders.values) { XCTAssertFalse(s.contains("{"), "\(e.id): unfilled placeholder in \(s)") }
            }
            switch config.transport {
            case .builtin(let connector):
                XCTAssertEqual(connector, e.builtin)
            case .stdio(let cmd, let args, let env):
                XCTAssertTrue(e.isLocal, "\(e.id): remote entry produced a stdio transport")
                for s in [cmd] + args + env.values { XCTAssertFalse(s.contains("{"), "\(e.id): unfilled placeholder in \(s)") }
            case .http(let url):
                XCTAssertFalse(e.isLocal, "\(e.id): local entry produced an http transport")
                XCTAssertFalse(url.absoluteString.contains("{"), "\(e.id): unfilled placeholder in url")
            }
        }
    }

    func testPlaceholdersMatchParameters() {
        for e in MCPCatalog.entries {
            let declared = Set(e.parameters.map(\.key))
            XCTAssertEqual(e.placeholderKeys, declared, "\(e.id): placeholders and parameters differ")
            XCTAssertEqual(declared.count, e.parameters.count, "\(e.id): duplicate parameter keys")
            for p in e.parameters {
                XCTAssertTrue(["folder", "text", "secret"].contains(p.kind), "\(e.id): unknown parameter kind \(p.kind)")
                XCTAssertFalse(p.label.isEmpty, "\(e.id): parameter \(p.key) has no label")
            }
        }
    }

    func testSymbolsCategoriesAndCopy() {
        let categories = Set(MCPCatalog.categories)
        for e in MCPCatalog.entries {
            XCTAssertFalse(e.symbol.isEmpty, "\(e.id): empty symbol")
            XCTAssertTrue(categories.contains(e.category), "\(e.id): category \(e.category) is not in the fixed set")
            XCTAssertFalse(e.name.isEmpty, "\(e.id): empty name")
            XCTAssertFalse(e.publisher.isEmpty, "\(e.id): empty publisher")
            XCTAssertFalse(e.summary.isEmpty, "\(e.id): empty summary")
            XCTAssertTrue(e.summary.hasSuffix("."), "\(e.id): summary should be one sentence")
            if let docs = e.docsURL { XCTAssertNotNil(URL(string: docs), "\(e.id): bad docsURL") }
            if let help = e.keyHelpURL { XCTAssertNotNil(URL(string: help), "\(e.id): bad keyHelpURL") }
        }
    }

    func testAPIKeyEntriesSayWhereToGetOne() {
        for e in MCPCatalog.entries {
            for auth in [e.auth, e.alternateAuth].compactMap({ $0 }) {
                if case .apiKey(let header, _) = auth {
                    XCTAssertFalse(header.isEmpty, "\(e.id): empty header")
                    XCTAssertNotNil(e.keyHelpURL, "\(e.id): API-key servers need a keyHelpURL")
                }
            }
            if e.parameters.contains(where: { $0.kind == "secret" }) {
                XCTAssertTrue(e.keyHelpURL != nil || e.docsURL != nil, "\(e.id): secret parameters need somewhere to point")
            }
            if e.isLocal { XCTAssertEqual(e.auth, .none, "\(e.id): local servers authenticate through their environment, not MCPAuth") }
        }
    }

    func testUnverifiedEntriesLinkToDocs() {
        for e in MCPCatalog.entries where !e.verified {
            XCTAssertNotNil(e.docsURL, "\(e.id): unverified entries must link to docs")
        }
    }

    func testLookupAndSearch() {
        XCTAssertEqual(MCPCatalog.entry("notion")?.name, "Notion")
        XCTAssertNil(MCPCatalog.entry("nope"))
        XCTAssertTrue(MCPCatalog.search("NOTION").contains { $0.id == "notion" })
        XCTAssertTrue(MCPCatalog.search("", category: "Local").allSatisfy { $0.category == "Local" })
        XCTAssertTrue(MCPCatalog.search("zzzz-no-such").isEmpty)
        XCTAssertEqual(MCPCatalog.search("").count, MCPCatalog.entries.count)
    }

    func testSignInLabels() throws {
        let filesystem = try XCTUnwrap(MCPCatalog.entry("filesystem"))
        XCTAssertEqual(filesystem.signInLabel, "Runs on this Mac")
        XCTAssertEqual(try XCTUnwrap(MCPCatalog.entry("notion")).signInLabel, "OAuth")
        XCTAssertEqual(try XCTUnwrap(MCPCatalog.entry("exa")).signInLabel, "API key")
        XCTAssertEqual(try XCTUnwrap(MCPCatalog.entry("deepwiki")).signInLabel, "No sign-in")
        XCTAssertNil(filesystem.alternateSignInLabel)
        XCTAssertEqual(try XCTUnwrap(MCPCatalog.entry("github")).alternateSignInLabel, "Sign in with OAuth instead")
        XCTAssertEqual(try XCTUnwrap(MCPCatalog.entry("hubspot")).alternateSignInLabel, "Sign in with OAuth instead")
        XCTAssertEqual(try XCTUnwrap(MCPCatalog.entry("github")).alternate?.alternateSignInLabel, "Use a token instead")
    }

    // MARK: Alternate sign-ins and registered clients

    private func kind(_ auth: MCPAuth) -> String {
        switch auth {
        case .none: return "none"
        case .apiKey: return "apiKey"
        case .oauth: return "oauth"
        }
    }

    func testAlternateSignInsAreWellFormed() {
        for e in MCPCatalog.entries {
            if let alt = e.alternateAuth {
                XCTAssertNotEqual(kind(alt), kind(e.auth), "\(e.id): the alternate must be a different kind of sign-in")
                if e.isLocal {
                    XCTAssertNotEqual(kind(alt), "none", "\(e.id): a local entry's alternate is a remote sign-in")
                    XCTAssertNotNil(e.url, "\(e.id): a local entry's alternate needs the remote URL")
                }
                XCTAssertNotNil(e.alternate, "\(e.id): alternate route could not be built")
            } else {
                XCTAssertNil(e.alternate, "\(e.id): no alternate auth, no alternate route")
            }
            if e.needsRegisteredClient {
                let oauth = [e.auth, e.alternateAuth].compactMap { $0 }.contains { kind($0) == "oauth" }
                XCTAssertTrue(oauth, "\(e.id): needsRegisteredClient only means something for OAuth")
                XCTAssertNotNil(e.docsURL, "\(e.id): a registered client needs the provider's console linked")
            }
        }
    }

    func testAlternateRouteOfARemoteEntrySwapsBothWays() throws {
        let github = try XCTUnwrap(MCPCatalog.entry("github"))
        XCTAssertEqual(github.auth, .bearerKey)
        XCTAssertEqual(github.alternateAuth, .oauthDefault)
        XCTAssertTrue(github.needsRegisteredClient)
        XCTAssertFalse(github.needsClientBeforeSignIn, "a token sign-in never needs a client")
        let oauth = try XCTUnwrap(github.alternate)
        XCTAssertEqual(oauth.id, github.id, "the alternate keeps the catalog id so the card finds its server")
        XCTAssertEqual(oauth.auth, .oauthDefault)
        XCTAssertEqual(oauth.alternateAuth, .bearerKey)
        XCTAssertTrue(oauth.needsClientBeforeSignIn)
        XCTAssertEqual(oauth.alternate, github)
        let config = try XCTUnwrap(oauth.makeConfig())
        XCTAssertEqual(config.auth, .oauthDefault)
        guard case .http(let url) = config.transport else { return XCTFail("remote alternate should be http") }
        XCTAssertEqual(url.absoluteString, github.url)
    }

    func testAlternateRouteOfALocalEntryIsTheRemoteServer() throws {
        let hubspot = try XCTUnwrap(MCPCatalog.entry("hubspot"))
        XCTAssertTrue(hubspot.isLocal)
        XCTAssertEqual(hubspot.command, "npx")
        XCTAssertEqual(hubspot.arguments, ["-y", "@hubspot/mcp-server"])
        XCTAssertEqual(hubspot.environment, ["PRIVATE_APP_ACCESS_TOKEN": "{PRIVATE_APP_ACCESS_TOKEN}"])
        XCTAssertEqual(hubspot.parameters.map(\.kind), ["secret"])
        XCTAssertNotNil(hubspot.keyHelpURL)
        XCTAssertFalse(hubspot.needsClientBeforeSignIn, "the local route never signs in")
        let remote = try XCTUnwrap(hubspot.alternate)
        XCTAssertFalse(remote.isLocal)
        XCTAssertTrue(remote.arguments.isEmpty && remote.environment.isEmpty && remote.parameters.isEmpty)
        XCTAssertEqual(remote.auth, .oauthDefault)
        XCTAssertNil(remote.alternateAuth, "a local primary cannot be expressed as an MCPAuth")
        XCTAssertTrue(remote.needsClientBeforeSignIn)
        let config = try XCTUnwrap(remote.makeConfig())
        XCTAssertEqual(config.catalogID, "hubspot")
        guard case .http(let url) = config.transport else { return XCTFail("remote alternate should be http") }
        XCTAssertEqual(url.absoluteString, "https://mcp.hubspot.com")
    }

    func testRegisteredClientLandsOnTheConfig() throws {
        let remote = try XCTUnwrap(MCPCatalog.entry("hubspot")?.alternate)
        let signedUp = remote.withRegisteredClient(id: " abc ", secret: " ")
        XCTAssertEqual(signedUp.auth, .oauth(scopes: [], clientID: "abc", clientSecret: nil))
        XCTAssertFalse(signedUp.needsClientBeforeSignIn)
        XCTAssertEqual(signedUp.withRegisteredClient(id: "abc", secret: "s3").makeConfig()?.auth, .oauth(scopes: [], clientID: "abc", clientSecret: "s3"))
        // Not an OAuth sign-in: nothing to register, the entry is returned as is.
        let github = try XCTUnwrap(MCPCatalog.entry("github"))
        XCTAssertEqual(github.withRegisteredClient(id: "abc", secret: nil), github)
    }

    func testAlternateFieldsAreOptionalOnTheWire() throws {
        // A host older than the alternate sign-in sends entries without these keys; they must still decode.
        let entry = try XCTUnwrap(MCPCatalog.entry("github"))
        XCTAssertNotNil(entry.alternateAuth)
        XCTAssertTrue(entry.needsRegisteredClient)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        XCTAssertNotNil(object["alternateAuth"])
        XCTAssertEqual(object["needsRegisteredClient"] as? Bool, true)
        object.removeValue(forKey: "alternateAuth")
        object.removeValue(forKey: "needsRegisteredClient")
        let back = try JSONDecoder().decode(MCPCatalogEntry.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(back.id, entry.id)
        XCTAssertEqual(back.auth, entry.auth)
        XCTAssertEqual(back.url, entry.url)
        XCTAssertEqual(back.brandIcon, entry.brandIcon)
        XCTAssertNil(back.alternateAuth)
        XCTAssertFalse(back.needsRegisteredClient)
        // With the keys present the round trip is exact.
        let same = try JSONDecoder().decode(MCPCatalogEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(same, entry)
    }

    func testPlaceholderKeysParsing() {
        let e = MCPCatalogEntry(id: "x", name: "X", publisher: "P", summary: "S.", category: "Local", symbol: "folder",
                                command: "run", arguments: ["{a}", "--b={b}", "{a}/{c}"], environment: ["K": "{d}"], auth: .none)
        XCTAssertEqual(e.placeholderKeys, ["a", "b", "c", "d"])
        XCTAssertEqual(e.makeConfig(values: ["a": "1", "b": "2", "c": "3", "d": "4"]).map { config -> [String] in
            if case .stdio(_, let args, _) = config.transport { return args }
            return []
        }, ["1", "--b=2", "1/3"])
    }

    func testBrandFieldsAreWellFormed() {
        var marked = 0
        for e in MCPCatalog.entries {
            if let icon = e.brandIcon {
                marked += 1
                XCTAssertFalse(icon.isEmpty, "\(e.id): empty brandIcon")
                XCTAssertEqual(icon, icon.lowercased(), "\(e.id): brandIcon \(icon) should be a lowercase slug")
                XCTAssertTrue(icon.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }, "\(e.id): brandIcon \(icon) is not a slug")
                XCTAssertTrue(icon.first?.isLetter == true, "\(e.id): brandIcon \(icon) should start with a letter")
                XCTAssertNotNil(e.brandColor, "\(e.id): a mark needs a brand colour to be tinted with")
            }
            if let color = e.brandColor {
                XCTAssertEqual(color.count, 7, "\(e.id): brandColor \(color) should be #RRGGBB")
                XCTAssertTrue(color.hasPrefix("#"), "\(e.id): brandColor \(color) should start with #")
                XCTAssertNotNil(UInt32(color.dropFirst(), radix: 16), "\(e.id): brandColor \(color) is not hex")
                XCTAssertEqual(color, color.uppercased(), "\(e.id): brandColor \(color) should be uppercase")
                // Without a mark, the colour tints the card's symbol (Microsoft and LinkedIn are not in Simple Icons).
            }
        }
        XCTAssertGreaterThanOrEqual(marked, 20, "most services should carry their own mark")
    }

    func testBrandFieldsAreOptionalOnTheWire() throws {
        // A host older than the marks sends entries without them; they must still decode.
        let entry = try XCTUnwrap(MCPCatalog.entry("github"))
        XCTAssertNotNil(entry.brandIcon)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        object.removeValue(forKey: "brandIcon")
        object.removeValue(forKey: "brandColor")
        let back = try JSONDecoder().decode(MCPCatalogEntry.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(back.id, entry.id)
        XCTAssertNil(back.brandIcon)
        XCTAssertNil(back.brandColor)
    }

    func testCatalogEntriesRoundTripOnTheWire() throws {
        let data = try WireMessage.reply(HostReply(commandID: CommandID(), result: .mcpCatalog(MCPCatalog.entries))).encoded()
        guard case .reply(let r) = try WireMessage.decode(data), case .mcpCatalog(let back) = r.result else { return XCTFail("not a catalog reply") }
        XCTAssertEqual(back, MCPCatalog.entries)
    }

    // MARK: Native connectors and Work IQ

    func testWorkIQEntryFillsTenantEverywhere() throws {
        let e = try XCTUnwrap(MCPCatalog.entries.first { $0.id == "workiq-teams" })
        let tenant = "11111111-2222-3333-4444-555555555555"
        let config = try XCTUnwrap(e.withRegisteredClient(id: " app-id ", secret: "", values: ["tenant": tenant]).makeConfig())
        guard case .http(let url) = config.transport else { return XCTFail("Work IQ is a remote server") }
        XCTAssertEqual(url.absoluteString, "https://agent365.svc.cloud.microsoft/agents/tenants/\(tenant)/servers/mcp_TeamsServer")
        guard case .oauth(let scopes, let clientID, let secret) = config.auth else { return XCTFail("OAuth expected") }
        XCTAssertEqual(clientID, "app-id")
        XCTAssertNil(secret)
        XCTAssertEqual(scopes.first, "https://agent365.svc.cloud.microsoft/agents/tenants/\(tenant)/servers/mcp_TeamsServer/.default")
        XCTAssertTrue(scopes.contains("offline_access"))
        XCTAssertEqual(config.oauthServer?.authorizeURL, "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/authorize")
        XCTAssertEqual(config.oauthServer?.sendsResource, false)
        XCTAssertEqual(config.oauthServer?.redirectURIToRegister, "http://localhost:47831/callback")
        XCTAssertEqual(config.settings["tenant"], tenant)
    }

    func testNativeConnectorEntries() throws {
        let ms = try XCTUnwrap(MCPCatalog.entries.first { $0.id == "microsoft365" })
        XCTAssertEqual(ms.builtin, "microsoft365")
        XCTAssertFalse(ms.needsClientSecret)
        XCTAssertTrue(ms.needsClientBeforeSignIn)
        let msConfig = try XCTUnwrap(ms.withRegisteredClient(id: "c", secret: nil, values: ["tenant": "organizations"]).makeConfig())
        XCTAssertEqual(msConfig.transport, .builtin(connector: "microsoft365"))
        XCTAssertEqual(msConfig.oauthServer?.tokenURL, "https://login.microsoftonline.com/organizations/oauth2/v2.0/token")
        XCTAssertTrue(msConfig.isBuiltin && msConfig.signsIn && !msConfig.isHTTP)

        let li = try XCTUnwrap(MCPCatalog.entries.first { $0.id == "linkedin" })
        XCTAssertTrue(li.needsClientSecret)
        XCTAssertEqual(li.oauthServer?.usesPKCE, false)
        XCTAssertEqual(li.oauthServer?.secretInBody, true)

        let reddit = try XCTUnwrap(MCPCatalog.entries.first { $0.id == "reddit" })
        let rConfig = try XCTUnwrap(reddit.withRegisteredClient(id: "r", secret: "", values: ["username": "alex"]).makeConfig())
        XCTAssertEqual(rConfig.oauthServer?.tokenHeaders["User-Agent"], "macos:dev.pennant.mac:v1 (by /u/alex)")
        XCTAssertEqual(rConfig.oauthServer?.extraAuthorizeParameters["duration"], "permanent")
        XCTAssertEqual(rConfig.oauthServer?.basicAuthWithEmptySecret, true)
        XCTAssertEqual(rConfig.settings["username"], "alex")
    }

    func testOlderConfigsAndEndpointsDecode() throws {
        let legacy = #"{"id":"s1","name":"Old","transport":{"http":{"url":"https://x.example/mcp"}},"enabled":true}"#
        let config = try JSONDecoder().decode(MCPServerConfig.self, from: Data(legacy.utf8))
        XCTAssertNil(config.oauthServer)
        XCTAssertEqual(config.settings, [:])
        let endpoints = #"{"authorizeURL":"https://a","tokenURL":"https://t"}"#
        let o = try JSONDecoder().decode(OAuthServerConfig.self, from: Data(endpoints.utf8))
        XCTAssertTrue(o.usesPKCE)
        XCTAssertFalse(o.sendsResource)
        XCTAssertNil(o.redirectHost)
        let built = MCPServerConfig(name: "N", transport: .builtin(connector: "reddit"), auth: .oauthDefault, oauthServer: o, settings: ["username": "u"])
        let round = try JSONDecoder().decode(MCPServerConfig.self, from: JSONEncoder().encode(built))
        XCTAssertEqual(round, built)
    }
}
