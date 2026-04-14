import SwiftUI

struct RootView: View {
    @Environment(ChronoStore.self) private var store
    @State private var selectedTab: Tab = .track
    @State private var showingSettings = false

    enum Tab: Hashable { case track, timeline, stats }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                TrackView(onOpenSettings: { showingSettings = true })
            }
            .tabItem { Label("Track", systemImage: "timer") }
            .tag(Tab.track)

            NavigationStack {
                TimelineView()
            }
            .tabItem { Label("Timeline", systemImage: "chart.bar.doc.horizontal") }
            .tag(Tab.timeline)

            NavigationStack {
                StatsView()
            }
            .tabItem { Label("Stats", systemImage: "chart.pie") }
            .tag(Tab.stats)
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SettingsView()
            }
        }
        .alert("Error", isPresented: errorBinding, presenting: store.lastError) { _ in
            Button("OK") { store.lastError = nil }
        } message: { message in
            Text(message)
        }
        .onChange(of: store.runningEntry) { _, new in
            let category = store.category(new?.categoryId)
            LiveActivityController.syncWith(runningEntry: new, category: category)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )
    }
}
