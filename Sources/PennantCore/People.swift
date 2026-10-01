import Foundation

/// The people who can use a host. The Mac's own account is the owner; teammates sign in with Microsoft, Google or
/// GitHub and join as members when their organisation is allowed or they were invited.
public enum PersonTag {}
public typealias PersonID = ID<PersonTag>

public enum PersonRole: String, Codable, Sendable, CaseIterable {
    /// The Mac's own user: manages people and sign-in, and can do everything.
    case owner
    /// A teammate: shares Pennant (its conversations, approvals, reports).
    case member
}

public enum SignInProvider: String, Codable, Sendable, CaseIterable, Identifiable {
    case microsoft, google, github
    public var id: String { rawValue }
    public var title: String {
        switch self { case .microsoft: return "Microsoft"; case .google: return "Google"; case .github: return "GitHub" }
    }
}

/// One way a person proves who they are: the provider's stable subject id for them.
public struct LinkedIdentity: Hashable, Codable, Sendable {
    public var provider: SignInProvider
    /// The provider's stable id: Microsoft `oid` (with `tid`), Google `sub`, GitHub user id.
    public var subject: String
    public var email: String
    /// Microsoft only: the organisation (tenant) the account belongs to.
    public var tenantID: String?
    public init(provider: SignInProvider, subject: String, email: String, tenantID: String? = nil) {
        self.provider = provider; self.subject = subject; self.email = email; self.tenantID = tenantID
    }
}

public struct Person: Hashable, Codable, Sendable, Identifiable {
    public var id: PersonID
    public var name: String
    public var email: String
    public var role: PersonRole
    public var identities: [LinkedIdentity]
    public var createdAt: Date
    public var lastSeenAt: Date?
    /// Signed-in sessions stop working and new sign-ins are refused.
    public var disabled: Bool
    /// Signs in with their email and a password (kept hashed on the host, never in this record).
    public var hasPassword: Bool

    public init(id: PersonID = PersonID(), name: String, email: String, role: PersonRole = .member, identities: [LinkedIdentity] = [],
                createdAt: Date = Date(), lastSeenAt: Date? = nil, disabled: Bool = false, hasPassword: Bool = false) {
        self.id = id; self.name = name; self.email = email; self.role = role; self.identities = identities
        self.createdAt = createdAt; self.lastSeenAt = lastSeenAt; self.disabled = disabled; self.hasPassword = hasPassword
    }

    /// Has at least one way to sign in from another device.
    public var canSignIn: Bool { hasPassword || !identities.isEmpty }

    private enum CodingKeys: String, CodingKey { case id, name, email, role, identities, createdAt, lastSeenAt, disabled, hasPassword }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(PersonID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
        role = try c.decodeIfPresent(PersonRole.self, forKey: .role) ?? .member
        identities = try c.decodeIfPresent([LinkedIdentity].self, forKey: .identities) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastSeenAt = try c.decodeIfPresent(Date.self, forKey: .lastSeenAt)
        disabled = try c.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
        hasPassword = try c.decodeIfPresent(Bool.self, forKey: .hasPassword) ?? false
    }

    /// The person behind the host's own (local or paired) clients.
    public static func owner(name: String) -> Person { Person(id: PersonID("owner"), name: name, email: "", role: .owner) }
}

/// An email address allowed to join before it has an account: by signing in with any provider whose verified email
/// matches, or by entering the invite's one-time code in the app and choosing a password.
public struct PersonInvite: Hashable, Codable, Sendable, Identifiable {
    public var email: String
    public var invitedAt: Date
    /// One-time code (8 characters) the owner sends; only owners see it. Nil on invites from before codes.
    public var code: String?
    public var expiresAt: Date?
    public var id: String { email }
    public init(email: String, invitedAt: Date = Date(), code: String? = nil, expiresAt: Date? = nil) {
        self.email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.invitedAt = invitedAt
        self.code = code
        self.expiresAt = expiresAt
    }

    public var isExpired: Bool { expiresAt.map { $0 < Date() } ?? false }

    /// "ABCD-EFGH", as people read it out.
    public var displayCode: String? {
        guard let code, code.count == 8 else { return code }
        return code.prefix(4) + "-" + code.suffix(4)
    }

    /// A code as someone typed it: dashes, spaces and case don't matter.
    public static func normalize(_ code: String) -> String {
        code.uppercased().filter { $0.isLetter || $0.isNumber }
    }
}

/// The people list and who may join, as the owner's Settings › People shows it.
public struct PeopleDirectory: Hashable, Codable, Sendable {
    public var people: [Person]
    public var invites: [PersonInvite]
    public var signIn: SignInSettings
    public init(people: [Person] = [], invites: [PersonInvite] = [], signIn: SignInSettings = SignInSettings()) {
        self.people = people; self.invites = invites; self.signIn = signIn
    }
}

/// Which providers are set up and who may join without an invite. Client ids are public; nothing here is secret.
public struct SignInSettings: Hashable, Codable, Sendable {
    public struct Provider: Hashable, Codable, Sendable {
        public var clientID: String
        /// Microsoft: the tenant to sign in against ("organizations" for any work account, or a tenant id).
        public var tenant: String?
        public init(clientID: String, tenant: String? = nil) { self.clientID = clientID; self.tenant = tenant }
    }
    public var microsoft: Provider?
    public var google: Provider?
    public var github: Provider?
    /// Microsoft organisations (tenant ids) whose members join without an invite.
    public var allowedTenants: [String]

    public init(microsoft: Provider? = nil, google: Provider? = nil, github: Provider? = nil, allowedTenants: [String] = []) {
        self.microsoft = microsoft; self.google = google; self.github = github; self.allowedTenants = allowedTenants
    }

    public func provider(_ p: SignInProvider) -> Provider? {
        switch p { case .microsoft: return microsoft; case .google: return google; case .github: return github }
    }
    public var configured: [SignInProvider] { SignInProvider.allCases.filter { provider($0) != nil } }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        microsoft = try c.decodeIfPresent(Provider.self, forKey: .microsoft)
        google = try c.decodeIfPresent(Provider.self, forKey: .google)
        github = try c.decodeIfPresent(Provider.self, forKey: .github)
        allowedTenants = try c.decodeIfPresent([String].self, forKey: .allowedTenants) ?? []
    }
}

/// How the app should run a sign-in the host started.
public struct SignInStart: Hashable, Codable, Sendable {
    public enum Step: Hashable, Codable, Sendable {
        /// Open this page in a browser sheet; the provider redirects to `callbackScheme://…` with a code.
        case browser(url: URL, callbackScheme: String)
        /// Show this code and open the page; the host waits for the person to enter it (GitHub).
        case deviceCode(userCode: String, verificationURL: URL, expiresAt: Date)
    }
    /// Ties the finish to this start; the host keeps the secret half of PKCE under it.
    public var state: String
    public var provider: SignInProvider
    public var step: Step
    public init(state: String, provider: SignInProvider, step: Step) { self.state = state; self.provider = provider; self.step = step }
}

/// What a signed-in client learns about itself.
public struct SignedIn: Hashable, Codable, Sendable {
    public var token: String
    public var person: Person
    public var hostName: String
    public init(token: String, person: Person, hostName: String) { self.token = token; self.person = person; self.hostName = hostName }
}
