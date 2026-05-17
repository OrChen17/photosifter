import SwiftUI

@main
struct PhotoSifterApp: App {
    @State private var libraryViewModel = LibraryViewModel()
    @State private var appSettings = AppSettings()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(libraryViewModel)
                .environment(appSettings)
                .preferredColorScheme(.dark)
                .onAppear { applyUITestingOverrides() }
                // If access was already granted, load immediately.
                // If not determined, PermissionView shows and the button triggers the request.
                .task {
                    if libraryViewModel.authStatus == .authorized || libraryViewModel.authStatus == .limited {
                        await libraryViewModel.load()
                    }
                }
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
