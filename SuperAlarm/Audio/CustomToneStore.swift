import Foundation
import AVFoundation
import Combine
import os.log

/// One piece of audio the user imported to use as an alarm sound.
public struct CustomToneRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// File name inside the custom sounds directory, extension included.
    public var fileName: String
    public var importedAt: Date
    public var duration: Double
}

/// Identifier helpers, kept outside the store so they are reachable from
/// non-main-actor code such as the notification scheduler.
public enum CustomTone {
    public static let prefix = "custom:"
    public static func isCustom(_ toneID: String) -> Bool { toneID.hasPrefix(prefix) }
    /// Directory imported audio lives in.
    public static var directory: URL {
        StorageLocation.rootURL.appendingPathComponent("CustomSounds", isDirectory: true)
    }
}

/// Backs the "My Music" tab of the sound picker.
///
/// Files are copied into the app's own container so the alarm never depends on
/// an external file still being there at 6am, and so playback needs no
/// security-scoped bookmark.
@MainActor
public final class CustomToneStore: ObservableObject {
    public static let shared = CustomToneStore()

    @Published public private(set) var records: [CustomToneRecord] = []

    private let files = JSONFileStore()
    private let indexFile = "custom-sounds.json"
    private let log = Logger(subsystem: "io.superalarm", category: "customtones")

    private init() {
        records = files.load([CustomToneRecord].self, from: indexFile) ?? []
        pruneMissingFiles()
    }

    // MARK: Locations

    public var directory: URL {
        let url = CustomTone.directory
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    public func url(forFileName fileName: String) -> URL {
        directory.appendingPathComponent(fileName)
    }

    // MARK: Access

    public var tones: [AlarmTone] {
        records.map(tone(from:))
    }

    public func tone(id: String) -> AlarmTone? {
        guard let record = records.first(where: { $0.id == id }) else { return nil }
        return tone(from: record)
    }

    private func tone(from record: CustomToneRecord) -> AlarmTone {
        AlarmTone(
            id: record.id,
            name: record.name,
            // Imported audio is not part of any built-in category; this value
            // is never used for grouping because custom tones live in their
            // own tab.
            category: .calm,
            fileName: record.fileName,
            isCustom: true
        )
    }

    // MARK: Import

    public enum ImportError: LocalizedError {
        case unreadable
        case unsupported
        case copyFailed

        public var errorDescription: String? {
            switch self {
            case .unreadable: return "That file could not be opened."
            case .unsupported: return "That audio format can't be played as an alarm."
            case .copyFailed: return "The file could not be saved into the app."
            }
        }
    }

    /// Copies an audio file in and registers it as a selectable tone.
    @discardableResult
    public func importFile(at sourceURL: URL, preferredName: String? = nil) throws -> AlarmTone {
        // Document-picker URLs need scoped access before they can be read.
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }

        guard FileManager.default.isReadableFile(atPath: sourceURL.path) else {
            throw ImportError.unreadable
        }

        let uuid = UUID().uuidString
        let ext = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension
        let fileName = "\(uuid).\(ext)"
        let destination = url(forFileName: fileName)

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destination)
        } catch {
            log.error("Custom tone copy failed: \(String(describing: error), privacy: .public)")
            throw ImportError.copyFailed
        }

        // Confirm it is actually playable before offering it as an alarm.
        guard let player = try? AVAudioPlayer(contentsOf: destination) else {
            try? FileManager.default.removeItem(at: destination)
            throw ImportError.unsupported
        }

        let name = preferredName
            ?? sourceURL.deletingPathExtension().lastPathComponent
        let record = CustomToneRecord(
            id: CustomTone.prefix + uuid,
            name: name.isEmpty ? "Imported sound" : name,
            fileName: fileName,
            importedAt: Date(),
            duration: player.duration
        )

        records.append(record)
        persist()
        log.info("Imported custom tone \(record.id, privacy: .public)")
        return tone(from: record)
    }

    public func rename(id: String, to newName: String) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].name = newName
        persist()
    }

    public func delete(id: String) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        let record = records.remove(at: index)
        try? FileManager.default.removeItem(at: url(forFileName: record.fileName))
        persist()
    }

    private func persist() {
        records.sort { $0.importedAt > $1.importedAt }
        files.save(records, to: indexFile)
    }

    /// Drops index entries whose file has gone missing, which can happen if
    /// the container is restored from a partial backup.
    private func pruneMissingFiles() {
        let before = records.count
        records.removeAll { !FileManager.default.fileExists(atPath: url(forFileName: $0.fileName).path) }
        if records.count != before { persist() }
    }
}
