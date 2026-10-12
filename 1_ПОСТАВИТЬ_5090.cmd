@echo off
chcp 65001 >nul
title RTX 5090 Scam Mode - INSTALL

rem === снимаем метку "файл из интернета" (Mark of the Web) ===
rem Файлы, скачанные zip-архивом с GitHub, помечаются как небезопасные,
rem и PowerShell может отказаться их запускать.
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "Get-ChildItem -LiteralPath '%~dp0' -Recurse -Force -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue" 2>nul

echo ============================================================
echo   RTX 5090 Scam Mode - ustanovka
echo ============================================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0apply.ps1"

set EXITCODE=%ERRORLEVEL%
echo.
if not "%EXITCODE%"=="0" (
    echo [VNIMANIE] PowerShell zavershilsya s kodom %EXITCODE%.
    echo Esli vyshe nichego ne bylo napisano, prover prava Administratory:
    echo   - klikni pravoi knopkoy na etot .fail - "Zapustit kak administrator"
    echo   - ili otkroy komandnuyu stroku ot imeni administratora
    echo   - skachannye iz arhiva faily inogda blokiruyutsya Windows
)

echo.
pause