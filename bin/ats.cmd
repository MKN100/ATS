@echo off
setlocal
title ATS
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\scripts\Start-ATSTui.ps1" %*
if errorlevel 1 (
  echo.
  echo ATS could not start.
  pause
)
endlocal
