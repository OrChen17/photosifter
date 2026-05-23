import SwiftUI
import Photos

struct ContentView: View {
    @Environment(LibraryViewModel.self) private var vm
    @State private var selectedTab: Int = 0

    private var isForcedDenied: Bool {
        ProcessInfo.processInfo.arguments.contains("FORCE_DENIED")
    }

    var body: some View {
        if isForcedDenied {
            DeniedView()
        } else {
            switch vm.authStatus {
            case .authorized, .limited:
                TabView(selection: $selectedTab) {
                    LibraryView()
                        .tabItem { Label("Flick", systemImage: "photo.stack") }
                        .tag(0)
                    HistoryView()
                        .tabItem { Label("History", systemImage: "checkmark.circle.fill") }
                        .tag(1)
                }
                .tint(.appAccent)
            case .denied, .restricted:
                DeniedView()
            default:
                PermissionView {
                    await vm.checkAuthorization()
                }
            }
        }
    }
}

private struct DeniedView: View {
    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.appTextSecondary)

                Text("Photo Access Denied")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text("Open Settings → Privacy → Photos\nand allow access to FlickPic.")
                    .font(.system(size: 16, design: .rounded))
                    .foregroundStyle(.appTextSecondary)
                    .multilineTextAlignment(.center)

                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.appAccent)
            }
            .padding(32)
        }
    }
}
