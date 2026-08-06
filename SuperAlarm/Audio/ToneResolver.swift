import Foundation

/// Resolves a stored tone identifier to an actual tone.
///
/// Beyond plain identifiers this understands the "Random" entries that sit at
/// the top of each sound category. Randomising the tone is the app's answer to
/// habituation: a sound you hear every morning for a month stops waking you.
public enum ToneResolver {
    public static let randomPrefix = "random:"

    /// Identifier stored on an alarm when the user picks "Random" in a category.
    public static func randomID(for category: SoundCategory) -> String {
        randomPrefix + category.rawValue
    }

    public static func isRandom(_ toneID: String) -> Bool {
        toneID.hasPrefix(randomPrefix)
    }

    /// The category a random identifier refers to, if it is one.
    public static func category(of toneID: String) -> SoundCategory? {
        guard isRandom(toneID) else { return nil }
        let raw = String(toneID.dropFirst(randomPrefix.count))
        return SoundCategory(rawValue: raw)
    }

    /// Picks the tone to actually play. `lastPlayed` is avoided where possible
    /// so the same random sound does not come up twice running.
    @MainActor
    public static func resolve(_ toneID: String, lastPlayed: String? = nil) -> AlarmTone {
        if CustomTone.isCustom(toneID), let imported = CustomToneStore.shared.tone(id: toneID) {
            return imported
        }
        if let category = category(of: toneID) {
            return SoundCatalog.randomTone(in: category, excluding: lastPlayed)
        }
        return SoundCatalog.tone(id: toneID)
    }

    /// Name shown in the alarm editor for a stored identifier.
    @MainActor
    public static func displayName(for toneID: String) -> String {
        if let category = category(of: toneID) {
            return "Random (\(category.displayName))"
        }
        if CustomTone.isCustom(toneID) {
            return CustomToneStore.shared.tone(id: toneID)?.name ?? "Imported sound"
        }
        return SoundCatalog.tone(id: toneID).name
    }

    /// A tone guaranteed to exist inside the app bundle.
    ///
    /// Notification sounds and AlarmKit alerts can only reference bundled
    /// resources, so imported audio has to fall back to a built-in tone in
    /// those contexts — it still plays correctly through the app's own audio
    /// engine once the alarm is handed over.
    public static func bundledTone(for toneID: String) -> AlarmTone {
        if CustomTone.isCustom(toneID) {
            return SoundCatalog.tone(id: SoundCatalog.defaultToneID)
        }
        if let category = category(of: toneID) {
            return SoundCatalog.tones(in: category).first
                ?? SoundCatalog.tone(id: SoundCatalog.defaultToneID)
        }
        return SoundCatalog.tone(id: toneID)
    }
}
