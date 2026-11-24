@echo off
REM portable-pi update launcher (Windows)
REM Usage: update.bat            interactive: check, then choose components
REM        update.bat /client    update pi only
REM        update.bat /ext       update extensions + skills only
REM        update.bat /all       update everything in one pass
setlocal EnableExtensions EnableDelayedExpansion
chcp 65001 >nul 2>&1
title portable-pi update

set "USB=%~dp0"
if "%USB:~-1%"=="\" set "USB=%USB:~0,-1%"

REM ── portable toolchain ───────────────────────────────────────────────
set "NODE_DIR="
for /d %%D in ("%USB%\bin\win\node-v*-win-x64") do set "NODE_DIR=%%D"
if not defined NODE_DIR (
    echo ERROR: Node.js not found in %USB%\bin\win
    echo Rebuild the drive first: scripts\build.ps1 -Target %USB%
    pause
    exit /b 1
)
set "PATH=%NODE_DIR%;%USB%\tools\bin;%PATH%"
if exist "%USB%\tools\git\mingit\usr\bin\bash.exe" (
    set "PATH=%USB%\tools\git\mingit\usr\bin;%USB%\tools\git\mingit\ucrt64\bin;%USB%\tools\git\mingit\cmd;%PATH%"
)

REM ── isolation: the same env start.bat sets, so nothing lands on the host ──
set "PI_CODING_AGENT_DIR=%USB%\config\pi"
set "PI_CODING_AGENT_SESSION_DIR=%USB%\config\pi\sessions"
set "PI_SKIP_VERSION_CHECK=1"
set "PI_TELEMETRY=0"
REM the host temp is remembered before TMP/TEMP move onto the drive: npm staging
REM belongs on the host (exFAT makes npm take minutes per package)
set "PI_HOST_TEMP=%TEMP%"
set "TMP=%USB%\temp"
set "TEMP=%USB%\temp"
set "NPM_CONFIG_CACHE=%USB%\temp\npm-cache"
set "NODE_COMPILE_CACHE=%USB%\temp\node-cache"
set "XDG_CACHE_HOME=%USB%\temp\cache"
REM exFAT has no ownership: keep git's exception in the environment
set "GIT_CONFIG_COUNT=1"
set "GIT_CONFIG_KEY_0=safe.directory"
set "GIT_CONFIG_VALUE_0=*"
if not exist "%USB%\temp\npm-cache" mkdir "%USB%\temp\npm-cache"
if exist "%USB%\config\env.bat" call "%USB%\config\env.bat"

REM ── what is out of date? ─────────────────────────────────────────────
echo.
echo  ======================================================
echo   portable-pi update
echo  ======================================================
"%NODE_DIR%\node.exe" "%USB%\scripts\check-updates.mjs" --drive "%USB%" --node --json "%USB%\temp\update-plan.json"
if errorlevel 3 (
    echo.
    echo  Rete non raggiungibile: impossibile controllare gli aggiornamenti.
    pause
    exit /b 1
)
"%NODE_DIR%\node.exe" -e "const p=require(process.argv[1]);process.exit(p.anyUpdate?0:1)" "%USB%\temp\update-plan.json"
if errorlevel 1 (
    echo  Niente da aggiornare. Esco senza toccare il drive.
    ping -n 4 127.0.0.1 >nul 2>&1
    exit /b 0
)

REM ── components ───────────────────────────────────────────────────────
set "COMP="
if /i "%~1"=="/client" set "COMP=client"
if /i "%~1"=="/ext" set "COMP=extensions"
if /i "%~1"=="/extensions" set "COMP=extensions"
if /i "%~1"=="/all" set "COMP=all"

if not defined COMP (
    echo.
    echo   [1] client      aggiorna pi ^(e Node, se lo chiedi^)
    echo   [2] estensioni  aggiorna pacchetti vendorizzati + skill
    echo   [3] tutto       client + estensioni in una passata
    echo   [0] esci
    echo.
    choice /c 1230 /n /m "  Scelta: "
    if errorlevel 4 exit /b 0
    if errorlevel 3 set "COMP=all"
    if errorlevel 2 set "COMP=extensions"
    if errorlevel 1 set "COMP=client"
)

set "NODEOPT="
if /i "%COMP%"=="client" (
    choice /c SN /n /m "  Aggiornare anche Node LTS? [S/n] "
    if not errorlevel 2 set "NODEOPT=-Node latest"
)
if /i "%COMP%"=="all" (
    choice /c SN /n /m "  Aggiornare anche Node LTS? [S/n] "
    if not errorlevel 2 set "NODEOPT=-Node latest"
)

echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%USB%\scripts\update.ps1" -Drive "%USB%" -Components %COMP% -Yes %NODEOPT%
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" (
    echo Aggiornamento NON riuscito ^(codice %RC%^). Il drive non e' stato lasciato a meta':
    echo riesegui questo launcher oppure scripts\verify.ps1 per vedere cosa manca.
    pause
    exit /b %RC%
)
echo  Fatto. Avvio normale: start.bat
pause
exit /b 0
