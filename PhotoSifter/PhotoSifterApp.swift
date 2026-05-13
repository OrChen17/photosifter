import SwiftUI

@main
struct PhotoSifterApp: App {
    @State private var libraryViewModel = LibraryViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(libraryViewModel)
                .preferredColorScheme(.dark)
        }
    }
}
