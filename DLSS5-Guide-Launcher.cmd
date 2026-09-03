@echo off
setlocal
title DLSS 5 Guide Launcher
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0DLSS5-Guide-Launcher.ps1" %*
set "DLSS5_EXIT=%ERRORLEVEL%"
if not "%DLSS5_EXIT%"=="0" (
  echo.
  echo The launcher ended with error code %DLSS5_EXIT%.
  if "%DLSS5_EXIT%"=="5" (
    echo If the launcher window never appeared, this VM may be blocking PowerShell itself.
    echo If the window did appear, check %%LOCALAPPDATA%%\DLSS5-Guide-Launcher\Logs for the exact denied path.
    echo This no-admin build will not request elevation.
  )
  pause
)
exit /b %DLSS5_EXIT%
