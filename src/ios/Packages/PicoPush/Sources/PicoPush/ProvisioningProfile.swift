import Foundation

public enum APNsEnvironment: String, Sendable {
    case development
    case production
}

public enum ProvisioningProfile {
    /// Reads `aps-environment` from `embedded.mobileprovision`, a CMS envelope around a plain XML plist.
    /// An App Store build carries no profile, and its tokens are production ones.
    public static func apsEnvironment(profile: Data?) -> APNsEnvironment {
        guard let profile,
              let start = profile.range(of: Data("<?xml".utf8)),
              let end = profile.range(of: Data("</plist>".utf8), in: start.lowerBound..<profile.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                  from: profile.subdata(in: start.lowerBound..<end.upperBound), format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let value = entitlements["aps-environment"] as? String,
              let environment = APNsEnvironment(rawValue: value)
        else { return .production }
        return environment
    }
}
