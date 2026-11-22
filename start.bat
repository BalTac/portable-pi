@echo off
REM portable-pi launcher (Windows)
REM Usage: start.bat [--shell] [pi args...]
setlocal EnableExtensions EnableDelayedExpansion
chcp 65001 >nul 2>&1

set "USB=%~dp0"
if "%USB:~-1%"=="\" set "USB=%USB:~0,-1%"

set "NODE_DIR="
for /d %%D in ("%USB%\bin\win\node-v*-win-x64") do set "NODE_DIR=%%D"
if not defined NODE_DIR (
    echo ERROR: Node.js not found in %USB%\bin\win
    echo Run scripts\build.ps1 on this drive first.
    pause
    exit /b 1
)

REM ── portable toolchain ───────────────────────────────────────────────
set "PATH=%NODE_DIR%;%USB%\tools\bin;%PATH%"
if exist "%USB%\tools\git\mingit\usr\bin\bash.exe" (
    set "PATH=%USB%\tools\git\mingit\usr\bin;%USB%\tools\git\mingit\ucrt64\bin;%USB%\tools\git\mingit\cmd;%PATH%"
)

REM ── agent dir: everything stays on the drive ─────────────────────────
set "PI_CODING_AGENT_DIR=%USB%\config\pi"
set "PI_CODING_AGENT_SESSION_DIR=%USB%\config\pi\sessions"
set "PI_SKIP_VERSION_CHECK=1"
set "PI_TELEMETRY=0"

REM ── no traces: temp/cache on the drive ───────────────────────────────
set "TMP=%USB%\temp"
set "TEMP=%USB%\temp"
set "NPM_CONFIG_CACHE=%USB%\temp\npm-cache"
set "NODE_COMPILE_CACHE=%USB%\temp\node-cache"
set "XDG_CACHE_HOME=%USB%\temp\cache"
if not exist "%USB%\temp\npm-cache" mkdir "%USB%\temp\npm-cache"
if not exist "%USB%\temp\node-cache" mkdir "%USB%\temp\node-cache"
if not exist "%USB%\temp\cache" mkdir "%USB%\temp\cache"
if not exist "%USB%\config\pi\sessions" mkdir "%USB%\config\pi\sessions"

REM ── optional API keys ────────────────────────────────────────────────
if exist "%USB%\config\env.bat" call "%USB%\config\env.bat"

REM ── shell-only mode ──────────────────────────────────────────────────
if /i "%~1"=="--shell" (
    shift
    cls
    echo.
    echo  ======================================================
    echo   portable-pi shell
    echo  ======================================================
    echo   pi       the agent ^(skills mounted from the drive^)
    for /f "delims=" %%V in ('node --version') do echo   node     %%V
    for /f "tokens=1-3" %%A in ('git --version 2^>nul') do echo   git      %%A %%B %%C
    echo   exit     to close
    echo  ======================================================
    echo.
    cmd /k "cd /d "%USERPROFILE%""
    exit /b 0
)

cd /d "%USERPROFILE%"
"%USB%\tools\bin\pi.cmd" %*
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
    echo.
    echo portable-pi exited with code %RC%.
    pause
)
exit /b %RC%
