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
    static let defaultAllowCloudDownload = false

    var allowCloudDownload: Bool {
        didSet { UserDefaults.standard.set(allowCloudDownload, forKey: Self.cloudKey) }
    }

    var appearance: AppearanceMode {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: Self.appearanceKey) }
    }

    init() {
        let stored = UserDefaults.standard.object(forKey: Self.cloudKey)
        allowCloudDownload = stored != nil ? UserDefaults.standard.bool(forKey: Self.cloudKey) : Self.defaultAllowCloudDownload

        let storedAppearance = UserDefaults.standard.string(forKey: Self.appearanceKey)
        appearance = storedAppearance.flatMap(AppearanceMode.init(rawValue:)) ?? .system
    }

    static var cloudDownloadEnabled: Bool {
        guard UserDefaults.standard.object(forKey: cloudKey) != nil else { return defaultAllowCloudDownload }
        return UserDefaults.standard.bool(forKey: cloudKey)
    }
}
