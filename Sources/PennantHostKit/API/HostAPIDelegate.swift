import PennantCore
import Foundation

/// A connected, authenticated client.
public struct ConnectedClient: Hashable, Sendable, Identifiable {
    public var id: ClientID
    public var displayName: String
    public var platform: String
    public var connectedAt: Date
    /// Who is using this client. The owner for the Mac's own apps and devices from before accounts.
    public var person: Person?
    /// Connected from this Mac itself.
    public var isLocal: Bool

    public var isOwner: Bool { person == nil || person?.role == .owner }

    public init(id: ClientID, displayName: String, platform: String, connectedAt: Date = Date(), person: Person? = nil, isLocal: Bool = false) {
        self.person = person
        self.isLocal = isLocal
        self.id = id
        self.displayName = displayName
        self.platform = platform
        self.connectedAt = connectedAt
    }
}

/// What the API server needs from the host. Implemented by `HostService`; consumed by `HostAPIServer`.
public protocol HostAPIDelegate: Sendable {
    /// Whether a token is the local one or a signed-in device's (of someone who still has access).
    func authenticate(token: String?) async -> Bool
    /// Snapshot for a freshly authenticated client.
    func snapshot() async -> StateSnapshot
    /// Handle any command other than hello/ping/subscribeScreen/unsubscribeScreen and signing in.
    func handle(_ body: CommandBody, from client: ConnectedClient) async -> ReplyBody
    /// Screen frames for one subscriber. The stream ends when the consumer cancels.
    func screenFrames(options: ScreenStreamOptions) async -> AsyncStream<(ScreenFrameHeader, Data)>
    func clientsChanged(_ clients: [ConnectedClient], streaming: Int) async
    /// Talk mode's natural voices for a device: say `request`, each piece of speech to `send`, in order, the last
    /// one `final`. Throws when the voice can't speak here.
    func speak(_ request: SpeechRequest, connection: UUID, send: @escaping VoiceService.Sink) async throws
    /// Drop what `connection` asked to be said.
    func stopSpeaking(connection: UUID) async

    // Sign-in. Requirements (not just extension methods) so the host's implementations are what the server calls;
    // the defaults below serve hosts and test doubles without people.
    func signInOptions() async -> [SignInProvider]
    func beginSignIn(provider: SignInProvider, redirectURI: String, trusted: Bool) async throws -> SignInStart
    func completeSignIn(state: String, code: String?, clientID: ClientID, clientName: String, platform: String, trusted: Bool) async throws -> SignedIn
    func person(forToken token: String?) async -> Person?
    /// Email-and-password sign-in and invite codes.
    func signInWithPassword(email: String, password: String, clientID: ClientID, clientName: String, platform: String, trusted: Bool) async throws -> SignedIn
    func redeemInvite(code: String, name: String, password: String, clientID: ClientID, clientName: String, platform: String, trusted: Bool) async throws -> SignedIn
    /// Through Cloudflare Access: who a verified Access token belongs to (the account with its email). Throws with a
    /// reason the app can show when there's no valid token or no such account.
    func edgePerson(accessToken: String?) async throws -> Person
}

/// Hosts without natural voices (test doubles) can't speak.
public extension HostAPIDelegate {
    func speak(_ request: SpeechRequest, connection: UUID, send: @escaping VoiceService.Sink) async throws {
        throw VoiceService.VoiceError.unavailable(request.voice)
    }
    func stopSpeaking(connection: UUID) async {}
}

/// Signing in with a provider, and knowing who a token belongs to. Hosts without people keep the defaults.
public extension HostAPIDelegate {
    func signInOptions() async -> [SignInProvider] { [] }
    func beginSignIn(provider: SignInProvider, redirectURI: String, trusted: Bool) async throws -> SignInStart {
        throw PeopleService.SignInError.notConfigured(provider)
    }
    func completeSignIn(state: String, code: String?, clientID: ClientID, clientName: String, platform: String, trusted: Bool) async throws -> SignedIn {
        throw PeopleService.SignInError.unknownState
    }
    /// The person a valid token belongs to; nil means the owner (or a host without people).
    func person(forToken token: String?) async -> Person? { nil }
    func edgePerson(accessToken: String?) async throws -> Person { throw PeopleService.SignInError.notConfigured(.microsoft) }
    func signInWithPassword(email: String, password: String, clientID: ClientID, clientName: String, platform: String, trusted: Bool) async throws -> SignedIn {
        throw PeopleService.SignInError.wrongPassword
    }
    func redeemInvite(code: String, name: String, password: String, clientID: ClientID, clientName: String, platform: String, trusted: Bool) async throws -> SignedIn {
        throw PeopleService.SignInError.badInviteCode
    }
}
