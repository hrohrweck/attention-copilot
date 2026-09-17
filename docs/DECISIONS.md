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
