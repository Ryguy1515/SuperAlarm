import Foundation
import os.log

// MARK: - Storage locations

/// Resolves where app data lives.
///
/// When the App Group entitlement is available the container is shared with
/// the widget extension. Otherwise everything falls back to the app's own
/// Application Support directory, so a build signed with a free personal team
/// still works — free teams cannot use App Groups at all, and requesting one
/// would make signing fail outright. In that case the widget simply shows a
/// placeholder rather than live alarm data.
public enum StorageLocation {
    public static let appGroupID = "group.io.superalarm.shared"

    public static let log = Logger(subsystem: "io.superalarm", category: "storage")

    /// True when the App Group container is reachable.
    public static var hasSharedContainer: Bool { sharedContainerURL != nil }

    public static var sharedContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    /// Directory all persisted files are written to.
    public static var rootURL: URL {
        let base: URL
        if let shared = sharedContainerURL {
            base = shared
        } else {
            base = (try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        }
        let directory = base.appendingPathComponent("SuperAlarm", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    /// Where object-scan reference photos are kept.
    public static var missionAssetsURL: URL {
        let directory = rootURL.appendingPathComponent("MissionAssets", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    public static let alarmsFile = "alarms.json"
    public static let settingsFile = "settings.json"
    public static let historyFile = "history.json"
    /// Compact payload the widget reads.
    public static let widgetSnapshotFile = "widget-snapshot.json"
    /// State of an alarm that is mid-ring, so a relaunch can resume it.
    public static let ringStateFile = "ring-state.json"

    /// Shared defaults, used for small flags the widget also needs.
    ///
    /// Only the App Group suite when the container is actually reachable.
    /// Without the entitlement `UserDefaults(suiteName:)` does not return
    /// nil on a device — it returns a suite that detaches from the
    /// preferences daemon and forgets everything at the next launch. The
    /// AlarmKit bookkeeping lives here, so that would mean every launch
    /// scheduling a fresh set of system alarms it could never cancel again.
    public static var defaults: UserDefaults { resolvedDefaults }

    private static let resolvedDefaults: UserDefaults = {
        guard hasSharedContainer, let suite = UserDefaults(suiteName: appGroupID) else {
            return .standard
        }
        return suite
    }()
}

// MARK: - Disk IO

/// Small atomic JSON reader/writer. Writes go through a serial queue so the
/// UI never blocks, and land atomically so a crash mid-write cannot corrupt
/// a user's alarms.
public final class JSONFileStore: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.superalarm.filestore", qos: .utility)
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// ISO8601 with milliseconds. The stock `.iso8601` strategy truncates to
    /// whole seconds, so a date would not survive a write/read round trip —
    /// which matters because `createdAt` is the tiebreaker when two alarms
    /// are set for the same time.
    private static let isoWithMillis: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Fallback for anything written before milliseconds were kept.
    private static let isoWholeSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    public init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(JSONFileStore.isoWithMillis.string(from: date))
        }

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = JSONFileStore.isoWithMillis.date(from: text) { return date }
            if let date = JSONFileStore.isoWholeSeconds.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognised date format: \(text)"
            )
        }
    }

    public func load<T: Decodable>(_ type: T.Type, from fileName: String) -> T? {
        let url = StorageLocation.rootURL.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            StorageLocation.log.error(
                "Failed to decode \(fileName, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            // Keep the unreadable file around for diagnosis rather than
            // silently destroying data.
            let backup = url.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            return nil
        }
    }

    public func save<T: Encodable>(_ value: T, to fileName: String) {
        let url = StorageLocation.rootURL.appendingPathComponent(fileName)
        guard let data = try? encoder.encode(value) else {
            StorageLocation.log.error("Failed to encode \(fileName, privacy: .public)")
            return
        }
        queue.async {
            do {
                try data.write(to: url, options: [.atomic])
            } catch {
                StorageLocation.log.error(
                    "Failed to write \(fileName, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    /// Synchronous variant for use when the process is about to be suspended.
    public func saveNow<T: Encodable>(_ value: T, to fileName: String) {
        let url = StorageLocation.rootURL.appendingPathComponent(fileName)
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    public func delete(_ fileName: String) {
        let url = StorageLocation.rootURL.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Widget snapshot

/// Minimal data the widget needs, written every time alarms change.
public struct WidgetSnapshot: Codable, Sendable {
    public struct Entry: Codable, Sendable, Identifiable {
        public var id: UUID
        public var label: String
        public var fireDate: Date
        public var missionSymbol: String
        public var missionName: String
        public var colorHex: String
        public var repeatDescription: String

        public init(
            id: UUID, label: String, fireDate: Date, missionSymbol: String,
            missionName: String, colorHex: String, repeatDescription: String
        ) {
            self.id = id
            self.label = label
            self.fireDate = fireDate
            self.missionSymbol = missionSymbol
            self.missionName = missionName
            self.colorHex = colorHex
            self.repeatDescription = repeatDescription
        }
    }

    public var upcoming: [Entry]
    public var enabledCount: Int
    public var currentStreak: Int
    public var generatedAt: Date

    public init(upcoming: [Entry], enabledCount: Int, currentStreak: Int, generatedAt: Date = Date()) {
        self.upcoming = upcoming
        self.enabledCount = enabledCount
        self.currentStreak = currentStreak
        self.generatedAt = generatedAt
    }

    public static let empty = WidgetSnapshot(upcoming: [], enabledCount: 0, currentStreak: 0)

    /// Reads the snapshot the app last wrote. Returns nil when there is no
    /// shared container, which is what happens under free-team signing.
    public static func load(using files: JSONFileStore = JSONFileStore()) -> WidgetSnapshot? {
        files.load(WidgetSnapshot.self, from: StorageLocation.widgetSnapshotFile)
    }
}
