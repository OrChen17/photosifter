import SwiftUI

@main
struct PhotoSifterApp: App {
    @State private var libraryViewModel = LibraryViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(libraryViewModel)
                .preferredColorScheme(.dark)
                .onAppear { applyUITestingOverrides() }
                // Check (and if needed request) authorization automatically on
                // every launch so returning users never see PermissionView
                // when they've already granted access.
                .task { await libraryViewModel.checkAuthorization() }
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
