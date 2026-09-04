@echo off
setlocal
title SSH + Tailscale OneClick
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0bootstrap.ps1" -TargetUser "%USERNAME%" -TargetProfile "%USERPROFILE%"
set "code=%ERRORLEVEL%"
if not "%code%"=="0" (
  echo.
  echo Setup did not finish successfully. Error code: %code%
  pause
)
exit /b %code%
