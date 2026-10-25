import Foundation

public enum APNsEnvironment: String, Sendable {
    case development
    case production
}

public enum ProvisioningProfileError: Error, Equatable {
    /// The profile is present but carries no `aps-environment`, so registering would pick the wrong APNs host.
    case unreadable
}

public enum ProvisioningProfile {
    /// Reads `aps-environment` from `embedded.mobileprovision`, a CMS envelope around a plain XML plist.
    /// A build with no profile is an App Store one, and its tokens are production ones.
    public static func apsEnvironment(profile: Data?) throws -> APNsEnvironment {
        guard let profile else { return .production }
        guard let start = profile.range(of: Data("<?xml".utf8)),
              let end = profile.range(of: Data("</plist>".utf8), in: start.lowerBound..<profile.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                  from: profile.subdata(in: start.lowerBound..<end.upperBound), format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let value = entitlements["aps-environment"] as? String,
              let environment = APNsEnvironment(rawValue: value)
        else { throw ProvisioningProfileError.unreadable }
        return environment
    }
}
