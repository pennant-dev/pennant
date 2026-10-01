import Foundation

// MARK: - Library: brand assets the user uploads for agents to use

/// A named set of files with written guidance: "Acme brand" with its logos, fonts and rules.
public struct LibraryCollection: Hashable, Codable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    /// How to use what is in it: colours, typography, where the logo goes, what never to do.
    public var notes: String

    public init(name: String, notes: String = "") {
        self.name = name
        self.notes = notes
    }
}

/// One uploaded file. `path` is where it lives on the host, for agents and scripts to use directly.
public struct LibraryAsset: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var collection: String
    /// What it is, in words: "Primary logo, white, for dark backgrounds".
    public var name: String
    public var fileName: String
    public var mimeType: String
    public var byteCount: Int
    public var width: Int?
    public var height: Int?
    /// When and how to use it.
    public var notes: String
    public var path: String
    public var createdAt: Date

    public init(id: String = UUID().uuidString, collection: String, name: String, fileName: String, mimeType: String, byteCount: Int, width: Int? = nil, height: Int? = nil, notes: String = "", path: String, createdAt: Date = Date()) {
        self.id = id
        self.collection = collection
        self.name = name
        self.fileName = fileName
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.width = width
        self.height = height
        self.notes = notes
        self.path = path
        self.createdAt = createdAt
    }

    public var isImage: Bool { mimeType.hasPrefix("image/") }
}

public struct LibraryIndex: Hashable, Codable, Sendable {
    public var collections: [LibraryCollection]
    public var assets: [LibraryAsset]
    public init(collections: [LibraryCollection] = [], assets: [LibraryAsset] = []) {
        self.collections = collections
        self.assets = assets
    }
}

// MARK: - Vault: sign-ins and secrets that scripts use without the model seeing them

/// What the vault shows about an entry. The secret parts never leave the host except into a script that asked for
/// the entry by name.
public struct VaultItem: Hashable, Codable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case login, secret }

    public var id: String
    /// The name scripts and agents use: "linkedin", "hubspot-api".
    public var name: String
    public var kind: Kind
    public var url: String?
    public var username: String?
    public var notes: String
    public var hasPassword: Bool
    /// A TOTP (authenticator app) secret is stored, so scripts can produce the current code.
    public var hasTOTP: Bool
    public var hasSecret: Bool
    public var updatedAt: Date

    public init(id: String = UUID().uuidString, name: String, kind: Kind = .login, url: String? = nil, username: String? = nil, notes: String = "", hasPassword: Bool = false, hasTOTP: Bool = false, hasSecret: Bool = false, updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.kind = kind
        self.url = url
        self.username = username
        self.notes = notes
        self.hasPassword = hasPassword
        self.hasTOTP = hasTOTP
        self.hasSecret = hasSecret
        self.updatedAt = updatedAt
    }
}

/// A Chrome profile on this Mac, for importing sign-ins.
public struct ChromeProfile: Hashable, Codable, Sendable, Identifiable {
    /// The profile folder: "Default", "Profile 1".
    public var id: String
    public var name: String
    /// The Google account signed in to that profile, if any.
    public var account: String?
    public init(id: String, name: String, account: String? = nil) {
        self.id = id
        self.name = name
        self.account = account
    }
}

/// A site a Chrome profile has cookies for (a sign-in is likely where there are many).
public struct ChromeSite: Hashable, Codable, Sendable, Identifiable {
    public var id: String { site }
    public var site: String
    public var cookies: Int
    public init(site: String, cookies: Int) {
        self.site = site
        self.cookies = cookies
    }
}

public struct ChromeImportResult: Hashable, Codable, Sendable {
    public var profile: String
    public var cookies: Int
    public var perSite: [String: Int]
    /// When each site's longest-lived cookie expires (roughly how long the sign-in lasts).
    public var expiresAt: [String: Date]
    public init(profile: String, cookies: Int, perSite: [String: Int], expiresAt: [String: Date] = [:]) {
        self.profile = profile
        self.cookies = cookies
        self.perSite = perSite
        self.expiresAt = expiresAt
    }
}

/// A site whose sign-in was copied from the user's browser into Pennant's, so the user can see what Pennant can use.
public struct BrowserSignIn: Hashable, Codable, Sendable, Identifiable {
    public var id: String { site }
    public var site: String
    /// Where it came from: "Chrome".
    public var browser: String
    /// The profile's display name, like "Your Chrome".
    public var profileName: String
    public var account: String?
    public var cookies: Int
    public var importedAt: Date
    public var expiresAt: Date?

    public init(site: String, browser: String = "Chrome", profileName: String, account: String? = nil, cookies: Int, importedAt: Date = Date(), expiresAt: Date? = nil) {
        self.site = site
        self.browser = browser
        self.profileName = profileName
        self.account = account
        self.cookies = cookies
        self.importedAt = importedAt
        self.expiresAt = expiresAt
    }
}

/// The secret parts, sent by a client when saving an entry. Nil fields keep what is stored.
public struct VaultSecret: Hashable, Codable, Sendable {
    public var password: String?
    /// Base32 TOTP secret (the text behind an authenticator QR code).
    public var totp: String?
    public var secret: String?

    public init(password: String? = nil, totp: String? = nil, secret: String? = nil) {
        self.password = password
        self.totp = totp
        self.secret = secret
    }
}
