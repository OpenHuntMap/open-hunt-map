# Patch maplibre_gl 0.27.0 for Flutter's AGP 9 + android.builtInKotlin=false default.
# Safe to re-run. Removes itself as a no-op once upstream ships the same guard.
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:LOCALAPPDATA 'Pub\Cache\hosted\pub.dev'
$dirs = Get-ChildItem -Path $root -Directory -Filter 'maplibre_gl-0.27*' -ErrorAction SilentlyContinue
if (-not $dirs) {
  Write-Host 'maplibre_gl 0.27.x not in pub cache; run flutter pub get first.'
  exit 0
}
$old = @'
def agpMajor = com.android.Version.ANDROID_GRADLE_PLUGIN_VERSION.tokenize('.')[0] as int
if (agpMajor < 9) {
    apply plugin: 'kotlin-android'
}
'@
$new = @'
def agpMajor = com.android.Version.ANDROID_GRADLE_PLUGIN_VERSION.tokenize('.')[0] as int
def builtInKotlinEnabled = project.findProperty('android.builtInKotlin')?.toString() == 'true'
if (agpMajor < 9 || !builtInKotlinEnabled) {
    apply plugin: 'kotlin-android'
}
'@
foreach ($dir in $dirs) {
  $gradle = Join-Path $dir.FullName 'android\build.gradle'
  if (-not (Test-Path $gradle)) { continue }
  $text = Get-Content -Raw -Path $gradle
  if ($text -match 'builtInKotlinEnabled') {
    Write-Host "Already patched: $($dir.Name)"
    continue
  }
  if ($text -notlike "*$($old.Trim())*" -and $text -notmatch 'if \(agpMajor < 9\)') {
    Write-Host "Unexpected maplibre_gl android/build.gradle layout in $($dir.Name); skip."
    continue
  }
  $patched = $text.Replace($old, $new)
  if ($patched -eq $text) {
    # Fallback: looser replace of the if-block only
    $patched = [regex]::Replace(
      $text,
      "def agpMajor = com\.android\.Version\.ANDROID_GRADLE_PLUGIN_VERSION\.tokenize\('\.'\)\[0\] as int\r?\nif \(agpMajor < 9\) \{\r?\n\s*apply plugin: 'kotlin-android'\r?\n\}",
      $new.Trim()
    )
  }
  if ($patched -eq $text) {
    Write-Host "Could not patch $($dir.Name)"
    continue
  }
  Set-Content -Path $gradle -Value $patched -NoNewline
  Write-Host "Patched: $($dir.Name)"
}
