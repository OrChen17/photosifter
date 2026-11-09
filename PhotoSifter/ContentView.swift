import SwiftUI
import Photos

struct ContentView: View {
    @Environment(LibraryViewModel.self) private var vm

    private var isForcedDenied: Bool {
        ProcessInfo.processInfo.arguments.contains("FORCE_DENIED")
    }

    var body: some View {
        if isForcedDenied {
            DeniedView()
        } else {
            switch vm.authStatus {
            case .authorized, .limited:
                HomeView()
                    .tint(.appKeep)
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
                    .scaledFont(size: 56)
                    .foregroundStyle(.appTextSecondary)

                Text("Photo Access Denied")
                    .scaledFont(size: 24, weight: .bold, design: .rounded)
                    .foregroundStyle(.appForeground)

                Text("Open Settings → Privacy → Photos\nand allow access to FlickPic.")
                    .font(.system(.callout, design: .rounded))
                    .foregroundStyle(.appTextSecondary)
                    .multilineTextAlignment(.center)

                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.system(.callout, design: .rounded, weight: .semibold))
                .foregroundStyle(.appKeep)
            }
            .padding(32)
        }
    }
}
