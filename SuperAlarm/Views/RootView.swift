import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AlarmStore
    @EnvironmentObject private var runtime: AlarmRuntime

    @State private var selectedTab: Tab = .alarms
    /// Fonts are computed from the current text size when a body runs;
    /// rebuilding the tree on a change is what makes a new size take effect.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    enum Tab: Hashable {
        case alarms, sleep, stats, settings
    }

    var body: some View {
        Group {
            if store.settings.hasCompletedOnboarding {
                mainInterface
            } else {
                OnboardingView()
            }
        }
        // The ring screen is a takeover: it cannot be swiped away, and any
        // attempt to leave the app puts it straight back on screen.
        .id(dynamicTypeSize)
        .fullScreenCover(isPresented: ringPresentation) {
            RingContainerView()
                .environmentObject(store)
                .environmentObject(runtime)
                .interactiveDismissDisabled(true)
                // Big is good on the ring screen, but the clock and counters
                // must still fit; the largest accessibility sizes are capped.
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        }
    }

    private var ringPresentation: Binding<Bool> {
        Binding(get: { runtime.isPresenting }, set: { _ in })
    }

    private var mainInterface: some View {
        TabView(selection: $selectedTab) {
            AlarmListView()
                .tabItem { Label("Alarms", systemImage: "alarm.fill") }
                .tag(Tab.alarms)

            SleepView()
                .tabItem { Label("Sleep", systemImage: "moon.stars.fill") }
                .tag(Tab.sleep)

            StatsView()
                .tabItem { Label("Stats", systemImage: "chart.bar.fill") }
                .tag(Tab.stats)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(Tab.settings)
        }
        .tint(SAColor.accent)
    }
}
