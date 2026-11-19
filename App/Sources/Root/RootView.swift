import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(TrackingController.self) private var tracking

    /// True while the night cover is on screen; the report waits until it has closed.
    @State private var coverVisible = false

    var body: some View {
        @Bindable var model = model
        Group {
            if settings.hasCompletedOnboarding {
                MainTabView()
                    // Real and demo data live in separate stores: rebuild the screens when switching.
                    .id(settings.demoMode)
            } else {
                OnboardingView()
            }
        }
        .fullScreenCover(isPresented: $model.isNightCoverPresented, onDismiss: {
            coverVisible = false
            model.presentCompletedReportIfNeeded()
        }) {
            NightContainerView()
                .environment(model)
                .environment(model.settings)
                .environment(model.tracking)
                .environment(model.alarms)
                .environment(model.relaxation)
                .environment(model.permissions)
                .preferredColorScheme(.dark)
                .onAppear { coverVisible = true }
        }
        .sheet(item: $model.reportRoute) { route in
            NavigationStack {
                ReportView(route: route)
            }
            .environment(model)
            .environment(model.settings)
            .environment(model.permissions)
            .modelContainer(model.store.container(demo: route.demo))
            .preferredColorScheme(model.settings.appearance.colorScheme)
        }
        .onChange(of: tracking.completedSessionID) { _, newValue in
            // Nights finished without the night screen (e.g. a recovered night) show their report
            // right away; otherwise the cover's onDismiss presents it.
            if newValue != nil && !coverVisible && !model.isNightCoverPresented {
                model.presentCompletedReportIfNeeded()
            }
        }
    }
}

/// Night screen while tracking; switches to the wake-up screen when the alarm rings.
struct NightContainerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            if model.showsWakeUp {
                WakeUpView()
                    .transition(.opacity)
            } else {
                NightModeView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.6), value: model.showsWakeUp)
    }
}

struct MainTabView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            NavigationStack { DashboardView() }
                .tabItem { Label("Today", systemImage: "moon.stars") }
                .tag(AppTab.today)
            NavigationStack { StatisticsView() }
                .tabItem { Label("Statistics", systemImage: "chart.bar.xaxis") }
                .tag(AppTab.statistics)
            NavigationStack { JournalView() }
                .tabItem { Label("Journal", systemImage: "book.closed") }
                .tag(AppTab.journal)
            NavigationStack { RelaxationView() }
                .tabItem { Label("Relax", systemImage: "headphones") }
                .tag(AppTab.relax)
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
    }
}

extension View {
    /// Shows the demo banner above the content while demo data is active.
    func demoBanner(_ visible: Bool) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            if visible { DemoBanner() }
        }
    }
}
