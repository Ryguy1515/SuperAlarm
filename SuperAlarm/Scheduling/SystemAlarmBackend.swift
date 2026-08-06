import Foundation

/// Chooses the strongest alarm mechanism this device supports.
///
/// iOS 26 introduced AlarmKit, which grants third-party apps the same alarm
/// privileges as the built-in Clock: alerts that sound through Silent mode and
/// Focus, and a real alarm UI on the Lock Screen. Below iOS 26 no such
/// mechanism exists, and the notification chain plus background audio in
/// `NotificationScheduler` and `AlarmAudioEngine` carry the load on their own.
public enum SystemAlarmBackendFactory {
    @MainActor
    public static func make() -> SystemAlarmBackend? {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            return AlarmKitBackend()
        }
        #endif
        return nil
    }
}
