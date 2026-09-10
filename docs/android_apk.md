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
