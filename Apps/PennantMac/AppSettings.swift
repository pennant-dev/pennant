import PennantClientKit
import PennantCore
import Foundation

/// Small persisted client settings. The host keeps everything that matters.
enum AppSettings {
    private static var defaults: UserDefaults { .standard }

    static var clientID: ClientID {
        if let s = defaults.string(forKey: "pennant.clientID") { return ClientID(s) }
        let id = ClientID()
        defaults.set(id.rawValue, forKey: "pennant.clientID")
        return id
    }

    static var endpoint: HostEndpoint {
        get {
            let host = defaults.string(forKey: "pennant.host") ?? "127.0.0.1"
            let port = defaults.integer(forKey: "pennant.port")
            return HostEndpoint(host: host, port: port == 0 ? 7331 : port, name: host == "127.0.0.1" ? "This Mac" : host)
        }
        set {
            defaults.set(newValue.host, forKey: "pennant.host")
            defaults.set(newValue.port, forKey: "pennant.port")
        }
    }

    static func token(for endpoint: HostEndpoint) -> String? {
        defaults.string(forKey: "pennant.token.\(endpoint.host):\(endpoint.port)")
    }

    static func setToken(_ token: String?, for endpoint: HostEndpoint) {
        defaults.set(token, forKey: "pennant.token.\(endpoint.host):\(endpoint.port)")
    }

    static var showComputerPanel: Bool {
        get { defaults.object(forKey: "pennant.showComputerPanel") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "pennant.showComputerPanel") }
    }
}

