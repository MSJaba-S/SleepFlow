import SwiftData
import SwiftUI

@main
struct SleepFlowApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(model.settings)
                .environment(model.tracking)
                .environment(model.alarms)
                .environment(model.relaxation)
                .environment(model.permissions)
                .modelContainer(model.activeContainer)
                .preferredColorScheme(model.settings.appearance.colorScheme)
                .tint(Theme.accent)
                .task { await model.onLaunch() }
        }
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(phase)
        }
    }
}
