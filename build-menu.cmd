@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tableside-build.ps1"
if errorlevel 1 (
  echo.
  echo The TableSide build menu ended with an error.
  pause
)
endlocal
