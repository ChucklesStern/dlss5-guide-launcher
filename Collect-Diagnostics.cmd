@echo off
setlocal EnableExtensions
title DLSS 5 Guide Launcher - Collect Diagnostics

rem ===========================================================================
rem  DLSS 5 Guide Launcher - standalone diagnostics
rem
rem  Built-in batch commands only. This tool must keep working when the thing
rem  it is diagnosing does not, so it deliberately repeats a little of the
rem  bootstrap's logic instead of sharing it. It never requires PowerShell,
rem  never requests elevation, and always pauses so the result can be read.
rem
rem  The report is written beside this file and falls back to %TEMP%. Local App
rem  Data is never used. Only launcher-relevant facts are collected: no
rem  environment dump, no user documents, no file contents.
rem ===========================================================================

set "REPORT="
set "REPORT_DIR="

for %%I in ("%~dp0.") do set "LAUNCHER_DIR=%%~fI"

call :get_stamp
call :resolve_report_dir
if not defined REPORT_DIR goto :no_report_location

set "REPORT=%REPORT_DIR%\diagnostics-%STAMP%.txt"
break > "%REPORT%" 2>nul
if not exist "%REPORT%" goto :no_report_location

call :out "DLSS 5 Guide Launcher - diagnostics report"
call :out "Collected: %DATE% %TIME%"
call :out ""

call :out "== Environment =="
call :out "  Launcher directory:     %LAUNCHER_DIR%"
call :out "  Report file:            %REPORT%"
for /f "delims=" %%I in ('ver 2^>nul') do call :out "  Windows version:        %%I"
call :out "  Processor architecture: %PROCESSOR_ARCHITECTURE%"
if defined TEMP call :out "  TEMP is defined:        yes"
if not defined TEMP call :out "  TEMP is defined:        no"
call :out ""

call :out "== Write access =="
call :check_writable "%LAUNCHER_DIR%" "Launcher folder"
call :check_writable "%LAUNCHER_DIR%\Logs" "Launcher Logs folder"
if defined TEMP call :check_writable "%TEMP%" "TEMP folder"
call :out ""

call :out "== Launcher files =="
call :check_file "%LAUNCHER_DIR%\DLSS5-Guide-Launcher.cmd" "Bootstrap wrapper"
call :check_file "%LAUNCHER_DIR%\DLSS5-Guide-Launcher.ps1" "Application script"
call :out ""

call :out "== PowerShell =="
call :check_powershell
call :out ""

call :out "== Existing bootstrap logs =="
call :list_logs "%LAUNCHER_DIR%\Logs"
if defined TEMP call :list_logs "%TEMP%\DLSS5-Guide-Launcher-Logs"
call :out ""

call :out "== Notes =="
call :out "  This launcher never requests administrator access."
call :out "  If process creation for powershell.exe is denied above, no launcher"
call :out "  or ReShade code can run, and no application log will exist."

echo.
echo Diagnostics written to:
echo   %REPORT%
echo.
echo Attach that file when reporting the problem.
echo.
type "%REPORT%"
goto :done


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

:resolve_report_dir
call :try_report_dir "%LAUNCHER_DIR%\Logs"
if defined REPORT_DIR goto :eof
if defined TEMP call :try_report_dir "%TEMP%\DLSS5-Guide-Launcher-Logs"
goto :eof

:try_report_dir
if defined REPORT_DIR goto :eof
set "CANDIDATE=%~1"
if not exist "%CANDIDATE%\" mkdir "%CANDIDATE%" 2>nul
if not exist "%CANDIDATE%\" goto :eof
break > "%CANDIDATE%\.write-probe.tmp" 2>nul
if not exist "%CANDIDATE%\.write-probe.tmp" goto :eof
del "%CANDIDATE%\.write-probe.tmp" 2>nul
set "REPORT_DIR=%CANDIDATE%"
goto :eof

:out
if not defined REPORT goto :eof
set "MSG=%~1"
setlocal EnableDelayedExpansion
>>"%REPORT%" echo(!MSG!
endlocal
goto :eof

:check_writable
set "TARGET=%~1"
set "LABEL=%~2"
if not exist "%TARGET%\" goto :check_writable_missing
break > "%TARGET%\.diag-probe.tmp" 2>nul
if not exist "%TARGET%\.diag-probe.tmp" goto :check_writable_denied
del "%TARGET%\.diag-probe.tmp" 2>nul
call :out "  [ OK ] %LABEL% is writable: %TARGET%"
goto :eof
:check_writable_missing
call :out "  [ -- ] %LABEL% does not exist: %TARGET%"
goto :eof
:check_writable_denied
call :out "  [FAIL] %LABEL% is NOT writable: %TARGET%"
goto :eof

:check_file
set "TARGET=%~1"
set "LABEL=%~2"
if not exist "%TARGET%" goto :check_file_missing
for %%I in ("%TARGET%") do call :out "  [ OK ] %LABEL% present (%%~zI bytes)"
goto :eof
:check_file_missing
call :out "  [FAIL] %LABEL% is MISSING: %TARGET%"
goto :eof

rem  Resolution alone does not prove that CreateProcess is permitted, so a
rem  sentinel file that only a running PowerShell can create is used instead.
:check_powershell
set "PS_WHERE="
for /f "delims=" %%I in ('where powershell.exe 2^>nul') do (
    if not defined PS_WHERE set "PS_WHERE=%%I"
)
if defined PS_WHERE call :out "  [ OK ] PATH resolves powershell.exe: %PS_WHERE%"
if not defined PS_WHERE call :out "  [FAIL] 'where powershell.exe' returned no result."

set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%PS_EXE%" goto :check_powershell_probe
call :out "  [FAIL] Not present at the standard location: %PS_EXE%"
if not defined PS_WHERE goto :eof
set "PS_EXE=%PS_WHERE%"

:check_powershell_probe
call :out "  [ .. ] Probing process creation for: %PS_EXE%"
set "DLSS5_PROBE=%REPORT_DIR%\diag-probe-%STAMP%.tmp"
if exist "%DLSS5_PROBE%" del "%DLSS5_PROBE%" 2>nul
"%PS_EXE%" -NoLogo -NoProfile -NonInteractive -Command "Set-Content -LiteralPath $env:DLSS5_PROBE -Value 'probe-ok'; exit 0" > "%REPORT_DIR%\diag-out-%STAMP%.tmp" 2>&1
set "PROBE_RC=%ERRORLEVEL%"
if not exist "%DLSS5_PROBE%" goto :check_powershell_denied
del "%DLSS5_PROBE%" 2>nul
if not "%PROBE_RC%"=="0" goto :check_powershell_rejected
call :out "  [ OK ] powershell.exe started and returned 0."
goto :check_powershell_output

:check_powershell_denied
call :out "  [FAIL] The probe process never started (exit code %PROBE_RC%, no sentinel)."
call :out "         Windows denied creation of powershell.exe."
call :out "         No launcher or ReShade code can run on this machine."
goto :check_powershell_output

:check_powershell_rejected
call :out "  [FAIL] powershell.exe started but returned %PROBE_RC%."
call :out "         PowerShell itself ran; policy or configuration rejected the command."

:check_powershell_output
if not exist "%REPORT_DIR%\diag-out-%STAMP%.tmp" goto :eof
for %%I in ("%REPORT_DIR%\diag-out-%STAMP%.tmp") do if %%~zI equ 0 goto :check_powershell_cleanup
call :out "         --- begin probe output ---"
type "%REPORT_DIR%\diag-out-%STAMP%.tmp" >> "%REPORT%" 2>nul
call :out "         --- end probe output ---"
:check_powershell_cleanup
del "%REPORT_DIR%\diag-out-%STAMP%.tmp" 2>nul
goto :eof

:list_logs
set "TARGET=%~1"
if not exist "%TARGET%\" goto :list_logs_missing
set "FOUND=0"
for %%I in ("%TARGET%\bootstrap-*.log") do call :list_one "%%~fI" "%%~zI"
if "%FOUND%"=="0" call :out "  (none in %TARGET%)"
goto :eof
:list_one
set "FOUND=1"
call :out "  %~1 (%~2 bytes)"
goto :eof
:list_logs_missing
call :out "  (folder does not exist: %TARGET%)"
goto :eof

:no_report_location
echo.
echo [!] No writable location was found for the diagnostics report.
echo     Tried: %LAUNCHER_DIR%\Logs
echo     Tried: %%TEMP%%\DLSS5-Guide-Launcher-Logs
echo.
echo     Copy the text in this window instead. The launcher folder and the
echo     TEMP folder both refused a test file, which is itself the finding.
echo.

:done
if "%DLSS5_NO_PAUSE%"=="1" goto :done_exit
pause
:done_exit
endlocal & exit /b 0
