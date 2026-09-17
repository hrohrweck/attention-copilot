# ARCHITECTURE — Attention Copilot

How the app is put together: the component map, the calendar-source matrix,
the deferral state machine, and the two deliberate platform exclusions
(Windows' native calendar, push notifications).

## Component map

One Flutter codebase (Flutter 3.47.4, pinned in
[Decisions](DECISIONS.md)) produces four apps. The layers:

```text
┌─────────────────────────────────────────────────────────────────┐
│ UI (lib/ui/)                                                     │
│   agenda_screen  onboarding_wizard  settings_screen             │
│   ringing_alert_view (Android AlertActivity)  diagnostics_view  │
├─────────────────────────────────────────────────────────────────┤
│ Composition root (lib/app/composition_root.dart)                │
│   riverpod provider graph: storage, sources, engine, presence,  │
│   tray/autostart, routing. Every plugin/IO call sits behind a   │
│   provider so widget tests boot the app with fakes.             │
├──────────────┬──────────────────┬───────────────────────────────┤
│ Domain       │ Data (lib/data/)  │ Platform adapters             │
│ (lib/domain/)│ sources/          │ presence/  (lock + idle)      │
│   agenda     │   EventKit         │   macOS: CGSession + idle    │
│   alert_     │   CalendarContract │   Windows: WTS + LastInput   │
│   policy     │   GoogleCalendar   │   Linux: logind → Mutter →   │
│   alert_     │   ICS/webcal       │     KDE ScreenSaver          │
│   engine     │   refresh_orch.    │ alert/ (surface + scheduler) │
│   models     │ storage/           │   desktop window_manager     │
│              │   settings/secrets │   Android exact-alarm + FSI  │
│              │   agenda_cache     │   deferral_coordinator       │
├──────────────┴──────────────────┴───────────────────────────────┤
│ Diagnostics (lib/diagnostics/) — local redacted log + report    │
└─────────────────────────────────────────────────────────────────┘
```

Design invariants enforced by the composition root:

- The wall clock is read in exactly one place (`clockProvider`); every other
  component receives `now` or a clock function. No `DateTime.now()` inside
  domain code.
- The alert engine stores and compares **absolute UTC instants** only —
  never countdowns, never relative timers as the source of truth.
- Every native touch (`window_manager`, `tray_manager`, `audioplayers`,
  notification plugins, platform channels) sits behind a seam that tests
  override. `flutter test` never opens a window or touches the OS.

## Calendar-source matrix

| Source | Platforms | Auth | Sync model |
| --- | --- | --- | --- |
| macOS EventKit (`eventkit`) | macOS | OS permission (full/read access, `NSCalendarsFullAccessUsageDescription`) | Full read of a 14-day window (EventKit has no deltas); `EKEventStoreChanged` push triggers out-of-band refreshes |
| Android CalendarContract (`calendarcontract`) | Android | Runtime `READ_CALENDAR` (no Google OAuth) | Windowed reads `[cursorEnd, now+7d)`; pre-expanded recurring instances from the provider |
| Google Calendar REST v3 (`google:primary`) | Linux, Windows, macOS | **User-supplied OAuth client** (PKCE + loopback), narrow read-only scopes | Full `events.list` then incremental `syncToken`; 410 → one full resync; 401 → one refresh-and-retry |
| ICS / `webcal` (`ics:<hash>`) | all four | None (public URL; bearer URLs treated as secrets) | Conditional GET (`If-None-Match` / `If-Modified-Since`), 304 = no change, content-hash dedupe; poll interval from `REFRESH-INTERVAL` / `X-PUBLISHED-TTL`, clamped ≥ 15 min |

All sources are **read-only by contract** (`CalendarSource.isReadOnly` is a
hard `true`); nothing ever writes to a provider.

Notes on the matrix:

- **Android has no Google OAuth source** on purpose: Google blocks loopback
  redirects for Android clients, and CalendarContract already surfaces
  Google calendars synced to the device — one permission, no sign-in.
- **Windows has no native source** — see "Why Windows' native calendar is
  excluded" below. On Windows the Google and ICS sources are the options.

### The refresh orchestrator

Fetches all enabled sources concurrently; merges and dedupes
deterministically (dedupe key = iCalUID + start + end when the event id is a
globally unique UID, else normalized title + start + source id; ties prefer
an occurrence with a join URL, then source priority, then id). Guarantees:

- a failing source never blanks the agenda — its error is recorded
  per-source and other sources' events stay;
- refreshes are throttled (min 5-minute interval, jittered) so polling can
  never run hot;
- failed sources back off exponentially (30 s → 15 min, jittered);
- cursors are persisted in the agenda cache, so a restart resumes
  incremental sync.

## The alert engine and the deferral state machine

The engine (`lib/domain/alert_engine.dart`) owns a **persisted pending set**
of triggers, keyed by a deterministic alarm id derived from
(event, lead time). Re-planning is idempotent: it can never double-fire or
lose a trigger. Every pending trigger is stored as an absolute UTC instant
in `pending_triggers.json`, so a crash, quit or reboot loses nothing; on
restart the engine restores the set and re-plans the fresh agenda on top.

Lifecycle states: `pending` → `deferred-locked` / `deferred-away` →
`ringing` → (acknowledged | retired).

```text
                 ┌─────────── due instant reached ──────────────┐
                 ▼                                              │
            ┌─────────┐  presence == active          ┌────────┐ │
            │ pending │ ───────────────────────────▶ │ ringing│ │
            └─────────┘                              └────────┘ │
                 │                                        │    │
                 │ due + locked           escalated until │    │
                 ▼                         acknowledged   ▼    │
        ┌────────────────┐                    ┌──────────────┐ │
        │ deferred-locked │                    │ acknowledged │ │
        │ deferred-away   │                    │ (only exit)  │ │
        └────────────────┘                    └──────────────┘ │
                 │  unlock / return                            │
                 ▼                                             │
        meeting ended > grace (2 min)? ── yes ──▶ retired as   │
                 │ no                          `meeting-ended` │
                 ▼                                             │
              fire immediately ────────────────────────────────┘
```

Rules, all enforced by the engine and covered by its test suite:

- **Acknowledgement is the only exit for a ringing alert.** There is no
  auto-dismiss timer anywhere in the engine.
- **Deferral while locked/away**: a due trigger whose meeting is still
  running is moved to `deferred-locked` or `deferred-away` — no window, no
  audio — and recorded with that reason.
- **Catch-up**: on unlock/wake (and on returning to active) every deferred
  trigger fires immediately in deterministic order.
- **Grace rule**: a trigger whose meeting ended more than 2 minutes ago is
  retired as `meeting-ended` ("started N minutes ago") instead of ringing.
- **Presence honesty**: if no lock/idle mechanism exists on a platform, the
  coordinator maps it to *active* — presence that cannot be measured never
  silently suppresses alerts.
- **Escalation**: while ringing, the policy ladder drives repeat audio
  cycles, volume ramp, window re-raise and accent change; a 1 s heartbeat
  runs only while ringing (30 s while anything is pending).

The desktop alert surface is an always-on-top full-screen window (one per
connected display when more than one is attached) with looping audio; the
Android surface is an exact alarm with a full-screen intent, a foreground
service while ringing, and boot-time rescheduling of the persisted set.

## Why Windows' native calendar is excluded

The app deliberately has **no dependency on the Windows
`Windows.ApplicationModel.Appointments` / `AppointmentStore` API**.
Evidence (research findings in the work plan):

- `FindAppointmentsAsync` has been reported **completely broken** since
  January 2025, with the issue closed *as not planned* (WindowsAppSDK
  #3748) — the API path is effectively dead.
- The API requires **package identity** (an MSIX-packaged app), which this
  project's unsigned release pipeline intentionally avoids.
- The provider app behind the user-facing calendar (Mail & Calendar) ended
  support on **2024-12-31** and was retired.

So on Windows the reliable paths are Google Calendar (your own client ID)
and ICS feeds — which is exactly what the app offers.

## Why push notifications are not used

The app polls. Google's `events.watch` push mechanism is **not** used
because it requires the client to provide a publicly reachable HTTPS webhook endpoint with a valid certificate — a local desktop app cannot
provide one, and building (and operating) a hosted receiver would violate
the project's no-server rule and its privacy model.

Polling is therefore the design, made honest:

- Google: incremental sync via `syncToken` — each poll returns only
  changes, not the whole calendar.
- ICS: conditional GETs — the common case is a 304 with no reparse.
- Native sources: change notifications from the OS (`EKEventStoreChanged`)
  or windowed reads.
- Global throttling and per-source exponential backoff prevent tight loops.

## Related documents

- [Decisions](DECISIONS.md) — dependency pins and the reasoning behind them
- [Setup](SETUP.md) — first run and permissions
- [Privacy](PRIVACY.md) — the no-telemetry, local-only data model
- [Troubleshooting](TROUBLESHOOTING.md) — the degradation cases this
  architecture anticipates
