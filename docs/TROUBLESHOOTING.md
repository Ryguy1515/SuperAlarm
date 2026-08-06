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
Almost always the wrong iTunes. Uninstall the **Microsoft Store** versions of iTunes and iCloud, then install both from `apple.com` directly. Reboot, reconnect, and tap **Trust** on the phone.

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

**The alarm didn't go off at all.**
Check, in this order:
1. **Diagnostics** — is the alarm mechanism authorised, and does *Next alarm* show the time you expect?
2. Was the app's certificate still valid? An expired build cannot run, and on the notification fallback path that means no alarm.
3. Low Power Mode aggressively suspends background audio. It does not affect AlarmKit.

**It rings twice, overlapping.**
Turn off **Settings → Reliability → Extra notification backup**. That setting deliberately schedules a second, independent alert; it's off by default for this reason.

**It's not loud enough.**
Open the alarm's Sound screen and confirm **Override device volume** is on and the volume slider is at maximum. Pick a tone from the **Noisy** category — Air Raid, Police Siren and Battle Stations are the most aggressive. Turn **Gradually increase volume** off if you want full blast from the first second.

**Volume buttons kill the alarm.**
Expected on iOS 26: Apple made any physical button dismiss an alerting AlarmKit alarm. That's precisely why a **backstop alarm** is armed every time one starts — the next one lands two minutes later and keeps coming until the mission is genuinely completed.

**A mission won't recognise me.**
Wait for the **"Can't complete this?"** link at the bottom of the mission screen (it appears after a couple of minutes, configurable per alarm), hold the button and type *"I give up"*. The alarm stops. Then switch that alarm to a deterministic mission — Math, Face ID, Barcode or Walk are far more reliable than camera-based object recognition in a dark bedroom.

**The object-scan mission never matches.**
It compares visual similarity, so it needs comparable lighting. Something photographed in daylight often won't match at 6am. Register the reference under the light you'll actually have, fill the frame, and pick something with strong texture. A barcode is the more reliable version of the same idea.

**Step counting seems stuck.**
The pedometer reports in batches every second or two rather than per step. Make sure **Settings → Privacy & Security → Motion & Fitness** is on for SuperAlarm.

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
