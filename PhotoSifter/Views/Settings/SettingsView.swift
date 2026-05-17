import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            ZStack {
                Color.appBackground.ignoresSafeArea()
                Form {
                    Section {
                        Toggle(isOn: $settings.allowCloudDownload) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Download from iCloud")
                                    .foregroundStyle(.white)
                                Text("Allow fetching photos not stored on this device")
                                    .font(.caption)
                                    .foregroundStyle(.appTextSecondary)
                            }
                        }
                        .tint(.appAccent)
                    }
                    .listRowBackground(Color.appCard)
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }
}
