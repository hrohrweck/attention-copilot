# TROUBLESHOOTING — Attention Copilot

Every degradation this app can show, per platform, and how to read the
"why didn't it alert?" diagnostics view. The design rule throughout: the app
**never fails silently** — when a platform cannot do something, Settings and
the diagnostics view say so.

## Always start here: the diagnostics view

Settings → **Diagnostics** (or the tray → Settings → Diagnostics) answers
"why didn't it alert?" for any trigger in the last 24 hours. It renders:

- **Presence** — current locked / idle / active state, which mechanism is in
  use, and whether presence detection is supported at all.
- **Sources** — per-calendar-source status and the error when one failed.
- **Capabilities** — platform grants (Android exact alarms, full-screen
  intent, notifications; always-on-top support; tray availability).
- **Next trigger** — the next planned alert instant.
- **Last 24h** — one line per engine record with a reason label:
  `fired`, `deferred-locked`, `deferred-away`, `meeting-ended`,
  `acknowledged`, `occurrence-removed`.

**Copy diagnostics** puts a redacted report (tokens, client IDs and feed
URLs removed) on your clipboard for pasting into a bug report.

## Why was an alert deferred?

Look for a `deferred-locked` / `deferred-away` record at the trigger
instant in the Last 24h list.

- `deferred-locked` — your screen was **locked** at the trigger instant. By
  design the app does not ring into a locked machine; it fired the alert
  the moment you unlocked (look for a `fired` record right after), unless…
- `meeting-ended` — the meeting had already ended more than 2 minutes ago
  by the time you returned, so the alert was retired as "started N minutes
  ago" instead of ringing. This is correct behaviour, not a bug.
- `deferred-away` — you had been **idle beyond the quiet threshold**
  (default 5 minutes). Same catch-up rules apply.
- `occurrence-removed` — the event left the agenda (cancelled, moved,
  removed from a source) before the alert was due.

To change this behaviour: Settings → **Alert even while locked / away**
(off by default) fires regardless of presence, and Settings → **Quiet when
away** adjusts the idle threshold. If presence is reported
`supported: false`, no lock/idle mechanism exists on your desktop — the app
deliberately treats you as present rather than silently swallowing alerts
(see the Linux note below).

Also check:

- **The trigger exists but never fired and no record exists** — the source
  failed and the event never reached the agenda. Check the Sources section
  and the per-source status line on the agenda.
- **The alert rang on the wrong minute** — lead times are set in Settings
  (default 10 and 1 minute). A re-plan after a calendar change keeps the
  deterministic alarm ids, so check that the meeting time itself moved.

## Linux: alert window is not always-on-top (Wayland)

On **Wayland**, no compositor lets an arbitrary client force
always-on-top — the compositor owns window placement. The app detects this
and reports it (capability: always-on-top unsupported) instead of
pretending the window is pinned. Full-screen size and audio still work;
the window just cannot be *forced* above others.

Workarounds:

- Run the app under an **X11/XWayland** session (X11 honours the
  `_NET_WM_STATE_ABOVE` request), or
- Keep the app's window on the current workspace — the escalation steps
  (re-raise, focus steal, audio) still draw your attention.

## Linux: no tray icon on GNOME

GNOME dropped legacy tray icons; the tray host only exists when the
**AppIndicator and KStatusNotifierItem Support** extension is installed
(`gnome-shell-extension-appindicator` on most distributions). Without it
the app reports "tray unavailable on this desktop" in Settings — it is
detected, never silently absent. Install the extension, or run the app
under a desktop that provides a StatusNotifierWatcher (KDE ships one).

If the tray icon is disabled in Settings and you re-enable it, the change
takes effect on the **next start** (a disposed tray cannot be recreated
in-process). The main window is unaffected.

## macOS: the calendar permission prompt never appears

The macOS calendar permission (TCC) is tied to the app's **signing
identity**. Unsigned / ad-hoc signed builds (which is everything this
project currently ships — see [Releasing](RELEASING.md)) can fail to show
the prompt, or show it and still read nothing. In that case:

1. Open System Settings → Privacy & Security → **Calendars** and check
   whether the app is listed — remove and re-add it if it is.
2. If the app is missing entirely, the OS never registered the request:
   run a **signed build** (Developer ID / any stable signature) — the TCC
   grant survives when the signing identity is stable, and a signed build
   is the reliable path to a working prompt.
3. On macOS 14+: grant **Full Access**, not "Write Only" — the app reads
   and needs the read level. macOS 12/13 report the legacy read grant as
   full access.
4. After changing the grant, restart the app and pull-to-refresh the
   agenda.

The app reports `permission-denied` with an "Open System Settings" action
instead of showing an empty-but-successful agenda, so a missing grant is
always visible.

## Android: alerts are late, or no full-screen alert appears

Android gates the over-lock-screen alarm behind two special permissions
plus the notification permission. The app checks all three and shows
exactly which one is missing (Settings → Diagnostics → Capabilities), with
a button that deep-links to the right screen.

- **Exact alarms** — Settings → Apps → Special app access → **Alarms &
  reminders** → enable for Attention Copilot. Without it the app falls
  back to inexact alarms and shows a persistent "alerts may be late"
  warning (`degraded: inexact-alarms`).
- **Full-screen intents** — enable via the app's deep link
  (`Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT`), or manually:
  Settings → Apps → Attention Copilot → **Allow display over other
  apps / full-screen notifications** (label varies by vendor). Without it
  the app degrades to a high-importance alarm-category notification —
  still loud, still exact, but not full-screen (`degraded:
  full-screen-intent-unavailable`).
- **Notifications** — if notifications are denied entirely, nothing can be
  posted; the app says so in the capability report.

Also check battery optimisation: the app does not request the exemption
permission by design, but if a vendor's "app battery" screen kills the
foreground service mid-alarm, re-check the diagnostics view. A reboot is
safe: pending triggers are persisted as absolute UTC instants and
rescheduled on `BOOT_COMPLETED` — if an alert was late after a reboot,
verify exact-alarms is still granted, because a revoked grant silently
moves delivery to the inexact path (the app warns, but only while it can
run).

## Desktop: the alert window won't stay on top / keeps losing focus

- On macOS, the full-screen window and audio are the escalation's own
  mechanisms — macOS Focus modes suppress *notifications*, not app audio.
  If the window is not raising, check the escalation settings in Settings
  (re-raise happens after 60 s by default).
- Multi-monitor: with more than one display the app opens one alert window
  **per display** (Settings → alert-on-all-displays, default on when 2+
  displays exist). If a display was hot-plugged mid-alert, acknowledge and
  fire a Test Alert to verify the current layout.
- If the alert never appears at all, it was deferred — see
  "Why was an alert deferred?" above.

## Google sign-in never opens / times out

- The browser opens and lands on an error, or nothing happens — the
  loopback server binds `127.0.0.1` on an ephemeral port; a strict
  firewall/proxy that intercepts localhost can break it. Try disabling any
  localhost-proxying VPN/filter, then reconnect the source in Settings.
- **7-day reconnects** — your OAuth consent screen is still in **Testing**:
  Google expires Testing refresh tokens after 7 days. Publish the consent
  screen to "In production" (unverified is fine) — see
  [Google OAuth](GOOGLE_OAUTH.md).
- The app shows "authorisation expired — reconnect" — reconnect the source
  in Settings (tokens were revoked or expired).

## Nothing above matches

1. Open Settings → Diagnostics and read the Sources + Capabilities
   sections.
2. Copy diagnostics and include the redacted report in your issue at
   `hrohrweck/attention-copilot`.
