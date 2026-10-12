@echo off
chcp 65001 >nul
title RTX 5090 Scam Mode - CHECK

rem === снимаем метку "файл из интернета" (Mark of the Web) ===
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "Get-ChildItem -LiteralPath '%~dp0' -Recurse -Force -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue" 2>nul

echo ============================================================
echo   RTX 5090 Scam Mode - proverka
echo ============================================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0check.ps1"

echo.
pause