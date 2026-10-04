# Windows Deployment Engineer / Microsoft MVP Expert Review for nano11

> 本ドキュメントは、オフラインイメージサービス（DISM/WinPE）および Windows デプロイメント専門家による `nano11` のコードレビュー、アーキテクチャ分析、および改善提案の完全記録です。

---

﻿<USER_REQUEST>
I'll answer as a world-famous Windows deployment engineer PhD in offline image servicing (DISM/WinPE) with a Microsoft MVP award in Windows Insider / Deployment.

**TL;DR**: 添付された `nano11builder.ps1` 全体と `nano11.log`・`nano11-GUI.bat` を精査しました。確定バグが数件(バッチファイルの構文崩れ、テストモードの無言終了、ソース検証の遅さ、Defender除外の残留、失敗時の残骸ファイル)、加えて信頼性・セキュリティ・パフォーマンス・保守性の観点で大量の改良案を出します。あなたが適用する前提で、すべてコード片付きで提示します。

## ログ解析：今回の実行で起きていること

`nano11.log` は `-NonInteractive -KeepStore -SourceDrive Z:\NonExistent` での実行を記録していますが、設定サマリー表示の直後(開始と同一秒)で終了し、以降の「Working Directory」出力も「Specified SourceDrive ... does not exist」のエラーも一切記録されていません 。原因は2つ考えられ、どちらもコード側で直すべきです。 [nano11.log]

- `NANO11_TEST_MODE` が立っていた場合、`Stop-Transcript; exit 0` する箇所にメッセージ出力が一切ありません 。ログを読んでも「なぜ止まったか」が分からない状態です。 [nano11builder.ps1]
- `-SourceDrive` の妥当性検証がワークスペース構築より後(かなり下流)にあり、無効ドライブ指定でも数ステップ無駄に進みます 。 [nano11builder.ps1]

修正案：

```powershell
# 設定表示の直後に移動
if ($env:NANO11_TEST_MODE -eq "1") {
    Write-Host "NANO11_TEST_MODE=1: 設定表示のみで終了します(ビルド未実行)" -ForegroundColor Yellow
    Stop-Transcript
    exit 0
}

# SourceDrive の早期検証(設定解決直後に配置)
if ($SourceDrive) {
    if ($SourceDrive -like '*.iso') {
        if (-not (Test-Path -LiteralPath $SourceDrive)) { throw "ISO が見つかりません: $SourceDrive" }
    } else {
        $cand = "$($SourceDrive.Trim().TrimEnd(':')):"
        if (-not (Test-Path -LiteralPath "$cand\sources\install.wim")) {
            throw "ソースメディアが無効です: $SourceDrive (sources\install.wim が必要)"
        }
    }
}
```

## 確定バグ(修正必須)

### 1. `nano11-GUI.bat` の構文崩れ

ファイル全体を確認しましたが、`if %errorLevel% neq 0 (` のブロックが一度も閉じられておらず、`exit /b` 以降の行が if ブロック内部に取り込まれています 。括弧ブロック内の `::` コメントもバッチではパースエラーの原因になります。つまりこのバッチは現状、意図した動作(非管理者時に昇格→再実行→GUI起動)をしません。修正版： [nano11-GUI.bat]

```bat
@echo off
setlocal
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting Administrator privileges to run nano11 GUI...
    powershell -NoProfile -Command "Start-Process cmd.exe -ArgumentList '/c ""%~f0""' -Verb RunAs"
    exit /b 1
)
cd /d "%~dp0"
title nano11 Builder GUI
echo Starting nano11 Graphical Interface...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0nano11builder.ps1" -GUI
if %errorLevel% neq 0 (
    echo.
    echo nano11 builder exited with code %errorLevel%.
    pause
)
```

`'/c \"%~f0\"'` の `\"` はcmdにとって解釈が曖昧なので、PowerShell流の `""...""` 二重引用符に置き換えています。パスにスペースがあっても安全です。

### 2. UltraSlim の WinRE 再圧縮で失敗時の残骸が残る

`tempCompactWinre` への Export が失敗・サイズ不足だった場合、`targetWinre` の削除もリネームも行われないのに `tempCompactWinre` 自体の削除がないため、`winrecompact.wim` がそのままイメージに混入します 。修正： [nano11builder.ps1]

```powershell
if (Test-Path -LiteralPath $tempCompactWinre -and (Get-Item -LiteralPath $tempCompactWinre).Length -gt 10MB) {
    Remove-Item -LiteralPath $targetWinre -Force -ErrorAction SilentlyContinue
    Rename-Item -LiteralPath $tempCompactWinre -NewName winre.wim -Force
} else {
    Remove-Item -LiteralPath $tempCompactWinre -Force -ErrorAction SilentlyContinue  # 残骸掃除
}
```

### 3. commit 失敗時の無断 discard

アンマウントcommitが4回失敗すると、ユーザーに何も確認せず `/discard` で全作業を破棄します 。個人用とはいえ数十分の作業が黙って消えるのは致命的です。discard 前に「保持して次回 `-Resume` で再開できる状態にする」選択肢か、最低限大きな警告と `exit 2` を。 [nano11builder.ps1]

### 4. Defender 除外が永久に残る

`Add-MpPreference -ExclusionPath $baseWorkDir` を追加していますが、対応する `Remove-MpPreference` がスクリプト内に存在しません 。ビルド完了後もワークスペースパスがスキャン除外のまま残ります。ビルド成否に関わらず実行される終端処理で必ず解除してください(後述の `finally` 構造とセットで)。 [nano11builder.ps1]

## 信頼性・エラー処理の強化

### 5. DISM 呼び出しの統一ラッパー(最重要)

現在、`dism.exe ... 2>&1 | Out-Null` でstderr/stdoutを握りつぶしている箇所が大量にあり、失敗しても `$LASTEXITCODE` を見ずに先へ進む箇所があります(例： WSL有効化、Recall無効化、各種レジストリ適用)  [nano11builder.ps1]。ラッパーを1つ作って全部置き換えるのが最大の改良です:

```powershell
function Invoke-Dism {
    param([Parameter(Mandatory)][string[]]$DismArgs, [int]$Retries = 1)
    for ($i = 1; $i -le $Retries; $i++) {
        & dism.exe /English @DismArgs
        if ($LASTEXITCODE -eq 0) { return $true }
        Write-Host "DISM 失敗 (exit=$LASTEXITCODE): $($DismArgs -join ' ') [試行 $i/$Retries]" -ForegroundColor Yellow
        Start-Sleep -Seconds 2
    }
    return $false
}
# 使用例
if (-not (Invoke-Dism @('/Image:'+$scratchDir,'/Enable-Feature','/FeatureName:VirtualMachinePlatform','/All'))) {
    throw "WSL2 の事前有効化に失敗"
}
```

### 6. マウント〜ハイブ操作を `try/finally` で包む

現状、途中で例外やCtrl+Cが発生すると、マウントされたイメージとロードされたレジストリハイブ(zSOFTWARE等)が残ります 。次回起動時の `Clear-DismMountConflicts` で部分的に救済されますが、メインフロー自体をこう構造化してください: [nano11builder.ps1]

```powershell
$script:MountOpened = $false; $script:HivesLoaded = $false
try {
    # マウント → ハイブロード → 各種変更 → アンマウント
}
finally {
    if ($HivesLoaded) { 'zCOMPONENTS','zDEFAULT','zNTUSER','zSOFTWARE','zSYSTEM' |
        ForEach-Object { [void](Unmount-RegistryHiveWithRetry -Name $_) } }
    if ($MountOpened) { & dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /commit }
    if ($defenderExclusionAdded) { try { Remove-MpPreference -ExclusionPath $baseWorkDir -ErrorAction Stop } catch {} }
}
```

これで例外時もハイブだけは必ずアンロードされ、部分的にcommitされた状態から再開できます。

### 7. 二重実行防止(ミューテックス)

nano11を2窓で起動するとDISMマウント競合(`0xc1420111`系)が起きます。冒頭に:

```powershell
$mutex = New-Object System.Threading.Mutex($false, 'Global\nano11Builder')
if (-not $mutex.WaitOne(0)) { throw "別の nano11 ビルドが実行中です" }
```

### 8. トランスクリプトの上書き問題

`Start-Transcript -Force` で毎回 `nano11.log` を上書きするため、失敗時の直前のログが消えます 。タイムスタンプ化+古ログの自動掃除に: [nano11builder.ps1]

```powershell
$logDir = Join-Path $scriptDir 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
Start-Transcript -Path (Join-Path $logDir ("nano11_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date)))
Get-ChildItem $logDir -Filter 'nano11_*.log' | Sort-Object LastWriteTime -Descending |
    Select-Object -Skip 10 | Remove-Item -Force -ErrorAction SilentlyContinue
```

スクリプト置き場が読み取り専用(ISOマウント上等)の場合に備え、`Start-Transcript` を try/catch して `$env:TEMP` へのフォールバックも。

### 9. 終了コード体系と最終レポート

`exit 0/1` のみで失敗理由がコードから読めません。冒頭でコメントの終了コード表を定義し(例： 0=成功、2=マウント失敗、3=エクスポート失敗、4=ハイブ操作失敗)、最後にこう出力:

```powershell
$sw = [System.Diagnostics.Stopwatch]::StartNew()  # 先頭で
# 末尾で
Write-Host ("完了: ISO {0:N2} GB / 所要 {1:mm\:ss}" -f ($isoItem.Length/1GB, $sw.Elapsed))
Get-FileHash $isoPath -Algorithm SHA256 | Format-List
```

フェーズごとに `Measure-Command` を取り、サイズ削減の内訳(WinSxS/AppX/ドライバ各何MB削れたか)をログに出すと、今後のチューニングが数値で比較できます。

## セキュリティ・整合性

### 10. ツール類のダウンロードが固定バージョン・ハッシュ検証なし

Revision Tool 2.11.1、Optimizer 16.7 のURLがハードコードされており、SHA256検証もありません 。個人用とはいえ、イメージ内に配置されるバイナリなので供給網リスクは潰すべきです: [nano11builder.ps1]

```powershell
$rel = Invoke-RestMethod 'https://api.github.com/repos/hellzerg/optimizer/releases/latest' -Headers @{ 'User-Agent' = 'nano11' }
$asset = $rel.assets | Where-Object name -like 'Optimizer-*.exe' | Select-Object -First 1
Invoke-WebRequest $asset.browser_download_url -OutFile $optLocal
if ($asset.digest) {  # "sha256:xxxx" 形式
    $expected = $asset.digest.Split(':') [nano11.log].ToLower()
    $actual = (Get-FileHash $optLocal -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $expected) { throw "Optimizer のハッシュ不一致" }
}
```

バージョンピン留めを維持したいなら、少なくとも既知のSHA256をスクリプト内定数に持ち照合する形で。FirstLogon の `Install-Browser.ps1`(Chrome/Firefox等のCDNダウンロード)も同様に、サイズ下限チェックだけでも入れるべきです 。 [nano11builder.ps1]

### 11. `robocopy /MIR` の安全ガード

`Reset-DirectoryWithRobocopy` と `Remove-ProtectedDirectory` は `/MIR` で対象をミラー削除します 。`$Path` に誤って `C:\` 等が渡わると壊滅します。ガードを追加: [nano11builder.ps1]

```powershell
function Reset-DirectoryWithRobocopy {
    param([Parameter(Mandatory)][string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($full -notmatch 'nano11|scratch|workspace' -and $full.Length -le 3) {
        throw "危険なパスは拒否: $full"
    }
    ...
}
```

### 12. 画像側のセキュリティ設定を明示的に

オフラインハイブに `LimitBlankPasswordUse=0` + 空パスワードでの `AutoAdminLogon=1`、UAC完全無効、PowerShell実行ポリシー `Unrestricted` を焼き込んでいます 。個人用でも、これらを1つの「セキュリティ緩和セット」として `-Hardened` 的なスイッチでON/OFFできるようにしておくと、人に見せるときやVMで使い分けるときに楽です。なおFirstLogon側の `sc stop WinDefend` はタンパープロテクション有効時は失敗するので、Control Center.bat の案内文にその注記を。 [nano11builder.ps1]

## パフォーマンス・保守性・機能追加

### 13. AppX パターンマッチの高速化・重複排除

`appxPatterns` には重複が多く(`Getstarted`/`GetStarted`/`Microsoft.Getstarted`、`Calculator`/`WindowsCalculator`、`Xbox` 系の重複)、パッケージ数×パターン数の `-like` ループはO(n×m)です 。1つの正規表現に統合: [nano11builder.ps1]

```powershell
$appxRegex = ($appxPatterns | Sort-Object -Unique) -join '|'
$packagesToRemove = Get-AppxProvisionedPackage -Path $scratchDir |
    Where-Object { $_.DisplayName -match $appxRegex -or $_.PackageName -match $appxRegex }
```

`-like 'Bing'` のようにワイルドカードなしの `-like` は部分一致しない(`Microsoft.BingWeather` にはマッチしない)点も要注意なので、`-match` への統一は正確性の面でも改善です。

### 14. プリセット定義の三重管理を一元化

同一のプリセット設定が「CLIの `-Profile` 分岐」「GUIの `$applyPreset`」「profiles\*.json」の3箇所に重複して存在します 。修正漏れの温床なので、冒頭で1回だけ定義: [nano11builder.ps1]

```powershell
$script:Presets = @{
    extreme  = @{ RemoveDefender=$true;  KeepExtraFonts=$false; DisableWindowsUpdate=$true;  KeepRecoveryEnv=$false; UltraSlimMode=$true;  PayloadFormat='WIM' }
    balanced = @{ RemoveDefender=$false; KeepExtraFonts=$true;  DisableWindowsUpdate=$false; KeepRecoveryEnv=$true;  UltraSlimMode=$false; PayloadFormat='WIM' }
    fat32    = @{ RemoveDefender=$true;  KeepExtraFonts=$false; DisableWindowsUpdate=$true;  KeepRecoveryEnv=$false; UltraSlimMode=$true;  PayloadFormat='SWM' }
}
# CLI・GUI・JSON出力すべてこのテーブルを参照・適用
```

### 15. パラメータ検証の強化

- `$Index` は `[string]` ですが `[int]` + `ValidateRange(1,99)` にすべきです 。 [nano11builder.ps1]
- 矛盾スイッチの検出: `-KeepDefender -RemoveDefender` など対立ペアが同時指定されたら今は暗黙の優先順位で解決されます。冒頭で `if ($KeepDefender -and $RemoveDefender) { throw '...' }` のように各ペアを明示的に拒否。
- `#Requires -Version 5.1` をファイル先頭に。
- JSONプロファイル読込時、`$data.Version` が `"2.0"` 以外なら警告、未知のキーがあれば列挙して警告(タイポ検出になります)。

### 16. GUI の修正点

- ISO自動検出が `E:\`、`D:\`、スクリプト置き場、USERPROFILE の決め打ちです  [nano11builder.ps1]。全ドライブ列挙に: `Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | Select -Expand DeviceID`。ファイル名パターン(`*Win11*`等)も、日本語ISO名以外で漏れる場合はボリュームラベル照合を追加。
- フォームが `AutoScaleMode` 未設定で座標固定のため高DPI環境で崩れます。`$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi` を追加。
- ビルド実行中もGUIが応答なしになるわけではないものの、ビルドの進捗がコンソールにしか出ないので、`-GUI` 時は `Start-Process powershell -ArgumentList ...` で別コンソールに進捗を出す形にすると視認性が上がります。

### 17. アグレッシブWinSxSモードの2つの問題

- `Copy-Item -Recurse` で WinSxS ディレクトリを退避コピーする方式は、ハードリンクによる実体共有が失われるため、場合によってはWIMがむしろ大きくなります 。安全側の `StartComponentCleanup /ResetBase` で十分削減できるので、アグレッシブモード自体の削除も選択肢です。 [nano11builder.ps1]
- 保持リストは amd64/arm64 用のスタックパターンしかなく、x86検出時は keep 対象ゼロで破壊的になります。x86を早期に拒否(`throw`)するのが正解です 。 [nano11builder.ps1]

### 18. その他の改良・機能追加案

- **`-DryRun` / `-WhatIf`**: `SupportsShouldProcess` を付け、解決後の設定と実行予定(削除予定パッケージ一覧、適用レジストリキー数)だけ表示するモード。現行の隠し環境変数 `NANO11_TEST_MODE` を正式パラメータ化。
- **`-Resume`**: マウント済みイメージ・ハイブが残っている状態から再開するモード。`Clear-DismMountConflicts` の情報を活用。
- **`-Offline` / `-RefreshTools`**: ネットワークなしでも`tools`キャッシュで完結すること、逆にキャッシュ強制更新を明示的に。
- **レジストリ適用のバッチ化**: `reg.exe add` が数百回呼ばれ、しかも `2>&1` で握りつぶされています 。キー/値のテーブルをループで回しつつ失敗をカウントし、最後に「適用N件/失敗M件」をログに出す helper(`Set-OfflineReg`)に置換。さらに速さを求めるなら全体を1つの `.reg` ファイルに組み立てて `reg import` 一発適用も可。 [nano11builder.ps1]
- **配布物のハッシュ付き検証**: エクスポート後に `dism /Get-WimInfo /WimFile:install.wim /Index:N` を実行してイメージ整合性を確認し、ISO完成後にSHA256をログ出力(前述の最終レポートに統合)。
- **コード品質**: 先頭に `Set-StrictMode -Version 2.0`、定期的に PSScriptAnalyzer を通す(`2>&1 | Out-Null` の乱用はPSAでも指摘されます)。264KBの単一ファイルは現実的な範囲なら `functions/` に分割して dot-source してもいいですが、単一ファイル配布を優先するならリージョンコメント(`#region Mount / #endregion`)でセクション区切りだけ入れるのが最小労力です。
- **プロファイル3種の重複**： `extreme-gaming.json` / `fat32-splitwim.json` / `balanced-pro.json` は実質3〜4項目しか違いません 。ベースプロファイル+差分マージ(`Merge-Hashtable`)にすると14項目の管理が1箇所で済みます。 

以上です。優先順位をつけるなら「1(bat修正)→ 5(Invoke-Dism)→ 6(try/finally)→ 4(Defender除外解除)→ 2(WinRE残骸)→ 13(AppX正規表現)」の順で、信頼性と正確性が最も大きく向上します。続きとして、前回触れていない部分(`autounattend.xml` 全体、`nano11builder.ps1` の後半〜ポストインストール資産、プロファイル回りの異常系)を精査しました。まだ掘り出せる点がかなりあります。

**TL;DR**: 新たに「機能していない死にコード」「レジストリの重複書き込み」「autounattend.xml の3重複と肥大」「ISO をマウントしたまま解除しないリーク」などの確定案件と、セットアップ時間短縮・自動検証・ポストインストール資産の改良案が出せます。

## 追加の確定バグ・死んでいるコード

### 1. `winre.wim.keep` マーカーは何もしていない

`keepRecoveryEnv` が有効なら `winre.wim.keep` マーカーファイルを作成しますが、直後に「マーカーが存在したら削除」という処理が走り、マーカーはイメージに残りません 。つまり作成→即削除で、FirstLogon 側で参照されることもない死にコードです。過去デザインの名残と思われるので、削除するか、本来の意図(FirstLogon が WinRE を残す/消す判定に使う)を実装してください:

```powershell
if ($keepRecoveryEnv) {
    # マーカーを残して FirstLogon が reagentc を無効化しない
    New-Item -Path $keepMarkerFile -ItemType File -Force | Out-Null
} else {
    Write-Host "FirstLogon で reagentc 無効化 + winre.wim 削除を指示" -ForegroundColor Cyan
    Set-Content -Path (Join-Path $scratchDir 'Windows\Setup\Scripts\winre-cleanup.flag') -Value 'remove'
}
# 既存の「Test-Path したら削除」の行は削除
```

### 2. 同じレジストリキーへの重複書き込みが大量にある

オフライン適用フェーズで、同一キー・同一値への `reg.exe add` が2〜3回連続で実行されている箇所が複数あります。例えば `SearchboxTaskbarMode` が同じブロック内で2回、`AppCaptureEnabled` が3回、`GameDVREnabled`/`GameDVRFSEBehaviorMode` が2回、`WinEnterLaunchNarrator`/`NoStartNarratorShortcut` が2回ずつ書かれています 。パッチ統合時のコピペ重複と見られ、結果は変わらないものの無駄で、ログも読みにくくなります。`Set-OfflineReg` ヘルパーに置き換えつつ重複排除を:

```powershell
$script:RegApplied = [System.Collections.Generic.HashSet[string]]::new()
function Set-OfflineReg {
    param([string]$Key, [string]$Name, [string]$Type, [string]$Data)
    $id = "$Key|$Name"
    if ($script:RegApplied.Contains($id)) { return }   # 重複スキップ
    [void]$script:RegApplied.Add($id)
    & reg.exe add $Key /v $Name /t $Type /d $Data /f 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "REG 失敗: $Key\$Name" -ForegroundColor Yellow }
}
# 最後に: Write-Host "レジストリ適用 $($script:RegApplied.Count) 件"
```

これで「適用N件・失敗M件」がログに出るようになり、タイポも検出できます。

### 3. ソースISOをマウントしたまま解除していない

`-SourceDrive` に ISO を渡すと `Mount-DiskImage` でマウントしますが、ビルド完了後の `Dismount-DiskImage` がスクリプト内に見当たりません 。ビルド後にISOがドライブとして居座り続けます。`finally` ブロック(前回案)に組み込んでください:

```powershell
$script:MountedIso = $null
# Mount-DiskImage 成功時: $script:MountedIso = $diskImg
# finally 側:
if ($script:MountedIso) { Dismount-DiskImage -ImagePath $script:MountedIso.ImagePath | Out-Null }
```

### 4. ツールキットの実態と表示の不一致

「WinUtil, Sophia Script, SophiApp, Optimizer, Bloatynosy, Revision Tool」をバンドルと謳っていますが、実際にダウンロードされるのは Revision Tool と Optimizer の2つだけで、残りは `tools\` に手動で置いてあった場合のみコピーされます 。しかも失敗時は `Write-Warning` のみで続行します。最低限:

- 実際にDLできた/存在したツール名だけを最後の完了メッセージに列挙する
- `-NonInteractive` 時はプロファイル欠落も含めて失敗を握らない(現状 `Import-Nano11Profile` 失敗時にデフォルト設定でビルドが続行し、exit code 0 で終わります  — 「指定したJSONが読めなかったのに成功扱い」は自動化では危険なので `throw` に)

### 5. ユーザー指定 WorkDir の空き容量チェックがない

ドライブ自動選択時は30GB以上の空きを条件にしていますが、`-WorkDir` で明示指定した場合は空き容量検証が一切ありません 。ビルド途中でのディスク枯渇は一番痛い失敗です。早期に:

```powershell
$needGB = 35  # ソースISO + マウント展開 + エクスポート分を見込む
$freeGB = (Get-PSDrive -Name $baseWorkDir.Substring(0,1)).Free / 1GB
if ($freeGB -lt $needGB) { throw "空き容量不足: {0:N1} GB / 必要 {1} GB" -f $freeGB, $needGB }
```

正確にやるなら `(Get-Item $destWim).Length` から必要容量を動算する方式も。

## autounattend.xml の改良

### 6. 同一コマンド列の3重複と259KBの肥大

`autounattend.xml` を読みましたが、Specialize の RunSynchronous に同一の LabConfig/BitLocker/BypassNRO の `reg.exe add` 列がそのまま3回繰り返されており、FirstLogon 呼び出しコマンドも3回出現します 。アーキテクチャ別(x64/arm64)のパス分けだとしても、同一内容なら統合可能で、その分セットアップ時間とファイルサイズを削減できます。まず実ファイルで `processorArchitecture` 属性を確認し、重複パスを1つにまとめてください。根本的には「259KBの静的XMLを持つのをやめて、ビルド時にオプション反映したXMLをスクリプトから生成する」のが理想です:

```powershell
$unattend = [xml](Get-Content $templatePath -Raw)
# $removeDefender 等のフラグに応じて <RunSynchronousCommand> を挿入/削除
$unattend.Save("$nano11Dir\autounattend.xml")
```

これなら「Defender保持なら Defender 無効化コマンドを入れない」のような条件化が可能になり、静的ファイルとの挙動ズレも消えます。

### 7. RunSynchronous 内の reg.exe を1スクリプトに統合

Specialize 中の `reg.exe add` は1コマンドずつ同期実行され、それぞれプロセス起動コストがかかります 。`Setup\Scripts\Specialize.ps1` として1ファイルにまとめて「1回のpowershell.exe呼び出し」にすればOOBEが数秒〜十数秒短縮されます:

```xml
<RunSynchronousCommand>
  <Order>1</Order>
  <Path>powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Setup\Scripts\Specialize.ps1</Path>
</RunSynchronousCommand>
```

### 8. 第三者スクリプト(Winhance)の丸埋め込み

`autounattend.xml` 内に Winhance の `Winhancements.ps1` が文字列として丸ごと埋め込まれています 。個人用でも、元プロジェクトの更新に追従できず、かつXML内ではdiffが取りにくいのが問題です。改善案：

- ビルド時に `tools\` キャッシュから最新版を取得し、`Extensions/File` 機構で配置する(スクリプト本体はXMLに埋め込まない)
- 取得時にピン留めバージョン+SHA256を検証(前回のRevision Tool/Optimizerと同じ仕組み)
- XMLに埋め込むとしても、ビルド時に `Get-Content` で注入する動的生成にする

### 9. FirstLogon の成否が完全に闇の中

FirstLogon 起点のラッパーは `try { & FirstLogon.ps1 } catch {}` で、内部エラーがすべて握りつぶされます 。ポストインストール処理が一部失敗しても気付けません。FirstLogon.ps1 の先頭に:

```powershell
$log = 'C:\Windows\Setup\Scripts\FirstLogon.log'
Start-Transcript -Path $log -Force
# ...(処理本体、各段階で Write-Host "OK: xxx" / "FAIL: xxx")
Stop-Transcript
# 成否マーカー: 処理終了時に Set-Content C:\ProgramData\nano11\firstlogon.done
```

とし、失敗時はイベントログ(`Write-EventLog` か `wevtutil`)にも書き出す。あなたはログ検証型のトラブルシュートをするタイプなので、これは特に効く改良です。

### 10. 空パスワード AutoAdminLogon の恒久化を確認

オフラインハイブに `AutoAdminLogon=1` + 空の `DefaultPassword` + `ForceAutoLogon=1` を焼き込み 、unattend 側にもAutoLogon設定があるため二重管理です 。unattendのLogonCountは減算されますが、オフライン側の`AutoAdminLogon=1`は減算されず**毎回自動ログイン**の可能性があります。FirstLogon.ps1 が初回ログオン後にこれを解除しているか確認し、未実装なら追加を:

```powershell
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' AutoAdminLogon 0
Remove-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' DefaultPassword -ErrorAction SilentlyContinue
```

## ビルド精度・自動化の改良

### 11. エディションの自動選択

現在は `-Index` 未指定でインデックス1を無条件選択します 。多くの場合 Pro が欲しいはずなので:

```powershell
$wimInfo = dism.exe /English /Get-WimInfo /WimFile:$destWim | Select-String 'Name\s*:\s*(.+)'
$proIndex = ($wimInfo | Where-Object { $_.Matches[0].Groups [polyformproject](https://polyformproject.org/licenses/shield/1.0.0).Value -match 'Pro' } | Select-Object -First 1)
# あればそのIndex、なければ1 + ユーザーに警告
```

### 12. プロファイルJSONに行った設定を全部保存する

`extreme-gaming.json` 等にはオプション15項目しか保存されず、`SourceDrive`・`WorkDir`・`Index` は保存されません 。同じ環境に繰り返しビルドする個人用途では、これらも含めて保存/復元できると `-LoadProfile` 一発で完全再現できます。`Export-Nano11Profile` の `Settings` に `SourceDrive`/`WorkDir`/`Index` を追加し、読み込み側で「指定がなければプロファイル値を使用」に。

### 13. ビルド後の自動検証(`-Validate`)

エクスポートしたWIMを検証無しで完成扱いにしています。あなたの検証志向に合う機能として:

```powershell
if ($Validate) {
    # ① エクスポート成果物の整合性
    dism.exe /English /Get-WimInfo /WimFile:$finalWim | Out-File "$baseWorkDir\verify-wiminfo.txt"
    # ② 読み取り専用で再マウントし、主要パス存在チェック
    dism.exe /English /Mount-Image /ImageFile:$finalWim /Index:1 /MountDir:$scratchDir\verify /ReadOnly
    @('Windows\System32\osk.exe','Windows\System32\ctfmon.exe',
      'Windows\System32\Microsoft-Edge-WebView','Windows\System32\Sysprep\sysprep.exe') |
        ForEach-Object { "{0} : {1}" -f $_, (Test-Path (Join-Path $scratchDir\verify $_)) } |
        Out-File "$baseWorkDir\verify-paths.txt"
    dism.exe /English /Unmount-Image /MountDir:$scratchDir\verify /Discard
}
```

さらに一歩進めるなら `-TestISO`: `New-VM` + `Add-VMDvdDrive` + `Start-VM` でHyper-Vに投げてOOBE到達を自動スモークテストするモード。VMがあるなら再現性のある検証として最強です。

### 14. ei.cfg の条件化

`ei.cfg` を常に `Channel Default` で生成しています 。LTSC等では挙動が変わるので、`-SkipEiCfg` スイッチかプロファイル項目で制御できるように。

## ポストインストール資産の細部改良

### 15. Control Center.bat の Defender トグルはタンパープロテクションで失敗する

`sc config WinDefend start disabled` / `sc stop WinDefend` は、タンパープロテクション有効な標準状態のWindows 11では拒否されます 。Control Centerの案内に「タンパープロテクションを手動オフにしてから実行」と注記するか、そもそもこのイメージではオフラインポリシーで無効化済みのはずなので、トグルは`Set-MpPreference -DisableRealtimeMonitoring`系のレジストリポリシー反転方式に寄せるのが確実です。あわせて:

- `FREEMEM` の `del /s /f /q %TEMP%\*` は使用中ファイルで大量のエラー出力が出る(リダイレクトで消えていますが)ので、`/q` を付けた上でエラーも `/nul 2>&1` に統一
- IFEO の `Debugger = systray.exe` リダイレクト  は、ブロック対象プロセスが起動されるたびにアプリエラーイベントがイベントログに積もります。許容範囲なら良いですが、ログのノイズが気になるならバイナリ名変更(`VoiceAccess.exe.bak` 等)に置き換える選択肢も

### 16. ブラウザインストーラの配備をオプション化

`Install-Browser.ps1/.cmd` と `Nano11 Control Center.bat` は常にデプロイされます 。個人的に不要になった場合のために `-NoPostInstallAssets` 的なスイッチ(またはプロファイル項目 `DeployControlCenter`)で配備可否を制御できると、ISOの内容を用途別に変えられます。

### 17. バージョン文字列の一元管理

GUIタイトルの「v2.0」、プロファイルの `Version = "2.0"` が各所にハードコードされています 。`$script:Nano11Version = '2.1'` を先頭に定義して全参照を置き換え、併せてビルド成果物のログ/ISOファイル名にバージョンと対象ビルド番号(`26300.xxxx`)を含めると、複数世代のISOを保持するときの判別が楽になります。

### 18. PowerShell 7 互換の明示

現在はPS 5.1前提です(トランスクリプトの内容からも確認できます )。`pwsh` で実行された場合の挙動差(`Set-Content -Encoding utf8` のBOM有無、`Invoke-WebRequest` の`-UseBasicParsing`廃止、Add-TypeのWinForms STA要件)を防ぐため、冒頭で:

```powershell
if ($PSVersionTable.PSVersion.Major -ge 7) {
    Write-Warning "PowerShell 7 は未検証です。Windows PowerShell 5.1 で実行してください。"
}
```

以上、前回の18案に加えてさらに18案です。特に「1(死にコード)」「2(重複レジストリ)」「3(ISOディスマウント漏れ)」「6(unattendの3重複)」「9(FirstLogonの成否可視化)」は確定案件なので、次に取り組むならこの5つからがおすすめです。
</USER_REQUEST>
<ADDITIONAL_METADATA>
The current local time is: 2026-10-05T07:36:08+09:00.
</ADDITIONAL_METADATA>
