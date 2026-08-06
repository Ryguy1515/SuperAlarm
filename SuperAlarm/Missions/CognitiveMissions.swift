import Foundation

// MARK: - Math

/// One arithmetic problem, e.g. `37 + 27 × 2`.
public struct MathProblem: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let terms: [Int]
    public let operators: [MathOperator]
    public let answer: Int

    /// The expression as shown to a half-awake user.
    public var display: String {
        var text = "\(terms[0])"
        for (index, op) in operators.enumerated() where index + 1 < terms.count {
            text += " \(op.symbol) \(terms[index + 1])"
        }
        return text
    }
}

public enum MathMission {
    /// Evaluates with normal precedence — multiplication binds tighter than
    /// addition and subtraction.
    public static func evaluate(terms: [Int], operators: [MathOperator]) -> Int {
        guard let first = terms.first else { return 0 }

        var values: [Int] = [first]
        var pending: [MathOperator] = []

        for (index, op) in operators.enumerated() where index + 1 < terms.count {
            let next = terms[index + 1]
            if op == .multiply {
                values[values.count - 1] *= next
            } else {
                pending.append(op)
                values.append(next)
            }
        }

        var result = values[0]
        for (index, op) in pending.enumerated() where index + 1 < values.count {
            switch op {
            case .add: result += values[index + 1]
            case .subtract: result -= values[index + 1]
            case .multiply: break
            }
        }
        return result
    }

    /// Builds a problem for the given difficulty. Retries until the answer is
    /// a sensible non-negative number that is not simply one of the operands.
    public static func generate(
        difficulty: MissionDifficulty,
        using generator: inout some RandomNumberGenerator
    ) -> MathProblem {
        let termCount = max(2, difficulty.mathTermCount)

        for _ in 0..<200 {
            var operators: [MathOperator] = []
            for _ in 0..<(termCount - 1) {
                operators.append(difficulty.mathOperators.randomElement(using: &generator) ?? .add)
            }

            var terms: [Int] = [Int.random(in: difficulty.mathOperandRange, using: &generator)]
            for op in operators {
                let range = op == .multiply ? difficulty.mathMultiplierRange : difficulty.mathOperandRange
                terms.append(Int.random(in: range, using: &generator))
            }

            let answer = evaluate(terms: terms, operators: operators)

            // Reject negatives, absurd magnitudes, and giveaways where the
            // answer is just one of the numbers on screen.
            guard answer >= 0, answer <= 99_999, !terms.contains(answer) else { continue }
            return MathProblem(terms: terms, operators: operators, answer: answer)
        }

        // Deterministic fallback so this can never fail to return.
        let terms = [12, 7]
        return MathProblem(terms: terms, operators: [.add], answer: 19)
    }

    public static func generate(difficulty: MissionDifficulty) -> MathProblem {
        var generator = SystemRandomNumberGenerator()
        return generate(difficulty: difficulty, using: &generator)
    }
}

// MARK: - Memory

/// One round of the memory mission: a grid with a subset of tiles lit.
public struct MemoryRound: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let gridSize: Int
    /// Indices into a `gridSize * gridSize` grid, row-major.
    public let litTiles: Set<Int>
    public let previewSeconds: Double

    public var tileCount: Int { gridSize * gridSize }
}

public enum MemoryMission {
    public static func generate(
        difficulty: MissionDifficulty,
        using generator: inout some RandomNumberGenerator
    ) -> MemoryRound {
        let size = difficulty.memoryGridSize
        let total = size * size
        let target = min(difficulty.memoryPatternLength, total - 1)

        var lit = Set<Int>()
        while lit.count < target {
            lit.insert(Int.random(in: 0..<total, using: &generator))
        }

        return MemoryRound(gridSize: size, litTiles: lit, previewSeconds: difficulty.memoryPreviewSeconds)
    }

    public static func generate(difficulty: MissionDifficulty) -> MemoryRound {
        var generator = SystemRandomNumberGenerator()
        return generate(difficulty: difficulty, using: &generator)
    }
}

// MARK: - Typing

/// A phrase the user has to reproduce exactly.
public struct TypingPhrase: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let text: String

    /// Comparison ignores leading/trailing whitespace and collapses runs of
    /// spaces, but is otherwise exact — including punctuation and case.
    public func matches(_ input: String) -> Bool {
        Self.normalise(input) == Self.normalise(text)
    }

    /// How much of the phrase has been typed correctly so far, 0...1. Drives
    /// the progress bar and turns the field red on the first wrong character.
    public func correctPrefixLength(of input: String) -> Int {
        let target = Array(text)
        let typed = Array(input)
        var count = 0
        while count < min(target.count, typed.count), target[count] == typed[count] {
            count += 1
        }
        return count
    }

    public func isPrefixValid(_ input: String) -> Bool {
        correctPrefixLength(of: input) == input.count
    }

    static func normalise(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}

public enum TypingMission {
    /// Short clauses assembled into a phrase of roughly the target length.
    /// Building phrases rather than storing whole sentences keeps them varied
    /// enough that they cannot be memorised over time.
    private static let openers = [
        "Get out of bed",
        "The morning is waiting",
        "Put both feet on the floor",
        "Stand up and stretch",
        "Today starts now",
        "Open the curtains",
        "Drink a glass of water",
        "No going back to sleep",
        "Move before you think",
        "The day will not wait",
        "Sit up straight",
        "Leave the pillow alone",
    ]

    private static let middles = [
        "and take a deep breath",
        "before the excuses arrive",
        "while the house is still quiet",
        "and put your shoes on",
        "then walk to the window",
        "because you set this alarm",
        "and let the light in",
        "before you change your mind",
        "and switch the kettle on",
        "while you still have time",
    ]

    private static let closers = [
        "you will be glad you did.",
        "the hard part is already over.",
        "this is the whole battle.",
        "nothing good happens under that duvet.",
        "you asked for this last night.",
        "future you is counting on it.",
        "momentum starts with standing up.",
        "the rest of the day follows from here.",
    ]

    public static func generate(
        difficulty: MissionDifficulty,
        using generator: inout some RandomNumberGenerator
    ) -> TypingPhrase {
        let target = difficulty.typingPhraseLength
        var parts: [String] = [openers.randomElement(using: &generator) ?? openers[0]]

        while parts.joined(separator: " ").count < target {
            if parts.count == 1 {
                parts.append(middles.randomElement(using: &generator) ?? middles[0])
            } else {
                parts.append(closers.randomElement(using: &generator) ?? closers[0])
                break
            }
        }

        var text = parts.joined(separator: " ")
        if !text.hasSuffix(".") { text += "." }
        return TypingPhrase(text: text)
    }

    public static func generate(difficulty: MissionDifficulty) -> TypingPhrase {
        var generator = SystemRandomNumberGenerator()
        return generate(difficulty: difficulty, using: &generator)
    }
}
