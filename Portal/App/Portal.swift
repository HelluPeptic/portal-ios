import UIKit

/// Where the site lives and what the app looks like.
enum Portal {
    static let siteURL = URL(string: "https://home.hellupeptic.org/")!
    static let siteHost = "home.hellupeptic.org"
    static let appPageURL = URL(string: "https://home.hellupeptic.org/app")!
    static let appInfoURL = URL(string: "https://home.hellupeptic.org/app/info.json")!
    static let sideStoreURL = URL(string: "sidestore://")!

    static func isSite(_ url: URL?) -> Bool {
        url?.host?.lowercased() == siteHost
    }
}

extension UIColor {
    static let portalBackground = UIColor(red: 0x16 / 255, green: 0x13 / 255, blue: 0x0f / 255, alpha: 1)
    static let portalElevated = UIColor(red: 0x21 / 255, green: 0x1c / 255, blue: 0x19 / 255, alpha: 1)
    static let portalBorder = UIColor(red: 0x3a / 255, green: 0x33 / 255, blue: 0x2c / 255, alpha: 1)
    static let portalText = UIColor(red: 0xf3 / 255, green: 0xef / 255, blue: 0xe9 / 255, alpha: 1)
    static let portalTextDim = UIColor(red: 0xa8 / 255, green: 0x9e / 255, blue: 0x93 / 255, alpha: 1)
    static let portalAccent = UIColor(red: 1, green: 0x6b / 255, blue: 0x6b / 255, alpha: 1)
}

/// The app's own version, and when its signature runs out.
enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    static var build: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    }

    /// SideStore signs the app with a free Apple ID, which is only good for
    /// 7 days; the date is in the provisioning profile it embeds. That file
    /// is a signed blob with a plain XML plist inside.
    static let expiryDate: Date? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else {
            return nil
        }
        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        return plist?["ExpirationDate"] as? Date
    }()
}
