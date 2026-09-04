@echo off
setlocal EnableExtensions
title DLSS 5 Guide Launcher

rem ===========================================================================
rem  DLSS 5 Guide Launcher - batch bootstrap
rem
rem  This wrapper writes a diagnostic log BEFORE powershell.exe is started, so
rem  a launch that never shows a window still leaves readable evidence behind.
rem  It uses only built-in batch commands and never requests elevation.
rem
rem  Logs are written beside this file (Logs\) and fall back to %TEMP%. Local
rem  App Data is deliberately never used: a managed profile can make it
rem  unreadable to the very user who needs the log.
rem
rem  Logging discipline: this file records the launch time, the launcher
rem  directory, the Windows version, how powershell.exe was resolved, a fixed
rem  command shape, the number of forwarded arguments, the exit code, and any
rem  output PowerShell produced. It never records raw argument values and never
rem  dumps the environment.
rem
rem  Documented environment overrides (testing and support use only):
rem    DLSS5_SCRIPT_PATH  full path of the application script to run
rem    DLSS5_NO_PAUSE     set to 1 to skip the final pause (used by CI)
rem
rem  Set for the application, not read from it:
rem    DLSS5_BOOTSTRAP_LOG       bootstrap log the application may append to
rem    DLSS5_STARTUP_SENTINEL    file the application creates to prove it began
rem ===========================================================================

set "APP_NAME=DLSS 5 Guide Launcher"
set "BOOTSTRAP_VERSION=1.3.1-noadmin"
set "LOG_FILE="
set "LOG_DIR="
set "LOG_FALLBACK=0"
set "PS_OUT="
set "EXIT_CODE=0"

for %%I in ("%~dp0.") do set "LAUNCHER_DIR=%%~fI"

call :get_stamp
call :resolve_log_dir
call :open_log

call :log "Stage 1: CMD wrapper began."
call :log_environment
call :resolve_powershell
if not "%EXIT_CODE%"=="0" goto :finish
call :probe_powershell
if not "%EXIT_CODE%"=="0" goto :finish
call :resolve_script
if not "%EXIT_CODE%"=="0" goto :finish
call :run_application %*
goto :finish


rem ---------------------------------------------------------------------------
rem  Timestamp: prefer a sortable YYYYMMDD-HHMMSS stamp, fall back to a
rem  sanitised locale stamp when wmic is unavailable or has been removed.
rem ---------------------------------------------------------------------------
:get_stamp
set "STAMP="
for /f "skip=1 tokens=1 delims=." %%I in ('wmic os get localdatetime 2^>nul') do (
    if not defined STAMP set "STAMP=%%I"
)
if defined STAMP if not "%STAMP:~13,1%"=="" (
    set "STAMP=%STAMP:~0,8%-%STAMP:~8,6%"
    goto :eof
)
set "STAMP=%DATE%_%TIME%"
set "STAMP=%STAMP:/=-%"
set "STAMP=%STAMP::=-%"
set "STAMP=%STAMP:.=-%"
set "STAMP=%STAMP:,=-%"
set "STAMP=%STAMP: =0%"
goto :eof


rem ---------------------------------------------------------------------------
rem  Log location: beside the launcher first, then %TEMP%. Never Local App Data.
rem ---------------------------------------------------------------------------
:resolve_log_dir
call :try_log_dir "%LAUNCHER_DIR%\Logs"
if defined LOG_DIR goto :eof
set "LOG_FALLBACK=1"
if defined TEMP call :try_log_dir "%TEMP%\DLSS5-Guide-Launcher-Logs"
if defined LOG_DIR goto :eof
set "LOG_FALLBACK=2"
goto :eof

:try_log_dir
if defined LOG_DIR goto :eof
set "CANDIDATE=%~1"
if not exist "%CANDIDATE%\" mkdir "%CANDIDATE%" 2>nul
if not exist "%CANDIDATE%\" goto :eof
break > "%CANDIDATE%\.write-probe.tmp" 2>nul
if not exist "%CANDIDATE%\.write-probe.tmp" goto :eof
del "%CANDIDATE%\.write-probe.tmp" 2>nul
set "LOG_DIR=%CANDIDATE%"
goto :eof

:open_log
if not defined LOG_DIR goto :open_log_failed
set "LOG_FILE=%LOG_DIR%\bootstrap-%STAMP%.log"
set "PS_OUT=%LOG_DIR%\bootstrap-%STAMP%.psout.tmp"
break > "%LOG_FILE%" 2>nul
if not exist "%LOG_FILE%" goto :open_log_unwritable
call :log "%APP_NAME% - bootstrap log"
call :log "Bootstrap version: %BOOTSTRAP_VERSION%"
call :log ""
goto :eof

:open_log_unwritable
set "LOG_FILE="
set "PS_OUT="
set "LOG_DIR="
:open_log_failed
echo.
echo [!] No writable log location was found.
echo     Tried: %LAUNCHER_DIR%\Logs
echo     Tried: %%TEMP%%\DLSS5-Guide-Launcher-Logs
echo     The launcher will continue, but nothing can be written to disk.
echo     Copy any text shown in this window when reporting the problem.
echo.
goto :eof

rem  Messages must always be passed quoted. Delayed expansion is enabled only
rem  inside this routine, so "&" and similar characters in a path cannot break
rem  the line, while "!" in a path stays intact everywhere it is assigned.
:log
if not defined LOG_FILE goto :eof
set "MSG=%~1"
setlocal EnableDelayedExpansion
>>"%LOG_FILE%" echo(!MSG!
endlocal
goto :eof


rem ---------------------------------------------------------------------------
rem  Environment facts. Deliberately narrow: no environment dump, no raw args.
rem ---------------------------------------------------------------------------
:log_environment
call :log "  Launch time (local):    %DATE% %TIME%"
call :log "  Launcher directory:     %LAUNCHER_DIR%"
if defined LOG_FILE call :log "  Bootstrap log:          %LOG_FILE%"
if "%LOG_FALLBACK%"=="1" call :log "  Log location:           fallback (the launcher folder was not writable)"
for /f "delims=" %%I in ('ver 2^>nul') do call :log "  Windows version:        %%I"
call :log "  Processor architecture: %PROCESSOR_ARCHITECTURE%"
goto :eof


rem ---------------------------------------------------------------------------
rem  Stage 2: is powershell.exe present at all?
rem
rem  The canonical System32 path is preferred over the PATH lookup so that a
rem  stray powershell.exe earlier in PATH cannot be launched instead. The PATH
rem  result is still recorded because it is useful diagnostic information.
rem ---------------------------------------------------------------------------
:resolve_powershell
set "PS_EXE="
set "PS_WHERE="
for /f "delims=" %%I in ('where powershell.exe 2^>nul') do (
    if not defined PS_WHERE set "PS_WHERE=%%I"
)
set "PS_CANONICAL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%PS_CANONICAL%" set "PS_EXE=%PS_CANONICAL%"
if not defined PS_EXE if defined PS_WHERE set "PS_EXE=%PS_WHERE%"

if defined PS_WHERE call :log "Stage 2: PATH resolves powershell.exe to: %PS_WHERE%"
if not defined PS_WHERE call :log "Stage 2: 'where powershell.exe' returned no result."
if defined PS_EXE goto :resolve_powershell_ok
call :log "Stage 2: FAILED - powershell.exe was not found (errorlevel 9009 class)."
call :log "         No PowerShell or ReShade code ran."
set "EXIT_CODE=10"
goto :eof

:resolve_powershell_ok
call :log "Stage 2: powershell.exe found; will launch: %PS_EXE%"
goto :eof


rem ---------------------------------------------------------------------------
rem  Stage 3: can Windows actually create the process?
rem
rem  Finding the executable does not prove that CreateProcess is permitted, and
rem  an exit code alone cannot separate "creation denied" from "ran and
rem  returned 5". So the probe writes a sentinel file that only a PowerShell
rem  that genuinely started can create. The path is passed through the
rem  environment to keep the command line free of nested quoting.
rem ---------------------------------------------------------------------------
:probe_powershell
if not defined LOG_DIR goto :probe_skipped
set "DLSS5_PROBE=%LOG_DIR%\probe-%STAMP%.tmp"
if exist "%DLSS5_PROBE%" del "%DLSS5_PROBE%" 2>nul
call :log "Stage 3: starting probe: powershell.exe -NoLogo -NoProfile -NonInteractive -Command <sentinel write>"
"%PS_EXE%" -NoLogo -NoProfile -NonInteractive -Command "Set-Content -LiteralPath $env:DLSS5_PROBE -Value 'probe-ok'; exit 0" > "%PS_OUT%" 2>&1
set "PROBE_RC=%ERRORLEVEL%"
call :append_ps_output "probe"
if not exist "%DLSS5_PROBE%" goto :probe_denied
del "%DLSS5_PROBE%" 2>nul
if not "%PROBE_RC%"=="0" goto :probe_rejected
call :log "Stage 3: OK - powershell.exe started and returned 0."
goto :eof

:probe_denied
call :log "Stage 3: FAILED - the probe process never started (exit code %PROBE_RC%, no sentinel)."
call :log "         Windows denied creation of powershell.exe."
call :log "         No PowerShell or ReShade code ran."
set "EXIT_CODE=11"
goto :eof

:probe_rejected
call :log "Stage 3: FAILED - powershell.exe started but returned %PROBE_RC%."
call :log "         PowerShell itself ran; policy or configuration rejected the command."
call :log "         No ReShade code ran. See the captured output above."
set "EXIT_CODE=12"
goto :eof

:probe_skipped
call :log "Stage 3: SKIPPED - no writable location for the probe sentinel."
call :log "         Process creation cannot be distinguished from an early exit."
goto :eof


rem ---------------------------------------------------------------------------
rem  Stage 4: is the application script present?
rem ---------------------------------------------------------------------------
:resolve_script
set "APP_SCRIPT=%LAUNCHER_DIR%\DLSS5-Guide-Launcher.ps1"
if not defined DLSS5_SCRIPT_PATH goto :check_script
set "APP_SCRIPT=%DLSS5_SCRIPT_PATH%"
call :log "Stage 4: using the DLSS5_SCRIPT_PATH override."

:check_script
if exist "%APP_SCRIPT%" goto :check_script_ok
call :log "Stage 4: FAILED - the application script was not found: %APP_SCRIPT%"
call :log "         Extract the whole folder before running the launcher."
set "EXIT_CODE=13"
goto :eof

:check_script_ok
call :log "Stage 4: OK - application script found: %APP_SCRIPT%"
goto :eof


rem ---------------------------------------------------------------------------
rem  Stage 5: run the application.
rem
rem  DLSS5_STARTUP_SENTINEL lets the application prove that its script body
rem  actually began executing, which separates "PowerShell ran but the script
rem  never started" from "the script started and then failed". The bootstrap
rem  log path is handed over through the environment rather than as a command
rem  line switch, so this wrapper stays compatible with application versions
rem  that do not yet accept the parameter.
rem ---------------------------------------------------------------------------
:run_application
set "ARGC=0"
call :count_args %*
set "DLSS5_STARTUP_SENTINEL="
set "DLSS5_BOOTSTRAP_LOG="
if not defined LOG_DIR goto :run_log_ready
set "DLSS5_STARTUP_SENTINEL=%LOG_DIR%\startup-%STAMP%.tmp"
set "DLSS5_BOOTSTRAP_LOG=%LOG_FILE%"
if exist "%DLSS5_STARTUP_SENTINEL%" del "%DLSS5_STARTUP_SENTINEL%" 2>nul

:run_log_ready
call :log "Stage 5: starting the application script."
call :log "  Command shape: powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File <script> [%ARGC% forwarded argument(s)]"
call :log "  Argument values are intentionally not logged."
if not defined PS_OUT goto :run_unredirected
"%PS_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%APP_SCRIPT%" %* > "%PS_OUT%" 2>&1
set "EXIT_CODE=%ERRORLEVEL%"
goto :run_finished

:run_unredirected
"%PS_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%APP_SCRIPT%" %*
set "EXIT_CODE=%ERRORLEVEL%"

:run_finished
call :log "Stage 5: the application exited with code %EXIT_CODE%."
call :append_ps_output "application"
call :report_startup_sentinel
goto :eof

:count_args
if "%~1"=="" goto :eof
set /a ARGC+=1
shift
goto :count_args

:report_startup_sentinel
if not defined DLSS5_STARTUP_SENTINEL goto :eof
if not exist "%DLSS5_STARTUP_SENTINEL%" goto :sentinel_absent
call :log "Stage 5: the application script began executing (startup sentinel present)."
del "%DLSS5_STARTUP_SENTINEL%" 2>nul
goto :eof

:sentinel_absent
call :log "Stage 5: startup sentinel absent - UNDETERMINED."
call :log "         Either the script never began executing, or this application"
call :log "         version predates sentinel support. Application versions from"
call :log "         1.3.1-noadmin onward always write the sentinel."
goto :eof


rem ---------------------------------------------------------------------------
rem  Fold captured PowerShell output into the bootstrap log. Output is captured
rem  to a separate file so that no handle is held open on the bootstrap log
rem  while the application is running and appending to that same log.
rem ---------------------------------------------------------------------------
:append_ps_output
if not defined PS_OUT goto :eof
if not exist "%PS_OUT%" goto :eof
for %%I in ("%PS_OUT%") do if %%~zI equ 0 goto :append_ps_empty
call :log "  --- begin %~1 output from powershell.exe ---"
type "%PS_OUT%" >> "%LOG_FILE%" 2>nul
call :log "  --- end %~1 output ---"
del "%PS_OUT%" 2>nul
goto :eof

:append_ps_empty
del "%PS_OUT%" 2>nul
goto :eof


rem ---------------------------------------------------------------------------
rem  Final report.
rem ---------------------------------------------------------------------------
:finish
call :log ""
call :log "Bootstrap finished with exit code %EXIT_CODE%."
if "%EXIT_CODE%"=="0" goto :finish_pause

echo.
echo The launcher ended with error code %EXIT_CODE%.
call :describe_code
if not defined LOG_FILE goto :finish_nolog
echo.
echo Bootstrap log:
echo   %LOG_FILE%
echo.
echo Attach that file when reporting the problem. It contains no personal data
echo beyond the folder this launcher was extracted to.
goto :finish_footer

:finish_nolog
echo.
echo No log file could be written. Copy the text in this window instead.

:finish_footer
echo.
echo This launcher never requests administrator access.

:finish_pause
if "%DLSS5_NO_PAUSE%"=="1" goto :finish_exit
if not "%EXIT_CODE%"=="0" pause

:finish_exit
endlocal & exit /b %EXIT_CODE%

:describe_code
if "%EXIT_CODE%"=="2" (
    echo   Meaning: closed without installing anything.
    goto :eof
)
if "%EXIT_CODE%"=="10" (
    echo   Meaning: powershell.exe was not found. No launcher code ran.
    goto :eof
)
if "%EXIT_CODE%"=="11" (
    echo   Meaning: Windows blocked starting powershell.exe. No launcher code ran.
    goto :eof
)
if "%EXIT_CODE%"=="12" (
    echo   Meaning: PowerShell started but rejected the command.
    goto :eof
)
if "%EXIT_CODE%"=="13" (
    echo   Meaning: the application script is missing from this folder.
    goto :eof
)
if %EXIT_CODE% geq 20 if %EXIT_CODE% leq 29 (
    echo   Meaning: the launcher failed while starting up.
    goto :eof
)
if %EXIT_CODE% geq 30 if %EXIT_CODE% leq 39 (
    echo   Meaning: the launcher failed during installation.
    goto :eof
)
if %EXIT_CODE% geq 40 if %EXIT_CODE% leq 49 (
    echo   Meaning: the launcher failed during rollback.
    goto :eof
)
echo   Meaning: unclassified failure reported by PowerShell or the application.
goto :eof
