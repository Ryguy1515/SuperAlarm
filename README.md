# SuperAlarm

A complete, from-scratch recreation of **SuperAlarm — Loud Alarm Clock** (App Store ID `6480463426`) as a native SwiftUI app for iOS 17+, built to be developed on Windows and installed on your own iPhone without a Mac.

Every alarm tone, the app icon, and all artwork are generated from source by scripts in `tools/`. Nothing is copied from the original app.

---

## What it does

The premise of the original is an *adversarial* model of the half-asleep user: it assumes you will try to defeat your own alarm, and closes every escape hatch. This build reproduces that model.

| Escape you'd try | What stops you |
|---|---|
| Tap it off and roll over | **Wake-up check** — re-rings if you don't confirm within 100 s |
| Dismiss it half-asleep | **Slide-to-turn-off** plus a **mission** you have to complete |
| Silence it with the side buttons | **Volume lock** restores the level; a **backstop alarm** lands 2 minutes later |
| Leave the phone on silent | **AlarmKit** rings through Silent mode, DND and every Focus |
| Force-quit the app | Alarms are owned by the system and survive termination and reboot |
| Get used to the sound | **Random** tone per category, different every morning |
| Snooze forever | Configurable limit, or intervals that **halve each time** |

### The ten missions

Math · Memory · QR/Barcode scan · Object scan · Face ID · Walk · Push-up · Squat · Shake · Typing

Every mission has difficulty tiers or a numeric goal, optional multiple rounds, an optional time limit, and — critically — an **escape hatch**. After a configurable delay a "Can't complete this?" option appears; hold a button and type *"I give up"* and the alarm stops. The most common one-star review in this entire app category is a mission that won't recognise the user, leaving them trapped with a screaming phone. Waking up should be hard, never impossible.

### Everything else

- **32 alarm tones** across the original's four categories — Bright, Noisy, Energetic, Calm — plus **Random** per category and **My Music** (import any audio file)
- **5 sleep sounds** (Ocean wave, Campfire, Rainy thunder, Forest crickets, Light rain) with a playback-duration timer and fade-out
- Gradual volume ramp, device-volume override, vibration, auto-stop
- Alarm names and memos, colour tags, weekday/weekend presets, **specific-date** schedules, **skip next occurrence**
- **Quick alarm** (nap timer), **pre-alarm** heads-up, **voice briefing** of time/date/weather
- Weather on the alarm screen (Open-Meteo, no API key needed)
- **Streaks, success rate and 30-day history**
- **Widgets** — home screen small/medium plus lock-screen circular, rectangular and inline
- Onboarding, full settings, and a **Diagnostics** screen that shows whether alarms are genuinely scheduled

---

## Install it on your iPhone from Windows

You need no Mac. The build happens on a GitHub-hosted macOS runner; you sign and install over USB.

### 1. Push this to a **public** GitHub repo

macOS runner minutes are free and unlimited on public repositories.

```powershell
cd C:\Users\RMS11\Desktop\SuperAlarm
git init
git add -A
git commit -m "SuperAlarm"
git branch -M main
git remote add origin https://github.com/<you>/SuperAlarm.git
git push -u origin main
```

### 2. Grab the build

The **Build IPA** workflow starts automatically. When it finishes (~10 min), open the run and download the **SuperAlarm-ipa** artifact. It contains:

- `SuperAlarm.ipa` — the full app including widgets
- `SuperAlarm-no-widget.ipa` — identical minus the widget extension, as a fallback (some Windows sideloading tools mis-sign app extensions)

Unzip the artifact to get the `.ipa` files.

### 3. Prepare Windows

1. Install **iTunes** from `apple.com` directly — **not** the Microsoft Store version, which lacks the Apple Mobile Device drivers Sideloadly needs. Uninstall the Store version first if present, then reboot. You never need to open or sign in to iTunes. (iCloud is *not* required — that is an AltStore prerequisite, not a Sideloadly one.)
2. Install **Sideloadly** from <https://sideloadly.io>.

### 4. Sign and install

1. Connect your iPhone by USB and tap **Trust** on the phone.
2. Open Sideloadly, drag `SuperAlarm.ipa` in, enter your Apple ID, click **Start**. Use an app-specific password if prompted.
3. On the iPhone: **Settings → General → VPN & Device Management** → tap your Apple ID → **Trust**.
4. **Settings → Privacy & Security → Developer Mode** → on → restart when asked.
5. Launch SuperAlarm and work through onboarding. Grant the alarm permission when asked — that is the one that matters.

> **Free Apple ID:** the signature lasts **7 days**, and you can have 3 sideloaded apps at once. Re-run Sideloadly before it expires. **Never delete the app when it stops opening** — re-signing keeps all your alarms and history. Set yourself a calendar reminder every 5 days. A paid Apple Developer account ($99/yr) extends this to 365 days; nothing else about the app changes.

If signing fails because of the widget, use `SuperAlarm-no-widget.ipa`.

---

## Verify it actually works

Do this the evening before you first rely on it.

1. **Settings → Diagnostics.** Confirm *Alarm mechanism* reads **AlarmKit** (iOS 26+) or **Notifications**, that authorisation says Yes, and that *Bundled sounds* says **All present**.
2. **Test the whole flow without waiting.** Open an alarm → **Test this alarm now**. The ring screen appears, the mission runs, the wake-up check follows.
3. **Test it for real while backgrounded.** Set an alarm 2 minutes out, lock the phone, put it face down, wait.
4. **Test the defences.** While it rings, press the volume-down button — the level should climb back. Force-quit the app — a backstop alarm should still arrive.
5. **Test silent mode.** Flip the ringer switch to silent and repeat step 3.

---

## Fidelity notes

Two advertised behaviours cannot be reproduced exactly, and the app is honest about it rather than pretending:

- **"App deletion prevention while alarm is ringing."** No third-party iOS app can block its own deletion. Doing so requires `ManagedSettings.denyAppRemoval`, which needs the **Family Controls** entitlement — Apple approval, paid account, and it would break free-account signing entirely. What this build does instead is arguably stronger: alarms are owned by the system, so they keep firing even if the app is closed, and a **backstop chain** of follow-up alarms is armed the moment one starts, cancelled only when a mission is genuinely completed.
- **"Power-off prevention."** Android-only in the original, via an Accessibility Service. iOS has no equivalent API.

One deliverable is deliberately left out:

- **No separate Apple Watch app.** The original ships a watchOS companion. Adding a watchOS target means a second bundle identifier and provisioning profile inside the same `.ipa`, which is the most common cause of sideloading failures on Windows with a free Apple ID — it would put the thing you actually need, the iPhone app, at risk. It is also the one component that could not be tested here. It costs you very little: AlarmKit already mirrors alarms to a paired Apple Watch automatically, so an alarm still sounds and can be stopped from your wrist without a bundled watch app.

Also worth knowing:

- **Widget data needs an App Group**, which free personal teams cannot use. Under free signing the widgets install and render but show *"Open SuperAlarm"* instead of live data. With a paid account, add the App Group capability and it lights up. The app detects this and degrades cleanly.
- **Imported audio ("My Music")** plays through the app's own engine. The system's lock-screen alert falls back to a built-in tone, because AlarmKit and notification sounds can only reference files inside the app bundle.
- **iOS 26.0** had a bug where AlarmKit custom sounds played the system error tone; the app falls back to the default alarm sound on that exact version. 26.1+ is fine.

---

## Architecture

```
Models/        Alarm, MissionSettings, AppSettings, WakeRecord + statistics
Store/         SharedStorage (atomic JSON, App Group aware) · AlarmStore
Scheduling/    AlarmCoordinator ─┬─ AlarmKitBackend   (iOS 26+, primary)
                                 └─ NotificationScheduler (fallback + extras)
               AlarmRuntime — the ring/mission/snooze/wake-check state machine
Audio/         AlarmAudioEngine · SystemVolume · HapticEngine · VoiceBriefing
               SleepSoundPlayer · CustomToneStore · SoundCatalog (generated)
Missions/      Cognitive · Motion · Camera · Biometric · MissionSession
Views/         Design system + every screen
```

**Why two schedulers.** AlarmKit is the only way to break through Silent mode and Focus, and it survives force-quit and reboot — but it needs iOS 26. Below that, a chain of local notifications 30 s apart plus a background-audio keep-alive carries the load. When AlarmKit is active the notification chain is deliberately *suppressed* so the two cannot alert on top of each other; the redundancy is available as an opt-in setting.

**Why a backstop chain.** Apple documents that a physical button press dismisses an AlarmKit alarm outright (not snooze), and that `stopIntent` does not fire on every dismissal path. Only the *currently alerting* alarm is dismissed, so alarms spaced two minutes apart survive a button mash. The chain stands down only when the app has verified the mission is complete.

---

## Developing

```powershell
node tools/generate-sounds.js   # 32 tones + 5 sleep sounds + keep-alive loop
node tools/verify-sounds.js     # header, duration, loudness and loop-seam checks
node tools/generate-icon.js     # 1024px app icon
node tools/preflight.js         # static checks that need no Swift toolchain
node tools/symbol-check.js      # resolves every MyType.member reference
node tools/typecheck-lite.js    # switch exhaustiveness + initialiser labels
```

On a Mac: `brew install xcodegen && xcodegen generate && open SuperAlarm.xcodeproj`.

Generated audio and the icon are gitignored — the scripts are the source of truth, and CI regenerates them on every run.

### What is verified where

This project was written on Windows, where no Swift compiler can run: Swift for Windows links through MSVC and needs Visual Studio plus the Windows SDK, and the toolchain itself needs an elevated install. So verification is split.

**Locally, with no compiler** — three tools, all of which also run in CI so they fail in seconds rather than after a full Xcode cycle:

- `preflight.js` — brace balance, duplicate top-level declarations, widget-target isolation, per-file framework imports, tone identifiers resolving against the generated catalog, required Info.plist keys, absence of an entitlements file, and GitHub workflow block-scalar indentation.
- `symbol-check.js` — indexes every type and member the project declares, then resolves every `MyType.member` reference against that index.
- `typecheck-lite.js` — four checks a compiler would normally do: switch statements over project enums are exhaustive; initialiser calls match a declared signature (accounting for default values, trailing closures and inits declared in extensions); no local shadows a property name that was already used earlier in the same scope; and no `ViewBuilder` container exceeds its ten-child limit.

Each was validated against deliberately broken code to confirm it actually fires rather than passing vacuously.

**In CI, with a real compiler** — the actual build, and 71 unit tests covering scheduling maths, mission generators, statistics and streaks, and persistence migration from older records.

`tools/core-tests.js` assembles the platform-independent core (models, mission generators, statistics) into a throwaway SwiftPM package and runs the portable subset of the test suite. It needs a Swift toolchain and MSVC, so it does nothing on a bare Windows box — it exists for anyone who has those, or on Linux.

### Changing the bundle identifier

Default is `com.superalarm.app`. Run the workflow manually (**Actions → Build IPA → Run workflow**) and enter a different one, or edit `project.yml`.
