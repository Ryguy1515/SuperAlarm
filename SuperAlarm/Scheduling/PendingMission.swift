import Foundation

/// Hand-off between an App Intent and the app itself.
///
/// When the user taps the alarm's "Turn off" button, the intent runs, silences
/// the system alarm and foregrounds the app. The intent and the app are the
/// same process but not the same object graph, so the alarm to resume is left
/// here — persisted, because the app may be launched cold by the intent.
public final class PendingMission: @unchecked Sendable {
    public static let shared = PendingMission()

    private let alarmKey = "pendingMission.alarmID"
    private let dateKey = "pendingMission.firedAt"
    private let defaults = StorageLocation.defaults

    private init() {}

    /// The alarm whose mission should be shown as soon as the app is up.
    public var armedAlarmID: UUID? {
        get {
            guard let raw = defaults.string(forKey: alarmKey) else { return nil }
            return UUID(uuidString: raw)
        }
        set {
            if let newValue {
                defaults.set(newValue.uuidString, forKey: alarmKey)
                defaults.set(Date().timeIntervalSince1970, forKey: dateKey)
            } else {
                defaults.removeObject(forKey: alarmKey)
                defaults.removeObject(forKey: dateKey)
            }
        }
    }

    public var armedAt: Date? {
        let seconds = defaults.double(forKey: dateKey)
        return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
    }

    public func arm(alarmID: UUID) {
        armedAlarmID = alarmID
    }

    /// Consumes the pending mission, if there is a recent one. Anything older
    /// than the window is stale — the user opened the app much later — and is
    /// discarded rather than firing an alarm out of nowhere.
    public func consume(within window: TimeInterval = 60 * 60) -> UUID? {
        guard let id = armedAlarmID else { return nil }
        defer { armedAlarmID = nil }
        guard let armedAt, Date().timeIntervalSince(armedAt) <= window else { return nil }
        return id
    }

    public func clear() {
        armedAlarmID = nil
    }
}
