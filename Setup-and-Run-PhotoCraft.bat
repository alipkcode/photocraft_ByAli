@echo off
rem Double-click to set up and open PhotoCraft on this Windows PC.
rem Checks the machine, installs the build tools if needed, builds PhotoCraft.exe,
rem adds Desktop and Start menu shortcuts and opens it. Safe to run again (updates the install).
rem Options: Setup-and-Run-PhotoCraft.bat -NoLaunch   (build and install only)
setlocal
title PhotoCraft setup
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0packaging\windows\local-setup.ps1" %*
if errorlevel 1 (
  echo.
  echo PhotoCraft setup did not finish. Read the message above, fix the problem and run this file again.
  echo Logs from a running PhotoCraft are in %%APPDATA%%\Photocraft\logs\
  echo.
  pause
  exit /b 1
)
"%SystemRoot%\System32\timeout.exe" /t 5 >nul 2>nul
endlocal
