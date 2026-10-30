@echo off
setlocal
title Fix OBS Auth
pushd "%~dp0"

if not exist "%~dp0obs-auth.ps1" (
    echo.
    echo ERROR: obs-auth.ps1 was not found.
    echo Keep obs-auth.bat and obs-auth.ps1 in the same folder.
    echo.
    pause
    popd
    exit /b 1
)

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"

"%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0obs-auth.ps1" %*
set "EXITCODE=%ERRORLEVEL%"

echo.
if not "%EXITCODE%"=="0" (
    echo Script finished with error code %EXITCODE%.
) else (
    echo Script finished.
)
pause
popd
exit /b %EXITCODE%

