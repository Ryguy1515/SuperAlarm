import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Thin wrapper so the store can nudge the widget without importing WidgetKit
/// everywhere, and so builds without the widget extension still compile.
public enum WidgetRefresher {
    public static func reload() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}

/// Locates a bundled sound file regardless of whether the Sounds directory was
/// added to the target as a flat group or as a folder reference.
public enum SoundBundle {
    public static func url(forFileNamed fileName: String) -> URL? {
        let name = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension.isEmpty ? "wav" : (fileName as NSString).pathExtension

        if let url = Bundle.main.url(forResource: name, withExtension: ext) { return url }
        if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Sounds") { return url }
        if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Resources/Sounds") { return url }

        // Imported audio lives in the app container rather than the bundle.
        let imported = CustomTone.directory.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: imported.path) { return imported }

        return nil
    }

    /// True when every tone in the catalog is actually present in the bundle.
    /// Surfaced in the diagnostics screen so a packaging mistake is obvious.
    public static func missingTones() -> [String] {
        var missing: [String] = []
        for tone in SoundCatalog.all where url(forFileNamed: tone.fileName) == nil {
            missing.append(tone.fileName)
        }
        for sound in SleepSoundCatalog.all where url(forFileNamed: sound.fileName) == nil {
            missing.append(sound.fileName)
        }
        if url(forFileNamed: SoundCatalog.keepAliveFileName) == nil {
            missing.append(SoundCatalog.keepAliveFileName)
        }
        return missing
    }
}
