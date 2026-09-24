import SwiftUI
import UserNotifications
import os.log

@main
struct SuperAlarmApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var store = AlarmStore()
    @StateObject private var runtime = AlarmRuntime()
    @StateObject private var coordinator = AlarmCoordinator.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(runtime)
                .environmentObject(coordinator)
                .preferredColorScheme(store.settings.theme.colorScheme)
                .tint(SAColor.accent)
                .task { await bootstrap() }
        }
    }

    @MainActor
    private func bootstrap() async {
        // The store owns persistence; the coordinator owns scheduling. Wiring
        // them with a closure keeps the store free of any scheduling imports.
        store.onScheduleInvalidated = { [weak store] in
            guard let store else { return }
            AlarmCoordinator.shared.rebuild(alarms: store.alarms, settings: store.settings)
        }

        appDelegate.runtime = runtime
        appDelegate.store = store

        HapticEngine.shared.uiFeedbackEnabled = store.settings.hapticFeedback

        // The hidden volume slider is vended asynchronously after joining a
        // window; attaching it now means it is ready long before any alarm.
        SystemVolume.shared.prepare()

        runtime.bootstrap(store: store)

        await coordinator.refreshAuthorizationStatus()
        if store.settings.hasCompletedOnboarding {
            await coordinator.rebuildNow(alarms: store.alarms, settings: store.settings)
        }

        if store.settings.showWeather {
            await WeatherService.shared.refreshIfNeeded()
        }
    }
}

extension AppTheme {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
