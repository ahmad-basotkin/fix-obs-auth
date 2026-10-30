@echo off
chcp 65001 >nul 2>&1
title fix obs auth
cd /d "%~dp0"

if not exist "%~dp0obs-auth.ps1" (
    echo.
    echo   Не найден файл obs-auth.ps1.
    echo   Он должен лежать в одной папке с этим файлом.
    echo.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0obs-auth.ps1" %*

echo.
echo   Нажми любую клавишу, чтобы закрыть окно.
pause >nul
