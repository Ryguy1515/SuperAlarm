import Foundation
import Combine
import os.log

/// Owns every alarm, the app settings, and the wake-up history.
///
/// Persistence lives here; scheduling does not. When something changes that
/// affects when an alarm should fire, `onScheduleInvalidated` is called and
/// whoever wired it up rebuilds the schedule. That keeps this file free of any
/// UserNotifications or AlarmKit dependency.
@MainActor
public final class AlarmStore: ObservableObject {
    @Published public private(set) var alarms: [Alarm] = []
    @Published public var settings = AppSettings() { didSet { persistSettings() } }
    @Published public private(set) var history: [WakeRecord] = []

    /// Recomputed whenever history changes.
    @Published public private(set) var statistics = WakeStatistics()

    public var onScheduleInvalidated: (() -> Void)?

    private let files: JSONFileStore
    private let log = Logger(subsystem: "io.superalarm", category: "store")

    public init(files: JSONFileStore = JSONFileStore(), loadFromDisk: Bool = true) {
        self.files = files
        guard loadFromDisk else { return }
        alarms = files.load([Alarm].self, from: StorageLocation.alarmsFile) ?? []
        settings = files.load(AppSettings.self, from: StorageLocation.settingsFile) ?? AppSettings()
        history = files.load([WakeRecord].self, from: StorageLocation.historyFile) ?? []
        recomputeStatistics()
    }

    // MARK: Derived

    /// Alarms ordered the way the list screen shows them: enabled ones first
    /// by next fire time, then disabled ones by clock time.
    public var sortedAlarms: [Alarm] {
        let now = Date()
        return alarms.sorted { lhs, rhs in
            let lhsNext = lhs.isEnabled ? lhs.nextFireDate(after: now) : nil
            let rhsNext = rhs.isEnabled ? rhs.nextFireDate(after: now) : nil

            switch (lhsNext, rhsNext) {
            case let (l?, r?):
                return l == r ? lhs.createdAt < rhs.createdAt : l < r
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                let lhsMinutes = lhs.hour * 60 + lhs.minute
                let rhsMinutes = rhs.hour * 60 + rhs.minute
                return lhsMinutes == rhsMinutes ? lhs.createdAt < rhs.createdAt : lhsMinutes < rhsMinutes
            }
        }
    }

    public var enabledAlarms: [Alarm] { alarms.filter(\.isEnabled) }

    /// The single soonest upcoming alarm, if any.
    public var nextAlarm: (alarm: Alarm, date: Date)? {
        let now = Date()
        return alarms
            .filter(\.isEnabled)
            .compactMap { alarm -> (Alarm, Date)? in
                guard let date = alarm.nextFireDate(after: now) else { return nil }
                return (alarm, date)
            }
            .min { $0.1 < $1.1 }
            .map { (alarm: $0.0, date: $0.1) }
    }

    public func alarm(with id: UUID) -> Alarm? {
        alarms.first { $0.id == id }
    }

    // MARK: Mutations

    public func add(_ alarm: Alarm) {
        alarms.append(alarm)
        commit()
    }

    public func update(_ alarm: Alarm) {
        guard let index = alarms.firstIndex(where: { $0.id == alarm.id }) else {
            alarms.append(alarm)
            commit()
            return
        }
        alarms[index] = alarm
        commit()
    }

    public func delete(_ alarm: Alarm) {
        delete(id: alarm.id)
    }

    public func delete(id: UUID) {
        // Clean up any registered object-scan photo so assets do not leak.
        if let existing = alarms.first(where: { $0.id == id }),
           let assetID = existing.mission.objectImageID {
            MissionAssetStore.shared.deleteImage(id: assetID)
        }
        alarms.removeAll { $0.id == id }
        commit()
    }

    public func deleteAll() {
        for alarm in alarms {
            if let assetID = alarm.mission.objectImageID {
                MissionAssetStore.shared.deleteImage(id: assetID)
            }
        }
        alarms.removeAll()
        commit()
    }

    public func setEnabled(_ enabled: Bool, for id: UUID) {
        guard let index = alarms.firstIndex(where: { $0.id == id }) else { return }
        alarms[index].isEnabled = enabled
        // Re-enabling clears a pending skip; leaving it set would be confusing.
        if enabled { alarms[index].skipNextOccurrence = false }
        commit()
    }

    public func toggle(id: UUID) {
        guard let alarm = alarm(with: id) else { return }
        setEnabled(!alarm.isEnabled, for: id)
    }

    public func setSkipNext(_ skip: Bool, for id: UUID) {
        guard let index = alarms.firstIndex(where: { $0.id == id }) else { return }
        alarms[index].skipNextOccurrence = skip
        commit()
    }

    /// Marks an alarm as having just fired. One-shot alarms switch themselves
    /// off; repeating alarms clear any pending skip.
    public func markFired(id: UUID, at date: Date = Date()) {
        guard let index = alarms.firstIndex(where: { $0.id == id }) else { return }
        alarms[index].lastFiredAt = date
        if alarms[index].skipNextOccurrence {
            alarms[index].skipNextOccurrence = false
        }
        if !alarms[index].isRepeating {
            alarms[index].isEnabled = false
        }
        commit()
    }

    // MARK: History

    public func record(_ entry: WakeRecord) {
        history.append(entry)
        // A little over a year of history is plenty and keeps the file small.
        let cutoff = Calendar.current.date(byAdding: .day, value: -400, to: Date()) ?? .distantPast
        history.removeAll { $0.scheduledFor < cutoff }
        files.save(history, to: StorageLocation.historyFile)
        recomputeStatistics()
        writeWidgetSnapshot()
    }

    public func updateRecord(_ entry: WakeRecord) {
        guard let index = history.firstIndex(where: { $0.id == entry.id }) else {
            record(entry)
            return
        }
        history[index] = entry
        files.save(history, to: StorageLocation.historyFile)
        recomputeStatistics()
        writeWidgetSnapshot()
    }

    public func clearHistory() {
        history.removeAll()
        files.save(history, to: StorageLocation.historyFile)
        recomputeStatistics()
        writeWidgetSnapshot()
    }

    private func recomputeStatistics() {
        statistics = WakeStatistics(records: history)
    }

    // MARK: Persistence

    /// Saves, refreshes the widget payload, and asks the scheduler to rebuild.
    public func commit() {
        files.save(alarms, to: StorageLocation.alarmsFile)
        writeWidgetSnapshot()
        onScheduleInvalidated?()
    }

    private func persistSettings() {
        files.save(settings, to: StorageLocation.settingsFile)
    }

    /// Flush everything synchronously — called when the app is backgrounding.
    public func flush() {
        files.saveNow(alarms, to: StorageLocation.alarmsFile)
        files.saveNow(settings, to: StorageLocation.settingsFile)
        files.saveNow(history, to: StorageLocation.historyFile)
    }

    private func writeWidgetSnapshot() {
        let now = Date()
        let entries = alarms
            .filter(\.isEnabled)
            .compactMap { alarm -> (Alarm, Date)? in
                guard let date = alarm.nextFireDate(after: now) else { return nil }
                return (alarm, date)
            }
            .sorted { $0.1 < $1.1 }
            .prefix(5)
            .map { alarm, date in
                WidgetSnapshot.Entry(
                    id: alarm.id,
                    label: alarm.displayLabel,
                    fireDate: date,
                    missionSymbol: alarm.mission.type.symbolName,
                    missionName: alarm.mission.type.displayName,
                    colorHex: AlarmPalette.hex(for: alarm.colorTag),
                    repeatDescription: alarm.repeatDescription
                )
            }

        let snapshot = WidgetSnapshot(
            upcoming: Array(entries),
            enabledCount: alarms.filter(\.isEnabled).count,
            currentStreak: statistics.currentStreak
        )
        files.save(snapshot, to: StorageLocation.widgetSnapshotFile)
        WidgetRefresher.reload()
    }
}

// MARK: - Mission assets

/// Stores the reference photo for the object-scan mission on disk.
public final class MissionAssetStore: @unchecked Sendable {
    public static let shared = MissionAssetStore()

    private init() {}

    public func url(for id: String) -> URL {
        StorageLocation.missionAssetsURL.appendingPathComponent("\(id).jpg")
    }

    @discardableResult
    public func saveImageData(_ data: Data, id: String = UUID().uuidString) -> String? {
        do {
            try data.write(to: url(for: id), options: [.atomic])
            return id
        } catch {
            StorageLocation.log.error("Failed to save mission asset: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    public func imageData(id: String) -> Data? {
        try? Data(contentsOf: url(for: id))
    }

    public func deleteImage(id: String) {
        try? FileManager.default.removeItem(at: url(for: id))
    }
}
