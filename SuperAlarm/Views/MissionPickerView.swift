import SwiftUI
import UIKit

// MARK: - Picker grid

struct MissionPickerView: View {
    @Binding var mission: MissionSettings
    @EnvironmentObject private var store: AlarmStore

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ZStack {
            SABackground()

            ScrollView {
                VStack(spacing: 18) {
                    intro

                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(MissionType.selectable) { type in
                            NavigationLink {
                                MissionConfigView(mission: $mission, type: type)
                                    .environmentObject(store)
                            } label: {
                                MissionTile(type: type, isSelected: mission.type == type)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    noneRow
                    Color.clear.frame(height: 24)
                }
                .padding(.horizontal, SAMetrics.screenPadding)
                .padding(.top, 8)
            }
        }
        .navigationTitle("Mission")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var intro: some View {
        SACard {
            VStack(alignment: .leading, spacing: 6) {
                Text("Solve tasks to stop the alarm")
                    .font(SAFont.title(20))
                    .foregroundStyle(SAColor.textPrimary)
                Text("A mission has to be completed before the alarm will switch off. Pick something that gets you out of bed rather than something you can do half asleep.")
                    .font(SAFont.body(14))
                    .foregroundStyle(SAColor.textSecondary)
            }
        }
    }

    private var noneRow: some View {
        Button {
            HapticEngine.shared.selection()
            mission = MissionSettings()
        } label: {
            SACard(padding: 16) {
                HStack(spacing: 12) {
                    Image(systemName: MissionType.none.symbolName)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(mission.type == .none ? SAColor.accent : SAColor.textTertiary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No mission")
                            .font(SAFont.emphasis(16))
                            .foregroundStyle(SAColor.textPrimary)
                        Text(MissionType.none.tagline)
                            .font(SAFont.body(13))
                            .foregroundStyle(SAColor.textSecondary)
                    }
                    Spacer()
                    if mission.type == .none {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(SAColor.accent)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Tile

struct MissionTile: View {
    let type: MissionType
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: type.symbolName)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(isSelected ? SAColor.onAccent : SAColor.accent)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(SAColor.onAccent)
                }
            }
            .frame(height: 30)

            Text(type.displayName)
                .font(SAFont.headline(16))
                .foregroundStyle(isSelected ? SAColor.onAccent : SAColor.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(type.tagline)
                .font(SAFont.body(11))
                .foregroundStyle(isSelected ? SAColor.onAccent.opacity(0.75) : SAColor.textSecondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(height: 138, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: SAMetrics.tileRadius, style: .continuous)
                .fill(isSelected ? SAColor.accent : SAColor.surface)
        )
    }
}

// MARK: - Configuration

struct MissionConfigView: View {
    @Binding var mission: MissionSettings
    let type: MissionType

    @EnvironmentObject private var store: AlarmStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft = MissionSettings()
    @State private var showingPreview = false
    @State private var showingBarcodeRegistration = false
    @State private var showingObjectRegistration = false
    @State private var biometricWarning: String?

    var body: some View {
        ZStack {
            SABackground()

            ScrollView {
                VStack(spacing: 16) {
                    explanation

                    if let biometricWarning {
                        warningCard(biometricWarning)
                    }

                    if type == .pushup || type == .squat { detectionCard }
                    if type.supportsGoalCount { goalCard }
                    if type.supportsDifficulty { difficultyCard }
                    if type.supportsRounds { roundsCard }
                    if type.requiresSetup { registrationCard }

                    limitsCard
                    Color.clear.frame(height: 100)
                }
                .padding(.horizontal, SAMetrics.screenPadding)
                .padding(.top, 8)
            }

            VStack {
                Spacer()
                saveBar
            }
        }
        .navigationTitle(type.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Preview") { showingPreview = true }
                    .buttonStyle(PillButtonStyle())
                    .disabled(type.requiresSetup && !draft.isReady)
            }
        }
        .onAppear(perform: prepareDraft)
        .fullScreenCover(isPresented: $showingPreview) {
            MissionRunnerView(
                settings: draft,
                isPreview: true,
                onComplete: { showingPreview = false },
                onGiveUp: { showingPreview = false }
            )
        }
        .fullScreenCover(isPresented: $showingBarcodeRegistration) {
            BarcodeRegistrationView { payload in
                draft.barcodePayload = payload
                if (draft.barcodeLabel ?? "").isEmpty { draft.barcodeLabel = "Registered code" }
                showingBarcodeRegistration = false
            } onCancel: {
                showingBarcodeRegistration = false
            }
        }
        .fullScreenCover(isPresented: $showingObjectRegistration) {
            ObjectRegistrationView { imageID in
                draft.objectImageID = imageID
                if (draft.objectLabel ?? "").isEmpty { draft.objectLabel = "Registered object" }
                showingObjectRegistration = false
            } onCancel: {
                showingObjectRegistration = false
            }
        }
    }

    private func prepareDraft() {
        // Editing the mission already attached keeps its settings; switching to
        // a different one starts from that mission's defaults.
        if mission.type == type {
            draft = mission
        } else {
            draft = MissionSettings(type: type)
        }
        draft.type = type

        if type == .faceID, !BiometricMission.isAvailable {
            biometricWarning = BiometricMission.unavailableReason
        }
    }

    // MARK: Cards

    private var explanation: some View {
        SACard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: type.symbolName)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(SAColor.accent)
                    Text(type.displayName)
                        .font(SAFont.title(20))
                        .foregroundStyle(SAColor.textPrimary)
                }
                Text(type.explanation)
                    .font(SAFont.body(14))
                    .foregroundStyle(SAColor.textSecondary)
            }
        }
    }

    private func warningCard(_ text: String) -> some View {
        SACard(background: SAColor.warning.opacity(0.15)) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(SAColor.warning)
                Text(text)
                    .font(SAFont.body(14))
                    .foregroundStyle(SAColor.textPrimary)
            }
        }
    }

    private var detectionCard: some View {
        SACard {
            VStack(alignment: .leading, spacing: 12) {
                Text("How reps are counted")
                    .font(SAFont.headline(17))
                    .foregroundStyle(SAColor.textPrimary)

                Picker("Detection", selection: $draft.repDetection) {
                    ForEach(RepDetection.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(draft.repDetection.detail)
                    .font(SAFont.body(13))
                    .foregroundStyle(SAColor.textSecondary)
            }
        }
    }

    private var goalCard: some View {
        SACard {
            VStack(spacing: 14) {
                Text(type.goalTitle)
                    .font(SAFont.headline(18))
                    .foregroundStyle(SAColor.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                let range = type.goalRange
                SABigStepper(
                    value: Binding(
                        get: { draft.effectiveGoal },
                        set: { draft.goal = $0 }
                    ),
                    range: range.min...range.max,
                    step: range.step,
                    caption: type.goalLabel
                )
            }
        }
    }

    private var difficultyCard: some View {
        SACard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Difficulty")
                    .font(SAFont.headline(17))
                    .foregroundStyle(SAColor.textPrimary)

                ForEach(MissionDifficulty.allCases) { level in
                    Button {
                        HapticEngine.shared.selection()
                        draft.difficulty = level
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: draft.difficulty == level ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(draft.difficulty == level ? SAColor.accent : SAColor.textTertiary)
                            Text(level.displayName)
                                .font(SAFont.body(16))
                                .foregroundStyle(SAColor.textPrimary)
                            Spacer()
                            SADifficultyPips(level: level.level)
                        }
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Text(difficultyHint)
                    .font(SAFont.body(12))
                    .foregroundStyle(SAColor.textTertiary)
            }
        }
    }

    private var difficultyHint: String {
        switch type {
        case .math:
            return "\(draft.difficulty.mathTermCount) numbers, up to \(draft.difficulty.mathOperandRange.upperBound)."
        case .memory:
            return "\(draft.difficulty.memoryGridSize)×\(draft.difficulty.memoryGridSize) grid, \(draft.difficulty.memoryPatternLength) tiles, shown for \(String(format: "%.1f", draft.difficulty.memoryPreviewSeconds))s."
        case .typing:
            return "Around \(draft.difficulty.typingPhraseLength) characters to type exactly."
        default:
            return ""
        }
    }

    private var roundsCard: some View {
        SACard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Rounds")
                    .font(SAFont.headline(17))
                    .foregroundStyle(SAColor.textPrimary)
                Text("How many times in a row it has to be completed.")
                    .font(SAFont.body(13))
                    .foregroundStyle(SAColor.textSecondary)

                Picker("Rounds", selection: $draft.rounds) {
                    ForEach(MissionSettings.roundOptions, id: \.self) { count in
                        Text("\(count)×").tag(count)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private var registrationCard: some View {
        SACard {
            VStack(alignment: .leading, spacing: 12) {
                Text(type == .barcode ? "Registered code" : "Registered object")
                    .font(SAFont.headline(17))
                    .foregroundStyle(SAColor.textPrimary)

                if draft.isReady {
                    HStack(spacing: 12) {
                        if type == .objectScan,
                           let id = draft.objectImageID,
                           let data = MissionAssetStore.shared.imageData(id: id),
                           let image = UIImage(data: data) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 60, height: 60)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        } else {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 26, weight: .bold))
                                .foregroundStyle(SAColor.success)
                                .frame(width: 60, height: 60)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            TextField(
                                "Name it, e.g. Bathroom shampoo",
                                text: Binding(
                                    get: { (type == .barcode ? draft.barcodeLabel : draft.objectLabel) ?? "" },
                                    set: {
                                        if type == .barcode { draft.barcodeLabel = $0 } else { draft.objectLabel = $0 }
                                    }
                                )
                            )
                            .font(SAFont.body(15))
                            .foregroundStyle(SAColor.textPrimary)

                            if type == .barcode, let payload = draft.barcodePayload {
                                Text(payload)
                                    .font(SAFont.body(12))
                                    .foregroundStyle(SAColor.textTertiary)
                                    .lineLimit(1)
                            }
                        }
                    }
                } else {
                    Text(type == .barcode
                         ? "Scan a barcode you keep somewhere you have to walk to — a shampoo bottle, a cereal box, the fridge."
                         : "Photograph something across the room. You will have to go and photograph it again to turn the alarm off.")
                        .font(SAFont.body(14))
                        .foregroundStyle(SAColor.textSecondary)
                }

                Button {
                    if type == .barcode {
                        showingBarcodeRegistration = true
                    } else {
                        showingObjectRegistration = true
                    }
                } label: {
                    Label(
                        draft.isReady ? "Register a different one" : "Register now",
                        systemImage: type == .barcode ? "qrcode.viewfinder" : "camera.fill"
                    )
                }
                .buttonStyle(SecondaryButtonStyle(height: 48))
            }
        }
    }

    private var limitsCard: some View {
        SACard {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Time limit")
                        .font(SAFont.emphasis(16))
                        .foregroundStyle(SAColor.textPrimary)
                    Text("Give up and go back to ringing after this long.")
                        .font(SAFont.body(12))
                        .foregroundStyle(SAColor.textSecondary)
                    Picker("Time limit", selection: $draft.timeLimitSeconds) {
                        ForEach(MissionSettings.timeLimitOptions, id: \.self) { seconds in
                            Text(seconds == 0 ? "None" : "\(seconds)s").tag(seconds)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(SAColor.accent)
                }

                Divider().overlay(SAColor.separator)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Escape hatch")
                        .font(SAFont.emphasis(16))
                        .foregroundStyle(SAColor.textPrimary)
                    Text("If the mission will not recognise you, an escape appears after this long: hold a button and type \"\(MissionSettings.escapeHatchPhrase)\". Waking up should be hard, never impossible.")
                        .font(SAFont.body(12))
                        .foregroundStyle(SAColor.textSecondary)
                    Picker("Escape hatch", selection: $draft.escapeHatchAfterSeconds) {
                        ForEach(MissionSettings.escapeHatchOptions, id: \.self) { seconds in
                            Text(seconds < 60 ? "\(seconds)s" : "\(seconds / 60) min").tag(seconds)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(SAColor.accent)
                }
            }
        }
    }

    private var saveBar: some View {
        VStack(spacing: 0) {
            Button {
                mission = draft
                HapticEngine.shared.success()
                dismiss()
            } label: {
                Text(type.requiresSetup && !draft.isReady ? "Register to continue" : "Save")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(type.requiresSetup && !draft.isReady)
            .opacity(type.requiresSetup && !draft.isReady ? 0.5 : 1)
            .padding(.horizontal, SAMetrics.screenPadding)
            .padding(.bottom, 10)
            .padding(.top, 12)
        }
        .background(
            LinearGradient(
                colors: [SAColor.background.opacity(0), SAColor.background, SAColor.background],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
    }
}
