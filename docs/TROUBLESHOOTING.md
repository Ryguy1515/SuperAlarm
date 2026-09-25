# Troubleshooting

Ordered by where people actually get stuck.

---

## The GitHub build

**The workflow didn't start.**
Actions are disabled by default on forks and sometimes on new repos. Open the **Actions** tab and click *"I understand my workflows, go ahead and enable them"*. You can also start it by hand: **Actions → Build IPA → Run workflow**.

**"macos-26 is not a valid runner label".**
GitHub retired the image. Change `runs-on: macos-26` in `.github/workflows/build-ipa.yml` to `macos-latest`, but check the log's "Show toolchain" step afterwards — if the Xcode version is older than 26, AlarmKit will not compile and you'll need a runner image that has it.

**The build burns through free minutes.**
Only on **private** repos. Public repositories get unlimited macOS minutes. If you'd rather keep it private, expect roughly 10–13 builds a month on the free tier.

**`xcodegen: command not found`.**
The Homebrew step failed, usually a transient network error. Re-run the job.

**Tests fail but you want the `.ipa` anyway.**
Comment out the *Run unit tests* step. Do read what failed first — the tests cover alarm scheduling maths, which is exactly the thing you don't want quietly broken.

---

## Sideloading

**Sideloadly can't see the iPhone.**
Almost always the wrong iTunes. Uninstall the **Microsoft Store** version, install iTunes from `apple.com` directly, and reboot. Then reconnect and tap **Trust** on the phone.

To confirm the drivers landed, open Device Manager with the phone plugged in and unlocked: **Apple Mobile Device USB Device** should be listed. If it is not, the Store build is probably still installed.

iCloud for Windows is **not** required — that is an AltStore prerequisite. Apple now ships iCloud through the Microsoft Store only, so there is no direct download to hunt for.

**"Provisioning profile doesn't include the … entitlement".**
This project deliberately ships no entitlements file, so if you see this you've added one. Remove it. Free personal teams cannot use App Groups, push, iCloud or in-app purchase, and requesting any of them fails signing outright.

**Signing fails somewhere inside `PlugIns`.**
That's the widget extension. Use `SuperAlarm-no-widget.ipa` from the same artifact — identical app, no widgets.

**"Unable to install — the maximum number of apps has been reached".**
A free Apple ID allows 3 sideloaded apps at once. Remove one.

**"This app cannot be installed because its integrity could not be verified".**
The 7-day certificate expired. Re-run Sideloadly. **Don't delete the app** — re-signing keeps every alarm and all your history. Deleting loses it.

**The app installs but immediately closes.**
Enable **Settings → Privacy & Security → Developer Mode**, then restart the phone. Also check **Settings → General → VPN & Device Management** and trust your Apple ID.

---

## The alarm itself

**Diagnostics says "Notifications" instead of "AlarmKit".**
You're below iOS 26, or the alarm permission was declined. On iOS 26+, go to **Settings → Diagnostics → Permissions** in the app and grant it. Without AlarmKit the alarm cannot break through Silent mode — turn **Background keep-alive** on in Settings and leave the ringer on.

**It didn't break through a Focus mode or Sleep Focus.**
On iOS 26 the system alarm and its follow-ups always break through; that is what AlarmKit is for. The *notifications* — the repeat chain, the still-ringing reminders, the wake-up check — are marked time-sensitive, but without Apple's time-sensitive entitlement (which free signing cannot include) iOS may treat them as ordinary notifications and hold them during a Focus. On iOS 17 and 18, where notifications are the only mechanism, allow SuperAlarm in your Sleep Focus (**Settings → Focus → Sleep → Apps**) or the chain will be muted exactly when you need it.

**The alarm didn't go off at all.**
Check, in this order:
1. **Diagnostics** — is the alarm mechanism authorised, and does *Next alarm* show the time you expect?
2. Was the app's certificate still valid? An expired build cannot run, and on the notification fallback path that means no alarm.
3. Low Power Mode aggressively suspends background audio. It does not affect AlarmKit.

**It rings twice, overlapping.**
On iOS 26 the first alert is the system alarm alone; the notification chain deliberately starts 45 seconds later and keeps re-summoning you until the mission is done, so a force-quit cannot end the alarm. If you would rather have the system alarm and its backstops only, turn off **Settings → Reliability → Extra notification backup**.

**It's not loud enough.**
Open the alarm's Sound screen and confirm **Override device volume** is on and the volume slider is at maximum. Pick a tone from the **Noisy** category — Air Raid, Police Siren and Battle Stations are the most aggressive. Turn **Gradually increase volume** off if you want full blast from the first second.

**Volume buttons kill the alarm.**
Expected on iOS 26 for the *system* alert: Apple made any physical button dismiss an alerting AlarmKit alarm. That's precisely why **backstop alarms** are armed together with every alarm — the first lands 30 seconds later and they keep coming until the mission is genuinely completed. Once the app is open and ringing, the side buttons only lower the volume for a frame; the volume lock puts it straight back and the ring screen shows *Volume restored*. (The system volume HUD does not appear inside the app; that is a side effect of the volume control, not a sign the buttons are being ignored.)

**The alarm came out of my headphones or a Bluetooth speaker.**
Expected. The app plays through whatever audio route is active, and iOS gives no way to force the built-in speaker for alarm-style playback. Take the headphones off or turn the speaker off before bed. Unplugging wired headphones mid-alarm is handled: playback carries on through the speaker.

**No vibration on silent.**
iOS only vibrates on silent if **Settings → Sounds & Haptics → Play Haptics in Silent Mode** is on. On iOS 26 the system alarm vibrates regardless.

**My shake or push-up count reset after the app was killed.**
The walk mission resumes its step count after a relaunch because the pedometer can be asked for the whole mission window; shakes, reps and camera reps are counted live and start again from zero. The mission itself is still owed — the alarm does not reset.

**A mission won't recognise me.**
Wait for the **"Can't complete this?"** link at the bottom of the mission screen (it appears after a couple of minutes, configurable per alarm), hold the button and type *"I give up"*. The alarm stops. Then switch that alarm to a deterministic mission — Math, Face ID, Barcode or Walk are far more reliable than camera-based object recognition in a dark bedroom.

**The object-scan mission never matches.**
It compares visual similarity, so it needs comparable lighting. Something photographed in daylight often won't match at 6am. Register the reference under the light you'll actually have, fill the frame, and pick something with strong texture. A barcode is the more reliable version of the same idea.

**Step counting seems stuck.**
The pedometer reports in batches a few seconds behind your feet, so the counter jumps rather than ticking. The screen turns green with *Movement detected* the moment you start moving, before the first batch lands — if it does not, the phone is not moving with you: carry it, don't leave it on the bed. If the counter never moves at all, make sure **Settings → Privacy & Security → Motion & Fitness** is on for SuperAlarm; the mission tells you when it is off.

---

## Widgets

**The widget says "Open SuperAlarm" and never updates.**
Expected under free-account signing. Widgets run in their own process and can only read the app's data through an **App Group**, which free personal teams cannot use. With a paid Apple Developer account, add an App Group named `group.io.superalarm.shared` to both targets in `project.yml` and it starts working. The app detects this and reports it in **Diagnostics → Shared container**.

---

## Getting your data out

Alarms, settings and history are plain JSON in the app container:

```
<container>/SuperAlarm/alarms.json
<container>/SuperAlarm/settings.json
<container>/SuperAlarm/history.json
```

Pull them with iMazing or any iOS file browser before you delete the app.
