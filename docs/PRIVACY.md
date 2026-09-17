# PRIVACY — Attention Copilot

Attention Copilot is a local-first, read-only calendar alarm app. The design
rule is: **nothing leaves your machine except the calendar requests you
explicitly enable.**

## The one-line statement

Attention Copilot contains **no telemetry, no analytics, no crash reporting**, and no third-party data collection of any kind. There is no
server, no account system, no push receiver, no advertising SDK and no
tracking SDK in the application.

## The local-only data model

Everything the app stores lives on your own device:

| What | Where | Contents |
| --- | --- | --- |
| Settings | `shared_preferences` (app data) | Lead times, snooze toggle, quiet-when-away threshold, the Google client ID you pasted, source toggles |
| Secrets | **OS keychain / credential store** (macOS Keychain, Windows DPAPI, Linux libsecret, Android Keystore / Credential Manager) | Google OAuth access + refresh tokens, the ICS feed URL (it may embed a bearer parameter) |
| Agenda cache | JSON file in the app-support directory | Incremental-sync cursors (Google `syncToken`, ICS ETag / Last-Modified) and the fetch timestamp — **not** your events |
| Pending alerts | JSON file in the app-support directory | Absolute UTC instants of planned triggers, so nothing is lost across a restart |
| Local log | Size-capped rolling file in the app-support directory | Diagnostic lines only — see "Log redaction" below |

Calendar data itself is never persisted by the app. The agenda is rebuilt
from the sources on every refresh; the only thing cached is sync cursors.

## What is sent to Google — and only when you enable that source

The Google Calendar source is **opt-in in two steps**: you must (1) create
and paste your own OAuth client ID, and (2) complete the sign-in. Until you
do both, the app makes **no network request to Google whatsoever**.

Once enabled, the app sends exactly these requests to Google:

- The OAuth authorization-code flow (PKCE, loopback redirect) — to
  `accounts.google.com` / `oauth2.googleapis.com`, when you sign in.
- Token refreshes — to `oauth2.googleapis.com`, when a stored access token
  expires.
- `events.list` reads for your primary calendar — to
  `www.googleapis.com`, on the app's refresh cadence.

That is the entire Google boundary. The app requests only the two
read-only scopes `calendar.events.readonly` and
`calendar.calendarlist.readonly` — it cannot create, edit or delete anything
in your calendar, and it never requests write or broad-read scopes. Your
Google refresh token lives in your OS keychain, not in the app's files.

## The other sources and what they touch

- **macOS Calendar (EventKit)** — the OS reads your local calendar store
  in-process. No data leaves the machine. The app requests **full (read)
  access only**; the native plugin transmits the conference URL but never
  your event notes.
- **Android calendars (CalendarContract)** — the OS reads your device
  calendar provider in-process, with only the `READ_CALENDAR` permission.
  No `WRITE_CALENDAR`, no contacts, no other provider. No data leaves the
  machine.
- **ICS / `webcal` feeds** — the app fetches exactly the URL you configure
  (conditional GETs only after the first fetch). The URL is treated as a
  secret: stored in the keychain and never written to logs or the cache.

## Log redaction

The local diagnostic log and the in-app "Copy diagnostics" report are
redacted: OAuth tokens, the Google client ID and ICS feed URLs never appear
in them. Logs contain no calendar titles, locations, notes, or attendee
data. The log is size-capped and rolls over.

## What the app does not do

- **No write operations on any calendar**, ever — no creating, editing,
  deleting or responding to events.
- **No server backend**, no hosted sync, no accounts of its own, and no
  push/webhook receiver (Google's push mechanism requires a public HTTPS
  endpoint a local app cannot provide — see
  [Architecture](ARCHITECTURE.md#why-push-notifications-are-not-used)).
- **No bundled credentials** — the app ships no Google client ID or secret
  ([Google OAuth](GOOGLE_OAUTH.md)).
- **No Do-Not-Disturb bypass** — the app never changes your global DND
  policy and never attempts to draw over a locked screen. It defers and
  catches up instead.
- **No diagnostics phone-home** — if you use "Copy diagnostics", you decide
  what to do with the redacted text; the app never transmits it.

## Contact

Privacy questions or issues: open an issue in the public repository
`hrohrweck/attention-copilot`.
