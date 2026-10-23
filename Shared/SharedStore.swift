import Foundation

/// What the app shares with its widgets and its share extension: the
/// widgets' token for the site, the app's login, and the last numbers the
/// widget got (shown while the Pi can't be reached). They live in an app group, which SideStore registers under the
/// account's team ID ("group.org.hellupeptic.portal.ABCDE12345"), so its
/// real name is read from the profile SideStore signed each of them with.
enum SharedStore {
    static let baseGroup = "group.org.hellupeptic.portal"
    static let statsURL = URL(string: "https://home.hellupeptic.org/api/widget/stats")!

    static let groupID: String? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String] else { return nil }
        return groups.first { $0.hasPrefix(baseGroup) }
    }()

    static var defaults: UserDefaults? { groupID.flatMap { UserDefaults(suiteName: $0) } }

    static var token: String? {
        get { defaults?.string(forKey: "widgetToken") }
        set { defaults?.set(newValue, forKey: "widgetToken") }
    }

    /// The app's login to the site (its site_session cookie), copied after
    /// each page load, which the share extension uploads with.
    static var sessionCookie: String? {
        get { defaults?.string(forKey: "sessionCookie") }
        set { defaults?.set(newValue, forKey: "sessionCookie") }
    }

    /// Whether the live panel is on, for its Control Center button.
    static var liveRunning: Bool {
        get { defaults?.bool(forKey: "liveRunning") ?? false }
        set { defaults?.set(newValue, forKey: "liveRunning") }
    }

    static var lastStats: ServerStats? {
        get {
            guard let data = defaults?.data(forKey: "lastStats") else { return nil }
            return try? JSONDecoder().decode(ServerStats.self, from: data)
        }
        set {
            defaults?.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "lastStats")
        }
    }
}
