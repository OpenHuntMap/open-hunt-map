<#
.SYNOPSIS
    Drives OpenWoodsMap on an Android emulator for sanity testing.

.DESCRIPTION
    A thin wrapper over adb, so a change can be checked on a real device before
    it is called done. The map is a native platform view, which rules out the
    two obvious alternatives: Flutter's integration_test composites only the
    Flutter layer and renders platform views black, and accessibility-tree
    drivers cannot see into the map surface at all. A device framebuffer grab is
    the only thing that shows what the map actually drew.

    adb also reaches the things this app needs faked, which a UI driver does
    not: a mock GPS fix for launch centring, and the radios for offline
    behaviour.

    Setup, once per machine: tools/devtest/create_avd.ps1

.EXAMPLE
    ./owm.ps1 doctor
    ./owm.ps1 boot
    ./owm.ps1 install
    ./owm.ps1 grant
    ./owm.ps1 gps 45.42 -75.70
    ./owm.ps1 launch -Settle 25
    ./owm.ps1 shot startup
    ./owm.ps1 tap "Map layers"
    ./owm.ps1 net off

    Quote any shell command that carries flags. PowerShell binds a bare -c to
    this script's own parameters before adb ever sees it:

    ./owm.ps1 shell "ping -c 2 8.8.8.8"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('doctor', 'boot', 'kill', 'install', 'launch', 'stop', 'clear',
        'grant', 'shot', 'dump', 'tap', 'tapxy', 'swipe', 'back', 'home',
        'type', 'gps', 'net', 'logs', 'shell', 'push')]
    [string]$Command,

    # Not $Args. That name is an automatic variable in PowerShell, so binding a
    # parameter to it silently yields nothing and every command sees no
    # arguments at all.
    [Parameter(Position = 1, ValueFromRemainingArguments)]
    [string[]]$Rest,

    # Seconds to wait before acting, for the map to fetch tiles and settle.
    [int]$Settle = 0,

    # Boot with a visible window on the host GPU instead of headless software
    # rendering. Faster and a truer test of GPU behaviour, but only usable while
    # someone is watching: see the note in Cmd-Boot.
    [switch]$Windowed
)

# Not 'Stop'. adb writes ordinary progress notices to stderr ("daemon not
# running; starting now", and every byte of `adb pull` progress), and with 2>&1
# in a pipeline PowerShell turns those into terminating errors. Real failures are
# raised explicitly with throw.
$ErrorActionPreference = 'Continue'

$Sdk = Join-Path $env:LOCALAPPDATA 'Android\sdk'
$Adb = Join-Path $Sdk 'platform-tools\adb.exe'
$Emulator = Join-Path $Sdk 'emulator\emulator.exe'
$Repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Artifacts = Join-Path $Repo '.artifacts'
$Package = 'ca.openwoodsmap.open_woods_map'
$Activity = "$Package/.MainActivity"
$AvdName = 'owm_test'

# /data/local/tmp, not /sdcard: under scoped storage a file written to /sdcard
# lands with the media provider's ownership and no read bit for others, so the
# pull fails even though the capture succeeded.
$DevShot = '/data/local/tmp/owm_shot.png'
$DevDump = '/data/local/tmp/owm_dump.xml'

if (-not (Test-Path $Adb)) { throw "adb not found at $Adb" }
New-Item -ItemType Directory -Force -Path $Artifacts | Out-Null

# Get the one-off daemon startup notice out of the way before anything reads
# adb's output.
& $Adb start-server 2>&1 | Out-Null

# ---------------------------------------------------------------- adb plumbing

# Takes one array rather than remaining arguments. With ValueFromRemainingArguments
# PowerShell tries to bind anything that looks like a flag -- `-p`, `-r`, `-d` --
# to this function's own parameters, fails, and because errors are non-terminating
# the adb call never runs at all. That failure is silent, which made screencap
# look like it was working while `pull` quietly returned the previous capture.
function Invoke-Adb([string[]]$AdbArgs, [string]$Serial) {
    if (-not $Serial) { $Serial = Get-Serial }
    & $Adb @('-s', $Serial) @AdbArgs 2>&1
}

function Test-Serial([string]$serial) {
    # BlueStacks completes the adb handshake and then refuses the shell service
    # when its ADB setting is off, so it shows up as `device` while being
    # useless. Only a serial that can actually run a command counts.
    #
    # The token has to be one that cannot occur in a failure message. adb echoes
    # the failing command's context, which includes this script's own path, so
    # anything resembling the tool's name matches even when the shell was
    # refused, and every device then looks healthy.
    $token = 'devtest_probe_ok'
    $probe = Invoke-Adb @('shell', 'echo', $token) -Serial $serial | Out-String
    return ($probe -split "`n" | Where-Object { $_.Trim() -eq $token }).Count -gt 0
}

function Get-AvdName([string]$serial) {
    # Read the name from a property rather than `adb emu avd name`. The latter
    # talks to the emulator console, and BlueStacks publishes an adb port with no
    # console behind it, so the console call hangs forever instead of failing.
    return (Invoke-Adb @('shell', 'getprop', 'ro.boot.qemu.avd_name') `
            -Serial $serial | Out-String).Trim()
}

function Get-Candidates {
    $lines = & $Adb devices 2>&1 | Select-Object -Skip 1
    $candidates = @()
    foreach ($line in $lines) {
        if ($line -match '^(\S+)\s+device\s*$') { $candidates += $Matches[1] }
    }
    return $candidates
}

$script:CachedSerial = $null

function Get-Serial {
    if ($script:CachedSerial) { return $script:CachedSerial }
    if ($env:OWM_SERIAL) {
        $script:CachedSerial = $env:OWM_SERIAL
        return $script:CachedSerial
    }
    $candidates = Get-Candidates
    foreach ($serial in $candidates) {
        if ((Get-AvdName $serial) -eq $AvdName) {
            $script:CachedSerial = $serial
            return $serial
        }
    }
    foreach ($serial in $candidates) {
        if (Test-Serial $serial) {
            $script:CachedSerial = $serial
            return $serial
        }
    }
    throw "No usable device. Run './owm.ps1 boot' first, or './owm.ps1 doctor'."
}

# -------------------------------------------------------------------- commands

function Cmd-Doctor {
    "adb      : $Adb"
    "emulator : $Emulator"
    "avd      : $AvdName"
    ''
    'Devices:'
    $lines = & $Adb devices 2>&1 | Select-Object -Skip 1
    foreach ($line in $lines) {
        if ($line -match '^(\S+)\s+(\S+)\s*$') {
            $serial = $Matches[1]
            $usable = if (Test-Serial $serial) { 'shell OK' } else { 'shell REFUSED' }
            "  {0,-22} {1,-10} {2,-14} {3}" -f `
                $serial, $Matches[2], $usable, (Get-AvdName $serial)
        }
    }
    ''
    # try/catch is a statement in Windows PowerShell 5.1, not an expression.
    try { "Selected : " + (Get-Serial) } catch { "Selected : none - $_" }
}

function Cmd-Boot {
    $existing = & $Emulator -list-avds 2>&1
    if ($existing -notcontains $AvdName) {
        throw "AVD '$AvdName' does not exist. Create it with tools/devtest/create_avd.ps1."
    }
    foreach ($candidate in Get-Candidates) {
        if ((Get-AvdName $candidate) -eq $AvdName) {
            "Already running as $candidate."
            return
        }
    }

    # Headless with software GL by default. With -gpu host the emulator only
    # produces frames while its window is actually on screen, so a minimized or
    # occluded window leaves screencap returning the same stale frame forever
    # while the device carries on running: the clock inside the capture stops
    # even though `adb shell date` keeps advancing. swiftshader_indirect renders
    # off-screen and keeps capturing correctly no matter what the desktop is
    # doing. It is a conformant GL implementation, so MapLibre draws the same
    # pixels, only slower, which is what -Settle is for.
    #
    # -no-snapshot-load forces a cold boot so a test never inherits state from
    # the last run.
    $gpuArgs = if ($Windowed) { @('-gpu', 'host') } `
        else { @('-no-window', '-gpu', 'swiftshader_indirect') }
    "Booting $AvdName$(if ($Windowed) { ' (windowed)' } else { ' (headless)' })..."
    Start-Process -FilePath $Emulator -ArgumentList (@(
            '-avd', $AvdName, '-no-snapshot-load',
            '-no-boot-anim', '-netdelay', 'none', '-netspeed', 'full'
        ) + $gpuArgs) -WindowStyle Minimized

    # Not `adb wait-for-device`: with another emulator already attached it has no
    # way to know which one to wait for. Poll for our own AVD by name instead,
    # then wait for the launcher, because adbd answers long before an app can be
    # started.
    for ($i = 0; $i -lt 150; $i++) {
        Start-Sleep -Seconds 2
        $serial = $null
        foreach ($candidate in Get-Candidates) {
            if ((Get-AvdName $candidate) -eq $AvdName) { $serial = $candidate; break }
        }
        if (-not $serial) { continue }
        $ready = (Invoke-Adb @('shell', 'getprop', 'sys.boot_completed') `
                -Serial $serial | Out-String).Trim()
        if ($ready -match '1') { "Booted as $serial after $($i * 2)s."; return }
    }
    throw 'Emulator did not finish booting within 300s.'
}

function Cmd-Kill { Invoke-Adb @('emu', 'kill') }

function Cmd-Install {
    $apk = Join-Path $Repo 'app\build\app\outputs\flutter-apk\app-x86_64-release.apk'
    if (-not (Test-Path $apk)) {
        throw "No x86_64 APK. Build one: cd app; flutter build apk --release --split-per-abi"
    }
    "Installing $([math]::Round((Get-Item $apk).Length / 1MB, 1)) MB..."
    Invoke-Adb @('install', '-r', '-d', $apk)
}

function Cmd-Grant {
    # Granted up front so a test exercises the located path rather than the
    # permission dialog. Use `clear` first to get the dialog back.
    Invoke-Adb @('shell', 'pm', 'grant', $Package,
        'android.permission.ACCESS_FINE_LOCATION') | Out-Null
    Invoke-Adb @('shell', 'pm', 'grant', $Package,
        'android.permission.ACCESS_COARSE_LOCATION') | Out-Null
    'Location permissions granted.'
}

function Cmd-Launch {
    # `am start -W` waits for the launch to settle and reports a real status.
    # `monkey` returns 0 whether or not the activity came up.
    $out = Invoke-Adb @('shell', 'am', 'start', '-W', '-n', $Activity) | Out-String
    if ($out -notmatch 'Status:\s*ok') { throw "Launch failed:`n$out" }
    if ($Settle -gt 0) { Start-Sleep -Seconds $Settle }
    # $PID is a read-only automatic variable in PowerShell, hence $appPid.
    $appPid = (Invoke-Adb @('shell', 'pidof', $Package) | Out-String).Trim()
    if (-not $appPid) { throw 'App started but is no longer running: check ./owm.ps1 logs.' }
    "Launched $Package (pid $appPid)."
}

function Cmd-Stop { Invoke-Adb @('shell', 'am', 'force-stop', $Package) | Out-Null; 'Stopped.' }

function Cmd-Clear {
    # Wipes saved areas, packs and preferences, which is the only way to test
    # first-run behaviour such as the launch location prompt.
    Invoke-Adb @('shell', 'pm', 'clear', $Package)
}

function Cmd-Push {
    if (-not $Rest -or -not $Rest[0]) {
        throw 'Usage: owm.ps1 push <local file> [device path]'
    }
    $local = (Resolve-Path $Rest[0]).Path
    $remote = if ($Rest.Count -ge 2) { $Rest[1] }
              else { '/sdcard/Download/' + (Split-Path -Leaf $local) }
    Invoke-Adb @('push', $local, $remote) | Out-Null
    $check = (Invoke-Adb @('shell', 'ls', '-l', $remote) | Out-String).Trim()
    if ($check -match 'No such file') { throw "Push failed: $check" }
    # Exists on disk is not the same as offered by the file picker: the picker
    # lists what MediaStore has indexed. Pushing into Download is normally
    # indexed for us, but the scan is asked for explicitly so a pack that has
    # not appeared is a failure here rather than a mystery in the UI.
    Invoke-Adb @('shell', 'am', 'broadcast', '-a',
        'android.intent.action.MEDIA_SCANNER_SCAN_FILE',
        '-d', "file://$remote") | Out-Null
    $check
}

function Get-DeviceFile([string]$devicePath, [string]$localPath) {
    # Remove first, so a capture that fails cannot leave the previous run's file
    # behind for `pull` to fetch. /data/local/tmp survives reboots, so a stale
    # file otherwise looks like a perfectly good screenshot of the wrong thing.
    Invoke-Adb @('shell', 'rm', '-f', $devicePath) | Out-Null
    return $devicePath
}

function Cmd-Shot {
    $name = if ($Rest -and $Rest[0]) { $Rest[0] } else { 'shot' }
    if ($Settle -gt 0) { Start-Sleep -Seconds $Settle }
    $path = Join-Path $Artifacts "$name.png"
    Get-DeviceFile $DevShot | Out-Null
    # Capture on device and pull the file. Streaming `exec-out screencap` through
    # PowerShell corrupts the PNG: the pipeline decodes bytes as text, and
    # Set-Content -Encoding Byte cannot take strings back.
    Invoke-Adb @('shell', 'screencap', '-p', $DevShot) | Out-Null
    $listing = Invoke-Adb @('shell', 'ls', '-l', $DevShot) | Out-String
    if ($listing -match 'No such file') { throw "screencap wrote nothing to $DevShot." }
    Remove-Item $path -ErrorAction SilentlyContinue
    Invoke-Adb @('pull', $DevShot, $path) | Out-Null
    if (-not (Test-Path $path)) { throw "Could not pull $DevShot." }
    "$path ($([math]::Round((Get-Item $path).Length / 1KB, 0)) KB)"
}

function Get-Nodes {
    Get-DeviceFile $DevDump | Out-Null
    Invoke-Adb @('shell', 'uiautomator', 'dump', $DevDump) | Out-Null
    $raw = Invoke-Adb @('shell', 'cat', $DevDump) | Out-String
    if ($raw -notmatch '<hierarchy') {
        throw 'uiautomator returned no hierarchy. Flutter only publishes its semantics tree while an accessibility client is attached.'
    }
    $xml = [xml]$raw
    $nodes = @()
    foreach ($n in $xml.SelectNodes('//node')) {
        $label = if ($n.text) { $n.text } else { $n.'content-desc' }
        if (-not $label) { continue }
        if ($n.bounds -match '\[(\d+),(\d+)\]\[(\d+),(\d+)\]') {
            $nodes += [pscustomobject]@{
                Label     = $label
                First     = ($label -split "`n")[0].Trim()
                X         = [int](([int]$Matches[1] + [int]$Matches[3]) / 2)
                Y         = [int](([int]$Matches[2] + [int]$Matches[4]) / 2)
                Class     = ($n.class -replace '^.*\.', '')
                Clickable = ($n.clickable -eq 'true')
            }
        }
    }
    return $nodes
}

function Cmd-Dump { Get-Nodes | Format-Table -AutoSize }

function Cmd-Tap {
    $needle = $Rest -join ' '
    if (-not $needle) { throw 'tap needs something to look for.' }
    # Rank rather than take the first substring hit. A sheet's heading often
    # contains the name of a button inside it -- "Basemap / Streets and satellite
    # need network" versus the Streets button -- and the heading comes first in
    # the tree, so a plain match taps the title and nothing happens.
    $ranked = Get-Nodes |
        Where-Object { $_.Label -like "*$needle*" } |
        ForEach-Object {
            $rank = if ($_.First -eq $needle) { 0 }
                    elseif ($_.First -like "$needle*") { 1 }
                    elseif ($_.Label -like "$needle*") { 2 }
                    else { 3 }
            $_ | Add-Member -NotePropertyName Rank -NotePropertyValue $rank -PassThru
        } |
        Sort-Object Rank, @{ Expression = { -not $_.Clickable } }
    $ranked = @($ranked)
    if (-not $ranked.Count) { throw "No element matching '$needle'. Try './owm.ps1 dump'." }
    # Refuse to guess between equals. Offline packs shows one card per province,
    # so "Import ZIP" and "Delete local pack" each appear as many times as there
    # are provinces, and picking one silently imports a pack into the wrong one.
    # That failure is invisible from the outside: the province you meant keeps the
    # data it already had, and it looks like the import having no effect.
    $best = @($ranked | Where-Object {
        $_.Rank -eq $ranked[0].Rank -and $_.Clickable -eq $ranked[0].Clickable
    })
    if ($best.Count -gt 1) {
        $where = ($best | ForEach-Object { "$($_.X),$($_.Y)" }) -join '  '
        throw ("'$needle' matches $($best.Count) elements equally well at $where. " +
               "Use tapxy with the one you mean; owm.ps1 dump shows their order.")
    }
    $match = $ranked[0]
    Invoke-Adb @('shell', 'input', 'tap', $match.X, $match.Y) | Out-Null
    "Tapped '$($match.Label)' at $($match.X),$($match.Y)."
}

function Cmd-TapXY {
    if ($Rest.Count -lt 2) { throw 'tapxy needs x and y.' }
    Invoke-Adb @('shell', 'input', 'tap', $Rest[0], $Rest[1]) | Out-Null
    "Tapped $($Rest[0]),$($Rest[1])."
}

function Cmd-Swipe {
    if ($Rest.Count -lt 4) { throw 'swipe needs x1 y1 x2 y2 [ms].' }
    $ms = if ($Rest.Count -ge 5) { $Rest[4] } else { '300' }
    Invoke-Adb @('shell', 'input', 'swipe', $Rest[0], $Rest[1], $Rest[2], $Rest[3], $ms) | Out-Null
    'Swiped.'
}

function Cmd-Back { Invoke-Adb @('shell', 'input', 'keyevent', 'KEYCODE_BACK') | Out-Null; 'Back.' }
function Cmd-Home { Invoke-Adb @('shell', 'input', 'keyevent', 'KEYCODE_HOME') | Out-Null; 'Home.' }

function Cmd-Type {
    Invoke-Adb @('shell', 'input', 'text', (($Rest -join ' ') -replace ' ', '%s')) | Out-Null
    'Typed.'
}

function Cmd-Gps {
    if ($Rest.Count -lt 2) { throw 'gps needs a latitude and a longitude.' }
    # The emulator console takes longitude first. Getting this backwards puts the
    # device in the Indian Ocean, which looks like a bug in the app.
    Invoke-Adb @('emu', 'geo', 'fix', $Rest[1], $Rest[0]) | Out-Null
    "Location set to $($Rest[0]), $($Rest[1])."
}

function Cmd-Net {
    switch ($Rest[0]) {
        'off' {
            Invoke-Adb @('shell', 'svc', 'wifi', 'disable') | Out-Null
            Invoke-Adb @('shell', 'svc', 'data', 'disable') | Out-Null
            'Radios off. Tiles must now come from saved areas or not at all.'
        }
        'on' {
            Invoke-Adb @('shell', 'svc', 'wifi', 'enable') | Out-Null
            Invoke-Adb @('shell', 'svc', 'data', 'enable') | Out-Null
            'Radios on.'
        }
        default { throw "net takes 'on' or 'off'." }
    }
}

function Cmd-Logs {
    $path = Join-Path $Artifacts 'logcat.txt'
    Invoke-Adb @('logcat', '-d', '-v', 'brief') | Set-Content -Path $path
    $hits = Select-String -Path $path `
        -Pattern 'flutter|maplibre|AndroidRuntime|OpenWoods|openwoodsmap' -CaseSensitive:$false
    "$path ($($hits.Count) relevant lines)"
    $hits | Select-Object -Last 40 | ForEach-Object { $_.Line }
}

function Cmd-Shell { Invoke-Adb (@('shell') + $Rest) }

switch ($Command) {
    'doctor' { Cmd-Doctor }
    'boot' { Cmd-Boot }
    'kill' { Cmd-Kill }
    'install' { Cmd-Install }
    'grant' { Cmd-Grant }
    'launch' { Cmd-Launch }
    'stop' { Cmd-Stop }
    'clear' { Cmd-Clear }
    'shot' { Cmd-Shot }
    'dump' { Cmd-Dump }
    'tap' { Cmd-Tap }
    'tapxy' { Cmd-TapXY }
    'swipe' { Cmd-Swipe }
    'back' { Cmd-Back }
    'home' { Cmd-Home }
    'type' { Cmd-Type }
    'gps' { Cmd-Gps }
    'net' { Cmd-Net }
    'logs' { Cmd-Logs }
    'shell' { Cmd-Shell }
    'push' { Cmd-Push }
}
