@echo off
chcp 65001 >nul
setlocal
title nano11 Builder - 次世代 Windows 11 軽量化＆カスタマイズ設定ツール

:: 管理者権限の確認 (管理者権限がない場合は昇格プロンプトを表示)
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo [nano11] 管理者権限が必要です。ユーザーアカウント制御 (UAC) 画面で「はい」を選択してください...
    powershell.exe -NoProfile -Command "Start-Process cmd.exe -ArgumentList '/c `""%~f0"`"' -Verb RunAs"
    exit /b 0
)

cd /d "%~dp0"

echo ==============================================================================
echo  nano11 Builder GUI - Windows 11 次世代超軽量化＆カスタマイズツール
echo ==============================================================================
echo.
echo [nano11] グラフィカル設定画面 (GUI) を起動しています...
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0nano11builder.ps1" -GUI
set "BUILD_EXIT=%errorLevel%"

if %BUILD_EXIT% neq 0 (
    echo.
    echo ==============================================================================
    echo [エラー] nano11 ビルダーが終了コード %BUILD_EXIT% で終了しました。
    echo 詳細なエラー内容は logs\ フォルダー内の最新ログファイルを確認してください。
    echo ==============================================================================
    echo.
    pause
)

exit /b %BUILD_EXIT%
