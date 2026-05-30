#Requires -Version 5
<#
.SYNOPSIS
    Meetily Windows Installer Builder
.DESCRIPTION
    Checks prerequisites, builds llama-helper sidecar, installs frontend deps,
    and runs `pnpm tauri build` to produce an NSIS .exe installer.
    All output is mirrored to build_installer.log in this directory.
#>

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogFile   = Join-Path $ScriptDir 'build_installer.log'

# ── Logging helpers ──────────────────────────────────────────────────────────
function Log {
    param([string]$Msg, [string]$Color = 'White')
    $ts = Get-Date -Format 'HH:mm:ss'
    $line = "[$ts] $Msg"
    Write-Host $line -ForegroundColor $Color
    Add-Content -Path $LogFile -Value $line
}
function LogOk  { param([string]$M) Log "  OK  $M" 'Green'  }
function LogErr { param([string]$M) Log " ERR  $M" 'Red'    }
function LogWrn { param([string]$M) Log "WARN  $M" 'Yellow' }
function Step   { param([string]$M) Log "`n--- $M ---" 'Cyan' }
function Bail {
    param([string]$Msg)
    LogErr $Msg
    Log "`nBuild FAILED. Full log at: $LogFile" 'Red'
    Read-Host "`nPress Enter to close"
    exit 1
}

# Start fresh log
Set-Content -Path $LogFile -Value "Meetily installer build — $(Get-Date)`n"

Log "============================================================" 'Cyan'
Log " Meetily - Windows Installer Builder" 'Cyan'
Log "============================================================" 'Cyan'
Log "Log file: $LogFile"

# ── Step 1: Prerequisites ────────────────────────────────────────────────────
Step "1/5  Checking prerequisites"

# Rust
try {
    $rv = & rustc --version 2>&1
    LogOk "Rust: $rv"
} catch {
    Bail "Rust not found. Install from https://rustup.rs/"
}

# Node
try {
    $nv = & node --version 2>&1
    LogOk "Node: $nv"
} catch {
    Bail "Node.js not found. Install from https://nodejs.org/"
}

# pnpm — install if missing
if (-not (Get-Command pnpm -ErrorAction SilentlyContinue)) {
    LogWrn "pnpm not found — installing via npm..."
    & npm install -g pnpm
    if ($LASTEXITCODE -ne 0) { Bail "Failed to install pnpm" }
}
$pv = & pnpm --version 2>&1
LogOk "pnpm: $pv"

# LLVM / libclang
$llvmFound = $false
$llvmCandidates = @(
    $env:LIBCLANG_PATH,
    'C:\Program Files\LLVM\bin',
    'C:\LLVM\bin'
)
foreach ($candidate in $llvmCandidates) {
    if ($candidate -and (Test-Path (Join-Path $candidate 'libclang.dll'))) {
        $env:LIBCLANG_PATH = $candidate
        LogOk "LLVM: found at $candidate"
        $llvmFound = $true
        break
    }
}
if (-not $llvmFound) {
    LogErr "LLVM/Clang (libclang.dll) not found."
    Log ""
    Log "  Please install LLVM from:" 'Yellow'
    Log "  https://github.com/llvm/llvm-project/releases/download/llvmorg-17.0.6/LLVM-17.0.6-win64.exe" 'Yellow'
    Log ""
    Log "  During install: CHECK 'Add LLVM to the system PATH'" 'Yellow'
    Log "  Then re-run this script." 'Yellow'
    Log ""
    Read-Host "Press Enter to close"
    exit 1
}

# ── Step 2: Build llama-helper sidecar ──────────────────────────────────────
Step "2/5  Building llama-helper sidecar"

$LlamaDir    = Join-Path $ScriptDir 'llama-helper'
$BinariesDir = Join-Path $ScriptDir 'frontend\src-tauri\binaries'

if (-not (Test-Path $BinariesDir)) {
    New-Item -ItemType Directory -Force -Path $BinariesDir | Out-Null
}

# Get the host target triple (e.g. x86_64-pc-windows-msvc)
$targetRaw = & rustc -vV 2>&1 | Select-String 'host:' | ForEach-Object { $_.Line.Trim() }
$targetTriple = $targetRaw -replace '^host:\s*', ''
Log "  Target triple: $targetTriple"

$LlamaOut = Join-Path $BinariesDir "llama-helper-$targetTriple.exe"

if (Test-Path $LlamaOut) {
    LogOk "llama-helper already built — skipping"
} else {
    Log "  Compiling llama-helper (may take a few minutes)..."
    Push-Location $LlamaDir
    & cargo build --release 2>&1 | ForEach-Object { Log "    $_" }
    $rc = $LASTEXITCODE
    Pop-Location
    if ($rc -ne 0) {
        LogWrn "llama-helper build failed (optional component) — continuing"
    } else {
        Copy-Item (Join-Path $LlamaDir 'target\release\llama-helper.exe') $LlamaOut -Force
        LogOk "llama-helper built OK -> $LlamaOut"
    }
}

# ── Step 3: Frontend dependencies ───────────────────────────────────────────
Step "3/5  Installing frontend dependencies"

Push-Location (Join-Path $ScriptDir 'frontend')
& pnpm install 2>&1 | ForEach-Object { Log "  $_" }
if ($LASTEXITCODE -ne 0) {
    Pop-Location
    Bail "pnpm install failed"
}
Pop-Location
LogOk "pnpm install complete"

# ── Step 4: Tauri build ──────────────────────────────────────────────────────
Step "4/5  Building Tauri app + installer"
Log "  First build compiles whisper.cpp — allow 15-20 minutes." 'Yellow'
Log ""

Push-Location (Join-Path $ScriptDir 'frontend')
& pnpm run tauri build 2>&1 | ForEach-Object { Log "  $_" }
$rc = $LASTEXITCODE
Pop-Location

if ($rc -ne 0) {
    Bail "Tauri build failed (exit $rc). Check the log above for details."
}
LogOk "Tauri build succeeded"

# ── Step 5: Show output ──────────────────────────────────────────────────────
Step "5/5  Build complete!"

$BundleDir = Join-Path $ScriptDir 'frontend\src-tauri\target\release\bundle'
Log ""
Log "Installer files:" 'Cyan'

$found = $false
@('nsis\*.exe','msi\*.msi') | ForEach-Object {
    $pattern = Join-Path $BundleDir $_
    Get-ChildItem $pattern -ErrorAction SilentlyContinue | ForEach-Object {
        Log "  $($_.FullName)" 'Green'
        $found = $true
    }
}

if (-not $found) {
    LogWrn "No installer found in $BundleDir — check log for errors"
}

Log ""
Log "Full build log saved to: $LogFile" 'Cyan'
Log ""
Read-Host "Press Enter to close"
