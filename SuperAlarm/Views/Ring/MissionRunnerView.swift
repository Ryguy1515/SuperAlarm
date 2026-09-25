import SwiftUI
import Combine

/// Hosts whichever mission an alarm is configured with, tracks rounds, and
/// owns the escape hatch.
struct MissionRunnerView: View {
    let settings: MissionSettings
    var isPreview: Bool = false
    var onComplete: () -> Void
    var onGiveUp: () -> Void
    /// The configured time limit ran out. Distinct from giving up: the alarm
    /// goes back to ringing, it does not stop.
    var onTimeout: () -> Void
    /// Called with the new total after every passed round.
    var onProgress: ((Int) -> Void)?
    /// Called on every wrong answer.
    var onFailure: (() -> Void)?

    @StateObject private var session: MissionSession
    @State private var elapsed: Int = 0
    @State private var showingEscapeHatch = false

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// - Parameters:
    ///   - startedAt: when the mission originally began. After a relaunch
    ///     this is the persisted start, so elapsed time and step counts resume.
    ///   - completedRounds: rounds already passed before a relaunch.
    init(
        settings: MissionSettings,
        isPreview: Bool = false,
        startedAt: Date = Date(),
        completedRounds: Int = 0,
        onComplete: @escaping () -> Void,
        onGiveUp: @escaping () -> Void,
        onTimeout: @escaping () -> Void,
        onProgress: ((Int) -> Void)? = nil,
        onFailure: (() -> Void)? = nil
    ) {
        self.settings = settings
        self.isPreview = isPreview
        self.onComplete = onComplete
        self.onGiveUp = onGiveUp
        self.onTimeout = onTimeout
        self.onProgress = onProgress
        self.onFailure = onFailure
        _session = StateObject(
            wrappedValue: MissionSession(settings: settings, now: startedAt, completedRounds: completedRounds)
        )
    }

    var body: some View {
        ZStack {
            SAColor.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                missionBody
                    // Regenerating on round change gives each round fresh
                    // content without rebuilding on every keystroke.
                    .id(session.completedRounds)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                footer
            }
        }
        .onAppear {
            // Capturing the closures into locals first avoids capturing the
            // view — which owns the session — and leaking it along with its
            // one-second timer.
            let complete = onComplete
            let timeout = onTimeout
            let progress = onProgress
            let failure = onFailure
            session.onComplete = { complete() }
            session.onTimeout = { timeout() }
            session.onProgress = { progress?($0) }
            session.onFailure = { failure?() }
            session.startTimerIfNeeded()
        }
        .onDisappear {
            session.onComplete = nil
            session.onTimeout = nil
            session.onProgress = nil
            session.onFailure = nil
            session.stopTimer()
        }
        .onReceive(tick) { _ in
            elapsed = Int(Date().timeIntervalSince(session.startedAt))
        }
        .sheet(isPresented: $showingEscapeHatch) {
            EscapeHatchView {
                showingEscapeHatch = false
                onGiveUp()
            } onCancel: {
                showingEscapeHatch = false
            }
            .presentationDetents([.medium, .large])
            // A thumb drifting during the three-second hold must not hand
            // the touch to the sheet and lose the typed phrase.
            .interactiveDismissDisabled()
        }
        .onChange(of: session.isBlocked) { _, blocked in
            if blocked {
                AccessibilityNotification.Announcement("This mission cannot run. Escape hatch available.").post()
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                if isPreview {
                    Button {
                        onGiveUp()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .black))
                            .foregroundStyle(SAColor.textSecondary)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(SAColor.surfaceElevated))
                    }
                    .accessibilityLabel("Close preview")
                }

                Spacer()

                VStack(spacing: 2) {
                    Text(settings.type.displayName)
                        .font(SAFont.headline(17))
                        .foregroundStyle(SAColor.textPrimary)
                    if let round = session.roundLabel {
                        Text(round)
                            .font(SAFont.headline(15))
                            .foregroundStyle(SAColor.accentText)
                    }
                }

                Spacer()

                if let remaining = session.secondsRemaining {
                    Text("\(remaining)s")
                        .font(SAFont.clock(22))
                        .foregroundStyle(remaining <= 10 ? SAColor.danger : SAColor.textSecondary)
                        .frame(minWidth: 52, alignment: .trailing)
                        .fixedSize()
                        .accessibilityLabel("Time left")
                        .accessibilityValue("\(remaining) seconds")
                        .accessibilityAddTraits(.updatesFrequently)
                } else if isPreview {
                    Color.clear.frame(width: 36, height: 36)
                }
            }
            .padding(.horizontal, SAMetrics.screenPadding)
            .padding(.top, 12)

            if session.totalRounds > 1 {
                ProgressView(value: session.progress)
                    .tint(SAColor.accent)
                    .padding(.horizontal, SAMetrics.screenPadding)
            }
        }
        .padding(.bottom, 8)
    }

    // MARK: Body

    @ViewBuilder
    private var missionBody: some View {
        switch settings.type {
        case .math:
            MathMissionView(session: session)
        case .memory:
            MemoryMissionView(session: session)
        case .typing:
            TypingMissionView(session: session)
        case .pushup where settings.repDetection == .camera:
            PoseRepMissionView(session: session, exercise: .pushup)
        case .squat where settings.repDetection == .camera:
            PoseRepMissionView(session: session, exercise: .squat)
        case .walk, .shake, .pushup, .squat:
            MotionMissionView(session: session)
        case .barcode:
            BarcodeMissionView(session: session)
        case .objectScan:
            ObjectMissionView(session: session)
        case .faceID:
            FaceIDMissionView(session: session)
        case .none:
            Color.clear.onAppear { onComplete() }
        }
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        let threshold = max(30, settings.escapeHatchAfterSeconds)
        // A mission that cannot run at all offers the way out at once.
        let hatchAvailable = elapsed >= threshold || session.isBlocked

        VStack(spacing: 6) {
            if session.failures > 0 {
                Text(session.failures == 1 ? "1 mistake" : "\(session.failures) mistakes")
                    .font(SAFont.caption(13))
                    .foregroundStyle(SAColor.textSecondary)
            }

            if hatchAvailable {
                Button {
                    showingEscapeHatch = true
                } label: {
                    Label("Can't complete this?", systemImage: "lifepreserver")
                        .font(SAFont.caption(14))
                        .foregroundStyle(SAColor.textSecondary)
                        .frame(minHeight: 44)
                        .padding(.horizontal, 16)
                        .contentShape(Rectangle())
                }
                .accessibilityHint("Opens the escape hatch, which turns off the alarm without finishing the mission")
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: hatchAvailable)
        .onChange(of: hatchAvailable) { _, available in
            if available {
                AccessibilityNotification.Announcement("Escape hatch available").post()
            }
        }
        .padding(.bottom, 14)
        .frame(minHeight: 44)
    }
}

// MARK: - Escape hatch

/// Deliberate friction, but always a way out. A mission that cannot be escaped
/// is a phone that cannot be silenced.
struct EscapeHatchView: View {
    var onGiveUp: () -> Void
    var onCancel: () -> Void

    @State private var typed = ""
    @State private var holdProgress: Double = 0
    @State private var isHolding = false
    @FocusState private var isFieldFocused: Bool

    private let holdDuration: Double = 3.0
    private let tick = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    private var phrase: String { MissionSettings.escapeHatchPhrase }
    private var phraseMatches: Bool {
        typed.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(phrase) == .orderedSame
    }

    var body: some View {
        ZStack {
            SABackground()

            ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "lifepreserver.fill")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(SAColor.warning)
                    .padding(.top, 26)
                    .accessibilityHidden(true)

                Text("Give up on this mission?")
                    .font(SAFont.title(22))
                    .foregroundStyle(SAColor.textPrimary)
                    .multilineTextAlignment(.center)

                Text("The alarm will turn off. Type \"\(phrase)\", then hold the button for three seconds.")
                    .font(SAFont.body(15))
                    .foregroundStyle(SAColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)

                TextField(phrase, text: $typed)
                    .font(SAFont.body(17))
                    .multilineTextAlignment(.center)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($isFieldFocused)
                    .submitLabel(.done)
                    .accessibilityLabel("Give-up phrase")
                    .padding(14)
                    .background(SAColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(phraseMatches ? SAColor.success : SAColor.separator, lineWidth: 1.5)
                    )
                    .padding(.horizontal, SAMetrics.screenPadding)

                ZStack {
                    RoundedRectangle(cornerRadius: SAMetrics.buttonRadius, style: .continuous)
                        .fill(SAColor.surfaceElevated)

                    GeometryReader { geometry in
                        RoundedRectangle(cornerRadius: SAMetrics.buttonRadius, style: .continuous)
                            .fill(SAColor.warning)
                            .frame(width: geometry.size.width * holdProgress)
                    }

                    Text(holdLabel)
                        .font(SAFont.headline(17))
                        .foregroundStyle(phraseMatches ? SAColor.textPrimary : SAColor.textSecondary)
                }
                .frame(height: SAMetrics.buttonHeight)
                .clipShape(RoundedRectangle(cornerRadius: SAMetrics.buttonRadius, style: .continuous))
                .padding(.horizontal, SAMetrics.screenPadding)
                .contentShape(Rectangle())
                // A long press rather than a drag: the fill still animates
                // while the finger is down, and a small drift no longer
                // cancels the hold.
                .onLongPressGesture(minimumDuration: holdDuration, maximumDistance: 60) {
                    guard phraseMatches else { return }
                    isHolding = false
                    HapticEngine.shared.warning()
                    onGiveUp()
                } onPressingChanged: { pressing in
                    guard phraseMatches else { return }
                    isHolding = pressing
                    if !pressing { holdProgress = 0 }
                }
                .disabled(!phraseMatches)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(phraseMatches ? "Give up and turn off the alarm" : "Give up (type the phrase first)")
                .accessibilityHint("Requires the phrase above.")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction {
                    // The three-second hold cannot be performed with
                    // VoiceOver; the typed phrase is the friction.
                    guard phraseMatches else { return }
                    HapticEngine.shared.warning()
                    onGiveUp()
                }

                Button("Keep trying") { onCancel() }
                    .font(SAFont.emphasis(16))
                    .foregroundStyle(SAColor.accentText)
                    .frame(minHeight: 44)
                    .padding(.horizontal, 24)
                    .contentShape(Rectangle())

                Spacer(minLength: 10)
            }
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .onAppear {
            // Focus after the sheet has finished presenting; set on the
            // first frame it is dropped.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                Task { @MainActor in isFieldFocused = true }
            }
        }
        .onReceive(tick) { _ in
            guard isHolding, phraseMatches else { return }
            holdProgress = min(1, holdProgress + 0.05 / holdDuration)
        }
    }

    private var holdLabel: String {
        if isHolding { return "Keep holding…" }
        return phraseMatches ? "Ready — hold to give up" : "Hold to give up"
    }
}

// MARK: - Math

struct MathMissionView: View {
    @ObservedObject var session: MissionSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var problem: MathProblem = MathMission.generate(difficulty: .normal)
    @State private var entry = ""
    @State private var isWrong = false

    var body: some View {
        VStack(spacing: 26) {
            Spacer(minLength: 0)

            Text(problem.display)
                .font(SAFont.display(46))
                .foregroundStyle(SAColor.textPrimary)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .padding(.horizontal, 20)
                .accessibilityLabel("Problem: \(problem.display)")

            Text(entry.isEmpty ? " " : entry)
                .font(SAFont.clock(40))
                .foregroundStyle(isWrong ? SAColor.danger : SAColor.accentText)
                .frame(minHeight: 52)
                .accessibilityLabel("Your answer")
                .accessibilityValue(entry.isEmpty ? "empty" : entry)
                .frame(minWidth: 160)
                .padding(.horizontal, 22)
                .background(SAColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(isWrong ? SAColor.danger : Color.clear, lineWidth: 2)
                )
                .offset(x: isWrong && !reduceMotion ? -6 : 0)
                .animation(reduceMotion ? nil : .default.repeatCount(3, autoreverses: true).speed(6), value: isWrong)

            Spacer(minLength: 0)

            NumberPad(
                onDigit: append,
                onDelete: deleteLast,
                onSubmit: submit,
                canSubmit: !entry.isEmpty
            )
            .padding(.horizontal, 16)
        }
        .onAppear { problem = MathMission.generate(difficulty: session.settings.difficulty) }
    }

    private func append(_ digit: String) {
        guard entry.count < 7 else { return }
        isWrong = false
        entry += digit
        HapticEngine.shared.selection()
    }

    private func deleteLast() {
        guard !entry.isEmpty else { return }
        isWrong = false
        entry.removeLast()
        HapticEngine.shared.selection()
    }

    private func submit() {
        guard let value = Int(entry) else { return }
        if value == problem.answer {
            entry = ""
            session.passRound()
            if !session.isComplete {
                problem = MathMission.generate(difficulty: session.settings.difficulty)
            }
        } else {
            isWrong = true
            entry = ""
            session.registerFailure()
            // A wrong answer earns a fresh problem, so guessing is pointless.
            problem = MathMission.generate(difficulty: session.settings.difficulty)
            AccessibilityNotification.Announcement("Wrong. New problem: \(problem.display)").post()
        }
    }
}

/// Large custom keypad — the system keyboard is far too fiddly at 6am.
struct NumberPad: View {
    var onDigit: (String) -> Void
    var onDelete: () -> Void
    var onSubmit: () -> Void
    var canSubmit: Bool

    private let rows = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"]]

    var body: some View {
        VStack(spacing: 10) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 10) {
                    ForEach(row, id: \.self) { digit in
                        key(digit) { onDigit(digit) }
                    }
                }
            }
            HStack(spacing: 10) {
                iconKey("delete.left.fill", tint: SAColor.textSecondary) { onDelete() }
                    .accessibilityLabel("Delete")
                key("0") { onDigit("0") }
                iconKey("checkmark", tint: SAColor.onAccent, background: canSubmit ? SAColor.accent : SAColor.surfaceElevated) {
                    onSubmit()
                }
                .disabled(!canSubmit)
                .accessibilityLabel("Submit answer")
            }
        }
    }

    private func key(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(SAFont.clock(28))
                .foregroundStyle(SAColor.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 62)
                .background(SAColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func iconKey(
        _ symbol: String,
        tint: Color,
        background: Color = SAColor.surface,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity)
                .frame(height: 62)
                .background(background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Memory

struct MemoryMissionView: View {
    @ObservedObject var session: MissionSession

    @State private var round = MemoryMission.generate(difficulty: .normal)
    @State private var isShowingPattern = true
    @State private var tapped: Set<Int> = []
    @State private var wrongTile: Int?

    var body: some View {
        VStack(spacing: 20) {
            Text(isShowingPattern ? "Memorise the pattern" : "Tap the tiles you saw")
                .font(SAFont.headline(19))
                .foregroundStyle(isShowingPattern ? SAColor.accentText : SAColor.textPrimary)

            Text("\(tapped.count) of \(round.litTiles.count)")
                .font(SAFont.body(14))
                .foregroundStyle(SAColor.textSecondary)
                .opacity(isShowingPattern ? 0 : 1)

            grid
                .padding(.horizontal, SAMetrics.screenPadding)

            Spacer(minLength: 0)
        }
        .padding(.top, 10)
        .onAppear(perform: startRound)
    }

    private var grid: some View {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: 10),
            count: round.gridSize
        )

        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(0..<round.tileCount, id: \.self) { index in
                tile(at: index)
            }
        }
    }

    private func tile(at index: Int) -> some View {
        let isLit = round.litTiles.contains(index)
        let isTapped = tapped.contains(index)
        let isWrong = wrongTile == index

        let fill: Color = {
            if isWrong { return SAColor.danger }
            if isShowingPattern && isLit { return SAColor.accent }
            if isTapped { return SAColor.accent }
            return SAColor.surface
        }()

        return RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(fill)
            .aspectRatio(1, contentMode: .fit)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(SAColor.separator, lineWidth: 1)
            )
            .onTapGesture { handleTap(index) }
            .animation(.easeOut(duration: 0.18), value: fill)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Tile \(index + 1) of \(round.tileCount)")
            .accessibilityValue(isShowingPattern && isLit ? "lit" : (isTapped ? "selected" : ""))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { handleTap(index) }
    }

    private func startRound() {
        round = MemoryMission.generate(difficulty: session.settings.difficulty)
        tapped = []
        wrongTile = nil
        isShowingPattern = true

        // VoiceOver cannot scan a grid in two seconds: read the lit tiles
        // out and give a much longer look.
        let voiceOver = UIAccessibility.isVoiceOverRunning
        if voiceOver {
            let numbers = round.litTiles.sorted().map { String($0 + 1) }.joined(separator: ", ")
            AccessibilityNotification.Announcement("Memorise tiles \(numbers)").post()
        }
        let preview = voiceOver ? max(8, round.previewSeconds * 3) : round.previewSeconds

        DispatchQueue.main.asyncAfter(deadline: .now() + preview) {
            Task { @MainActor in
                withAnimation { isShowingPattern = false }
            }
        }
    }

    private func handleTap(_ index: Int) {
        guard !isShowingPattern, !session.isComplete else { return }
        guard !tapped.contains(index) else { return }

        if round.litTiles.contains(index) {
            tapped.insert(index)
            HapticEngine.shared.selection()
            if tapped == round.litTiles {
                session.passRound()
                if !session.isComplete { startRound() }
            }
        } else {
            wrongTile = index
            session.registerFailure()
            // Wrong tile restarts the round with a brand new pattern.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                Task { @MainActor in startRound() }
            }
        }
    }
}

// MARK: - Typing

struct TypingMissionView: View {
    @ObservedObject var session: MissionSession

    @State private var phrase = TypingMission.generate(difficulty: .normal)
    @State private var typed = ""
    @FocusState private var isFocused: Bool

    private var isValidPrefix: Bool { phrase.isPrefixValid(typed) }
    private var isComplete: Bool { phrase.matches(typed) }

    var body: some View {
        VStack(spacing: 22) {
            Text("Type this exactly")
                .font(SAFont.caption(14))
                .foregroundStyle(SAColor.textSecondary)

            Text(phrase.text)
                .font(SAFont.headline(22))
                .foregroundStyle(SAColor.textPrimary)
                .multilineTextAlignment(.center)
                .padding(18)
                .frame(maxWidth: .infinity)
                .background(SAColor.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.horizontal, SAMetrics.screenPadding)

            TextField("Start typing…", text: $typed, axis: .vertical)
                .font(SAFont.body(18))
                .foregroundStyle(isValidPrefix ? SAColor.textPrimary : SAColor.danger)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($isFocused)
                .padding(16)
                .frame(minHeight: 90, alignment: .topLeading)
                .background(SAColor.surfaceElevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(
                            isComplete ? SAColor.success : (isValidPrefix ? SAColor.separator : SAColor.danger),
                            lineWidth: 1.5
                        )
                )
                .padding(.horizontal, SAMetrics.screenPadding)

            ProgressView(
                value: Double(phrase.correctPrefixLength(of: typed)),
                total: Double(max(1, phrase.text.count))
            )
            .tint(SAColor.accent)
            .padding(.horizontal, SAMetrics.screenPadding)

            if !isValidPrefix {
                Text("That does not match — check the last character.")
                    .font(SAFont.body(14))
                    .foregroundStyle(SAColor.danger)
            } else {
                Text("It passes the moment the phrase matches.")
                    .font(SAFont.body(14))
                    .foregroundStyle(SAColor.textSecondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .onAppear {
            phrase = TypingMission.generate(difficulty: session.settings.difficulty)
            // Focus after the cover has finished presenting; set on the
            // first frame it is dropped.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                Task { @MainActor in isFocused = true }
            }
        }
        // No Submit button to reach under the keyboard on a small phone: a
        // matching phrase passes by itself.
        .onChange(of: typed) { _, _ in
            if isComplete { submit() }
        }
        .onChange(of: isValidPrefix) { wasValid, isValid in
            if wasValid, !isValid { session.registerFailure() }
        }
    }

    private func submit() {
        guard isComplete else { return }
        typed = ""
        session.passRound()
        if !session.isComplete {
            phrase = TypingMission.generate(difficulty: session.settings.difficulty)
        }
    }
}
