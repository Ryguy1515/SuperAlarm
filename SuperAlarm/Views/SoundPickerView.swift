import SwiftUI
import UniformTypeIdentifiers

struct SoundPickerView: View {
    @State private var tonePendingDelete: AlarmTone?
    @Binding var sound: SoundSettings

    @StateObject private var audio = AlarmAudioEngine.shared
    @StateObject private var customTones = CustomToneStore.shared

    @State private var tab: Tab = .ringtones
    @State private var category: SoundCategory = .noisy
    @State private var showingImporter = false
    @State private var importError: String?

    enum Tab: String, CaseIterable, Identifiable {
        case ringtones = "Ringtones"
        case myMusic = "My Music"
        var id: String { rawValue }
    }

    var body: some View {
        ZStack {
            SABackground()

            ScrollView {
                VStack(spacing: 16) {
                    enableRow
                    if sound.isEnabled {
                        tabPicker
                        switch tab {
                        case .ringtones: ringtoneSection
                        case .myMusic: myMusicSection
                        }
                        volumeCard
                    } else {
                        vibrateOnlyNote
                    }
                    Color.clear.frame(height: 24)
                }
                .padding(.horizontal, SAMetrics.screenPadding)
                .padding(.top, 8)
            }
        }
        .navigationTitle("Sound")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Open on the category the current tone belongs to.
            if let random = ToneResolver.category(of: sound.toneID) {
                category = random
            } else if !CustomTone.isCustom(sound.toneID) {
                category = SoundCatalog.tone(id: sound.toneID).category
            } else {
                tab = .myMusic
            }
        }
        .onDisappear { audio.stopPreview() }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.audio, .mp3, .wav, .aiff, .mpeg4Audio],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .alert("Couldn't import", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    // MARK: Enable

    private var enableRow: some View {
        SACard(padding: 0) {
            SARow(
                icon: "speaker.wave.2.fill",
                title: "Enable sound",
                subtitle: sound.isEnabled ? nil : "The alarm will only vibrate",
                showsChevron: false
            ) {
                Toggle("Enable sound", isOn: $sound.isEnabled)
                    .labelsHidden()
                    .tint(SAColor.accent)
            }
        }
    }

    private var vibrateOnlyNote: some View {
        SACard {
            VStack(alignment: .leading, spacing: 8) {
                Label("Vibration only", systemImage: "iphone.radiowaves.left.and.right")
                    .font(SAFont.emphasis(16))
                    .foregroundStyle(SAColor.textPrimary)
                Text("This alarm will buzz but make no sound. Make sure that is enough to wake you.")
                    .font(SAFont.body(14))
                    .foregroundStyle(SAColor.textSecondary)
                Toggle("Vibrate", isOn: $sound.vibrate)
                    .font(SAFont.body(15))
                    .tint(SAColor.accent)
            }
        }
    }

    // MARK: Tabs

    private var tabPicker: some View {
        HStack(spacing: 22) {
            ForEach(Tab.allCases) { item in
                Button {
                    HapticEngine.shared.selection()
                    audio.stopPreview()
                    tab = item
                } label: {
                    VStack(spacing: 6) {
                        Text(item.rawValue)
                            .font(SAFont.headline(17))
                            .foregroundStyle(tab == item ? SAColor.accentText : SAColor.textTertiary)
                        Capsule()
                            .fill(tab == item ? SAColor.accent : Color.clear)
                            .frame(height: 3)
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    // MARK: Ringtones

    private var ringtoneSection: some View {
        VStack(spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(SoundCategory.allCases) { item in
                        Button {
                            HapticEngine.shared.selection()
                            audio.stopPreview()
                            category = item
                        } label: {
                            SAChip(
                                title: item.displayName,
                                systemImage: item.symbolName,
                                isSelected: category == item
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
            }

            VStack(spacing: 0) {
                randomRow
                SADivider()

                ForEach(Array(SoundCatalog.tones(in: category).enumerated()), id: \.element.id) { index, tone in
                    toneRow(tone)
                    if index < SoundCatalog.tones(in: category).count - 1 {
                        SADivider()
                    }
                }
            }
            .saGroupedCard()
        }
    }

    private var randomRow: some View {
        let id = ToneResolver.randomID(for: category)
        let isSelected = sound.toneID == id

        return Button {
            HapticEngine.shared.selection()
            sound.toneID = id
            audio.stopPreview()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "shuffle")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(SAColor.accent)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Random (\(category.displayName))")
                        .font(SAFont.emphasis(16))
                        .foregroundStyle(SAColor.accentText)
                    Text("A different sound every morning, so you never get used to one")
                        .font(SAFont.body(12))
                        .foregroundStyle(SAColor.textSecondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 6)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(SAColor.accent)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toneRow(_ tone: AlarmTone) -> some View {
        let isSelected = sound.toneID == tone.id
        let isPreviewing = audio.previewingToneID == tone.id

        return HStack(spacing: 12) {
            Button {
                HapticEngine.shared.selection()
                sound.toneID = tone.id
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(isSelected ? SAColor.accent : SAColor.textTertiary)

                    Text(tone.name)
                        .font(SAFont.body(16))
                        .foregroundStyle(SAColor.textPrimary)

                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                audio.preview(tone: tone, volume: sound.volume)
            } label: {
                Image(systemName: isPreviewing ? "stop.fill" : "play.fill")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(isPreviewing ? SAColor.onAccent : SAColor.accent)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(isPreviewing ? SAColor.accent : SAColor.accent.opacity(0.15)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPreviewing ? "Stop preview" : "Preview \(tone.name)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    // MARK: My music

    private var myMusicSection: some View {
        VStack(spacing: 14) {
            Button {
                showingImporter = true
            } label: {
                Label("Import audio file", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(PrimaryButtonStyle())

            if customTones.records.isEmpty {
                SACard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No imported sounds yet")
                            .font(SAFont.emphasis(16))
                            .foregroundStyle(SAColor.textPrimary)
                        Text("Import any audio file from Files or iCloud Drive and use it as your alarm. It is copied into the app, so it keeps working even if the original is moved.")
                            .font(SAFont.body(14))
                            .foregroundStyle(SAColor.textSecondary)
                    }
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(customTones.tones.enumerated()), id: \.element.id) { index, tone in
                        customToneRow(tone)
                        if index < customTones.tones.count - 1 { SADivider() }
                    }
                }
                .saGroupedCard()

                Text("Imported audio plays once the alarm opens in the app; the Lock Screen alert itself uses a built-in tone.")
                    .font(SAFont.body(12))
                    .foregroundStyle(SAColor.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func customToneRow(_ tone: AlarmTone) -> some View {
        let isSelected = sound.toneID == tone.id
        let isPreviewing = audio.previewingToneID == tone.id

        return HStack(spacing: 12) {
            Button {
                HapticEngine.shared.selection()
                sound.toneID = tone.id
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(isSelected ? SAColor.accent : SAColor.textTertiary)
                    Text(tone.name)
                        .font(SAFont.body(16))
                        .foregroundStyle(SAColor.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                audio.preview(tone: tone, volume: sound.volume)
            } label: {
                Image(systemName: isPreviewing ? "stop.fill" : "play.fill")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(isPreviewing ? SAColor.onAccent : SAColor.accent)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(isPreviewing ? SAColor.accent : SAColor.accent.opacity(0.15)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPreviewing ? "Stop preview" : "Preview \(tone.name)")

            Button(role: .destructive) {
                tonePendingDelete = tone
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(SAColor.danger)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete \(tone.name)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .confirmationDialog(
            "Delete \(tonePendingDelete?.name ?? "this tone")?",
            isPresented: Binding(get: { tonePendingDelete != nil }, set: { if !$0 { tonePendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let tone = tonePendingDelete {
                    if sound.toneID == tone.id { sound.toneID = SoundCatalog.defaultToneID }
                    audio.stopPreview()
                    customTones.delete(id: tone.id)
                }
                tonePendingDelete = nil
            }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let tone = try customTones.importFile(at: url)
                sound.toneID = tone.id
                HapticEngine.shared.success()
            } catch {
                importError = (error as? LocalizedError)?.errorDescription ?? "That file could not be imported."
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    // MARK: Volume

    private var volumeCard: some View {
        SACard {
            VStack(alignment: .leading, spacing: 16) {
                Toggle(isOn: $sound.gradualIncrease) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Gradually increase volume")
                            .font(SAFont.emphasis(16))
                            .foregroundStyle(SAColor.textPrimary)
                        Text("Starts quiet and climbs to full over \(Int(sound.gradualRampSeconds))s")
                            .font(SAFont.body(12))
                            .foregroundStyle(SAColor.textSecondary)
                    }
                }
                .tint(SAColor.accent)

                if sound.gradualIncrease {
                    Picker("Ramp", selection: $sound.gradualRampSeconds) {
                        ForEach(SoundSettings.rampOptions, id: \.self) { seconds in
                            Text(seconds < 60 ? "\(Int(seconds))s" : "\(Int(seconds / 60))m").tag(seconds)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Divider().overlay(SAColor.separator)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Volume")
                        .font(SAFont.emphasis(15))
                        .foregroundStyle(SAColor.textPrimary)
                    HStack(spacing: 12) {
                        Image(systemName: "speaker.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(SAColor.textTertiary)
                        Slider(value: $sound.volume, in: 0.1...1.0)
                            .tint(SAColor.accent)
                        Image(systemName: "speaker.wave.3.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(SAColor.accent)
                    }
                }

                Divider().overlay(SAColor.separator)

                Toggle(isOn: $sound.overrideSystemVolume) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Override device volume")
                            .font(SAFont.emphasis(16))
                            .foregroundStyle(SAColor.textPrimary)
                        Text("Turns the phone up when the alarm starts, so a phone turned right down still wakes you")
                            .font(SAFont.body(12))
                            .foregroundStyle(SAColor.textSecondary)
                    }
                }
                .tint(SAColor.accent)

                Toggle(isOn: $sound.vibrate) {
                    Text("Vibrate")
                        .font(SAFont.emphasis(16))
                        .foregroundStyle(SAColor.textPrimary)
                }
                .tint(SAColor.accent)

                Divider().overlay(SAColor.separator)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Stop ringing after")
                        .font(SAFont.emphasis(15))
                        .foregroundStyle(SAColor.textPrimary)
                    Picker("Auto stop", selection: $sound.autoStopMinutes) {
                        ForEach(SoundSettings.autoStopOptions, id: \.self) { minutes in
                            Text(minutes == 0 ? "Never" : "\(minutes) min").tag(minutes)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(SAColor.accent)
                }
            }
        }
    }
}
