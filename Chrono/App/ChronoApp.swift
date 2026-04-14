import SwiftUI

@main
struct ChronoApp: App {
    @State private var store = ChronoStore()
    @State private var clock = LiveClock()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Warm up the haptic engines so the first tap after cold-launch has no
        // perceptible delay. The performance budget allows <16 ms tap latency,
        // and the generator's first-use warmup can exceed that on older devices.
        Haptics.prepare()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(clock)
                .task {
                    await store.bootstrap()
                    await store.replayPendingWidgetActions()
                    clock.start()
                }
                // Follow system light/dark per spec.
                .preferredColorScheme(nil)
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                // Reconcile any timer actions the user kicked off from a widget
                // while the app was suspended.
                Task {
                    await store.replayPendingWidgetActions()
                    await store.reloadAll()
                }
            case .background:
                // Refresh widget snapshot one last time before the process may be frozen.
                Task { await store.refreshWidgetSnapshot() }
            default:
                break
            }
        }
    }
}
