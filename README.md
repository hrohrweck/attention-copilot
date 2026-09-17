# Attention Copilot

Attention Copilot is a cross-platform meeting-attention app for **Linux,
Windows, macOS and Android**. It shows today's agenda with the next meeting
front and centre and a live countdown, so you always know what is coming up.
When a meeting needs you, it raises un-ignorable, acknowledgement-gated alerts
— full screen, loud, repeating — that stop only when you explicitly
acknowledge them. On the desktop it watches whether you are actually there:
if your screen is locked or you have walked away, it stays silent and alarms
you the moment you come back, instead of disturbing an empty desk.

Read-only by design: it never creates, edits or deletes calendar entries, and
it ships **no telemetry** — nothing leaves your machine except the calendar
requests you explicitly enable. See [Privacy](docs/PRIVACY.md).

> This project is not affiliated with, endorsed by, or related to any other
> application that happens to share the "Attention Copilot" name.

## Install

Builds are produced by the release workflow (see
[Releasing](docs/RELEASING.md)); the guaranteed artifacts per platform are:

| Platform | Artifact | First-run note |
| --- | --- | --- |
| macOS | `attention-copilot-<ver>-macos.dmg` (unsigned) | Right-click → Open the first time (Gatekeeper) |
| Windows | `attention-copilot-<ver>-windows-x64.zip` | SmartScreen → "More info" → "Run anyway" |
| Linux | `attention-copilot-<ver>-linux-x64.tar.gz` | Unpack and run the `attention_copilot` binary |
| Android | `attention-copilot-<ver>-android.apk` | Sideload (signed with the debug key) |

The `.deb`, `.AppImage` and Windows installer are best-effort extras in the
same release; the table above lists the always-produced ones.

Or build from source with Flutter **3.47.4** (see
[Decisions](docs/DECISIONS.md) for the pinned SDK):

```bash
flutter pub get
flutter run -d <your-device>        # or: flutter build macos|windows|linux|apk
```

## 60-second quick start

1. Install and launch the app.
2. The onboarding wizard opens. Connect a calendar source:
   - **macOS** → enable "macOS Calendar" and grant the system prompt.
   - **Android** → enable "device calendars" and grant the prompt (this
     covers Google calendars synced to the device).
   - **Any desktop** → paste your own Google client ID and sign in
     (walkthrough: [Google OAuth](docs/GOOGLE_OAUTH.md)), or paste an ICS /
     `webcal` calendar URL — zero sign-in required.
3. The today-first agenda appears with the next meeting dominant.
4. Press **Test Alert** (Settings gear, or the tray menu) — a full-screen
   alert rings a few seconds later and stops only when you acknowledge it.
   If it doesn't ring, see
   [Troubleshooting](docs/TROUBLESHOOTING.md).

Done. You now have acknowledgement-gated alerts at your configured lead times
(defaults: 10 and 1 minute before each meeting).

## Features

- **Today-first agenda** — the current day's appointments in chronological
  order, with the next meeting visually dominant and a live countdown.
  All-day events get their own strip; past meetings are muted.
- **Un-ignorable alerts** — full-screen always-on-top window (one per
  connected display) plus looping audio. Closing the window does not stop
  it: **explicit acknowledgement is the only way an alert ends.**
- **Configurable lead times** — one or more lead times per meeting (default
  10 + 1 minutes). Short lead times use the loud urgent profile; long ones
  the gentle heads-up chime.
- **Escalation while unacknowledged** — audio repeats, volume ramps up, the
  window re-raises itself and the accent changes until you acknowledge.
- **Presence-aware deferral (desktop)** — while your screen is locked or you
  are away beyond the quiet threshold, due alerts are deferred silently and
  fire the moment you return. Meetings that already ended are retired with a
  visible reason instead of ringing. Deferral never tries to bypass Do Not
  Disturb or draw over the lock screen.
- **Four calendar sources, all read-only** — macOS EventKit, Android
  CalendarContract, Google Calendar (bring-your-own client ID) and ICS /
  `webcal` feeds.
- **Tray + autostart (desktop)** — resident tray icon (Open today, Test
  alert, Settings, Quit); close-to-tray; opt-in launch-at-login.
- **Android full-screen alarms** — exact alarms with a full-screen intent
  that rings over the lock screen, rescheduled after reboot, with a visible
  fallback ladder when a special permission is denied.
- **Diagnostics** — an in-app "why didn't it alert?" view with the last 24 h
  of planned/fired/deferred/retired triggers, per-source status and platform
  capability checks.
- **Local and private** — no server, no account system, no telemetry. See
  [Privacy](docs/PRIVACY.md).

## Documentation

| Doc | What it covers |
| --- | --- |
| [Setup](docs/SETUP.md) | Per-OS first run, permissions, tray/autostart, deferral behaviour |
| [Google OAuth](docs/GOOGLE_OAUTH.md) | Step-by-step bring-your-own client ID walkthrough |
| [Privacy](docs/PRIVACY.md) | What stays local, what leaves, and when |
| [Architecture](docs/ARCHITECTURE.md) | Component map, calendar-source matrix, deferral state machine |
| [Troubleshooting](docs/TROUBLESHOOTING.md) | Wayland, GNOME tray, macOS permissions, Android alarms, deferred alerts |
| [Decisions](docs/DECISIONS.md) | Dependency and SDK decisions (single source of truth for pinning) |
| [Releasing](docs/RELEASING.md) | Release workflow and the paid code-signing paths |

## Status

Four-platform app in active development: Linux, Windows, macOS and Android.
MIT licensed, public repository. Contributions and bug reports welcome.
