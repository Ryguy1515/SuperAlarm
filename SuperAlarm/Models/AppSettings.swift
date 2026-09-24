import Foundation

// MARK: - Sleep sound settings

/// The bedtime player on the sleep screen: an ambient loop that fades out
/// after a set duration, or runs right up until the alarm.
public struct SleepSoundSettings: Codable, Hashable, Sendable {
    /// Nil means "None" is selected.
    public var soundID: String?
    /// Minutes to play before fading out. 0 = until the alarm rings.
    public var durationMinutes: Int = 30
    public var volume: Double = 0.6
    /// Fade the last 30 seconds so it does not stop abruptly.
    public var fadeOut: Bool = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        soundID = try? c.decodeIfPresent(String.self, forKey: .soundID)
        durationMinutes = c.decodeOr(.durationMinutes, 30)
        volume = c.decodeOr(.volume, 0.6)
        fadeOut = c.decodeOr(.fadeOut, true)
    }

    public var durationLabel: String {
        durationMinutes == 0 ? "Until alarm" : "\(durationMinutes)min"
    }
}

// MARK: - Theme

public enum AppTheme: String, Codable, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    public var symbolName: String {
        switch self {
        case .system: return "iphone"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }
}

// MARK: - Temperature unit

public enum TemperatureUnit: String, Codable, CaseIterable, Identifiable, Sendable {
    case celsius, fahrenheit

    public var id: String { rawValue }
    public var displayName: String { self == .celsius ? "Celsius (°C)" : "Fahrenheit (°F)" }
    public var symbol: String { self == .celsius ? "°C" : "°F" }
}

// MARK: - App settings

public struct AppSettings: Codable, Hashable, Sendable {
    // Presentation --------------------------------------------------------
    public var theme: AppTheme = .system
    public var use24HourClock: Bool = false
    /// Show the seconds hand and live clock on the alarm list header.
    public var showLiveClock: Bool = true
    public var hapticFeedback: Bool = true

    // Defaults applied to newly created alarms ----------------------------
    public var defaultSound = SoundSettings()
    public var defaultSnooze = SnoozeSettings()
    public var defaultMission = MissionSettings()
    public var defaultWakeUpCheck = WakeUpCheckSettings()

    // Guards ---------------------------------------------------------------
    /// Warn loudly and block the ring screen from being backgrounded while an
    /// alarm is going off. This is what stands in for the store listing's
    /// "app deletion prevention while alarm is ringing".
    public var deletionGuard: Bool = true
    /// Keep nagging with a full-screen takeover if the app is foregrounded
    /// while an alarm is unacknowledged.
    public var powerOffGuard: Bool = true
    /// Ignore the hardware volume buttons while ringing by restoring the
    /// system level whenever it is lowered.
    public var lockVolumeWhileRinging: Bool = true

    // Background behaviour --------------------------------------------------
    /// Hold the audio session open in the background so the app is still
    /// running when an alarm comes due. Only used when the system has no
    /// AlarmKit backend, and only close to an alarm — this is the setting that
    /// trades battery for reliability.
    public var backgroundKeepAlive: Bool = true
    /// How far ahead of an alarm the keep-alive loop starts.
    public var keepAliveWindowHours: Int = 12
    /// Schedule the notification chain even when the system alarm backend is
    /// active. On by default: it is the layer that keeps re-summoning the
    /// user after the app is force-quit. When system alarms are active the
    /// chain is offset so it does not double up with the first alert.
    public var redundantNotificationBackup: Bool = true

    // Weather --------------------------------------------------------------
    public var showWeather: Bool = true
    public var temperatureUnit: TemperatureUnit = .celsius

    // Sleep ---------------------------------------------------------------
    public var sleepSound = SleepSoundSettings()
    /// Nightly nudge to go to bed.
    public var bedtimeReminderEnabled: Bool = false
    public var bedtimeHour: Int = 23
    public var bedtimeMinute: Int = 0

    // Membership -----------------------------------------------------------
    /// Locally built copies are not attached to a store account, so every
    /// mission and feature is available. The paywall screen is still reachable
    /// from Settings so the flow can be seen.
    public var isPro: Bool = true

    // Onboarding -----------------------------------------------------------
    public var hasCompletedOnboarding: Bool = false
    /// Bumped when a migration needs to run.
    public var schemaVersion: Int = 1

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        theme = c.decodeOr(.theme, AppTheme.system)
        use24HourClock = c.decodeOr(.use24HourClock, false)
        showLiveClock = c.decodeOr(.showLiveClock, true)
        hapticFeedback = c.decodeOr(.hapticFeedback, true)
        defaultSound = c.decodeOr(.defaultSound, SoundSettings())
        defaultSnooze = c.decodeOr(.defaultSnooze, SnoozeSettings())
        defaultMission = c.decodeOr(.defaultMission, MissionSettings())
        defaultWakeUpCheck = c.decodeOr(.defaultWakeUpCheck, WakeUpCheckSettings())
        deletionGuard = c.decodeOr(.deletionGuard, true)
        powerOffGuard = c.decodeOr(.powerOffGuard, true)
        lockVolumeWhileRinging = c.decodeOr(.lockVolumeWhileRinging, true)
        backgroundKeepAlive = c.decodeOr(.backgroundKeepAlive, true)
        keepAliveWindowHours = c.decodeOr(.keepAliveWindowHours, 12)
        redundantNotificationBackup = c.decodeOr(.redundantNotificationBackup, true)
        showWeather = c.decodeOr(.showWeather, true)
        temperatureUnit = c.decodeOr(.temperatureUnit, TemperatureUnit.celsius)
        sleepSound = c.decodeOr(.sleepSound, SleepSoundSettings())
        bedtimeReminderEnabled = c.decodeOr(.bedtimeReminderEnabled, false)
        bedtimeHour = c.decodeOr(.bedtimeHour, 23)
        bedtimeMinute = c.decodeOr(.bedtimeMinute, 0)
        isPro = c.decodeOr(.isPro, true)
        hasCompletedOnboarding = c.decodeOr(.hasCompletedOnboarding, false)
        schemaVersion = c.decodeOr(.schemaVersion, 1)
    }

    /// Applies the stored defaults to a freshly created alarm.
    public func applyDefaults(to alarm: inout Alarm) {
        alarm.sound = defaultSound
        alarm.snooze = defaultSnooze
        alarm.mission = defaultMission
        alarm.wakeUpCheck = defaultWakeUpCheck
    }
}
