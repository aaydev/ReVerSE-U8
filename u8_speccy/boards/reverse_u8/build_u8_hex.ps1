# Root = the directory where the script is located
$BOARD_DIR = "$PSScriptRoot\"
$SJASM     = Join-Path $BOARD_DIR "..\..\tools\sjasmplus.exe"
$BINHEX    = Join-Path $BOARD_DIR "..\..\tools\bin2hex.exe"

# Helper: wait for any key press (equivalent to batch 'pause')
function Wait-Key {
    Write-Host "Press any key to continue . . ."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

# Check for required tools
if (!(Test-Path $SJASM)) {
    Write-Host "[ERROR] sjasmplus.exe not found: $SJASM"
    Wait-Key
    exit 1
}
if (!(Test-Path $BINHEX)) {
    Write-Host "[ERROR] bin2hex.exe not found: $BINHEX"
    Wait-Key
    exit 1
}

Clear-Host
Write-Host "============================================"
Write-Host "  ReVerSE-U8 Firmware Build (from board dir)"
Write-Host "============================================"
Write-Host ""

# ----------------------------------------
# Function: convert a single ROM file to HEX
# ----------------------------------------
function Convert-Rom {
    param(
        [string]$RomFile,
        [string]$HexFile
    )

    $romPath = Join-Path $script:ROM_DIR $RomFile
    $hexPath = Join-Path $script:HEX_DIR $HexFile

    if (!(Test-Path $romPath)) {
        Write-Host "[SKIP] $RomFile not found"
        return $false
    }

    & $script:BINHEX $romPath $hexPath
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[FAIL] Conversion failed: $RomFile"
        return $false
    }

    Write-Host "[OK]   $RomFile -> $HexFile"
    return $true
}

# ----------------------------------------
Write-Host "[1/4] BUILD LOADER"
Write-Host "----------------------------------------"
$loaderDir = Join-Path $BOARD_DIR "firmwares\loader"
Push-Location $loaderDir
Remove-Item -Path "*.bin", "*.hex" -Force -ErrorAction SilentlyContinue

& $SJASM loader.asm
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] sjasmplus failed for loader.asm"
    Pop-Location; Wait-Key; exit 1
}

& $BINHEX loader.bin loader.hex
Remove-Item -Path "*.bin" -Force -ErrorAction SilentlyContinue
Pop-Location
Write-Host "[OK] Loader built successfully"
Write-Host ""

# ----------------------------------------
Write-Host "[2/4] BUILD OSD ROM"
Write-Host "----------------------------------------"
$osdDir = Join-Path $BOARD_DIR "firmwares\osd"
Push-Location $osdDir
Remove-Item -Path "*.bin", "*.hex" -Force -ErrorAction SilentlyContinue

& $SJASM rom.asm
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] sjasmplus failed for rom.asm"
    Pop-Location; Wait-Key; exit 1
}

& $BINHEX rom.bin rom.hex
Remove-Item -Path "*.bin" -Force -ErrorAction SilentlyContinue
Pop-Location
Write-Host "[OK] OSD ROM built successfully"
Write-Host ""

# ----------------------------------------
Write-Host "[3/4] BUILD EXTERNAL ROMS"
Write-Host "----------------------------------------"
$script:ROM_DIR = Join-Path $BOARD_DIR "firmwares\loader\rom"
$script:HEX_DIR = Join-Path $BOARD_DIR "firmwares\loader\rom"

if (!(Test-Path $script:HEX_DIR)) {
    New-Item -ItemType Directory -Path $script:HEX_DIR | Out-Null
}
Remove-Item -Path (Join-Path $script:HEX_DIR "*.hex") -Force -ErrorAction SilentlyContinue

$buildOk = $true
$roms = @(
    @{ Src = "82.rom";         Dst = "82.hex" }
    @{ Src = "86.rom";         Dst = "86.hex" }
    @{ Src = "esxmmc089.rom";  Dst = "esxmmc.hex" }
    @{ Src = "gs105a.rom";     Dst = "gs105a.hex" }
    @{ Src = "hegluk_19.rom";  Dst = "hegluk_19.hex" }
    @{ Src = "trdos_605e.rom"; Dst = "trdos_605e.hex" }
)

foreach ($rom in $roms) {
    $result = Convert-Rom -RomFile $rom.Src -HexFile $rom.Dst
    if (!$result) { $buildOk = $false }
}

if (!$buildOk) {
    Write-Host "[WARNING] Some ROM conversions failed!"
} else {
    Write-Host "[OK] All external ROMs converted successfully"
}
Write-Host ""

# ----------------------------------------
Write-Host "[4/4] CONVERT FONT 8x16"
Write-Host "----------------------------------------"
$FONT_SRC = Join-Path $BOARD_DIR "..\..\cores\txt\8x16.fnt"
$FONT_DST = Join-Path $BOARD_DIR "..\..\cores\txt\8x16.hex"

if (!(Test-Path $FONT_SRC)) {
    Write-Host "[SKIP] 8x16.fnt not found: $FONT_SRC"
    $buildOk = $false
} else {
    & $BINHEX $FONT_SRC $FONT_DST
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[FAIL] Font conversion failed: 8x16.fnt"
        $buildOk = $false
    } else {
        Write-Host "[OK]   8x16.fnt -> 8x16.hex"
    }
}
Write-Host ""

Write-Host "============================================"
Write-Host "  Build complete!"
Write-Host "============================================"
Wait-Key
exit 0