import Foundation

@Observable
final class AppSettings {
    private static let cloudKey = "allowCloudDownload"

    var allowCloudDownload: Bool {
        didSet { UserDefaults.standard.set(allowCloudDownload, forKey: Self.cloudKey) }
    }

    init() {
        // Default true: most users have iCloud Photos with Optimize Storage, and
        // without network access the feature-print comparison silently fails for
        // any photo not locally cached.
        let stored = UserDefaults.standard.object(forKey: Self.cloudKey)
        allowCloudDownload = stored != nil ? UserDefaults.standard.bool(forKey: Self.cloudKey) : true
    }

    static var cloudDownloadEnabled: Bool {
        // Match the instance's default-true behaviour when the key has never been written.
        guard UserDefaults.standard.object(forKey: cloudKey) != nil else { return true }
        return UserDefaults.standard.bool(forKey: cloudKey)
    }
}
