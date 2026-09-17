# SETUP — Attention Copilot

First run, permissions and resident behaviour on all four platforms. For
release artifacts and code signing, see [Releasing](RELEASING.md). For known
platform degradations, see [Troubleshooting](TROUBLESHOOTING.md).

## First run, per OS

### macOS

1. Open the app. The build is **unsigned**, so Gatekeeper shows
   "cannot be opened because it is from an unidentified developer" on first
   launch. Get past this **once** with **right-click → Open → Open** in
   Finder (a plain double-click has no bypass button), or System Settings →
   Privacy & Security → scroll to "Security" → **Open Anyway**.
2. The onboarding wizard opens. Enable the **macOS Calendar** source: macOS
   shows its own calendar-permission prompt. Grant **full access** (read is
   all the app uses; it never requests write access).
3. Verify with **Test Alert** in Settings (or the tray menu).

Calendar permission lives in System Settings → Privacy & Security →
Calendars. The app only asks when you enable the source — never at launch.
macOS 14+ splits calendar access into read/write levels: the app needs the
full-access (read) level, and macOS 12/13 grant paths behave as full access.

### Windows

1. Unpack the release zip (or run the installer). The build is **unsigned**:
   SmartScreen shows "Windows protected your PC" → **More info** →
   **Run anyway**.
2. The onboarding wizard opens. Windows has **no native calendar source** in
   this app — Microsoft's `Appointments` API is broken and its provider app
   was retired (see [Architecture](ARCHITECTURE.md)). Connect either:
   - **Google Calendar** with your own client ID
     ([walkthrough](GOOGLE_OAUTH.md)), or
   - an **ICS / `webcal` feed URL** (no sign-in).

### Linux

1. Unpack the tarball and run the `attention_copilot` binary from a
   terminal the first time (so you can see any startup errors), or install
   the `.deb`/AppImage when available.
2. Connect a source in the wizard: Google Calendar (own client ID) or an
   ICS / `webcal` URL.
3. GNOME note: the tray icon only appears when the **AppIndicator**
   extension is installed (see [Troubleshooting](TROUBLESHOOTING.md)). The
   app reports "tray unavailable on this desktop" in Settings instead of
   silently having no icon.

Presence detection (screen lock / idle) uses the logind session, falling
back to GNOME's IdleMonitor or KDE's ScreenSaver. If no mechanism responds
on an exotic desktop, the app reports `supported=false` and deliberately
treats you as **present** — it never silently suppresses alerts it cannot
measure.

### Android

1. Sideload the APK (release builds are signed with the debug key — see
   [Releasing](RELEASING.md)).
2. The wizard offers the **device calendars** source. Enable it and grant
   the `READ_CALENDAR` runtime permission. This also covers Google calendars
   synced to the device — no Google sign-in is needed on Android.
3. For the over-lock-screen alarm to work, two **special app access**
   permissions must be granted: **Alarms & reminders** (exact alarms) and
   **full-screen intents**. The app checks both and shows exactly which
   setting to open when one is missing (see
   [Troubleshooting](TROUBLESHOOTING.md)). Without them the app degrades
   visibly to a high-importance notification / inexact timing — it never
   silently misses a meeting.

## The onboarding wizard

Every first run (or until at least one source is enabled) shows the wizard:

1. Choose calendar sources — platform-native (macOS / Android), Google
   (paste your own client ID), or an ICS URL.
2. Keep or change the default lead times (**10 and 1 minute**).
3. Fire a **Test Alert** to verify the full ring path on this machine.
4. Land on the today-first agenda.

Each source has an explicit state (`not configured`, `needs permission`,
`permission denied`, `connected`, `error`). A denied permission never
continues as if connected — you get an "Open Settings" action instead.

## Tray, resident mode and autostart (desktop)

- **Tray icon** with Open today / Test alert / Settings / Quit.
- **Resident mode**: closing the main window hides it; the app keeps running
  in the tray. **Quit is the only path that exits the process.**
- **Autostart** is off by default; enable the toggle in Settings. It
  registers a macOS Login Item, a Windows Run key, or a
  `~/.config/autostart/*.desktop` entry — and removes it when disabled.
- If you disable the tray and later re-enable it in the same run, the change
  takes effect on the **next start** (a disposed tray cannot be recreated
  in-process). Autostart applies immediately.

## What happens when alerts are deferred

On desktop the app watches whether you are actually there. While your screen
is **locked**, or you have been **away** (no input) beyond the quiet
threshold (default **5 minutes**):

- A due alert does **not** ring: no window, no audio. The deferral is
  recorded with its reason (`deferred-locked` / `deferred-away`).
- The moment you unlock or return, every deferred alert fires immediately,
  in order — unless the meeting has already ended by more than **2 minutes**
  (the grace period), in which case it is retired and shown as
  "started N minutes ago" instead of ringing.
- If the machine was asleep past a trigger instant, the wake/unlock
  catch-up handles it the same way.

Settings that change this behaviour:

| Setting | Default | Effect |
| --- | --- | --- |
| Quiet-when-away threshold | 5 min | Idle time before an unlocked user counts as away |
| Alert even while locked / away | OFF | Manual override: fire regardless of presence |

Deferral is the designed behaviour on desktop — a third-party app cannot
draw over a locked screen there. The app never attempts to bypass Do Not
Disturb or the lock screen. Every deferral decision is visible afterwards in
the in-app diagnostics view (see
[Troubleshooting](TROUBLESHOOTING.md#why-was-an-alert-deferred)).

## Where data lives

Everything is local: settings, the agenda cache, the pending-alert store and
a size-capped, redacted log live in the app-support directory; OAuth tokens
and ICS bearer URLs live in the platform keychain. Details in
[Privacy](PRIVACY.md).
