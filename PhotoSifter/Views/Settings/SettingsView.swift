import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            ZStack {
                Color.appBackground.ignoresSafeArea()
                Form {
                    Section("Appearance") {
                        Picker("Appearance", selection: $settings.appearance) {
                            ForEach(AppearanceMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("appearancePicker")
                    }
                    .listRowBackground(Color.appCard)

                    Section {
                        Toggle(isOn: $settings.allowCloudDownload) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Download from iCloud")
                                    .foregroundStyle(.appForeground)
                                Text("Allow fetching photos not stored on this device")
                                    .font(.caption)
                                    .foregroundStyle(.appTextSecondary)
                            }
                        }
                        .tint(.appKeep)
                    }
                    .listRowBackground(Color.appCard)
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
