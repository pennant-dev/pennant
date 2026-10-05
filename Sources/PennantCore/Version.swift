import Foundation

public enum PennantVersion {
    /// This release. The apps and the host's helper bundle carry the same number in their Info.plist.
    public static let string = "0.3.1"
    /// The build number of the app or helper bundle this process runs from; nil for a command-line build.
    public static let build: String? = Bundle.main.bundleIdentifier?.hasPrefix("dev.pennant.") == true
        ? Bundle.main.infoDictionary?["CFBundleVersion"] as? String : nil
    public static let bonjourServiceType = "_pennant._tcp"
}
