# Android APK (phone or emulator)

OpenWoodsMap ships for **Android** (and iOS). On a Windows/Mac/Linux PC, install the APK in **BlueStacks** or Android Studio’s emulator.

## 1. One-time: Android SDK

1. Install [Android Studio](https://developer.android.com/studio).
2. SDK Manager → install **Android SDK**, a recent **SDK Platform** (API 34+), and **Command-line Tools**.
3. Accept licenses and confirm Flutter sees the toolchain:

```powershell
$env:PATH = "C:\_stuff\dev\tools\flutter\bin;$env:PATH"
flutter doctor --android-licenses
flutter doctor
```

`Android toolchain` should be green.

## 2. Sync data + build debug APK

```powershell
$env:PATH = "C:\_stuff\dev\tools\flutter\bin;$env:PATH"
cd C:\_stuff\dev\open-woods-map
powershell -File scripts\sync_assets.ps1
cd app
flutter pub get
flutter build apk --debug
```

APK path:

`app\build\app\outputs\flutter-apk\app-debug.apk`

## 3. Install

**Physical phone:** USB debugging on, then `flutter install`, or copy the APK and open it (allow unknown apps).

**BlueStacks / emulator:** drag-and-drop the APK into the emulator window, or use `adb install` if `adb` is on your PATH.

## 4. Smoke test

1. Open OpenWoodsMap (Ontario sample / bundled CLUPA).
2. Tap a green crown-land polygon → Land Info (local government + policy).
3. Offline packs → Download Ontario (or Import `packs/on-overlays.zip`).
4. Optional: Streets / Satellite basemap (needs network).

---

# Publishing a signed release

Releases are built by [`.github/workflows/release-apk.yml`](../.github/workflows/release-apk.yml)
and published as GitHub Releases, one immutable tag per version. This is
deliberately **not** the `packs-latest` release: that tag is rolling and its
assets are replaced every month, which is the opposite of what an app build needs.

## Why the signing key matters more than it looks

Android identifies an app by its signing key. Two consequences that are worth
understanding before you generate anything:

- **The key cannot be rotated.** Replacing it forces every user to uninstall and
  reinstall, which deletes their saved waypoints. Whatever key you first publish
  with, you are keeping.
- **Losing it is the same as rotating it.** No backup means no upgrade path for
  anyone who installed the app. Keep at least two copies, at least one offline.

Until a keystore exists, `flutter build apk --release` falls back to the debug
key so local release builds still work. That key's password is the public string
`android`, so anything signed with it can be replaced by anyone — which is why
the workflow verifies the built APK's certificate and refuses to publish a
debug-signed one, rather than trusting that the secrets were configured right.

## 1. One-time: create the keystore

Keep it **outside the repository**. `.gitignore` covers `*.jks`, `*.keystore` and
`key.properties` as a backstop, but the file should not be in the tree at all.

```powershell
$env:JAVA_HOME = "C:\Program Files\Android\Android Studio\jbr"
& "$env:JAVA_HOME\bin\keytool.exe" -genkeypair -v `
  -keystore "$HOME\owm-release.jks" `
  -storetype JKS -keyalg RSA -keysize 2048 -validity 10000 `
  -alias owm-release
```

It prompts for a store password, a key password and a distinguished name. Two
practical notes:

- **Use an alphanumeric password.** It ends up in a Java `.properties` file, whose
  parser treats backslashes as escapes, so a password containing `\` will fail in
  a way that looks like a wrong password.
- `-validity 10000` is about 27 years. It only has to outlive the app.

Then back it up, along with both passwords.

## 2. One-time: verify signing works before you ever tag

Do this once locally, so the first thing that exercises your keystore is not a
release. Create `app\android\key.properties` — gitignored, and note the **forward
slashes**, because backslashes are escapes in this format:

```properties
storeFile=C:/Users/you/owm-release.jks
storePassword=<store password>
keyAlias=owm-release
keyPassword=<key password>
```

Build and check what signed it:

```powershell
$env:PATH = "C:\_stuff\dev\tools\flutter\bin;$env:PATH"
$env:JAVA_HOME = "C:\Program Files\Android\Android Studio\jbr"
cd app
flutter build apk --release
& "$env:LOCALAPPDATA\Android\Sdk\build-tools\36.0.0\apksigner.bat" `
  verify -v --print-certs build\app\outputs\flutter-apk\app-release.apk
```

You want a bare `Verifies` line and a `Signer #1` whose name is yours. If it says
`CN=Android Debug`, `key.properties` was not picked up. The `-v` matters: without
it apksigner prints the certificates and no verdict at all, which reads like
success and proves nothing.

That distinction is the whole reason the workflow's check is shaped the way it
is. An erroring `apksigner` also lacks the debug name, so testing only for the
absence of `CN=Android Debug` passes when nothing was checked. The workflow
therefore requires the `Verifies` line, and then pins the certificate's SHA-256
digest, so a wrong keystore in the secrets fails as loudly as no keystore at all.
Replace the key and that pin has to change with it — see `EXPECTED` in
`.github/workflows/release-apk.yml`.

## 3. One-time: add the GitHub secrets

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("$HOME\owm-release.jks")) |
  Set-Clipboard
```

Then **Settings → Secrets and variables → Actions → New repository secret**, four
of them:

| Secret | Value |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | the clipboard contents from above |
| `ANDROID_KEYSTORE_PASSWORD` | store password |
| `ANDROID_KEY_ALIAS` | `owm-release` |
| `ANDROID_KEY_PASSWORD` | key password |

## 4. Cut a release

Bump `version:` in `app/pubspec.yaml` first. **Raise the `+N` build number too** —
Android refuses to install an APK whose version code is lower than the installed
one, so a forgotten `+N` produces an update users cannot apply.

```powershell
# app/pubspec.yaml -> version: 0.2.0+2
git commit -am "Release 0.2.0"
git tag v0.2.0
git push origin main --tags
```

The workflow checks the tag against `pubspec.yaml`, runs `flutter analyze` and
`flutter test`, syncs the bundled asset, builds, verifies the signature and
publishes the release. A mismatch, a failing test or a debug signature all stop
it before anything is published.

To exercise the pipeline without publishing: **Actions → Release APK → Run
workflow**, which uploads the APK as a build artifact and creates no release.

## What people download

**One universal APK**, not one per ABI. It runs on every phone and on x86_64
emulators such as BlueStacks, so there is no wrong choice to make. Per-ABI builds
are about 30 MB smaller, and `flutter build apk --release --split-per-abi` still
produces them locally, but they are not published: Flutter offsets the version
code per ABI, so a per-ABI install (arm64 becomes `1002`) and a universal one
(`1`) are an upgrade in one direction and a refused downgrade in the other.
Offering both is a good way to get someone stuck.

GitHub Releases has no update mechanism of its own. The suggested install path for
users who want updates is [Obtainium](https://github.com/ImranR98/Obtainium),
which watches this repository's releases. That matters more here than for most
apps: map data refreshes through packs on its own, but a fix to how the app
*reasons* about that data — a wrong Sunday gun answer, say — only reaches someone
who updates the binary.

Map data is not in the APK. The app downloads a province pack on first run, and
those refresh on their own schedule.
