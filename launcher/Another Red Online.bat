@echo off
rem Another Red Online launcher: checks GitHub for the latest mod, applies it,
rem then starts the game. Place this file and launcher.ps1 in your game folder
rem (next to Game.exe) and run THIS instead of Game.exe.
setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launcher.ps1"
endlocal
