import Foundation

/// The sandbox a plugin runs in (`sandbox-exec`): it reads its own bundle and the system's libraries, reads and writes
/// its own data folder, reaches the network only when the owner granted it, and can't start other programs, read the
/// owner's files or touch their Keychain. Everything else it needs, it asks Pennant for.
public enum PluginSandbox {
    public static let launcher = "/usr/bin/sandbox-exec"

    public static func profile(executable: URL, bundle: URL, data: URL, network: Bool) -> String {
        let exe = quote(realPath(executable))
        let bundlePath = quote(realPath(bundle))
        let dataPath = quote(realPath(data))
        return """
        (version 1)
        (deny default)
        (import "bsd.sb")
        (allow process-exec (literal \(exe)))
        (allow file-read* (subpath \(bundlePath)))
        (allow file-read* file-write* (subpath \(dataPath)))
        (allow file-read* (subpath "/System") (subpath "/usr/lib") (subpath "/usr/share") (subpath "/Library/Preferences")
          (subpath "/private/var/db/timezone") (subpath "/private/etc")
          (literal "/dev/urandom") (literal "/dev/random") (literal "/dev/null"))
        (allow mach-lookup (global-name "com.apple.trustd" "com.apple.trustd.agent" "com.apple.SystemConfiguration.configd"
          "com.apple.SystemConfiguration.DNSConfiguration" "com.apple.dnssd.service" "com.apple.networkd" "com.apple.cfprefsd.daemon"
          "com.apple.cfprefsd.agent" "com.apple.ocspd" "com.apple.SecurityServer" "com.apple.usymptomsd" "com.apple.symptomsd"
          "com.apple.nehelper" "com.apple.networkserviceproxy" "com.apple.logd" "com.apple.diagnosticd"
          "com.apple.system.opendirectoryd.libinfo" "com.apple.system.notification_center" "com.apple.mDNSResponder"))
        (allow system-socket)
        (allow sysctl-read)
        \(network ? "(allow network-outbound)" : "")
        """
    }

    /// The path the kernel checks: every symlink resolved, /private kept (`resolvingSymlinksInPath` drops it, and
    /// then nothing matches). As given when it doesn't exist yet.
    static func realPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// A path as an SBPL string.
    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
