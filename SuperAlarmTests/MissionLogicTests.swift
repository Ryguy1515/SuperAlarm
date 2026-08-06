import XCTest
@testable import SuperAlarm

final class MissionLogicTests: XCTestCase {

    // MARK: Math

    func testEvaluateRespectsOperatorPrecedence() {
        // 2 + 3 × 4 = 14, not 20.
        XCTAssertEqual(MathMission.evaluate(terms: [2, 3, 4], operators: [.add, .multiply]), 14)
        // 20 − 3 × 4 = 8.
        XCTAssertEqual(MathMission.evaluate(terms: [20, 3, 4], operators: [.subtract, .multiply]), 8)
        // 3 × 4 + 5 = 17.
        XCTAssertEqual(MathMission.evaluate(terms: [3, 4, 5], operators: [.multiply, .add]), 17)
        // Left-to-right for equal precedence: 20 − 5 − 3 = 12.
        XCTAssertEqual(MathMission.evaluate(terms: [20, 5, 3], operators: [.subtract, .subtract]), 12)
    }

    func testEvaluateHandlesSingleTerm() {
        XCTAssertEqual(MathMission.evaluate(terms: [7], operators: []), 7)
        XCTAssertEqual(MathMission.evaluate(terms: [], operators: []), 0)
    }

    func testGeneratedProblemsAreSolvableAndConsistent() {
        for difficulty in MissionDifficulty.allCases {
            for _ in 0..<300 {
                let problem = MathMission.generate(difficulty: difficulty)

                XCTAssertEqual(
                    problem.answer,
                    MathMission.evaluate(terms: problem.terms, operators: problem.operators),
                    "Stored answer disagrees with the expression for \(problem.display)"
                )
                XCTAssertGreaterThanOrEqual(problem.answer, 0, "Negative answers are hostile on a numeric pad")
                XCTAssertLessThanOrEqual(problem.answer, 99_999)
                XCTAssertFalse(
                    problem.terms.contains(problem.answer),
                    "The answer must not be visible in the question: \(problem.display)"
                )
                XCTAssertEqual(problem.terms.count, difficulty.mathTermCount)
                XCTAssertEqual(problem.operators.count, difficulty.mathTermCount - 1)
            }
        }
    }

    func testDifficultyActuallyEscalates() {
        XCTAssertLessThan(
            MissionDifficulty.veryEasy.mathOperandRange.upperBound,
            MissionDifficulty.veryHard.mathOperandRange.upperBound
        )
        XCTAssertEqual(MissionDifficulty.veryEasy.mathOperators, [.add])
        XCTAssertTrue(MissionDifficulty.veryHard.mathOperators.contains(.multiply))
        XCTAssertLessThanOrEqual(MissionDifficulty.veryEasy.mathTermCount, MissionDifficulty.veryHard.mathTermCount)
    }

    func testProblemDisplayReadsCorrectly() {
        let problem = MathProblem(terms: [12, 7], operators: [.add], answer: 19)
        XCTAssertEqual(problem.display, "12 + 7")

        let three = MathProblem(terms: [2, 3, 4], operators: [.subtract, .multiply], answer: -10)
        XCTAssertEqual(three.display, "2 − 3 × 4")
    }

    // MARK: Memory

    func testMemoryRoundsFitTheirGrid() {
        for difficulty in MissionDifficulty.allCases {
            for _ in 0..<200 {
                let round = MemoryMission.generate(difficulty: difficulty)
                let total = round.gridSize * round.gridSize

                XCTAssertEqual(round.gridSize, difficulty.memoryGridSize)
                XCTAssertEqual(round.tileCount, total)
                XCTAssertFalse(round.litTiles.isEmpty)
                XCTAssertLessThan(
                    round.litTiles.count, total,
                    "Lighting every tile would make the round trivial"
                )
                for index in round.litTiles {
                    XCTAssertTrue((0..<total).contains(index), "Tile \(index) is outside the grid")
                }
                XCTAssertGreaterThan(round.previewSeconds, 0)
            }
        }
    }

    func testHarderMemoryRoundsShowMoreTilesForLess() {
        XCTAssertLessThan(
            MissionDifficulty.veryEasy.memoryPatternLength,
            MissionDifficulty.veryHard.memoryPatternLength
        )
        XCTAssertGreaterThan(
            MissionDifficulty.veryEasy.memoryPreviewSeconds,
            MissionDifficulty.veryHard.memoryPreviewSeconds
        )
    }

    // MARK: Typing

    func testTypingPhraseMatchingIsForgivingOnlyAboutWhitespace() {
        let phrase = TypingPhrase(text: "Get out of bed.")

        XCTAssertTrue(phrase.matches("Get out of bed."))
        XCTAssertTrue(phrase.matches("  Get out of bed.  "), "Leading and trailing space should not matter")
        XCTAssertTrue(phrase.matches("Get  out   of bed."), "Repeated spaces should collapse")
        XCTAssertFalse(phrase.matches("get out of bed."), "Case must match")
        XCTAssertFalse(phrase.matches("Get out of bed"), "Punctuation must match")
        XCTAssertFalse(phrase.matches("Get out of the bed."))
    }

    func testTypingPrefixTrackingDrivesLiveFeedback() {
        let phrase = TypingPhrase(text: "Stand up")

        XCTAssertEqual(phrase.correctPrefixLength(of: ""), 0)
        XCTAssertEqual(phrase.correctPrefixLength(of: "Stan"), 4)
        XCTAssertEqual(phrase.correctPrefixLength(of: "Stand up"), 8)
        XCTAssertEqual(phrase.correctPrefixLength(of: "Stbnd"), 2)

        XCTAssertTrue(phrase.isPrefixValid("Stand"))
        XCTAssertFalse(phrase.isPrefixValid("Stond"))
        XCTAssertTrue(phrase.isPrefixValid(""))
    }

    func testGeneratedPhrasesScaleWithDifficulty() {
        for difficulty in MissionDifficulty.allCases {
            for _ in 0..<50 {
                let phrase = TypingMission.generate(difficulty: difficulty)
                XCTAssertFalse(phrase.text.isEmpty)
                XCTAssertTrue(phrase.text.hasSuffix("."), "Phrases should end cleanly")
                XCTAssertGreaterThanOrEqual(
                    phrase.text.count, min(10, difficulty.typingPhraseLength / 2),
                    "Phrase far shorter than the difficulty implies"
                )
            }
        }
    }

    // MARK: Mission settings

    func testMissionReadinessBlocksHalfConfiguredMissions() {
        var barcode = MissionSettings(type: .barcode)
        XCTAssertFalse(barcode.isReady, "A barcode mission with nothing registered must not be usable")
        barcode.barcodePayload = "0123456789"
        XCTAssertTrue(barcode.isReady)

        var object = MissionSettings(type: .objectScan)
        XCTAssertFalse(object.isReady)
        object.objectImageID = "abc"
        XCTAssertTrue(object.isReady)

        XCTAssertTrue(MissionSettings(type: .math).isReady)
        XCTAssertTrue(MissionSettings().isReady)
    }

    func testMissionDefaultsMatchTheirType() {
        XCTAssertEqual(MissionSettings(type: .walk).effectiveGoal, 500, "Walk should default to 500 steps")
        XCTAssertEqual(MissionSettings(type: .shake).effectiveGoal, 30)
        XCTAssertEqual(MissionSettings(type: .pushup).effectiveGoal, 10)
        XCTAssertEqual(MissionSettings(type: .squat).effectiveGoal, 10)
    }

    func testEveryMissionHasAnEscapeHatchByDefault() {
        // A mission that cannot be escaped is a phone that cannot be silenced.
        for type in MissionType.allCases {
            let settings = MissionSettings(type: type)
            XCTAssertGreaterThan(
                settings.escapeHatchAfterSeconds, 0,
                "\(type.displayName) has no escape hatch"
            )
        }
    }

    func testMissionCatalogueIsComplete() {
        // The nine missions the app advertises, plus typing.
        let expected: Set<MissionType> = [
            .math, .memory, .barcode, .objectScan, .faceID,
            .walk, .pushup, .squat, .shake, .typing,
        ]
        XCTAssertEqual(Set(MissionType.selectable), expected)
        XCTAssertFalse(MissionType.selectable.contains(.none))
    }

    func testMissionCapabilityFlagsAreCoherent() {
        XCTAssertTrue(MissionType.barcode.requiresCamera)
        XCTAssertTrue(MissionType.objectScan.requiresCamera)
        XCTAssertTrue(MissionType.walk.requiresMotion)
        XCTAssertTrue(MissionType.faceID.requiresBiometrics)

        // Anything needing registration must also declare a camera need.
        for type in MissionType.allCases where type.requiresSetup {
            XCTAssertTrue(type.requiresCamera, "\(type.displayName) needs setup but claims no camera")
        }

        // Counting missions must expose a sane stepper range.
        for type in MissionType.allCases where type.supportsGoalCount {
            let range = type.goalRange
            XCTAssertGreaterThan(range.step, 0)
            XCTAssertLessThan(range.min, range.max)
            XCTAssertTrue((range.min...range.max).contains(range.initial))
        }
    }

    // MARK: Session

    @MainActor
    func testSessionCompletesAfterEveryRound() {
        var settings = MissionSettings(type: .math)
        settings.rounds = 3
        let session = MissionSession(settings: settings)

        var completions = 0
        session.onComplete = { completions += 1 }

        XCTAssertEqual(session.currentRound, 1)
        session.passRound()
        XCTAssertFalse(session.isComplete)
        XCTAssertEqual(session.currentRound, 2)
        session.passRound()
        XCTAssertFalse(session.isComplete)
        session.passRound()

        XCTAssertTrue(session.isComplete)
        XCTAssertEqual(completions, 1)

        // Extra passes must not fire the callback again.
        session.passRound()
        XCTAssertEqual(completions, 1)
    }

    @MainActor
    func testSessionTracksFailures() {
        let session = MissionSession(settings: MissionSettings(type: .math))
        session.registerFailure()
        session.registerFailure()
        XCTAssertEqual(session.failures, 2)
    }

    @MainActor
    func testForceCompleteSatisfiesTheWholeSession() {
        var settings = MissionSettings(type: .memory)
        settings.rounds = 5
        let session = MissionSession(settings: settings)

        var completions = 0
        session.onComplete = { completions += 1 }
        session.forceComplete()

        XCTAssertTrue(session.isComplete)
        XCTAssertEqual(session.completedRounds, 5)
        XCTAssertEqual(completions, 1)
    }

    @MainActor
    func testRoundLabelOnlyAppearsForMultiRoundMissions() {
        let single = MissionSession(settings: MissionSettings(type: .math))
        XCTAssertNil(single.roundLabel)

        var settings = MissionSettings(type: .math)
        settings.rounds = 3
        let multi = MissionSession(settings: settings)
        XCTAssertEqual(multi.roundLabel, "Round 1 of 3")
    }

    // MARK: Tone resolution

    func testRandomToneIdentifiersRoundTrip() {
        for category in SoundCategory.allCases {
            let id = ToneResolver.randomID(for: category)
            XCTAssertTrue(ToneResolver.isRandom(id))
            XCTAssertEqual(ToneResolver.category(of: id), category)
            XCTAssertEqual(ToneResolver.displayName(for: id), "Random (\(category.displayName))")
        }
        XCTAssertFalse(ToneResolver.isRandom("air_raid"))
        XCTAssertNil(ToneResolver.category(of: "air_raid"))
    }

    func testBundledToneFallbackAlwaysResolvesToARealFile() {
        // Notification and AlarmKit sounds can only reference bundled files.
        let fromCustom = ToneResolver.bundledTone(for: "custom:whatever")
        XCTAssertFalse(fromCustom.isCustom)
        XCTAssertTrue(SoundCatalog.all.contains { $0.id == fromCustom.id })

        for category in SoundCategory.allCases {
            let tone = ToneResolver.bundledTone(for: ToneResolver.randomID(for: category))
            XCTAssertTrue(SoundCatalog.all.contains { $0.id == tone.id })
        }

        let unknown = ToneResolver.bundledTone(for: "does_not_exist")
        XCTAssertTrue(SoundCatalog.all.contains { $0.id == unknown.id })
    }

    func testSoundCatalogueIsPopulatedAndCategorised() {
        XCTAssertGreaterThanOrEqual(SoundCatalog.all.count, 24, "The library should be substantial")

        for category in SoundCategory.allCases {
            XCTAssertFalse(
                SoundCatalog.tones(in: category).isEmpty,
                "Category \(category.displayName) has no sounds"
            )
        }

        // Identifiers must be unique, or selection breaks.
        let ids = Set(SoundCatalog.all.map(\.id))
        XCTAssertEqual(ids.count, SoundCatalog.all.count)

        // Every tone must sit under the 30 s notification-sound ceiling.
        XCTAssertLessThan(SoundCatalog.toneDuration, 30)

        XCTAssertFalse(SleepSoundCatalog.all.isEmpty)
    }

    func testRandomToneAvoidsRepeatingTheLastOne() {
        let category = SoundCategory.noisy
        let pool = SoundCatalog.tones(in: category)
        guard pool.count > 1 else { return XCTFail("Need more than one tone to test exclusion") }

        for _ in 0..<50 {
            let picked = SoundCatalog.randomTone(in: category, excluding: pool[0].id)
            XCTAssertNotEqual(picked.id, pool[0].id)
        }
    }
}
