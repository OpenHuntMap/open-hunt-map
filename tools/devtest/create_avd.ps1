<#
.SYNOPSIS
    Creates the `owm_test` emulator used by tools/devtest/owm.ps1.

.DESCRIPTION
    Run once per machine. Needs the system image first:

        $sdk = "$env:LOCALAPPDATA\Android\sdk"
        # --package_file avoids the semicolon problem described below
        "system-images;android-35;google_apis;x86_64" | Set-Content pkg.txt
        & "$sdk\cmdline-tools\latest\bin\sdkmanager.bat" --package_file=pkg.txt

    Google APIs rather than Play Store, so the image stays debuggable and
    `adb root` keeps working. API 35 rather than the newest, so the device is
    one real users are on.
#>
[CmdletBinding()]
param([string]$AvdName = 'owm_test')

$ErrorActionPreference = 'Stop'

$Sdk = Join-Path $env:LOCALAPPDATA 'Android\sdk'
$AvdManager = Join-Path $Sdk 'cmdline-tools\latest\bin\avdmanager.bat'
$SystemImage = 'system-images;android-35;google_apis;x86_64'

if (-not (Test-Path $AvdManager)) { throw "avdmanager not found at $AvdManager" }
if (-not $env:JAVA_HOME) {
    $jbr = 'C:\Program Files\Android\Android Studio\jbr'
    if (Test-Path $jbr) { $env:JAVA_HOME = $jbr }
}

# cmd.exe splits unquoted arguments on semicolons, and these SDK entry points
# are batch files, so a package id passed straight from PowerShell arrives as
# four separate arguments and every one of them is reported "not found".
# Building the command line for cmd with the quotes intact is what keeps the id
# in one piece.
$command = '"{0}" create avd -n {1} -k "{2}" -d pixel_6 --force' -f `
    $AvdManager, $AvdName, $SystemImage

Write-Host "Creating AVD '$AvdName' from $SystemImage..."
'no' | & cmd /c $command

$config = Join-Path $env:USERPROFILE ".android\avd\$AvdName.avd\config.ini"
if (-not (Test-Path $config)) { throw "AVD created but no config at $config" }

# Defaults are too small to render a vector basemap and download tiles at the
# same time, and the emulator will not use the host GPU unless told to.
$settings = @{
    'hw.gpu.enabled'    = 'yes'
    'hw.gpu.mode'       = 'host'
    'hw.ramSize'        = '4096'
    'vm.heapSize'       = '512'
    'disk.dataPartition.size' = '8G'
    'hw.keyboard'       = 'yes'
    # Location fixes are pushed over the console by owm.ps1 rather than typed
    # into the emulator UI.
    'hw.gps'            = 'yes'
}

$lines = Get-Content $config
foreach ($key in $settings.Keys) {
    $value = $settings[$key]
    if ($lines -match "^$([regex]::Escape($key))=") {
        $lines = $lines -replace "^$([regex]::Escape($key))=.*", "$key=$value"
    } else {
        $lines += "$key=$value"
    }
}
$lines | Set-Content $config

Write-Host "Done. Boot it with: ./tools/devtest/owm.ps1 boot"
