import Foundation
import AVFoundation
import Combine

/// Speaks the time, date and forecast when an alarm goes off.
///
/// The alarm tone is ducked rather than paused while the briefing plays, so
/// the alarm never actually goes quiet.
@MainActor
public final class VoiceBriefing: NSObject, ObservableObject {
    public static let shared = VoiceBriefing()

    @Published public private(set) var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()
    private var repeatTimer: Timer?
    private var pendingText: String?
    private var rate: Double = 0.5

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Speaking

    public func speakBriefing(for alarm: Alarm, settings: AppSettings) {
        let text = Self.briefingText(for: alarm, settings: settings, weather: WeatherService.shared.snapshot)
        guard !text.isEmpty else { return }

        rate = alarm.voiceBriefing.speechRate
        pendingText = text
        speak(text)

        let interval = alarm.voiceBriefing.repeatIntervalSeconds
        if interval > 0 {
            let timer = Timer(timeInterval: TimeInterval(interval), repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let text = self.pendingText else { return }
                    self.speak(text)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            repeatTimer = timer
        }
    }

    /// Used by the preview button in the alarm editor.
    public func preview(for alarm: Alarm, settings: AppSettings) {
        let text = Self.briefingText(for: alarm, settings: settings, weather: WeatherService.shared.snapshot)
        rate = alarm.voiceBriefing.speechRate
        speak(text)
    }

    private func speak(_ text: String) {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier)
            ?? AVSpeechSynthesisVoice(language: "en-US")
        // AVSpeechUtterance rates are not linear; map 0...1 onto a usable band
        // around the default.
        let minRate = AVSpeechUtteranceMinimumSpeechRate
        let maxRate = AVSpeechUtteranceDefaultSpeechRate * 1.5
        utterance.rate = minRate + Float(max(0, min(1, rate))) * (maxRate - minRate)
        utterance.volume = 1.0
        utterance.preUtteranceDelay = 0.2

        synthesizer.speak(utterance)
    }

    public func stop() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        pendingText = nil
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
        AlarmAudioEngine.shared.setDucked(false)
    }

    // MARK: - Text

    /// Builds the spoken script from whichever pieces the alarm asked for.
    static func briefingText(for alarm: Alarm, settings: AppSettings, weather: WeatherSnapshot?) -> String {
        let config = alarm.voiceBriefing
        var parts: [String] = []

        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 4..<12: parts.append("Good morning.")
        case 12..<18: parts.append("Good afternoon.")
        default: parts.append("Good evening.")
        }

        if config.announceTime {
            let formatter = DateFormatter()
            formatter.dateFormat = settings.use24HourClock ? "HH:mm" : "h:mm a"
            parts.append("It's \(formatter.string(from: Date())).")
        }

        if config.announceDate {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE, MMMM d"
            parts.append("Today is \(formatter.string(from: Date())).")
        }

        if config.announceWeather, let weather {
            let unit = settings.temperatureUnit
            let degrees = weather.temperature(in: unit)
            let unitWord = unit == .celsius ? "degrees" : "degrees Fahrenheit"
            parts.append("It's currently \(degrees) \(unitWord) and \(weather.summary.lowercased()).")
            parts.append("Today's high is \(weather.high(in: unit)), with a low of \(weather.low(in: unit)).")
        }

        if config.announceLabel, !alarm.label.isEmpty {
            parts.append(alarm.label + ".")
        }

        if !alarm.memo.isEmpty {
            parts.append(alarm.memo)
        }

        return parts.joined(separator: " ")
    }
}

// MARK: - Delegate

extension VoiceBriefing: AVSpeechSynthesizerDelegate {
    public nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didStart utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            self.isSpeaking = true
            AlarmAudioEngine.shared.setDucked(true)
        }
    }

    public nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            self.isSpeaking = false
            AlarmAudioEngine.shared.setDucked(false)
        }
    }

    public nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            self.isSpeaking = false
            AlarmAudioEngine.shared.setDucked(false)
        }
    }
}
