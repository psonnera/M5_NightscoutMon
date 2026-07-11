<#
.SYNOPSIS
    Compiles M5_NightscoutMon into the minimum set of firmwares for the whole
    M5Stack lineup and exports them to <repo>\Binaries\<group>\.

.DESCRIPTION
    One M5Unified source now covers every board; the firmware count is driven only
    by chip architecture + flash size. Three build groups:

      Basic4MB   - old Basic (<=2020.5, 4 MB, no PSRAM). min_spiffs is the only
                   4 MB scheme that fits AND keeps OTA. This board is the growth
                   ceiling for its own image; it no longer caps the others.
      ESP32_16MB - Basic 16 MB/v2.7, Fire, all Core2 (16 MB ESP32). default_16MB
                   gives 2x 6.25 MiB OTA slots (~5 MB expansion headroom), so the
                   app can grow and still self-update OTA with no repartition/USB
                   reflash. Built PSRAM-off so the single image is also safe on the
                   no-PSRAM Basic 16 MB (Fire/Core2 PSRAM sits idle; app needs none).
      CoreS3     - all CoreS3 (K128/Lite/SE/K149). Separate binary only because
                   ESP32-S3 is a different CPU architecture.

    Board sub-variants (AXP192/AXP2101 PMU, IMU, RTC, touch) are auto-detected by
    M5Unified at runtime, so no further binaries are needed.

.PARAMETER Target
    Basic4MB | ESP32_16MB | CoreS3 | All. Omit for an interactive menu.

.PARAMETER ArduinoCli
    Path to arduino-cli.exe. Defaults to the one bundled with Arduino IDE 2.x,
    or the ARDUINO_CLI environment variable if set.

.EXAMPLE
    .\build.ps1                 # interactive menu
    .\build.ps1 -Target All     # build all three firmwares
#>

[CmdletBinding()]
param(
    [ValidateSet('Basic4MB', 'ESP32_16MB', 'CoreS3', 'All')]
    [string]$Target,

    [string]$ArduinoCli
)

$ErrorActionPreference = 'Stop'

# --- Paths --------------------------------------------------------------------
$RepoRoot = Split-Path $PSScriptRoot -Parent
$Sketch   = Join-Path $RepoRoot 'M5_NightscoutMon.ino'

if (-not (Test-Path $Sketch)) {
    throw "Sketch not found: $Sketch"
}

# --- Locate arduino-cli -------------------------------------------------------
if (-not $ArduinoCli) { $ArduinoCli = $env:ARDUINO_CLI }
if (-not $ArduinoCli) {
    $ArduinoCli = 'C:/Users/patri/AppData/Local/Programs/Arduino IDE/resources/app/lib/backend/resources/arduino-cli.exe'
}
if (-not (Test-Path $ArduinoCli)) {
    throw "arduino-cli not found at '$ArduinoCli'. Pass -ArduinoCli <path> or set `$env:ARDUINO_CLI."
}

# --- Environment so the CLI finds the ESP32 core + libraries ------------------
$env:ARDUINO_DIRECTORIES_DATA = 'C:/Users/patri/AppData/Local/Arduino15'
$env:ARDUINO_DIRECTORIES_USER = 'C:/Users/patri/Documents/Arduino'

# --- Target table -------------------------------------------------------------
# Order matters for the interactive menu.
$Targets = [ordered]@{
    'Basic4MB'   = @{ Fqbn = 'esp32:esp32:m5stack-core-esp32:PartitionScheme=min_spiffs';           Folder = 'Basic_4MB';   Desc = 'old Basic <=2020.5, 4MB, no PSRAM  -> min_spiffs' }
    'ESP32_16MB' = @{ Fqbn = 'esp32:esp32:m5stack-fire:PartitionScheme=default,PSRAM=disabled';      Folder = 'ESP32_16MB';  Desc = 'Basic 16MB, Fire, all Core2         -> default 16MB, PSRAM off' }
    'CoreS3'     = @{ Fqbn = 'esp32:esp32:m5stack-cores3:PartitionScheme=default_16MB';              Folder = 'CoreS3';      Desc = 'all CoreS3 (ESP32-S3)              -> default_16MB' }
}

# Common flag: matches the PlatformIO fix for the missing gpio_deep_sleep_hold_dis
# method on this core build. Harmless where not needed.
$ExtraFlags = 'compiler.cpp.extra_flags=-Dgpio_deep_sleep_hold_dis=_NOP'

# --- Firmware version (drives OTA's update.inf) -------------------------------
# OTA (M5NSWebConfig.cpp) compares this string lexicographically, so it must stay
# a fixed-width, zero-padded, monotonically increasing token (currently YYYYMMDDnn).
$versionMatch = Select-String -Path $Sketch -Pattern 'String\s+M5NSversion\("([^"]+)"\)' | Select-Object -First 1
if (-not $versionMatch) {
    throw "Could not find M5NSversion in $Sketch"
}
$FirmwareVersion = $versionMatch.Matches[0].Groups[1].Value

# --- Interactive menu (only if no -Target given) ------------------------------
if (-not $Target) {
    Write-Host ''
    Write-Host 'M5_NightscoutMon - firmware build' -ForegroundColor Cyan
    Write-Host '---------------------------------'
    $i = 1
    $indexMap = @{}
    foreach ($name in $Targets.Keys) {
        Write-Host ("  [{0}] {1,-11} ({2})" -f $i, $name, $Targets[$name].Desc)
        $indexMap[[string]$i] = $name
        $i++
    }
    Write-Host ("  [{0}] All" -f $i)
    $indexMap[[string]$i] = 'All'
    Write-Host ''
    $choice = Read-Host 'Select target'
    if (-not $indexMap.ContainsKey($choice)) { throw "Invalid selection: '$choice'" }
    $Target = $indexMap[$choice]
}

# --- Resolve selection to a list of target names ------------------------------
$toBuild = if ($Target -eq 'All') { @($Targets.Keys) } else { @($Target) }

# --- Build --------------------------------------------------------------------
$results = @()
foreach ($name in $toBuild) {
    $t       = $Targets[$name]
    $outDir  = Join-Path (Join-Path $RepoRoot 'Binaries') $t.Folder

    Write-Host ''
    Write-Host ("=== Building $name ===") -ForegroundColor Green
    Write-Host ("    FQBN : {0}" -f $t.Fqbn)
    Write-Host ("    Out  : {0}" -f $outDir)

    New-Item -ItemType Directory -Force -Path $outDir | Out-Null

    & $ArduinoCli compile --clean `
        --fqbn $t.Fqbn `
        --build-property $ExtraFlags `
        --output-dir $outDir `
        $Sketch

    if ($LASTEXITCODE -ne 0) {
        throw "Build FAILED for $name (arduino-cli exit $LASTEXITCODE)."
    }

    # Keep only the flashable bins; drop the heavy .elf/.map debug artifacts (~40 MB/group).
    Get-ChildItem $outDir -Include *.elf, *.map -File -Recurse | Remove-Item -Force

    # OTA (M5NSWebConfig.cpp) pulls this file to decide whether a newer firmware is
    # available; regenerate it every build so it always matches what was just built.
    # whatsnew.txt is hand-authored and intentionally left untouched here.
    $infPath = Join-Path $outDir 'update.inf'
    Set-Content -Path $infPath -Value $FirmwareVersion -NoNewline -Encoding ascii

    $results += $name
}

Write-Host ''
Write-Host ("Done. Built: {0}" -f ($results -join ', ')) -ForegroundColor Cyan
Write-Host "Binaries are in <repo>\Binaries\<group>\ (app + bootloader + partitions). See Scripts\README.md to flash."
