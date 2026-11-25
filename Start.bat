@echo off
set "SCRIPT=%~dp0CadenasOrganizer.ps1"
if not exist "%SCRIPT%" (
  echo Cannot find "%SCRIPT%"
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%SCRIPT%"
if errorlevel 1 pause
