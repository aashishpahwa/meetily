@echo off
setlocal EnableDelayedExpansion

echo ============================================================
echo  Meetily - Windows Installer Builder
echo ============================================================
echo.

:: ── 1. Check prerequisites ──────────────────────────────────────────────────

echo [1/5] Checking prerequisites...

where rustc >nul 2>&1
if errorlevel 1 (
    echo ERROR: Rust not found. Install from https://rustup.rs/
    pause & exit /b 1
)
for /f "tokens=*" %%v in ('rustc --version') do echo   Rust: %%v

where node >nul 2>&1
if errorlevel 1 (
    echo ERROR: Node.js not found. Install from https://nodejs.org/
    pause & exit /b 1
)
for /f "tokens=*" %%v in ('node --version') do echo   Node: %%v

where pnpm >nul 2>&1
if errorlevel 1 (
    echo   pnpm not found - installing...
    call npm install -g pnpm
    if errorlevel 1 (
        echo ERROR: Failed to install pnpm
        pause & exit /b 1
    )
)
for /f "tokens=*" %%v in ('pnpm --version') do echo   pnpm: %%v

:: Check LLVM/Clang
if not defined LIBCLANG_PATH (
    if exist "C:\Program Files\LLVM\bin\libclang.dll" (
        set LIBCLANG_PATH=C:\Program Files\LLVM\bin
        echo   LLVM: Found at C:\Program Files\LLVM\bin
    ) else (
        echo.
        echo ERROR: LLVM/Clang not found.
        echo.
        echo   Please install LLVM from:
        echo   https://github.com/llvm/llvm-project/releases/download/llvmorg-17.0.6/LLVM-17.0.6-win64.exe
        echo.
        echo   During install, check "Add LLVM to the system PATH", then run:
        echo   setx LIBCLANG_PATH "C:\Program Files\LLVM\bin" /M
        echo.
        echo   Restart this script after installing LLVM.
        pause & exit /b 1
    )
) else (
    echo   LLVM: LIBCLANG_PATH=%LIBCLANG_PATH%
)

echo.

:: ── 2. Build llama-helper sidecar ──────────────────────────────────────────

echo [2/5] Building llama-helper sidecar binary...

set SCRIPT_DIR=%~dp0
set LLAMA_DIR=%SCRIPT_DIR%llama-helper
set BINARIES_DIR=%SCRIPT_DIR%frontend\src-tauri\binaries

if not exist "%BINARIES_DIR%" mkdir "%BINARIES_DIR%"

:: Detect target triple (usually x86_64-pc-windows-msvc)
for /f "tokens=*" %%t in ('rustc -vV ^| findstr /C:"host:"') do (
    set HOST_LINE=%%t
)
set TARGET_TRIPLE=!HOST_LINE:host: =!

set LLAMA_OUTPUT=%BINARIES_DIR%\llama-helper-%TARGET_TRIPLE%.exe

if exist "%LLAMA_OUTPUT%" (
    echo   llama-helper already built, skipping.
) else (
    echo   Building for target: %TARGET_TRIPLE%
    pushd "%LLAMA_DIR%"
    cargo build --release
    if errorlevel 1 (
        echo ERROR: Failed to build llama-helper
        echo   (This is optional - the app works without it)
        echo   Continuing anyway...
    ) else (
        copy /Y "target\release\llama-helper.exe" "%LLAMA_OUTPUT%"
        echo   llama-helper built OK
    )
    popd
)

echo.

:: ── 3. Install frontend dependencies ────────────────────────────────────────

echo [3/5] Installing frontend dependencies...
pushd "%SCRIPT_DIR%frontend"
call pnpm install
if errorlevel 1 (
    echo ERROR: pnpm install failed
    popd & pause & exit /b 1
)
popd
echo.

:: ── 4. Build the Tauri app + installer ──────────────────────────────────────

echo [4/5] Building Tauri app and creating installer...
echo   This will take 10-20 minutes on first build (compiling whisper.cpp).
echo.

pushd "%SCRIPT_DIR%frontend"
call pnpm run tauri build
if errorlevel 1 (
    echo ERROR: Tauri build failed. Check the output above.
    popd & pause & exit /b 1
)
popd
echo.

:: ── 5. Report output location ───────────────────────────────────────────────

echo [5/5] Build complete!
echo.
set BUNDLE_DIR=%SCRIPT_DIR%frontend\src-tauri\target\release\bundle
echo Installer location:
echo.

if exist "%BUNDLE_DIR%\nsis\" (
    echo   NSIS installer (.exe):
    for %%f in ("%BUNDLE_DIR%\nsis\*.exe") do echo     %%f
)
if exist "%BUNDLE_DIR%\msi\" (
    echo   MSI installer:
    for %%f in ("%BUNDLE_DIR%\msi\*.msi") do echo     %%f
)

echo.
echo Done! Double-click the .exe to install Meetily.
echo.
pause
