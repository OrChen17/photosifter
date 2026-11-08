import SwiftUI

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "System"
        case .light:  "Light"
        case .dark:   "Dark"
        }
    }

    var userInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light:  .light
        case .dark:   .dark
        }
    }
}

@Observable
final class AppSettings {
    private static let cloudKey = "allowCloudDownload"
    private static let appearanceKey = "appearanceMode"

    var allowCloudDownload: Bool {
        didSet { UserDefaults.standard.set(allowCloudDownload, forKey: Self.cloudKey) }
    }

    var appearance: AppearanceMode {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: Self.appearanceKey) }
    }

    init() {
        // Default true: most users have iCloud Photos with Optimize Storage, and
        // without network access the feature-print comparison silently fails for
        // any photo not locally cached.
        let stored = UserDefaults.standard.object(forKey: Self.cloudKey)
        allowCloudDownload = stored != nil ? UserDefaults.standard.bool(forKey: Self.cloudKey) : true

        let storedAppearance = UserDefaults.standard.string(forKey: Self.appearanceKey)
        appearance = storedAppearance.flatMap(AppearanceMode.init(rawValue:)) ?? .system
    }

    static var cloudDownloadEnabled: Bool {
        // Match the instance's default-true behaviour when the key has never been written.
        guard UserDefaults.standard.object(forKey: cloudKey) != nil else { return true }
        return UserDefaults.standard.bool(forKey: cloudKey)
    }
}
