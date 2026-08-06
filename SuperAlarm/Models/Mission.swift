import Foundation

// MARK: - Mission type

/// Every way the app can make you prove you are actually awake before it will
/// stop ringing. Order matches the mission grid on the picker screen.
public enum MissionType: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case math
    case pushup
    case walk
    case faceID
    case objectScan
    case barcode
    case shake
    case memory
    case squat
    case typing

    public var id: String { rawValue }

    /// Everything except `.none`, in picker order.
    public static var selectable: [MissionType] {
        allCases.filter { $0 != .none }
    }

    public var displayName: String {
        switch self {
        case .none: return "None"
        case .math: return "Math"
        case .pushup: return "Push-up"
        case .walk: return "Walk"
        case .faceID: return "Face ID"
        case .objectScan: return "Object scan"
        case .barcode: return "QR/Barcode Scan"
        case .shake: return "Shake"
        case .memory: return "Memory"
        case .squat: return "Squat"
        case .typing: return "Typing"
        }
    }

    public var symbolName: String {
        switch self {
        case .none: return "moon.zzz.fill"
        case .math: return "plus.forwardslash.minus"
        case .pushup: return "figure.strengthtraining.functional"
        case .walk: return "figure.walk"
        case .faceID: return "faceid"
        case .objectScan: return "cube.transparent.fill"
        case .barcode: return "qrcode.viewfinder"
        case .shake: return "iphone.gen3.radiowaves.left.and.right"
        case .memory: return "square.grid.3x3.fill"
        case .squat: return "figure.cross.training"
        case .typing: return "keyboard.fill"
        }
    }

    /// One-line explanation shown under the tile on the picker.
    public var tagline: String {
        switch self {
        case .none: return "Turn the alarm off with a single slide."
        case .math: return "Solve arithmetic to shake off the fog."
        case .pushup: return "Do real push-ups. The phone counts them."
        case .walk: return "Get out of bed and take some steps."
        case .faceID: return "Scan your face to prove you sat up."
        case .objectScan: return "Photograph a registered object across the room."
        case .barcode: return "Scan a barcode you keep somewhere else."
        case .shake: return "Shake the phone until the counter fills."
        case .memory: return "Repeat a pattern from memory."
        case .squat: return "Complete real squats to stop the alarm."
        case .typing: return "Type a phrase exactly as shown."
        }
    }

    /// Longer copy for the mission detail screen.
    public var explanation: String {
        switch self {
        case .none:
            return "The alarm can be dismissed straight from the ring screen."
        case .math:
            return "Solve a set of arithmetic problems. Harder difficulties use larger numbers and more operations, which forces genuine mental effort rather than muscle memory."
        case .pushup:
            return "Hold the phone against your chest or place it on the floor beneath you. Motion sensors count each rep — half-reps do not register."
        case .walk:
            return "The step counter runs until you hit your goal. Leaving the bed is the entire point, so pick a number that gets you out of the room."
        case .faceID:
            return "Face ID requires your eyes open and your face square to the camera, which means actually sitting up."
        case .objectScan:
            return "Register a photo of something far from your bed — the bathroom mirror, the kettle, your pet. When the alarm rings you have to go photograph it again."
        case .barcode:
            return "Register any barcode or QR code — a shampoo bottle, a cereal box, a sticker on the fridge. You will have to walk to it to dismiss the alarm."
        case .shake:
            return "Shake the phone until the counter fills. Simple, physical, and impossible to do while lying still."
        case .memory:
            return "A pattern of tiles lights up. Reproduce it from memory. Larger grids and longer sequences make this genuinely demanding."
        case .squat:
            return "Keep the phone in a pocket or hold it to your chest. Motion sensors count full squats — depth matters."
        case .typing:
            return "Type the phrase exactly, including punctuation. Typos reset the current phrase."
        }
    }

    // MARK: Capability requirements

    public var requiresCamera: Bool { self == .objectScan || self == .barcode }
    public var requiresMotion: Bool { self == .walk || self == .pushup || self == .squat || self == .shake }
    public var requiresBiometrics: Bool { self == .faceID }
    /// Missions that need something registered ahead of time before they can
    /// be saved onto an alarm.
    public var requiresSetup: Bool { self == .objectScan || self == .barcode }

    public var supportsDifficulty: Bool { self == .math || self == .memory || self == .typing }
    public var supportsRounds: Bool { self == .math || self == .memory || self == .typing || self == .objectScan || self == .barcode }
    public var supportsGoalCount: Bool { self == .walk || self == .shake || self == .pushup || self == .squat }

    /// Label for the numeric goal stepper, e.g. "Steps to walk".
    public var goalLabel: String {
        switch self {
        case .walk: return "Steps to walk"
        case .shake: return "Times to shake"
        case .pushup: return "Push-ups to complete"
        case .squat: return "Squats to complete"
        default: return "Repetitions"
        }
    }

    public var goalTitle: String {
        switch self {
        case .walk: return "Set your step count goal"
        case .shake: return "Set your shake count goal"
        case .pushup: return "Set your push-up goal"
        case .squat: return "Set your squat goal"
        default: return "Set your goal"
        }
    }

    /// Default, minimum, maximum and step for the goal stepper.
    public var goalRange: (initial: Int, min: Int, max: Int, step: Int) {
        switch self {
        case .walk: return (500, 10, 5_000, 10)
        case .shake: return (30, 5, 300, 5)
        case .pushup: return (10, 1, 100, 1)
        case .squat: return (10, 1, 100, 1)
        default: return (1, 1, 50, 1)
        }
    }

    /// Missions available without a membership. Matches the shipping free tier.
    public static let freeTier: Set<MissionType> = [.none, .math, .faceID]

    public var isPremium: Bool { !MissionType.freeTier.contains(self) }
}

// MARK: - Difficulty

public enum MissionDifficulty: String, Codable, CaseIterable, Identifiable, Sendable {
    case veryEasy, easy, normal, hard, veryHard

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .veryEasy: return "Very easy"
        case .easy: return "Easy"
        case .normal: return "Normal"
        case .hard: return "Hard"
        case .veryHard: return "Very hard"
        }
    }

    /// 1...5, used to draw the difficulty pips.
    public var level: Int {
        switch self {
        case .veryEasy: return 1
        case .easy: return 2
        case .normal: return 3
        case .hard: return 4
        case .veryHard: return 5
        }
    }

    // MARK: Math parameters

    /// Operand range and permitted operators for the math mission.
    public var mathOperandRange: ClosedRange<Int> {
        switch self {
        case .veryEasy: return 1...9
        case .easy: return 10...49
        case .normal: return 10...99
        case .hard: return 12...99
        case .veryHard: return 15...199
        }
    }

    public var mathOperators: [MathOperator] {
        switch self {
        case .veryEasy: return [.add]
        case .easy: return [.add, .subtract]
        case .normal: return [.add, .subtract, .multiply]
        case .hard: return [.add, .subtract, .multiply]
        case .veryHard: return [.add, .subtract, .multiply]
        }
    }

    /// Number of terms in the expression, e.g. 3 gives "12 + 7 × 4".
    public var mathTermCount: Int {
        switch self {
        case .veryEasy, .easy: return 2
        case .normal: return 2
        case .hard: return 3
        case .veryHard: return 3
        }
    }

    /// Multiplication gets its own smaller range so answers stay reasonable.
    public var mathMultiplierRange: ClosedRange<Int> {
        switch self {
        case .veryEasy, .easy: return 2...5
        case .normal: return 2...9
        case .hard: return 3...12
        case .veryHard: return 6...19
        }
    }

    // MARK: Memory parameters

    /// Grid dimension for the memory mission.
    public var memoryGridSize: Int {
        switch self {
        case .veryEasy: return 3
        case .easy: return 3
        case .normal: return 4
        case .hard: return 4
        case .veryHard: return 5
        }
    }

    /// How many tiles light up in the pattern.
    public var memoryPatternLength: Int {
        switch self {
        case .veryEasy: return 3
        case .easy: return 4
        case .normal: return 5
        case .hard: return 7
        case .veryHard: return 9
        }
    }

    /// Seconds the pattern is visible before it hides.
    public var memoryPreviewSeconds: Double {
        switch self {
        case .veryEasy: return 3.0
        case .easy: return 2.5
        case .normal: return 2.2
        case .hard: return 1.8
        case .veryHard: return 1.5
        }
    }

    // MARK: Typing parameters

    /// Approximate character count of the phrase to type.
    public var typingPhraseLength: Int {
        switch self {
        case .veryEasy: return 12
        case .easy: return 22
        case .normal: return 38
        case .hard: return 60
        case .veryHard: return 90
        }
    }
}

public enum MathOperator: String, Codable, Sendable {
    case add, subtract, multiply

    public var symbol: String {
        switch self {
        case .add: return "+"
        case .subtract: return "−"
        case .multiply: return "×"
        }
    }
}

// MARK: - Mission settings

public struct MissionSettings: Codable, Hashable, Sendable {
    public var type: MissionType = .none
    public var difficulty: MissionDifficulty = .normal
    /// How many times the mission must be completed back to back.
    public var rounds: Int = 1
    /// Numeric target for counting missions (steps, shakes, reps).
    public var goal: Int = 0
    /// Abandon the mission and re-ring after this many seconds. 0 disables.
    public var timeLimitSeconds: Int = 0
    /// Offer the give-up escape hatch once the mission has been fought with
    /// for this long. Never below a sensible floor — a mission that cannot be
    /// escaped is a phone that cannot be silenced, which is the single most
    /// common complaint about apps in this category.
    public var escapeHatchAfterSeconds: Int = 120

    // Registered payloads --------------------------------------------------

    /// The exact barcode/QR string that must be scanned.
    public var barcodePayload: String?
    /// Friendly name shown in the editor, e.g. "Shampoo bottle".
    public var barcodeLabel: String?
    /// File name of the reference photo stored in Application Support.
    public var objectImageID: String?
    /// Friendly name for the registered object, e.g. "Kettle".
    public var objectLabel: String?

    public init() {}

    public init(type: MissionType) {
        self.type = type
        self.goal = type.goalRange.initial
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = c.decodeOr(.type, MissionType.none)
        difficulty = c.decodeOr(.difficulty, MissionDifficulty.normal)
        rounds = max(1, c.decodeOr(.rounds, 1))
        goal = c.decodeOr(.goal, 0)
        timeLimitSeconds = c.decodeOr(.timeLimitSeconds, 0)
        escapeHatchAfterSeconds = c.decodeOr(.escapeHatchAfterSeconds, 120)
        barcodePayload = try? c.decodeIfPresent(String.self, forKey: .barcodePayload)
        barcodeLabel = try? c.decodeIfPresent(String.self, forKey: .barcodeLabel)
        objectImageID = try? c.decodeIfPresent(String.self, forKey: .objectImageID)
        objectLabel = try? c.decodeIfPresent(String.self, forKey: .objectLabel)
    }

    /// Effective goal, falling back to the type's default if unset.
    public var effectiveGoal: Int {
        goal > 0 ? goal : type.goalRange.initial
    }

    /// True when the mission is configured enough to actually run.
    public var isReady: Bool {
        switch type {
        case .barcode: return !(barcodePayload ?? "").isEmpty
        case .objectScan: return !(objectImageID ?? "").isEmpty
        default: return true
        }
    }

    /// Short description for the alarm editor row, e.g. "Math · Hard · 3×".
    public var summary: String {
        guard type != .none else { return "None" }
        var parts: [String] = [type.displayName]
        if type.supportsDifficulty { parts.append(difficulty.displayName) }
        if type.supportsGoalCount {
            let unit: String
            switch type {
            case .walk: unit = "steps"
            case .shake: unit = "shakes"
            default: unit = "reps"
            }
            parts.append("\(effectiveGoal) \(unit)")
        }
        if type.supportsRounds && rounds > 1 { parts.append("\(rounds)×") }
        return parts.joined(separator: " · ")
    }

    public static let roundOptions: [Int] = [1, 2, 3, 4, 5, 10]
    public static let timeLimitOptions: [Int] = [0, 30, 60, 120, 180, 300]
    public static let escapeHatchOptions: [Int] = [60, 120, 180, 300, 600]

    /// Phrase the user must type to abandon a mission. Deliberately tedious
    /// enough that it is not the easy route, but always available.
    public static let escapeHatchPhrase = "I give up"
}
