import SwiftUI
import Photos
import PostHog

enum PostHogAppLogger {
    static func photoLibraryAccessRequested() {
        PostHogSDK.shared.logger?.info("photo library access requested")
    }

    static func libraryScanStarted(assetCount: Int) {
        PostHogSDK.shared.logger?.info(
            "photo library scan started",
            attributes: ["asset_count": assetCount]
        )
    }

    static func libraryScanCompleted(
        assetCount: Int,
        groupCount: Int,
        durationMs: Int,
        firstGroupMs: Int?,
        cloudSkippedCount: Int
    ) {
        var attributes: [String: Any] = [
            "asset_count": assetCount,
            "group_count": groupCount,
            "duration_ms": durationMs,
            "cloud_skipped_count": cloudSkippedCount,
        ]
        if let firstGroupMs { attributes["first_group_ms"] = firstGroupMs }
        PostHogSDK.shared.logger?.info("photo library scan completed", attributes: attributes)
    }
}

enum PostHogInfoKey: String {
    case projectToken = "PostHogProjectToken"
    case host = "PostHogHost"
}

enum PostHogBootstrap {
    private static let serviceName = "photosifter-ios"
    private static let uiTestingArgument = "UI_TESTING"
    private static let xcTestConfigurationKey = "XCTestConfigurationFilePath"
    private static let unexpandedBuildSettingPrefix = "$("

    static func start() {
        guard !isRunningTests else { return }
        guard let projectToken = infoValue(.projectToken), let host = infoValue(.host) else {
            #if DEBUG
            print("PostHog disabled: set the POSTHOG_PROJECT_TOKEN and POSTHOG_HOST build settings")
            #endif
            return
        }

        let config = PostHogConfig(projectToken: projectToken, host: host)
        config.errorTrackingConfig.autoCapture = true
        config.logs.serviceName = serviceName
        #if DEBUG
        config.logs.environment = "debug"
        #else
        config.logs.environment = "production"
        #endif
        PostHogSDK.shared.setup(config)
    }

    private static var isRunningTests: Bool {
        let process = ProcessInfo.processInfo
        return process.arguments.contains(uiTestingArgument)
            || process.environment[xcTestConfigurationKey] != nil
    }

    private static func infoValue(_ key: PostHogInfoKey) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key.rawValue) as? String,
              !value.isEmpty,
              !value.hasPrefix(unexpandedBuildSettingPrefix) else { return nil }
        return value
    }
}

@main
struct PhotoSifterApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var libraryViewModel = LibraryViewModel()
    @State private var appSettings = AppSettings()

    init() {
        PostHogBootstrap.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(libraryViewModel)
                .environment(appSettings)
                .onAppear { applyUITestingOverrides() }
                // Window-level override instead of .preferredColorScheme so UIKit-presented
                // UI (alerts, the iOS delete-confirmation sheet) follows the setting too.
                .onChange(of: appSettings.appearance, initial: true) { _, mode in
                    applyAppearance(mode)
                }
                // If access was already granted, load immediately.
                // If not determined, PermissionView shows and the button triggers the request.
                .task {
                    if libraryViewModel.authStatus == .authorized || libraryViewModel.authStatus == .limited {
                        await libraryViewModel.load()
                    }
                }
                // Re-check auth when returning from Settings so the denied→re-grant
                // warm-return flow works without a full relaunch.
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                    guard current != libraryViewModel.authStatus else { return }
                    libraryViewModel.authStatus = current
                    if current == .authorized || current == .limited {
                        Task { await libraryViewModel.load() }
                    }
                }
        }
    }

    private func applyAppearance(_ mode: AppearanceMode) {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        for window in windows {
            window.overrideUserInterfaceStyle = mode.userInterfaceStyle
        }
    }

    private func applyUITestingOverrides() {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("UI_TESTING") else { return }

        if args.contains("FORCE_EMPTY_LIBRARY") {
            libraryViewModel.groups = []
            libraryViewModel.isScanning = false
        }
    }
}
