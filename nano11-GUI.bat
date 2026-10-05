@echo off
chcp 65001 >nul
setlocal
title nano11 Builder GUI

:: 管理者権限チェック (net session)
net session >nul 2>&1
if %errorLevel% equ 0 goto :RUN

echo ==============================================================================
echo  nano11 Builder GUI - Windows 11 次世代超軽量化＆カスタマイズツール
echo ==============================================================================
echo.
echo [nano11] 管理者権限で起動しています... ユーザーアカウント制御 (UAC) 画面で許可してください。
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try { Start-Process powershell.exe -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File """%~dp0nano11builder.ps1""" -GUI' -Verb RunAs } catch { exit 1223 }"
set "ELEVATE_EXIT=%errorLevel%"

if %ELEVATE_EXIT% equ 1223 (
    echo.
    echo ==============================================================================
    echo [エラー] 管理者権限への昇格がキャンセルされました (UAC キャンセル)。
    echo nano11 ビルダーを実行するには管理者権限が必要です。
    echo ==============================================================================
    echo.
    pause
    exit /b 1223
)
exit /b %ELEVATE_EXIT%

:RUN
cd /d "%~dp0"
title nano11 Builder - 次世代 Windows 11 軽量化＆カスタマイズ設定ツール

echo ==============================================================================
echo  nano11 Builder GUI - Windows 11 次世代超軽量化＆カスタマイズツール
echo ==============================================================================
echo.
echo [nano11] グラフィカル設定画面を起動しています...
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0nano11builder.ps1" -GUI
set "BUILD_EXIT=%errorLevel%"

if %BUILD_EXIT% neq 0 (
    echo.
    echo ==============================================================================
    echo [エラー] nano11 ビルダーが終了コード %BUILD_EXIT% で終了しました。
    echo 詳細なエラー内容は logs フォルダー内の最新ログファイルを確認してください。
    echo ==============================================================================
    echo.
    pause
)
exit /b %BUILD_EXIT%
