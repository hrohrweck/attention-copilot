# DECISIONS — attention-copilot

Recorded dependency, SDK and platform decisions. Kept as the single source of
truth for version pinning; update when a version changes and say why.

## Pinned SDKs

| Tool | Version | Where pinned |
| --- | --- | --- |
| Flutter | **3.47.4** (stable, revision `9584c6713b`, 2026-09-10) | `$HOME/flutter`, invoked via absolute path |
| Dart | **3.13.3** | ships with the Flutter SDK above |

`pubspec.yaml` pins `environment: sdk: ^3.13.3` — the exact constraint
`flutter create` resolved from the installed Dart (`dart --version` =
3.13.3). CI installs the same Flutter version via `flutter-version: 3.47.4`
(todo 3).

## Runtime dependencies (resolved versions from `pubspec.lock`)

| Package | Version | Reason |
| --- | --- | --- |
| flutter_riverpod | 3.4.3 | State management for the app (the ONLY state framework — guardrail). |
| window_manager | 0.5.2 | Desktop alert surface: `setAlwaysOnTop`, `setFullScreen`, `show`, `focus` for the un-ignorable full-screen alarm window. |
| tray_manager | 0.5.3 | Resident tray icon/behaviour on all three desktop platforms. |
| launch_at_startup | 0.5.1 | Autostart-at-login toggle (Windows/macOS/Linux). |
| audioplayers | 6.8.1 | Looping loud alarm audio on all four platforms. Loop = replay-on-completion while ringing (some backends have gapless-loop gaps). |
| flutter_local_notifications | 22.3.1 | Desktop notifications + Android notification channel plumbing; Android full-screen-intent scheduling path. |
| flutter_foreground_task | 11.0.3 | Android foreground service so the alarm keeps working in the background. |
| flutter_secure_storage | 10.3.4 | OAuth refresh/access tokens + ICS bearer URL. Keychain (macOS), Keystore/Credential Manager (Android), DPAPI/libsecret (Win/Linux). |
| shared_preferences | 2.5.5 | Plain settings persistence (lead times, escalation, snooze toggle). |
| path_provider | 2.1.6 | App support directory for the JSON agenda cache and logs. |
| http | 1.6.0 | Google Calendar REST v3 + ICS/webcal fetching. |
| oauth2 | 2.0.5 | Authorization Code + PKCE primitives (`AuthorizationCodeGrant`) for the BYO Google client. |
| googleapis | 17.0.0 | Official Dart client for the Google Calendar v3 REST API. |
| googleapis_auth | 2.3.3 | Auth helpers pairing with `googleapis` (scopes, credential handling). |
| dbus | 0.7.15 | **Linux-only.** D-Bus client for the Linux presence adapter (screen lock / idle). |
| win32 | 5.15.0 | **Windows-only.** Windows API bindings for the Windows presence adapter (no C++ plugin needed). |
| ffi | 2.2.0 | **Windows-only.** FFI substrate used by the Windows presence adapter. |
| timezone | 0.11.1 | IANA timezone database; `tz.initializeTimeZones()` at startup before any zone resolution (else `tz.local` defaults to UTC). |
| flutter_timezone | 5.1.0 | Reads the device's IANA zone so `tz.local` matches the OS. |
| intl | 0.20.3 | Date/time formatting for the agenda UI. |
| cupertino_icons | 1.0.9 | Generated icon set used by the UI. |

## Dev dependencies

| Package | Version | Reason |
| --- | --- | --- |
| mocktail | 1.0.5 | Mocking for unit/widget tests (test-after for native shims, TDD for pure Dart). |
| integration_test | SDK-pinned (`sdk: flutter`) | On-device integration flows. Must be `sdk: flutter` — the pub.dev `integration_test` package is a null-safety-era artifact and fails resolution on Dart 3. |
| flutter_lints | 6.0.0 | Default lint set. |

## Platform gating rules

- `dbus` is **Linux-only**; `win32` and `ffi` are **Windows-only**. They must be
  imported only inside their platform files (or behind conditional imports) so
  the macOS, Android and other builds never resolve them. Presence adapters
  (todo 14) are the consumers.
- `flutter_local_notifications`, `flutter_foreground_task` etc. are
  cross-platform packages; their platform channels simply no-op where a
  platform has no implementation.

## Platform build status (CI-deferred)

Local platform builds are **NOT attempted** on this machine and are
deliberately deferred to the CI matrix (todo 3):

- **macOS**: no Xcode installed (Command Line Tools only) → `flutter build
  macos` fails locally; `macos-latest` runner has Xcode.
- **Android**: Homebrew cmdline-tools only, SDK 34 present but SDK 36 + licences
  missing → `flutter build apk` fails locally; `ubuntu-latest` runner has the
  full SDK.
- **Linux/Windows**: no cmake/ninja toolchain → desktop builds fail locally.

Local verification surface for this todo is therefore `flutter analyze` +
`flutter test` only. Android SDK levels (`minSdk 26` / `targetSdk 35`) are
pinned in the Android task (todo 18), not here.

## Packaging and release (todo 25)

- **Unsigned by design.** `.github/workflows/release.yml` (tag `v*`) builds
  all four targets with `--release`, stamps `--build-name` from the tag
  (Android `versionCode` from `GITHUB_RUN_NUMBER` for monotonicity), and
  attaches artifacts via `softprops/action-gh-release` with
  `permissions: contents: write`. It references **zero secrets** and needs
  no paid account. The paid signing paths (Apple Developer ID + hardened
  runtime + notarization + stapling, Windows Authenticode via `signtool`,
  Play Console with an upload keystore) are documented with exact commands
  in `docs/RELEASING.md` but deliberately not wired into CI.
- **Linux deb/AppImage** use `fastforge` (renamed `flutter_distributor`,
  `dart pub global activate fastforge`); the workflow step is best-effort
  (`continue-on-error`) because its AppImage maker downloads `appimagetool`
  at runtime and tool/Dart-version drift is possible — the guaranteed Linux
  artifact is the `flutter build linux --release` tarball.
- **Windows installer** uses Inno Setup via `choco` (best-effort,
  `continue-on-error`); the guaranteed artifact is the release-bundle zip.
  MSIX was rejected for the unsigned pipeline because MSIX requires a
  signature by design.
- **Android release builds fall back to the debug signing config**
  (`android/app/build.gradle.kts`), so the pipeline needs no keystore; the
  Play-uploadable signing path lives in `docs/RELEASING.md`.

## Scaffold decisions

- `flutter create --platforms=linux,windows,macos,android --project-name
  attention_copilot --org com.hrohrweck .` — no iOS/web/watch targets
  (guardrail: four platforms only).
- Generated counter demo deleted everywhere (`lib/main.dart` replaced by a
  minimal app shell; `test/widget_test.dart` replaced by a smoke test that
  pumps the shell).
- Skeleton `lib/{app,domain,data,presence,alert,ui}` with one placeholder file
  each; real content lands in todos 4-24.
- No database dependency (no sqflite/drift/isar) — the agenda cache is JSON
  (guardrail). No state framework beyond flutter_riverpod (guardrail).

## ICS parsing (todo 8)

- **Decision: own RFC 5545 subset parser; revisit `icalendar_parser`/`rrule`
  only if scope grows.** The task checked pub.dev candidates: none covers the
  needed subset (embedded VTIMEZONE transition building, RECURRENCE-ID with
  RANGE=THISANDFUTURE, RFC 7986 refresh hints) without pulling a larger
  dependency graph, so `lib/data/ics/` implements it directly with zero new
  pub dependencies (pubspec.lock stays stable for sibling tasks).
- Subset boundaries (documented in `lib/data/ics/ics.dart`): line unfolding
  per RFC 5545 3.1 (CRLF+WSP is *removed* on unfold), quote-aware property
  and parameter parsing, VEVENT/VALARM/VTIMEZONE, DATE/DATE-TIME/DURATION/
  UTC-offset values, RRULE (FREQ SECONDLY..YEARLY, INTERVAL, COUNT, UNTIL,
  BYMONTH, BYMONTHDAY, BYDAY, BYHOUR/BYMINUTE/BYSECOND, WKST), RDATE, EXDATE,
  RECURRENCE-ID (single and THISANDFUTURE). BYSETPOS/BYWEEKNO/BYYEARDAY are
  recognised but deliberately not expanded (recorded as diagnostics).
- Timezone policy: TZID resolves against embedded VTIMEZONE first (built into
  a `timezone` package `Location` from STANDARD/DAYLIGHT observances, with
  transitions materialised for 1970-2099), then the IANA database via
  `timezone`'s `tz.getLocation`, then - with a recorded diagnostic - the
  floating zone. Local times are never trusted without a resolution step.
- Refresh cadence: REFRESH-INTERVAL (RFC 7986) > X-PUBLISHED-TTL
  (MS-OXCICAL) > 30-minute default, clamped to a 15-minute minimum
  (`kMinPollInterval`).
- VALARM is parsed into passive `ProviderReminder` objects only; the alert
  policy engine remains the single scheduling authority.
