# On-device sanity testing

How to check a change on a real Android device before calling it done, using
[`tools/devtest/owm.ps1`](../tools/devtest/owm.ps1). Optional for human
contributors; `flutter run` is fine. It exists so an agent can see the app
rather than guess.

## Why adb, and not a test framework

The map is a native platform view, which rules out the obvious choices:

- **`integration_test`** composites only the Flutter layer. Platform views come
  out black, so screenshots of the one thing most worth checking are useless.
  It remains the right tool for widget logic, just not for the map.
- **Accessibility-tree drivers** (Maestro, Appium) cannot see inside the map
  surface at all. They can drive the chrome around it and assert on labels, but
  never on what MapLibre drew.
- **`adb exec-out screencap`** grabs the device framebuffer, map included. It
  also reaches what this app needs faked and a UI driver cannot touch: a mock
  GPS fix for launch centring, and the radios for offline behaviour.

## One-time setup

BlueStacks is a supported *product* target but a poor *test* target: see the
note below. Create a dedicated emulator instead.

```powershell
$sdk = "$env:LOCALAPPDATA\Android\sdk"
$sm = "$sdk\cmdline-tools\latest\bin\sdkmanager.bat"

# Licences first, or the install refuses.
("y`n" * 80) | & $sm --licenses

# Use --package_file, never the package id as an argument. These SDK entry
# points are batch files and cmd.exe splits unquoted arguments on semicolons, so
# "system-images;android-35;google_apis;x86_64" arrives as four arguments and
# every one is reported "not found".
"system-images;android-35;google_apis;x86_64" | Set-Content pkg.txt
& $sm --package_file=pkg.txt

powershell -File tools\devtest\create_avd.ps1
```

`sdkmanager` exits with `0xC0000409` after doing its work correctly. Check for
`system-images\android-35\google_apis\x86_64\system.img` rather than trusting the
exit code.

Google APIs rather than Play Store, so the image stays debuggable. API 35 rather
than the newest, so the device is one real users are on.

## The loop

```powershell
powershell -File tools\devtest\owm.ps1 doctor      # which device will be used
powershell -File tools\devtest\owm.ps1 boot
cd app; flutter build apk --release --split-per-abi; cd ..
powershell -File tools\devtest\owm.ps1 install
powershell -File tools\devtest\owm.ps1 grant       # skip to test the permission prompt
powershell -File tools\devtest\owm.ps1 gps 45.42 -75.70
powershell -File tools\devtest\owm.ps1 launch -Settle 25
powershell -File tools\devtest\owm.ps1 shot before-change
```

`push <file>` puts a file where the app's own file picker will offer it, which is
how to get a rebuilt pack onto the device: `push packs\on-overlays.zip`, then
import it through Offline packs. It lands in `/sdcard/Download` and tells
MediaStore to index it, without which the picker lists nothing. Going around the
picker by writing into the app's private directory is not an option on a release
build — `run-as` refuses a package that is not debuggable — and the import path
is worth exercising anyway.

`dump` lists every labelled element with tap coordinates; `tap "Offline packs"`
hits one by label. Flutter publishes its full semantics tree to `uiautomator`, so
this works across the whole app without adding anything to production code.
Icon-only buttons are reachable because their tooltips become semantics labels.

`tapshot x y [shotWidth]` taps a point read straight off a screenshot, scaling it
to device pixels from the width the device reports. It exists for the things
`tap` cannot reach — a spot on the map, a colour swatch, anything without a
label — because those coordinates come off an image that has usually been
downscaled on the way to whoever is reading it. `shotWidth` defaults to 461,
which is the width an agent sees. Doing that multiplication by hand fails
quietly, by tapping the wrong widget, which reads as the app misbehaving.

Two things a swipe can get wrong, both of which look like app bugs: dragging
across an open keyboard glide-types into the focused field, and dragging inside a
scrollable sheet is fine but dragging over the map pans it. Dismiss the keyboard
with `back` before any swipe meant to scroll.

Screenshots and logcat land in `.artifacts/`, which is gitignored. They are
evidence from one run, not repo content.

`Get-Help tools\devtest\owm.ps1 -Full` lists the rest.

## Traps that cost real time

- **BlueStacks refuses the shell unless ADB is enabled.** With
  `bst.enable_adb_access="0"` in `C:\ProgramData\BlueStacks_nxt\bluestacks.conf`
  it still completes the adb handshake and reports state `device`, then fails
  every command with `error: closed`. No adb client version works around it. Its
  adb port also has no emulator console behind it, so `adb emu` calls hang
  forever instead of failing; `owm.ps1` reads `ro.boot.qemu.avd_name` instead.
- **The headless emulator draws no symbol layers at all.** This is the expensive
  one. Under `swiftshader_indirect` fills, lines and circles render faithfully,
  so a screenshot looks entirely healthy — but every symbol layer is missing,
  including the basemap's own place and road labels. A waypoint glyph added
  through `addSymbolLayer` therefore renders as nothing, with no error, no
  exception from `addImage` or `addSymbolLayer`, and nothing in logcat. It is
  indistinguishable from a bug in your own code, and it will cost you several
  build cycles if you do not know.

  The tell is the basemap: if you cannot see "North Gower" or a road name
  anywhere, symbol rendering is off and the screenshot cannot tell you anything
  about your icon. Re-check with `boot -Windowed`, which uses the host GPU, and
  confirm from `dumpsys SurfaceFlinger | grep GLES` that you got a real driver
  rather than `Google SwiftShader`.
- **Two release APKs live in the same directory, and installing the wrong one
  looks like your change not working.** `--split-per-abi` writes
  `app-x86_64-release.apk`, a plain `--release` writes `app-release.apk`, and
  neither build deletes the other. `install` used to name the split one outright,
  so after a split build every later `--target-platform android-x64` rebuild
  installed nothing new: the app launched, the screenshot came back clean, and it
  showed the old binary. It now installs whichever of the two is newer and prints
  the build's age, so read that line — an install that says "58 minutes ago" is a
  build you forgot to run.
- **A minimized `-gpu host` emulator stops producing frames.** `screencap` then
  returns the same stale image indefinitely while the device keeps running: the
  clock inside the capture freezes while `adb shell date` advances. `boot`
  defaults to headless `swiftshader_indirect`, which renders off-screen and does
  not have this failure mode. `-Windowed` therefore leaves the window at normal
  size rather than minimizing it, since minimizing is the one thing that makes
  that mode useless. Expect slow frames and occasional "System UI isn't
  responding" under software GL, which is an emulator artifact rather than an app
  fault.
- **Write device files to `/data/local/tmp`, not `/sdcard`.** Under scoped
  storage a `/sdcard` file gets the media provider's ownership and no read bit
  for others, so the pull fails after a capture that succeeded. `/data/local/tmp`
  also survives reboots, which is why `shot` deletes before capturing: otherwise
  a failed capture silently yields the previous run's screenshot.
- **`gps` does not always move the app.** `adb emu geo fix` answers `OK` and sets
  the emulator's gps provider, but on a `google_apis` image the app asks Play
  services' *fused* provider, which happily serves a cached fix hours old and
  thousands of kilometres away while `dumpsys location` shows the gps provider as
  `ProviderRequest[OFF]`. Repeating the fix during an active request does not
  dislodge it. It is worse than a stale reading, because the fused answer is
  derived from the host's network and so lands somewhere plausibly nearby — a
  follow-along bar read "35 km off the track" for a fix that was exactly on it,
  which looks far more like a bug in your own projection maths than like the
  emulator lying about where the phone is.

  Check what the app actually got with
  `owm.ps1 shell "dumpsys location" | Select-String fused` before trusting where
  you think you are. To make the mock fix reach the app, leave Play services no
  network position to prefer:

  ```powershell
  owm.ps1 shell "svc wifi disable"
  owm.ps1 shell "svc data disable"
  owm.ps1 shell "settings put secure location_mode 1"   # sensors only
  owm.ps1 gps 45.095 -75.748
  ```

  Restore all three afterwards (`enable`, `enable`, `location_mode 3`) or the
  next run's basemap and weather checks fail for reasons that have nothing to do
  with the change under test. Re-send `gps` a few times a second apart and allow
  a few seconds before the screenshot: the app can otherwise be read mid-move,
  which shows up as a distance a few metres off the one you calculated.
- **Quote shell commands carrying flags:** `owm.ps1 shell "ping -c 2 8.8.8.8"`.
  PowerShell binds a bare `-c` to the script's own parameters first.
- **`tap` used to pick one of several equal matches, silently.** Offline packs
  draws one card per province, so "Import ZIP" and "Delete local pack" each appear
  twice. `tap "Import ZIP"` hit Quebec's, the Ontario pack was rejected as not
  being a QC pack, and Ontario went on serving the data it already had. It looked
  for an hour like importing over an installed pack was broken, which it is not.
  `tap` now refuses an ambiguous label and prints the coordinates instead; when a
  screen has repeated labels, use `tapxy`.
- **Overlays lag an import.** Coming back from Offline packs reloads the province,
  but MapLibre then reads and tiles every layer file natively, and the Ontario
  pack is around 50 MB of GeoJSON. On a software-GL emulator the map can sit bare
  for a good many seconds, including the WMU lines. Take a second screenshot
  before concluding a layer is missing; a `stop` and `launch` proves nothing
  except that you waited.
- **A desktop connection makes basemap downloads look broken.** BlueStacks and
  the emulator download tiles over the host's link, which saturates the request
  budget far faster than a phone does and collects HTTP 429s from the free tile
  endpoints. MapLibre retries those on a growing backoff, so the download crawls
  instead of failing and reads as stuck at a few megabytes. The same area
  downloads cleanly on a phone. Confirm with
  `owm.ps1 logs | Select-String REASON_RATE_LIMIT` before treating a slow
  download as a bug.

## Testing offline honestly

Turning the radios off and seeing the map still render proves nothing on its own.
MapLibre keeps an ambient cache of recently viewed tiles, so anywhere already
browsed will render offline whether or not a basemap area was saved.

To test a saved area, pan to part of it that has **never** been on screen. Verify
the network is actually down rather than reading the status bar:

```powershell
powershell -File tools\devtest\owm.ps1 shell "dumpsys connectivity" | Select-String "Active default network"
```

`Active default network: none` is the only acceptable answer.

Leaving a saved area is harder than it looks. At Overview detail one area covers
far more ground than the picker's frame suggests, and Quebec's default view sits
at Ottawa–Gatineau, inside an area saved around Ottawa. Use `gps` and a genuinely
distant fix rather than panning.
