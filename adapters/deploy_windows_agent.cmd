@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy_windows_agent.ps1" %*
if errorlevel 1 pause
