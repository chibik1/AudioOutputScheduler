# Audio Output Scheduler — Specification

Version 1.0 · macOS 14+

This document describes the behavior, data formats and internals of Audio Output Scheduler.
For installation and everyday use, see the [README](../README.md).

## 1. Overview

Audio Output Scheduler changes the macOS **default output device** at user-defined times on
user-selected days. If audio is playing on the current output at the scheduled time, the switch
is deferred until playback stops. The user is notified when a switch happens or fails.

## 2. Components

| Component | Location | Role |
| --- | --- | --- |
| **App** | `/Applications/Audio Output Scheduler.app` (`io.github.chibik1.audiooutputscheduler`) | SwiftUI settings window. Edits the schedule, installs the launchd job, shows live status. Not needed at switch time. |
| **Helper** | `…/Contents/Library/Helpers/AudioOutputSchedulerHelper.app` (`io.github.chibik1.audiooutputscheduler.helper`, `LSUIElement`) | Command-line executable inside its own bundle. Performs the switch, waits for silence, posts notifications. |
| **launchd agent** | `~/Library/LaunchAgents/io.github.chibik1.audiooutputscheduler.plist` | Starts the helper at every scheduled time. |
| **Config** | `~/Library/Application Support/AudioOutputScheduler/schedule.json` | Single source of truth shared by app and helper. |
| **Status file** | `~/Library/Application Support/AudioOutputScheduler/status.txt` | Exists only while the helper is waiting for silence. |
| **Log** | `/tmp/audio-switch.log` | Helper stdout/stderr. |

Source layout:

```
Sources/Shared/Shared.swift   Core Audio access, device classification, config model, scheduler, launchd installer
Sources/App/App.swift         SwiftUI app (store, main window, editor)
Sources/Runner/main.swift     Helper: switching loop, silence detection, notifications
Tools/icon.swift              Renders the app icon (1024 px) with AppKit
Resources/*.plist             Info.plist for the app and the helper
build.sh                      Compiles, renders the icon, assembles and ad-hoc signs both bundles
```

The helper lives in its own bundle so that `UNUserNotificationCenter` has a bundle identity and
an icon, and so notification permission belongs to it.

## 3. Configuration file

`schedule.json`, written atomically by the app (pretty-printed, sorted keys):

```json
{
  "entries" : [
    {
      "device" : "DELL U2724DE",
      "hour" : 8,
      "id" : "1B5FF39F-AF5E-4117-8A36-3DEF07882DEA",
      "minute" : 0,
      "weekdays" : [1, 2, 3, 4, 5, 6, 7]
    }
  ],
  "ignoredApps" : ["com.apple.garageband10", "com.apple.logic10", "com.apple.mainstage3",
                   "com.steinberg.cubase", "com.ableton.live"],
  "notify" : true,
  "waitForSilence" : true
}
```

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `entries[].id` | UUID | new | Stable identity used for editing. |
| `entries[].hour`, `minute` | Int | — | 0–23, 0–59. |
| `entries[].device` | String | — | Output device **name** as reported by Core Audio. |
| `entries[].weekdays` | Set\<Int\> | 1…7 | `Calendar` weekdays: 1 = Sunday … 7 = Saturday. Empty = schedule is off. |
| `waitForSilence` | Bool | `true` | Defer switching while audio is playing. |
| `ignoredApps` | [String] | DAWs | Bundle-ID **prefixes** excluded from playback detection. |
| `notify` | Bool | `true` | Post notifications from the helper. |

Missing keys fall back to their defaults, so older files keep working.
If the file does not exist, the app starts with an empty schedule and default settings.

**Uniqueness rule:** two entries may share a time only if their weekdays don't overlap. When an
entry is saved, any other entry at the same time loses the overlapping days (and is removed if
none remain). The editor warns before this happens.

## 4. Scheduling

### 4.1 launchd job

The app (re)writes the agent whenever the config changes:

- `ProgramArguments` = path to the helper executable inside the installed app.
- `StartCalendarInterval` = one `{Hour, Minute}` dict per **distinct time** among entries that
  have at least one weekday. Weekday filtering is done by the helper, not by launchd.
- `ProcessType` = `Background`; stdout/stderr → `/tmp/audio-switch.log`.

The job is reloaded (`launchctl bootout` + `bootstrap` in `gui/<uid>`) **only if the generated
plist differs** from the one on disk or the job isn't loaded. This prevents unrelated edits
(e.g. toggling notifications) from killing a helper that is currently waiting for silence. If no
entry is active, the job is unloaded and the plist removed. The app also re-installs the job on
every launch, so moving the app updates the helper path.

launchd coalesces fires missed during sleep into one fire at wake; combined with 4.2 this makes
the Mac catch up to the correct device after sleep.

### 4.2 Choosing the target

Each run computes the entry that should be in effect *now*: the most recent occurrence at or
before the current time, looking back up to 7 days.

```
for offset in 0...7:
    day      = today − offset
    weekday  = weekday(day)
    candidates = entries where weekday ∈ entry.weekdays
                 and (offset > 0 or entry.minutes ≤ now.minutes)
    if candidates: return the one with the largest minutes
return none
```

Because the target is recomputed on every loop iteration (4.4), config edits and the passing of
the next scheduled time are picked up while waiting.

## 5. Playback (silence) detection

`kAudioDevicePropertyDeviceIsRunningSomewhere` is not usable on its own: DAWs and browsers keep
the device running while silent. Detection is therefore done per process:

1. Read `kAudioHardwarePropertyProcessObjectList` from the system object (macOS 14+).
2. Keep processes whose `kAudioProcessPropertyIsRunningOutput` ≠ 0 **and** whose
   `kAudioProcessPropertyDevices` (output scope) contains the current default output device.
3. Discard processes whose `kAudioProcessPropertyBundleID` has a prefix in `ignoredApps`
   (prefix matching covers helpers such as `com.google.Chrome.helper`).
4. "Playing" = at least one process remains.

Processes without a bundle ID (e.g. `afplay`) count as playing.

## 6. Helper run loop

```
waiting = false
loop every 1 s:
    config = load()
    target = Scheduler.target(config)            → none: log, exit
    device = output device named target.device   → missing: notify "not connected", exit
    if current default output == device:          exit
    if waitForSilence and playing(current):
        waiting = true; quietSince = nil; write status file
    else if waitForSilence and waiting and quiet for < 3 s:
        keep waiting
    else:
        set kAudioHardwarePropertyDefaultOutputDevice = device
        notify "Sound output switched"; exit
remove status file on exit (also on SIGTERM)
```

- If nothing is playing at fire time, the switch is immediate (no 3 s delay).
- After playback was detected, 3 consecutive seconds of silence are required.
- There is no timeout: if the target changes while waiting, the new target is used; if the
  current device becomes the target, the helper exits.
- Only the default *output* device is changed (not the system-alert device or input).

Status file format: `HH:MM<TAB>Device name`. The app polls it every 2 s and shows
"Waiting for audio to stop — will switch to …".

### Helper arguments

| Argument | Effect |
| --- | --- |
| *(none)* | Normal scheduled run (above). |
| `--authorize` | Requests notification permission, then exits. Run by the app on launch and when notifications are enabled. |

## 7. Notifications

- Posted by the helper with `UNUserNotificationCenter` (title + body, no sound by default).
- A `UNUserNotificationCenterDelegate` returns `[.banner, .list, .sound]` from `willPresent`, so
  banners appear even if the system considers the helper foreground.
- After `add`, the helper keeps its run loop alive briefly (≤ 3 s) so presentation can complete.
- Messages:
  - `Sound output switched` — `Now playing through <device>.` / `… (after playback stopped).`
  - `Couldn't switch sound output` — `<device> is not connected (<HH:MM> schedule).` or
    `Switching to <device> failed.`

macOS hides banners while the display is mirrored or shared (setting
*Allow notifications when mirroring or sharing the display*); virtual displays can trigger this.

## 8. Device classification

Kinds are derived from `kAudioDevicePropertyTransportType` plus the device name:

| Transport | Kind | SF Symbol | Color |
| --- | --- | --- | --- |
| BuiltIn | Built-in Speakers / Built-in Headphones¹ | `laptopcomputer` / `headphones` | gray |
| DisplayPort, HDMI | External Display | `display` | blue |
| Bluetooth, BluetoothLE | Bluetooth | `headphones` | pink |
| AirPlay | AirPlay | `airplayaudio` | teal |
| Virtual | Virtual Output | `waveform` | purple |
| Aggregate, AutoAggregate | Multi-Output Device | `square.stack.3d.up.fill` | indigo |
| anything else (USB, Thunderbolt, PCI, unknown) | Audio Interface / Headphones¹ | `slider.vertical.3` / `headphones` | orange / pink |
| device not present | Not connected | `questionmark` | secondary |

¹ when the name contains *headphone*, *headset*, *AirPods* or *ヘッドフォン*.

Only devices with output streams are listed; duplicate names are shown once. Some drivers
report no transport type (e.g. Steinberg UR-C multi-device mode); these appear as Audio Interface.

## 9. User interface

**Main window** (fixed width, top-aligned)
- Header and description.
- One row per entry, sorted by time: large time, device icon, device name and kind (or
  "Off — no days selected"), weekday chips *Su Mo Tu We Th Fr Sa* (click to toggle), edit and
  delete buttons. Double-click a row to edit. Rows with no days are dimmed.
- **Add Schedule** button.
- *Wait until audio stops playing* switch with explanation.
- Ignore list (shown while waiting is enabled): apps currently using the output (tagged
  *Using audio now*) plus installed apps already ignored, each with an **Ignore** checkbox;
  **Add App…** opens a panel in `/Applications` (multiple selection) and stores each bundle ID.
- *Show a notification when the output switches* switch.
- Live status: waiting banner, errors, and *Current output: …* (refreshed every 2 s and on activation).

**Editor sheet**
- Left: scrollable list of output devices with icons and kinds; a not-connected device of an
  existing entry is kept in the list.
- Right: selected device (large icon, name, kind) · **Hour** and **Minute** spin buttons that
  wrap (23 → 00, 59 → 00) · minute presets `:00 :15 :30 :45` · day chips with *Every day /
  Weekdays / Weekends* · overlap warning.
- New entries default to the current output device, 08:00, every day.
- **Save** (Return) / **Cancel** (Esc).

Closing the window quits the app; scheduling keeps working through launchd.

## 10. Build

`build.sh` compiles two executables with `swiftc -O` (no Xcode project), renders the icon with
`Tools/icon.swift`, builds an `.icns` with `sips` + `iconutil`, assembles both bundles, and
ad-hoc signs them (helper first). `--install` copies the app to `/Applications` and registers
both bundles with Launch Services.

## 11. Limitations

- Devices are matched by name; renaming a device (e.g. in Audio MIDI Setup) breaks its schedules.
- Playback detection reflects an open, running output stream, not actual signal level; apps that
  keep streams running while silent must be ignored manually.
- Times use the Mac's local time zone; there is no per-schedule time zone.
- Ad-hoc signed; not notarized. Bundle identifiers use the `io.github.chibik1.` prefix.
