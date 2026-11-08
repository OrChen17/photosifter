import SwiftUI
import Photos

@main
struct PhotoSifterApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var libraryViewModel = LibraryViewModel()
    @State private var appSettings = AppSettings()

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
