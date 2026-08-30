@echo off
setlocal
title DLSS 5 Guide Launcher
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0DLSS5-Guide-Launcher.ps1" %*
set "DLSS5_EXIT=%ERRORLEVEL%"
if not "%DLSS5_EXIT%"=="0" (
  echo.
  echo The launcher ended with error code %DLSS5_EXIT%.
  pause
)
exit /b %DLSS5_EXIT%
