# SuperAlarm — Final Pristine Build

Take SuperAlarm (`C:\Users\RMS11\Desktop\SuperAlarm`, GitHub `Ryguy1515/SuperAlarm`, branch `main`) from "works on a simulator" to a build I would trust to wake me up. Fix the three bugs I found on a real iPhone, then run a full bug sweep and a UI/UX refinement pass with subagent teams, and don't stop until CI is green on a build that contains all of it. Use a workflow / subagent teams for the sweep phases.

## Context you need

- Native SwiftUI, iOS 17+, AlarmKit on iOS 26 with a UserNotifications chain as the fallback. No Mac: the only compiler is the GitHub Actions macOS runner (`.github/workflows/build-ipa.yml`); failures surface as `::error::` annotations at `GET /repos/Ryguy1515/SuperAlarm/check-runs/{id}/annotations`. Job logs and artifact downloads 403 without admin auth.
- Local gates that must stay at zero: `node tools/preflight.js`, `node tools/symbol-check.js`, `node tools/typecheck-lite.js`, `node tools/verify-sounds.js` (after `node tools/generate-sounds.js`). Read `README.md` → "Verify it actually works" and `docs/TROUBLESHOOTING.md` first.
- Installed with a free Apple ID via Sideloadly. Anything that breaks free signing is off the table: no new entitlements, no App Groups, no Family Controls / ManagedSettings, no second bundle ID (no Watch app), no reliance on the critical-alert entitlement. Widgets already degrade to "Open SuperAlarm" and that's fine.
- My phone is on the newest iOS (AlarmKit path). The build I tested was `22a710f` (pre-camera). The camera rep counter (`87ef6f1` / `5f4d610`) is untested on hardware and is in scope for the sweep.
- Nothing has ever run on a physical iPhone except one shaker-alarm test. All 90 simulator tests pass. Treat "passes on simulator" as necessary, not sufficient.

## Platform truths — do not chase the impossible

iOS will not let a third-party app block the Home gesture, the app switcher, force-quit, or the hardware volume buttons. What the app can do:

1. **Volume:** observe `AVAudioSession.outputVolume` and immediately push it back up through the hidden `MPVolumeView` slider. The user can press down; the app snaps it back within a frame. That is the standard "volume lock" and it is what the App Store SuperAlarm does.
2. **Leaving the app:** keep the app's audio playing in the background (`UIBackgroundModes: audio` is already declared) and make the system re-summon the user relentlessly — AlarmKit backstops and/or a time-sensitive notification chain — until the mission is verifiably complete. The correct experience: I swipe home, the alarm keeps blaring, a "Finish your mission" notification lands within seconds, and tapping it puts me straight back on the ring screen mid-mission.
3. **Force-quit:** the process is gone; only system-scheduled alarms survive. The backstop/chain must be armed before the user can act, spaced tightly, and relaunching the app must resume the ring + mission from persisted state, not show the alarm list.

Anything beyond this (Guided Access, MDM, "deletion prevention") is documented as out of scope — do not build it.

## P0 — Field-observed bugs (fix first, each with a test or a documented device check)

### 1. Volume can be turned down during the shake mission

**Observed:** while shaking, pressing volume-down lowered the alarm and it stayed low.

**Where:** `SuperAlarm/Audio/AlarmAudioEngine.swift` `startVolumeLock()` (0.5 s polling timer) and `SuperAlarm/Audio/SystemVolume.swift` (`MPVolumeView` slider, attached lazily to `keyWindow` at ring time).

**Likely causes to verify and fix:**

- Polling every 0.5 s is too slow and racy. Replace with KVO on `AVAudioSession.sharedInstance().outputVolume` (`observe(\.outputVolume, options: [.new])`) and reset on change; keep a slow timer only as a safety net.
- `SystemVolume.prepare()` is first called at ring time; `keyWindow` may be nil or the slider not yet vended while the ring screen is a `fullScreenCover`. Prepare at app launch, log loudly if the slider is never found, and expose that state in Settings › Diagnostics.
- `lockedVolumeTarget` is captured once; confirm it is 1.0 when `overrideSystemVolume` is on and that `set()` actually takes effect on iOS 17/18/26 — the slider technique has changed behaviour across versions; research current behaviour, don't assume.
- The player's own gain must stay at 1.0 regardless of hardware volume so the floor is as loud as the OS permits.

**Acceptance:** during ring + mission, pressing volume-down produces at most a momentary dip and the volume HUD shows it snapping back. Add a unit test for the lock's decision logic and a device-check line for the rest.

### 2. Force-quitting the app silences the alarm

**Observed (newest iOS, so the AlarmKit path):** while ringing I could swipe home and it kept ringing — good. But opening the app switcher and swiping the app away killed the alarm outright, and it never came back.

**Where:** `AlarmKitBackend` — `SuperAlarmOpenMissionIntent` ("Turn off") calls `AlarmManager.shared.stop` and hands over to in-app audio, so from that moment nothing system-level is ringing; backstops are 5 × 120 s (`backstopCount` / `backstopSpacing`). `AlarmRuntime.startRinging` arms them (~line 366) but only via `systemBackend`. `NotificationScheduler` has a 30 s chain but `redundantNotificationBackup` defaults to false, so it never runs on AlarmKit devices. `restoreState()` on cold launch. `RootView` (`fullScreenCover` + `interactiveDismissDisabled`).

**Required behaviour — a force-quit must be pointless:**

- **Preferred design:** keep the AlarmKit alert alive through the whole mission. Do not stop the system alarm when the app opens; let the system alert keep sounding (it survives force-quit and lock) and only stop it in the one place a mission is verified complete (`AlarmRuntime` ~528). The app's own audio engine then becomes the volume-lock / gradual-ramp layer on top, or is muted while the system alert carries the sound — research how an AlarmKit alert behaves alongside app audio and with the side buttons, and pick the combination that is loudest and least escapable. If the system alert cannot stay up while the app is foregrounded, fall back to the next two bullets and say so.
- **Backstops tight and universal:** armed the instant the alarm fires, first re-fire within ~30 s of a kill, then every 30–60 s, on every backend, and enable the notification chain alongside AlarmKit by default. Nothing but verified mission completion may cancel them — audit every `cancelBackstops` call site (`AlarmKitBackend` 210/336/366) and the stop/snooze/"I'm up" paths in `AppDelegate.didReceive` and both intents.
- **Relaunch resumes the ring.** After a force-quit, tapping the backstop/notification (or just opening the app) must land on the ring screen for the same alarm with the mission still owed — not the alarm list, not a reset. Persist alarm ID, occurrence, phase and mission progress; cover `restoreState()` with tests.
- **Backgrounding** already keeps audio going; keep it that way and add the ≤5 s "Alarm still ringing — finish your mission" time-sensitive notification, repeating every 20–30 s, that reopens straight into the mission.

**Acceptance:** unit tests for arming/stand-down invariants and state restore; a device checklist covering swipe-home, app-switcher kill (wait 60 s), and lock-screen paths.

### 3. Walking mission is buggy

**Observed:** step counting is erratic / laggy / doesn't feel like it tracks me.

**Where:** `SuperAlarm/Missions/MotionMissions.swift` `startSteps()` — `CMPedometer.startUpdates(from: Date())` only.

**Known behaviour to design around:** `CMPedometer` batches updates every few seconds with roughly a 5–10 step latency and can take longer for the first callback; the count is cumulative from start. Fix candidates: poll `queryPedometerData(from:to:)` every ~1 s alongside live updates; show immediate "movement detected" feedback (`CMMotionActivityManager` or accelerometer magnitude) so the user sees the phone reacting before steps land; make the engine survive view re-renders and backgrounding without resetting; handle the first-ever Motion permission prompt appearing mid-mission; handle `stop()` being called from inside the update callback. Re-examine goal defaults (a 20-step goal with 10-step latency feels broken). Re-check the shake mission for the same re-render/reset class of bug, since it shares the engine.

**Acceptance:** mission-logic tests for the counting model with simulated pedometer batches; device checklist.

## Phase plan

### Phase 0 — Orient

Read README, TROUBLESHOOTING, the four test files, and the files named above. Record a baseline: tool outputs, test count, latest CI run.

### Phase 1 — P0 fixes

Fix the three bugs above. Push and confirm CI green before Phase 2, so a later regression is attributable.

### Phase 2 — Bug sweep (parallel subagent team: findings only, then a fix pass)

Each agent reports file:line, severity (P0 crash / data loss / alarm doesn't fire; P1 wrong behaviour; P2 polish), a concrete failure scenario, and a proposed fix. Verify each P0/P1 adversarially before fixing. Areas:

- **Alarm reliability:** scheduling math (repeat days, DST, midnight rollover, snooze limits, catch-up window), AlarmKit ↔ notification fallback parity, authorization-denied paths, `mostRecentFireDate`, wake-up check, pre-alarm, bedtime.
- **Missions:** every type (math, memory, typing, QR/barcode/photo scan, shake, steps, squats, push-ups, biometric, camera pose) — permission-denied UI, retry/failure counters, timeout, mission-time accounting, escape paths, pose thresholds and tracking-loss handling.
- **Audio:** session category and interruptions (phone call, Siri, other audio), silent switch, gradual ramp, custom tones, voice briefing overlap, keep-alive battery behaviour, headphone/Bluetooth route changes.
- **Persistence & store:** `SharedStorage` millisecond dates, migration of older saved data, flush on every lifecycle edge, widget refresh under free signing, stats/streak math.
- **Lifecycle:** cold start, background, force-quit, Low Power Mode, Focus modes, Do Not Disturb, locked device.
- **Concurrency & Swift correctness:** `@MainActor` isolation, retain cycles in timers/observers, observers never removed, force unwraps, `try?` swallowing real errors.
- **CI/tooling:** anything the lite tools miss that the compiler would catch; test flakiness; artifact contents.

### Phase 3 — UI/UX refinement (parallel subagent team)

Goal: pristine, refined, consistent with `Views/DesignSystem.swift`, and faithful to the real SuperAlarm's flow where fidelity was the intent. Agents:

- **Flow audit** — onboarding → first alarm → ring → mission → stats: every screen, empty state, error state and permission prompt. Kill dead ends and double-taps.
- **Visual consistency** — spacing, type scale, colours, corner radii, iconography, button hierarchy; Dark Mode; Dynamic Type up to accessibility sizes; wide layouts not breaking.
- **Ring & mission screens specifically** — used half-asleep: huge targets, zero ambiguity, obvious progress, no control that looks like "stop" but isn't, clear feedback that volume is locked and that leaving won't help. The pose mission's counter/gauge/skeleton must read at arm's length.
- **Accessibility** — VoiceOver labels, Reduce Motion, colour-blind-safe status colours, haptics.
- **Copy** — every string: consistent tone, no developer-speak, no guidance that cannot physically work.

Fix what they find; do not restyle for its own sake.

### Phase 4 — Regression + ship

All tools at zero, all tests green, new tests for every fix, README/TROUBLESHOOTING updated (including a truthful "what iOS does not allow" section), focused commits, push, wait for CI, and give me the artifact link. Then give me a device test checklist ordered by risk — volume lock, swipe-home, force-quit, lock screen, each mission — with what "pass" looks like, because you cannot run the hardware and I can.

## Definition of done

- CI green on `main`; `SuperAlarm-ipa` artifact link in the final message.
- Volume-down during a ringing alarm snaps back; killing the app from the app switcher does not end an alarm; the app relaunches into the outstanding ring; the walking mission tracks smoothly.
- Every P0/P1 from the sweep fixed with a test, or explicitly deferred with a reason; P2s fixed where cheap.
- UI/UX findings resolved; Dark Mode and Dynamic Type verified in code.
- Free-account signing unaffected (no new entitlements or bundle IDs); docs honest about platform limits.
- A device test checklist I can run in ten minutes.

## Working agreement

Work autonomously. Don't ask me to confirm routine calls; do ask before removing any existing feature. Report failures truthfully — a red CI run with an explanation beats a claimed green.
