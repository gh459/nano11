@echo off
setlocal EnableDelayedExpansion

:: Check for Administrator privileges
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting Administrator privileges to run nano11 GUI...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process cmd.exe -ArgumentList '/c \"\"%~f0\"\"' -Verb RunAs"
    exit /b
)

:: Run nano11 Builder in GUI Mode
cd /d "%~dp0"
title nano11 Builder GUI
echo Starting nano11 Graphical Interface...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0nano11builder.ps1" -GUI
if %errorLevel% neq 0 (
    echo.
    echo nano11 builder exited with code %errorLevel%.
    pause
)
