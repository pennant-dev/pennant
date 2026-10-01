import Foundation

/// Settings the apps saved before Pennant had its name: the Mac app was dev.ayes.mac, and io.cove.mac before that,
/// and both apps kept their keys under "cove.". Brought over once per device, before anything reads settings.
public enum LegacyDefaults {
    public static let macDomains = ["dev.ayes.mac", "io.cove.mac"]

    public static func migrate(_ defaults: UserDefaults = .standard, domains: [String] = []) {
        if !defaults.bool(forKey: "pennant.migratedLegacyDefaults") {
            // Newer names win.
            for domain in domains {
                guard let old = defaults.persistentDomain(forName: domain) else { continue }
                for (key, value) in old where defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
            }
            defaults.set(true, forKey: "pennant.migratedLegacyDefaults")
        }
        guard !defaults.bool(forKey: "pennant.renamedLegacyKeys") else { return }
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix("cove.") {
            let renamed = "pennant." + key.dropFirst("cove.".count)
            if defaults.object(forKey: renamed) == nil { defaults.set(value, forKey: renamed) }
            defaults.removeObject(forKey: key)
        }
        defaults.set(true, forKey: "pennant.renamedLegacyKeys")
    }
}
