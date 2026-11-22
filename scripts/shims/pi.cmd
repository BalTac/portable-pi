@echo off
REM portable-pi shim: runs the bundled pi with the portable Node runtime.
REM Self-contained on purpose: works even when invoked outside start.bat.
setlocal EnableExtensions

set "BIN=%~dp0"
if "%BIN:~-1%"=="\" set "BIN=%BIN:~0,-1%"
for %%P in ("%BIN%\..\..") do set "USB=%%~fP"
if "%USB:~-1%"=="\" set "USB=%USB:~0,-1%"

set "NODE_DIR="
for /d %%D in ("%USB%\bin\win\node-v*-win-x64") do set "NODE_DIR=%%D"
if not defined NODE_DIR (
  echo portable-pi: Node.js not found in %USB%\bin\win ^(run the build first^) 1>&2
  exit /b 1
)

if not defined PI_CODING_AGENT_DIR set "PI_CODING_AGENT_DIR=%USB%\config\pi"
if not defined PI_CODING_AGENT_SESSION_DIR set "PI_CODING_AGENT_SESSION_DIR=%USB%\config\pi\sessions"
if not defined PI_SKIP_VERSION_CHECK set "PI_SKIP_VERSION_CHECK=1"
if not defined PI_TELEMETRY set "PI_TELEMETRY=0"
if not defined TMP set "TMP=%USB%\temp"
if not defined TEMP set "TEMP=%USB%\temp"
if not defined NPM_CONFIG_CACHE set "NPM_CONFIG_CACHE=%USB%\temp\npm-cache"
if not defined NODE_COMPILE_CACHE set "NODE_COMPILE_CACHE=%USB%\temp\node-cache"
if not defined XDG_CACHE_HOME set "XDG_CACHE_HOME=%USB%\temp\cache"
if exist "%USB%\tools\bin\fix-paths.js" "%NODE_DIR%\node.exe" "%USB%\tools\bin\fix-paths.js" "%USB%" --quiet

set "CLI=%USB%\tools\pi\node_modules\@earendil-works\pi-coding-agent\dist\bundle\cli.js"
if exist "%USB%\tools\git\mingit\usr\bin\bash.exe" (
  set "PATH=%USB%\tools\git\mingit\usr\bin;%USB%\tools\git\mingit\ucrt64\bin;%USB%\tools\git\mingit\cmd;%PATH%"
)
set "SKILLS=%USB%\config\pi\skills"
if exist "%SKILLS%" (
  "%NODE_DIR%\node.exe" "%CLI%" -ns --skill "%SKILLS%" %*
) else (
  "%NODE_DIR%\node.exe" "%CLI%" -ns %*
)
exit /b %ERRORLEVEL%
