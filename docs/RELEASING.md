# RELEASING — attention-copilot

How releases are cut, what the tag-triggered workflow produces, and how to
move from the current **unsigned** artifacts to signed, notarized ones.

> **Current state: every artifact published by `.github/workflows/release.yml`
> is unsigned. The pipeline needs no secrets and no paid account to go green.
> Everything in the "paid signing paths" sections below is run manually by
> whoever owns the accounts — none of it is wired into CI.**

## TL;DR — cutting a release

```bash
# 1. Bump the version in pubspec.yaml (e.g. version: 1.1.0+1) and commit it.
# 2. Tag and push — the tag IS the release trigger.
git tag v1.1.0
git push origin v1.1.0
```

Pushing a tag `vX.Y.Z` runs `.github/workflows/release.yml`, which builds all
four targets, stamps the version from the tag, and attaches the artifacts to
a GitHub Release named `vX.Y.Z` (release notes auto-generated from merged
PRs). A tag that does not match strict `X.Y.Z` (no `-rc1`, no `v` prefix in
the version itself) **fails the workflow** rather than publishing a
mislabelled artifact.

You can also run the workflow manually (`Actions → Release → Run workflow`)
with an optional `version` input; the manual path defaults to the checked-out
ref's version.

## What gets published

| Platform | Artifact | How | Guaranteed? |
| --- | --- | --- | --- |
| Linux | `attention-copilot-<ver>-linux-x64.tar.gz` | `flutter build linux --release` bundle | yes |
| Linux | `.deb`, `.AppImage` | `fastforge` (best-effort, see below) | no — the tarball is the fallback |
| Windows | `attention-copilot-<ver>-windows-x64.zip` | `flutter build windows --release` bundle | yes |
| Windows | `attention-copilot-<ver>-windows-x64-setup.exe` | Inno Setup (best-effort) | no — the zip is the fallback |
| macOS | `attention-copilot-<ver>-macos.dmg` + `-macos-app.zip` | `flutter build macos --release` + `hdiutil` | yes |
| Android | `attention-copilot-<ver>-android.apk` + `.aab` | `flutter build apk/appbundle --release` | yes |

Version stamping: `--build-name` is always the tag version. Android
`versionCode` is stamped from `GITHUB_RUN_NUMBER` so it stays monotonic
across releases. All four jobs run `flutter analyze` and `flutter test`
before building — a broken tree cannot produce a release.

## Why the Linux/Windows installers are "best-effort"

- **Linux deb/AppImage** uses [`fastforge`](https://pub.dev/packages/fastforge)
  (the renamed `flutter_distributor`, by leanflutter). Its AppImage maker
  downloads `appimagetool` at runtime and the tool's compatibility with the
  pinned Dart 3.13.3 is not guaranteed forever, so the workflow marks the
  step `continue-on-error` and always ships the raw release tarball. Locally:

  ```bash
  dart pub global activate fastforge
  export PATH="$PATH:$HOME/.pub-cache/bin"
  fastforge package --platform linux --targets deb,appimage --build-args build-name=1.1.0
  # output lands in dist/
  ```

- **Windows installer** installs Inno Setup via `choco` (community feed,
  occasionally rate-limited) and compiles an inline `.iss` script. The raw
  zip is the guaranteed artifact. If the installer step matters for a given
  release, prefer producing and attaching it from a local machine instead.

Both steps are deliberately best-effort so a toolchain hiccup cannot block a
release.

## macOS: unsigned today, and what that costs users

The macOS `.app`/`.dmg` are **unsigned** (only ad-hoc signed by Xcode on the
runner). Consequence: on the first launch, Gatekeeper shows

> "attention_copilot" cannot be opened because it is from an unidentified
> developer.

The user gets past this **one time** with either:

- **Right-click → Open → Open** in Finder (the *right-click matters* — a
  plain double-click has no bypass button), or
- System Settings → Privacy & Security → scroll to "Security" → **Open
  Anyway**.

After that first approval the app launches normally. If the dialog instead
says the app is **"damaged"** and only offers "Move to Trash", the download
was altered after signing (or the quarantine flag was stripped and re-added)
— the correct response is to re-download, not to bypass. Do not tell users to
run `xattr -dr com.apple.quarantine` as a matter of course; it defeats
Gatekeeper for every app touched, and this project does not ship that as
advice.

### Paid path: Developer ID + hardened runtime + notarization

Requires an **Apple Developer Program** membership (USD 99/year). Once you
have a `Developer ID Application` certificate in your keychain:

1. **Sign with hardened runtime** (no `get-task-allow`; both flags are
   required for notarization):

   ```bash
   flutter build macos --release
   APP=build/macos/Build/Products/Release/attention_copilot.app
   codesign --force --deep --options runtime \
     --sign "Developer ID Application: Your Name (TEAMID12345)" \
     --timestamp "$APP"
   ```

   (`--options runtime` = Hardened Runtime. If you enable hardened-runtime
   entitlements, do **not** include `com.apple.security.get-task-allow` in a
   shipped build — it invalidates notarization. The repo's
   `macos/Runner/Release.entitlements` is the place for app-sandbox or
   hardened-runtime exceptions; none are needed for this app.)

2. **Package and notarize**:

   ```bash
   hdiutil create -volname "Attention Copilot" -srcfolder dmg-staging \
     -ov -format UDZO attention-copilot-1.1.0-macos.dmg
   xcrun notarytool submit attention-copilot-1.1.0-macos.dmg \
     --apple-id "you@example.com" \
     --team-id "TEAMID12345" \
     --password "xxxx-xxxx-xxxx-xxxx" \
     --wait
   ```

   The `--password` is an **app-specific password** generated at
   appleid.apple.com (not the account password). Prefer storing it in a
   keychain profile so it never lands in shell history:

   ```bash
   xcrun notarytool store-credentials notary-profile \
     --apple-id "you@example.com" --team-id "TEAMID12345" \
     --password "xxxx-xxxx-xxxx-xxxx"
   xcrun notarytool submit attention-copilot-1.1.0-macos.dmg \
     --keychain-profile notary-profile --wait
   ```

3. **Staple** the notarization ticket to the artifact (so offline users
   don't re-check with Apple):

   ```bash
   xcrun stapler staple attention-copilot-1.1.0-macos.dmg
   xcrun stapler validate attention-copilot-1.1.0-macos.dmg   # "The validate action worked!"
   ```

4. Verify what you shipped:

   ```bash
   spctl -a -vvv -t install attention-copilot-1.1.0-macos.dmg  # "accepted ... source=Notarized Developer ID"
   ```

To automate in CI you would store `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`
and `APPLE_TEAM_ID` as GitHub Actions secrets and extend the `macos` job —
**this workflow intentionally does not** (see the top of this file).

## Windows: Authenticode signing

Unsigned: SmartScreen shows "Windows protected your PC" → "More info" →
"Run anyway". That is the designed first-run experience today.

Paid path — an **OV or EV code-signing certificate** (~USD 200-500/year;
EV ships on an HSM/`/usb` token). With the certificate installed in the
local machine store:

```bash
# Sign the installer (or any exe) with SHA-256 + RFC 3161 timestamping:
signtool sign /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 /a \
  attention-copilot-1.1.0-windows-x64-setup.exe

# With a PFX file instead of the machine store:
signtool sign /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 \
  /f cert.pfx /p <password> attention-copilot-1.1.0-windows-x64-setup.exe

# Verify:
signtool verify /pa /v attention-copilot-1.1.0-windows-x64-setup.exe
```

Notes:

- SmartScreen reputation is earned by signed volume, not by the signature
  alone — a freshly minted OV cert still triggers the warning for a while.
- MSIX is an alternative packaging format but **requires signing by design**
  (every MSIX must carry a signature, even a self-signed one), which is why
  the unsigned pipeline uses Inno Setup instead.
- Never commit a `.pfx`/`.p12`. In CI you would store it base64-encoded in a
  GitHub Actions secret and import it in the job — not wired here.

## Android: Play Console

The workflow's APK/AAB are signed with the **debug key fallback**
(`android/app/build.gradle.kts` points the release build type at the debug
signing config). Fine for sideloading; **not** uploadable to Play Console.

Paid path — a **Google Play Console account** (USD 25 one-time) and an
upload keystore of your own:

```bash
# 1. Create the upload keystore (keep this file OUT of git):
keytool -genkey -v -keystore upload-keystore.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias upload

# 2. android/key.properties (gitignored — never commit):
#   storePassword=<keystore password>
#   keyPassword=<key password>
#   keyAlias=upload
#   storeFile=/absolute/path/to/upload-keystore.jks
```

3. Wire it in `android/app/build.gradle.kts` (replace the debug-signing
   fallback):

```kotlin
import java.util.Properties
import java.io.FileInputStream

val keystoreProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) load(FileInputStream(f))
}

android {
    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String
            keyPassword = keystoreProperties["keyPassword"] as String
            storeFile = file(keystoreProperties["storeFile"] as String)
            storePassword = keystoreProperties["storePassword"] as String
        }
    }
    buildTypes {
        getByName("release") {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}
```

4. Build and upload:

```bash
flutter build appbundle --release
# Upload build/app/outputs/bundle/release/app-release.aab
# Play Console → Create app → Production → Create release → upload the .aab
```

5. In **Play Console → App integrity → App signing**, enroll in **Play App
   Signing** so Google manages the release key while you keep only the
   upload key. Export the PEPK certificate Google asks for during
   enrollment:

   ```bash
   keytool -export -rfc -keystore upload-keystore.jks -alias upload -file upload_certificate.pem
   ```

   The `.aab` is mandatory for Play; the `.apk` remains for direct
   sideloading.

## Secrets: what would be needed for signed CI (none are used today)

| Secret | Used for | Where it lives |
| --- | --- | --- |
| `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID` | notarization | GitHub Actions secrets + keychain profile locally |
| `WINDOWS_PFX_BASE64` + `WINDOWS_PFX_PASSWORD` | Authenticode in CI | GitHub Actions secrets |
| `key.properties` / `upload-keystore.jks` | Android release signing | local machine only, gitignored |

**The release workflow references zero secrets.** If you add signed steps,
extend `.github/workflows/release.yml` (store secrets under the repo's
Settings → Secrets and never in the repo), and keep the unsigned path as the
default so the pipeline still goes green without accounts.

## Troubleshooting

- **Tag pushed but no release**: the tag didn't match `v*`, or the version
  check in the workflow failed — open the run log; the `Stamp version from
  tag` step prints the reason.
- **Release exists but has no deb/AppImage/installer**: the best-effort step
  failed (see the run log). Re-run it locally with the commands above and
  upload the files to the release via `gh release upload`.
- **"damaged and can't be opened"** on macOS: re-download; do not bypass.
- **`fastforge` command not found**: `export PATH="$PATH:$HOME/.pub-cache/bin"`.
