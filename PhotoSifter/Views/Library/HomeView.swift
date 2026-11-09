import SwiftUI

/// App root. Flick Forever fills the screen; everything else lives in the
/// menu on the top left and is pushed (History, Quick Wins) or shown as a
/// sheet (Settings).
struct HomeView: View {
    @Environment(LibraryViewModel.self) private var vm
    @Environment(AppSettings.self) private var appSettings
    @State private var sweepVM = SweepSifterViewModel(groups: [])
    @State private var showingHistory = false
    @State private var showingSettings = false

    var body: some View {
        @Bindable var vm = vm
        NavigationStack {
            SweepSifterView(vm: sweepVM, onOpenHistory: openHistory)
                .id(ObjectIdentifier(sweepVM))
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { menu }
                }
                .navigationDestination(isPresented: $showingHistory) {
                    HistoryView()
                }
                .navigationDestination(item: $vm.selectedQuickWin) { win in
                    SifterView(group: win.group, mode: .screenshots)
                }
                .navigationDestination(item: $vm.selectedDuplicateSession) { session in
                    DuplicateGroupSifterView(groups: session.groups)
                }
                .sheet(isPresented: $showingSettings) {
                    SettingsView()
                        .environment(appSettings)
                        .presentationDetents([.medium])
                }
        }
    }

    // MARK: - Menu

    private var menu: some View {
        Menu {
            Section {
                Button(action: openHistory) {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
            }

            let categories = QuickWinCategory.allCases.filter { vm.quickWinPhotoCount($0) > 0 }
            if !categories.isEmpty {
                Section("Quick Wins") {
                    ForEach(categories, id: \.self) { category in
                        Button { vm.openQuickWin(category) } label: {
                            Label(category.label, systemImage: category.systemImage)
                            Text("\(vm.quickWinPhotoCount(category)) photos")
                        }
                    }
                }
            }

            Section {
                Picker(selection: sortOrderBinding) {
                    ForEach(GroupSortOrder.allCases, id: \.self) { order in
                        Text(order.label).tag(order)
                    }
                } label: {
                    Label("Order", systemImage: "arrow.up.arrow.down")
                    Text(sweepVM.hasPendingDecisions ? "Apply first to reorder" : vm.sortOrder.label)
                }
                .pickerStyle(.menu)
                .disabled(sweepVM.hasPendingDecisions)

                Button { showingSettings = true } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        } label: {
            menuLabel
        }
        .accessibilityLabel("Menu")
        .accessibilityIdentifier("menuButton")
    }

    @ViewBuilder
    private var menuLabel: some View {
        let icon = Image(systemName: "line.3.horizontal")
            .font(.system(.body, weight: .semibold))
            .foregroundStyle(.appForeground)
            .overlay(alignment: .topTrailing) {
                if !vm.quickWins.isEmpty {
                    Circle()
                        .fill(.appKeep)
                        .frame(width: 7, height: 7)
                        .offset(x: 5, y: -4)
                }
            }
        if #available(iOS 26.0, *) {
            icon
        } else {
            icon
                .frame(width: 36, height: 36)
                .appGlass(in: Circle(), interactive: false)
        }
    }

    private var sortOrderBinding: Binding<GroupSortOrder> {
        Binding(
            get: { vm.sortOrder },
            set: { order in
                guard order != vm.sortOrder, !sweepVM.hasPendingDecisions else { return }
                vm.sortOrder = order
                vm.applySort()
                sweepVM = SweepSifterViewModel(groups: vm.groups)
            }
        )
    }

    private func openHistory() {
        HapticManager.shared.playNavigate()
        showingHistory = true
    }
}
