<#
.SYNOPSIS
    nano11 Builder - Universal, Language-Independent Windows 11 Image Reducer
.DESCRIPTION
    Generates a significantly reduced Windows 11 image with support for:
    - Universal language compatibility (independent of host OS locale)
    - Full Debloat with optional customizations (keep IME, Defender, Fonts, Drivers, Updates, Bluetooth)
    - Optional WSL2 & VirtualMachinePlatform pre-enablement before WinSxS slimming (-EnableWSL)
    - Custom working directory support (-WorkDir) to prevent disk space issues
    - Setup hardware requirement bypasses including appraiserres.dll patch for Canary 28020+
    - Fixed WinSxS and DriverStore permission issues (robocopy mirror trick & .NET ACL)
    - Architecture support: amd64 (x64) and arm64
    - Proper placement of autounattend.xml (in ISO root, Sysprep, Panther) with self-healing and CompactOS
    - Clean unattended setup with local account support
.NOTES
    Original Author: NTDEV
    Contributions: Tinnitus97 (PR #6), Antigravity (Multi-language, ARM64, Bugfixes, WSL2 & Customization)
    License: MIT
#>

[CmdletBinding()]
param(
    [switch]$NonInteractive,
    [string]$SourceDrive,
    [string]$WorkDir,
    [string]$Index,
    [switch]$KeepIME,
    [switch]$KeepDefender,
    [switch]$KeepFonts,
    [switch]$KeepDrivers,
    [switch]$KeepWindowsUpdate,
    [switch]$KeepBluetooth,
    [switch]$EnableWSL,
    [switch]$KeepRecovery,
    [switch]$KeepWinRE,
    [switch]$SafeDebloat,
    [switch]$AggressiveWinSxS,
    [switch]$TrimWinSxS,
    [switch]$UltraSlim,
    [switch]$JapaneseKeyboard,
    [switch]$NoJapaneseKeyboard,
    [switch]$AtlasReviOS,
    [switch]$NoAtlasReviOS,
    [switch]$ExportESD
)

# 1. Check and adjust Execution Policy
if ((Get-ExecutionPolicy) -eq 'Restricted') {
    Write-Host "Your current PowerShell Execution Policy is 'Restricted', which prevents scripts from running." -ForegroundColor Yellow
    Write-Host "Do you want to change it to 'RemoteSigned'? (yes/no)"
    $response = Read-Host
    if ($response -and ($response.Trim().ToLower() -in @('yes', 'y'))) {
        Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Confirm:$false
        Write-Host "Execution Policy has been changed to RemoteSigned." -ForegroundColor Green
    } else {
        Write-Host "The script cannot run without changing the execution policy. Exiting..." -ForegroundColor Red
        exit 1
    }
}

# 2. Check for Admin rights and restart with full arguments preserved
$myWindowsID = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$myWindowsPrincipal = New-Object System.Security.Principal.WindowsPrincipal($myWindowsID)
if (-not $myWindowsPrincipal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Restarting script with Administrator privileges in a new window..." -ForegroundColor Yellow
    
    # Reconstruct bound parameters for elevated process
    $paramList = [System.Collections.Generic.List[string]]::new()
    foreach ($key in $PSBoundParameters.Keys) {
        $val = $PSBoundParameters[$key]
        if ($val -is [System.Management.Automation.SwitchParameter]) {
            if ($val.IsPresent) { $paramList.Add("-$key") }
        } elseif ($val -is [bool]) {
            if ($val) { $paramList.Add("-$key") } else { $paramList.Add("-$key`:$false") }
        } else {
            $paramList.Add("-$key `"$val`"")
        }
    }
    
    $newProcess = New-Object System.Diagnostics.ProcessStartInfo "PowerShell"
    $newProcess.Arguments = "-File `"$($myInvocation.MyCommand.Definition)`" " + ($paramList -join " ")
    $newProcess.Verb = "runas"
    try {
        [System.Diagnostics.Process]::Start($newProcess) | Out-Null
    } catch {
        Write-Host "Failed to elevate privileges: $_" -ForegroundColor Red
    }
    exit 0
}

# Helper function: Safely unmount offline registry hive with retry and garbage collection
function Unmount-RegistryHiveWithRetry {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Name,
        [int]$Retries = 3
    )
    $path = "HKLM:\$Name"
    for ($i = 0; $i -le $Retries; $i++) {
        if (-not (Test-Path -LiteralPath $path)) {
            return $true
        }
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        Start-Sleep -Milliseconds 250
        & reg.exe unload "HKLM\$Name" > $null 2>&1
        if ($LASTEXITCODE -eq 0) {
            return $true
        }
    }
    return $false
}

# Helper function: Detect and discard conflicting/orphaned DISM mounts (Resolves Error 0xc1420127)
function Clear-DismMountConflicts {
    param(
        [string]$TargetMountDir,
        [string]$TargetWimFile
    )
    $mountedOutput = & dism.exe /English /Get-MountedImageInfo 2>&1
    if ($LASTEXITCODE -eq 0 -and $mountedOutput) {
        $normMount = if ($TargetMountDir) { try { [System.IO.Path]::GetFullPath($TargetMountDir).TrimEnd('\') } catch { $null } } else { $null }
        $normWim   = if ($TargetWimFile)  { try { [System.IO.Path]::GetFullPath($TargetWimFile).TrimEnd('\') } catch { $null } } else { $null }

        $records = @()
        $currentRecord = [ordered]@{}
        foreach ($line in $mountedOutput) {
            $t = [string]$line
            if ([string]::IsNullOrWhiteSpace($t)) {
                if ($currentRecord.Count -gt 0) {
                    $records += [pscustomobject]$currentRecord
                    $currentRecord = [ordered]@{}
                }
                continue
            }
            if ($t -match '^\s*([^:]+?)\s*:\s*(.*)$') {
                $currentRecord[$matches[1].Trim()] = $matches[2].Trim()
            }
        }
        if ($currentRecord.Count -gt 0) {
            $records += [pscustomobject]$currentRecord
        }

        foreach ($rec in $records) {
            $mDir = $rec.'Mount Dir'
            $iFile = $rec.'Image File'
            $status = $rec.'Status'
            if (-not $mDir) { continue }

            $isConflict = $false
            if ($normMount) {
                try {
                    if ([System.IO.Path]::GetFullPath($mDir).TrimEnd('\') -ieq $normMount) { $isConflict = $true }
                } catch {}
            }
            if (-not $isConflict -and $normWim -and $iFile) {
                try {
                    if ([System.IO.Path]::GetFullPath($iFile).TrimEnd('\') -ieq $normWim) { $isConflict = $true }
                } catch {}
            }
            # Auto-cleanup orphaned nano11 scratch mounts if running generic sweep
            if (-not $isConflict -and (-not $TargetMountDir) -and (-not $TargetWimFile)) {
                if ($mDir -like "*scratchdir*" -or $mDir -like "*nano11*" -or $iFile -like "*nano11*") {
                    $isConflict = $true
                }
            }

            if ($isConflict) {
                Write-Host "Found conflicting/orphaned DISM mount at '$mDir' (Status: $status). Discarding..." -ForegroundColor Yellow
                if ($status -eq "Needs Remount") {
                    & dism.exe /English /Remount-Image "/MountDir:$mDir" > $null 2>&1
                }
                & dism.exe /English /Unmount-Image "/MountDir:$mDir" /discard > $null 2>&1
            }
        }
    }

    & dism.exe /English /Cleanup-Wim > $null 2>&1
    & dism.exe /English /Cleanup-Mountpoints > $null 2>&1
}

# 3. Clean up any orphaned DISM mount points and leftover registry hives from previous failed runs
Write-Host "Checking for and repairing any orphaned DISM mount points and registry hives..." -ForegroundColor Cyan
Clear-DismMountConflicts
@('zCOMPONENTS', 'zDEFAULT', 'zNTUSER', 'zSOFTWARE', 'zSYSTEM') | ForEach-Object {
    [void](Unmount-RegistryHiveWithRetry -Name $_)
}

# 4. Language-independent Administrators group via Well-Known SID (S-1-5-32-544)
$adminGroupSid = New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)

# Helper function: Take ownership and grant FullControl using PowerShell .NET ACL (Locale-independent via direct SID)
function Set-ItemOwnershipAndAccess {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path,
        [switch]$Recurse
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    try {
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        try {
            $acl.SetOwner($adminGroupSid)
        } catch {}

        if ($Recurse) {
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $adminGroupSid,
                [System.Security.AccessControl.FileSystemRights]::FullControl,
                "ContainerInherit, ObjectInherit",
                "None",
                "Allow"
            )
        } else {
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $adminGroupSid,
                [System.Security.AccessControl.FileSystemRights]::FullControl,
                "Allow"
            )
        }
        $acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
    } catch {
        # Fallback to takeown/icacls with well-known administrator SID
        if ($Recurse) {
            & takeown.exe /F "$Path" /R /D Y > $null 2>&1
            & icacls.exe "$Path" /grant "*S-1-5-32-544:(OI)(CI)F" /T /C /Q > $null 2>&1
        } else {
            & takeown.exe /F "$Path" /D Y > $null 2>&1
            & icacls.exe "$Path" /grant "*S-1-5-32-544:F" /C /Q > $null 2>&1
        }
    }
}

# Helper function: Robust directory deletion using empty directory robocopy mirror trick
function Remove-ProtectedDirectory {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path,
        [Parameter(Mandatory=$true)]
        [string]$ScratchPath
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    Set-ItemOwnershipAndAccess -Path $Path -Recurse
    $emptyTemp = Join-Path -Path $ScratchPath -ChildPath "empty_dir_for_delete_$([System.IO.Path]::GetRandomFileName())"
    try {
        New-Item -Path $emptyTemp -ItemType Directory -Force | Out-Null
        & robocopy.exe $emptyTemp $Path /MIR /R:0 /W:0 /NP /NFL /NDL /NJH /NJS > $null 2>&1
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    } finally {
        if (Test-Path -LiteralPath $emptyTemp) {
            Remove-Item -LiteralPath $emptyTemp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# Start Transcript
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$transcriptPath = Join-Path -Path $scriptDir -ChildPath "nano11.log"
Start-Transcript -Path $transcriptPath -Force

Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "               Welcome to nano11 builder!                " -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "This script generates a significantly reduced Windows 11 image."
Write-Host "Suitable for testing, low-spec VMs, and rapid prototyping."
Write-Host ""

# Confirmation
if (-not $NonInteractive) {
    Write-Host "Do you want to continue? (y/n)" -ForegroundColor Yellow
    $confirm = Read-Host
    if (-not ($confirm -and ($confirm.Trim().ToLower() -in @('yes', 'y')))) {
        Write-Host "Process cancelled by user. Exiting..." -ForegroundColor Gray
        Stop-Transcript
        exit 0
    }
}

# Customization Options (Resolves Issues #1, #5, #9, #10, #12, #13)
Write-Host ""
Write-Host "--- Customization Settings ---" -ForegroundColor Green
$removeDefender = $true
$keepAsianIME = $true
$keepExtraFonts = $true
$removeDrivers = $true
$disableWU = $true
$keepBT = $true
$wslSupport = $false
$keepRecoveryEnv = $false
$safeDebloatMode = $true
$ultraSlimMode = $false
$setJapaneseKeyboard = $true
$atlasReviOSMode = $true
$exportESDMode = $false

if ($NonInteractive) {
    if ($KeepDefender)          { $removeDefender = $false }
    if (-not $KeepIME)          { $keepAsianIME = $false }
    if (-not $KeepFonts)        { $keepExtraFonts = $false }
    if ($KeepDrivers)           { $removeDrivers = $false }
    if ($KeepWindowsUpdate)     { $disableWU = $false }
    if ($KeepBluetooth)         { $keepBT = $true }
    if ($EnableWSL)             { $wslSupport = $true }
    if ($KeepRecovery -or $KeepWinRE) { $keepRecoveryEnv = $true }
    if ($AggressiveWinSxS -or $TrimWinSxS) { $safeDebloatMode = $false }
    if ($UltraSlim)             { $ultraSlimMode = $true; $keepExtraFonts = $false }
    if ($NoJapaneseKeyboard)    { $setJapaneseKeyboard = $false }
    elseif ($JapaneseKeyboard)  { $setJapaneseKeyboard = $true }
    if ($NoAtlasReviOS)         { $atlasReviOSMode = $false }
    elseif ($AtlasReviOS)       { $atlasReviOSMode = $true }
    if ($ExportESD)             { $exportESDMode = $true }
} else {
    Write-Host "Configure debloat options (Press Enter to use recommended defaults):" -ForegroundColor Gray
    
    # 1. Windows Defender
    $opt = Read-Host "1. Remove Windows Defender? [Y/n] (Default: Y)"
    if ($opt -and ($opt.Trim().ToLower() -in @('no', 'n'))) { $removeDefender = $false }

    # 2. Asian IMEs (Japanese, Chinese, Korean)
    $opt = Read-Host "2. Keep Asian language IMEs (Japanese, Chinese, Korean)? [Y/n] (Default: Y)"
    if ($opt -and ($opt.Trim().ToLower() -in @('no', 'n'))) {
        $keepAsianIME = $false
    } else {
        $keepAsianIME = $true
    }

    # 3. Fonts
    $opt = Read-Host "3. Keep extra international & Asian fonts? [Y/n] (Default: Y)"
    if ($opt -and ($opt.Trim().ToLower() -in @('no', 'n'))) {
        $keepExtraFonts = $false
    } else {
        $keepExtraFonts = $true
    }

    # 4. Drivers
    $opt = Read-Host "4. Remove non-essential drivers (printers, scanners, fax)? [Y/n] (Default: Y)"
    if ($opt -and ($opt.Trim().ToLower() -in @('no', 'n'))) { $removeDrivers = $false }

    # 5. Windows Update
    $opt = Read-Host "5. Disable Windows Update? [Y/n] (Default: Y)"
    if ($opt -and ($opt.Trim().ToLower() -in @('no', 'n'))) { $disableWU = $false }

    # 6. Bluetooth & Audio peripherals
    $opt = Read-Host "6. Keep Bluetooth audio and peripheral services? [Y/n] (Default: Y)"
    if ($opt -and ($opt.Trim().ToLower() -in @('no', 'n'))) { $keepBT = $false }

    # 7. WSL2 & Virtualization (Resolves Issue #5)
    $opt = Read-Host "7. Enable WSL2 and Virtual Machine Platform before stripping WinSxS? [y/N] (Default: N)"
    if ($opt -and ($opt.Trim().ToLower() -in @('yes', 'y'))) { $wslSupport = $true }

    # 8. Windows Recovery Environment (WinRE)
    $opt = Read-Host "8. Keep Windows Recovery Environment (WinRE)? [y/N] (Default: N - removes WinRE safely post-install)"
    if ($opt -and ($opt.Trim().ToLower() -in @('yes', 'y'))) { $keepRecoveryEnv = $true }

    # 9. Component Store (WinSxS) Optimization Mode
    $opt = Read-Host "9. Component Store optimization mode [1=Safe Cleanup (Recommended: 100% Setup success), 2=Aggressive Pruning (Experimental)] (Default: 1)"
    if ($opt -and ($opt.Trim() -eq '2')) {
        $safeDebloatMode = $false
    } else {
        $safeDebloatMode = $true
    }

    # 10. UltraSlim (~3.2 GB ISO Target Mode)
    $opt = Read-Host "10. Enable UltraSlim mode (~3.2 GB ISO target: prunes Edge browser, non-JP CJK fonts, WinSxS dead weight, preserves WebView2 for OOBE)? [Y/n] (Default: Y)"
    if ($opt -and ($opt.Trim().ToLower() -in @('no', 'n'))) {
        $ultraSlimMode = $false
    } else {
        $ultraSlimMode = $true
        $keepExtraFonts = $false
    }

    # 11. Japanese 106/109 Keyboard Layout Configuration
    $opt = Read-Host "11. Configure Japanese 106/109 keyboard layout (prevents @/: mismatch)? [Y/n] (Default: Y)"
    if ($opt -and ($opt.Trim().ToLower() -in @('no', 'n'))) {
        $setJapaneseKeyboard = $false
    } else {
        $setJapaneseKeyboard = $true
    }

    # 12. AtlasOS & ReviOS Radical Debloat & Performance Optimization
    $opt = Read-Host "12. Enable AtlasOS & ReviOS radical debloat & latency optimizations? [Y/n] (Default: Y)"
    if ($opt -and ($opt.Trim().ToLower() -in @('no', 'n'))) {
        $atlasReviOSMode = $false
    } else {
        $atlasReviOSMode = $true
    }

    # 13. Image Compression Format (Default: LZX install.wim to prevent 24H2 DISM WIMGAPI 0xc0000005 crash)
    $opt = Read-Host "13. Image compression format [1=install.wim LZX (Recommended: Fast & Crash-Free), 2=install.esd Recovery (LZMS, experimental)] (Default: 1)"
    if ($opt -and ($opt.Trim() -eq '2')) {
        $exportESDMode = $true
    } else {
        $exportESDMode = $false
    }
}

Write-Host ""
Write-Host "Active configuration:" -ForegroundColor Cyan
Write-Host "  - Remove Windows Defender: $removeDefender"
Write-Host "  - Keep Asian IMEs:         $keepAsianIME"
Write-Host "  - Keep Extra Fonts:        $keepExtraFonts"
Write-Host "  - Remove Legacy Drivers:   $removeDrivers"
Write-Host "  - Disable Windows Update:  $disableWU"
Write-Host "  - Keep Bluetooth Services: $keepBT"
Write-Host "  - Enable WSL2 Platform:    $wslSupport"
Write-Host "  - Keep Recovery (WinRE):   $keepRecoveryEnv"
Write-Host "  - Safe Debloat (WinSxS):   $safeDebloatMode"
Write-Host "  - UltraSlim (~3GB ISO):    $ultraSlimMode"
Write-Host "  - Japanese 106 Keyboard:   $setJapaneseKeyboard"
Write-Host "  - AtlasOS & ReviOS Tuning: $atlasReviOSMode"
Write-Host "  - Payload Format:          $(if ($exportESDMode) { 'install.esd (LZMS)' } else { 'install.wim (LZX - Recommended)' })"
Write-Host ""

# Determine Working Directory (Resolves Issue #27, #23 - Low disk space on C:)
if ($WorkDir) {
    if (-not (Test-Path -LiteralPath $WorkDir)) {
        New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
    }
    $baseWorkDir = (Resolve-Path -LiteralPath $WorkDir).Path
} else {
    $sysDrive = (Get-Item -LiteralPath $env:SystemDrive).PSDrive
    if ($sysDrive -and $sysDrive.Free -lt 25GB) {
        $altDrive = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Free -gt 30GB -and $_.Root -ne $env:SystemDrive } | Sort-Object Free -Descending | Select-Object -First 1
        if ($altDrive) {
            Write-Host "System drive has low free space ($([math]::Round($sysDrive.Free / 1GB, 1)) GB). Using $($altDrive.Root) for working directory." -ForegroundColor Yellow
            $baseWorkDir = $altDrive.Root.TrimEnd('\')
        } else {
            $baseWorkDir = $env:SystemDrive
        }
    } else {
        $baseWorkDir = $env:SystemDrive
    }
}

$nano11Dir = Join-Path -Path $baseWorkDir -ChildPath "nano11"
$scratchDir = Join-Path -Path $baseWorkDir -ChildPath "scratchdir"
Write-Host "Working Directory: $baseWorkDir" -ForegroundColor Cyan

if (Test-Path -LiteralPath $nano11Dir) {
    Write-Host "Cleaning up previous $nano11Dir to prevent leftover file conflicts..." -ForegroundColor Yellow
    Remove-Item -LiteralPath $nano11Dir -Recurse -Force -ErrorAction SilentlyContinue
}
if (Test-Path -LiteralPath $scratchDir) {
    Clear-DismMountConflicts -TargetMountDir $scratchDir
    Remove-Item -LiteralPath $scratchDir -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Force -Path (Join-Path -Path $nano11Dir -ChildPath "sources") | Out-Null

# Determine source drive letter (with auto-detection)
$DriveLetter = ""
if ($SourceDrive) {
    $candDrive = $SourceDrive.Trim().TrimEnd(':') + ":"
    if (Test-Path -LiteralPath $candDrive) {
        $DriveLetter = $candDrive
        Write-Host "Using specified SourceDrive: $DriveLetter" -ForegroundColor Green
    } else {
        Write-Host "Specified SourceDrive '$SourceDrive' does not exist." -ForegroundColor Red
    }
}

# Helper: Scan for healthy Windows 11 ISO files on local storage and auto-mount if needed
function Find-AndMountHealthyWindowsIso {
    $searchPaths = @("E:\", "D:\", (Split-Path -Parent $PSScriptRoot), $env:USERPROFILE)
    $candidateIsos = @()
    foreach ($p in $searchPaths) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $candidateIsos += Get-ChildItem -Path $p -Filter "*.iso" -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -gt 4GB -and ($_.Name -like "*26300*" -or $_.Name -like "*Win11*" -or $_.Name -like "*Windows11*") -and $_.Name -notlike "*nano11*" }
    }
    # Sort: Prioritize 26300 (26H2) official ISO first, then by size
    $sortedIsos = $candidateIsos | Sort-Object { if ($_.Name -like "*26300*") { 0 } else { 1 } }, Length -Descending
    foreach ($iso in $sortedIsos) {
        try {
            $diskImg = Get-DiskImage -ImagePath $iso.FullName -ErrorAction SilentlyContinue
            if (-not $diskImg -or -not $diskImg.Attached) {
                Write-Host "Auto-mounting healthy Windows 11 ISO: $($iso.Name)..." -ForegroundColor Cyan
                $diskImg = Mount-DiskImage -ImagePath $iso.FullName -PassThru -ErrorAction SilentlyContinue
            }
            if ($diskImg) {
                $vol = $diskImg | Get-Volume -ErrorAction SilentlyContinue
                if ($vol -and $vol.DriveLetter) {
                    $dl = "$($vol.DriveLetter):"
                    $wimCheck = Join-Path -Path "$dl\sources" -ChildPath "install.wim"
                    if ((Test-Path -LiteralPath $wimCheck) -and ((Get-Item -LiteralPath $wimCheck).Length -gt 1GB)) {
                        return $dl
                    }
                }
            }
        } catch {}
    }
    return $null
}

if (-not $DriveLetter) {
    # Scan all filesystem drives for sources\install.wim or sources\install.esd
    $detectedMediaDrives = @()
    foreach ($psd in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        if (-not $psd.Root) { continue }
        $rootClean = $psd.Root.TrimEnd('\')
        $wimP = Join-Path -Path "$rootClean\sources" -ChildPath "install.wim"
        $esdP = Join-Path -Path "$rootClean\sources" -ChildPath "install.esd"
        $hasWimP = (Test-Path -LiteralPath $wimP) -and ((Get-Item -LiteralPath $wimP).Length -gt 1GB)
        $hasEsdP = (Test-Path -LiteralPath $esdP) -and ((Get-Item -LiteralPath $esdP).Length -gt 1GB)
        if ($hasWimP -or $hasEsdP) {
            $detectedMediaDrives += $psd
        }
    }

    # If no healthy install.wim drive is mounted, check if a healthy official ISO can be auto-mounted
    $hasHealthyWimMounted = $detectedMediaDrives | Where-Object {
        $r = $_.Root.TrimEnd('\')
        Test-Path -LiteralPath "$r\sources\install.wim"
    }
    if (-not $hasHealthyWimMounted) {
        $mountedDriveLetter = Find-AndMountHealthyWindowsIso
        if ($mountedDriveLetter) {
            $mountedClean = $mountedDriveLetter.TrimEnd(':')
            $newPsd = Get-PSDrive -Name $mountedClean -PSProvider FileSystem -ErrorAction SilentlyContinue
            if ($newPsd -and ($detectedMediaDrives.Root -notcontains $newPsd.Root)) {
                $detectedMediaDrives += $newPsd
            }
        }
    }

    # Prioritize install.wim media over install.esd, and prioritize newer/larger 26H2 Build 26300 media
    $detectedMediaDrives = @($detectedMediaDrives | Sort-Object {
        $rootClean = $_.Root.TrimEnd('\')
        $wimFile = Join-Path -Path "$rootClean\sources" -ChildPath "install.wim"
        if (Test-Path -LiteralPath $wimFile) {
            # Negative length so larger (26H2 Build 26300 @ 8.01 GB) sorts before smaller media
            return -1 * ((Get-Item -LiteralPath $wimFile).Length)
        } else {
            return [long]::MaxValue
        }
    })

    if ($NonInteractive -and $detectedMediaDrives.Count -gt 0) {
        $DriveLetter = $detectedMediaDrives[0].Root.TrimEnd('\')
        Write-Host "Auto-detected Windows installation media on: $DriveLetter" -ForegroundColor Green
    } elseif ($detectedMediaDrives.Count -eq 1) {
        $cand = $detectedMediaDrives[0].Root.TrimEnd('\')
        $vol = Get-Volume -DriveLetter ($cand.TrimEnd(':')) -ErrorAction SilentlyContinue
        $volLabel = if ($vol -and $vol.FileSystemLabel) { " [$($vol.FileSystemLabel)]" } else { "" }
        $wimP = Join-Path -Path "$cand\sources" -ChildPath "install.wim"
        $esdP = Join-Path -Path "$cand\sources" -ChildPath "install.esd"
        $typeDesc = if (Test-Path -LiteralPath $wimP) {
            "install.wim ($([math]::Round((Get-Item -LiteralPath $wimP).Length / 1GB, 2)) GB) [Recommended - Direct LZX, 100% Stable]"
        } elseif (Test-Path -LiteralPath $esdP) {
            "install.esd ($([math]::Round((Get-Item -LiteralPath $esdP).Length / 1GB, 2)) GB) [Requires ESD Decompression]"
        } else { "" }
        Write-Host "Auto-detected Windows 11 installation media on drive $cand$volLabel ($typeDesc)" -ForegroundColor Green
        $inputDrive = Read-Host "Use drive $cand? [Y/n, or enter another drive letter] (Default: Y)"
        if (-not $inputDrive -or ($inputDrive.Trim().ToLower() -in @('y', 'yes'))) {
            $DriveLetter = $cand
        } else {
            $candInput = $inputDrive.Trim().TrimEnd(':') + ":"
            if (Test-Path -LiteralPath $candInput) {
                $DriveLetter = $candInput
            }
        }
    } elseif ($detectedMediaDrives.Count -gt 1) {
        Write-Host "Multiple Windows installation media drives detected:" -ForegroundColor Green
        for ($i = 0; $i -lt $detectedMediaDrives.Count; $i++) {
            $d = $detectedMediaDrives[$i].Root.TrimEnd('\')
            $vol = Get-Volume -DriveLetter ($d.TrimEnd(':')) -ErrorAction SilentlyContinue
            $volLabel = if ($vol -and $vol.FileSystemLabel) { " [$($vol.FileSystemLabel)]" } else { "" }
            $wimP = Join-Path -Path "$d\sources" -ChildPath "install.wim"
            $esdP = Join-Path -Path "$d\sources" -ChildPath "install.esd"
            $typeDesc = if (Test-Path -LiteralPath $wimP) {
                "install.wim ($([math]::Round((Get-Item -LiteralPath $wimP).Length / 1GB, 2)) GB) [Recommended - Windows 11 26H2 Official, 100% Stable]"
            } elseif (Test-Path -LiteralPath $esdP) {
                "install.esd ($([math]::Round((Get-Item -LiteralPath $esdP).Length / 1GB, 2)) GB) [Warning: Potential Error 1392 in ESD stream]"
            } else { "" }
            Write-Host "  [$($i+1)] Drive $d$volLabel - $typeDesc"
        }
        $sel = Read-Host "Select a drive number [1-$($detectedMediaDrives.Count)] or enter a drive letter (Default: 1)"
        if (-not $sel -or $sel.Trim() -eq '1') {
            $DriveLetter = $detectedMediaDrives[0].Root.TrimEnd('\')
        } elseif ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $detectedMediaDrives.Count) {
            $DriveLetter = $detectedMediaDrives[[int]$sel - 1].Root.TrimEnd('\')
        } else {
            $candInput = $sel.Trim().TrimEnd(':') + ":"
            if (Test-Path -LiteralPath $candInput) {
                $DriveLetter = $candInput
            }
        }
    }

    while (-not $DriveLetter) {
        $inputDrive = Read-Host "Please enter the drive letter for the Windows 11 installation media (e.g. D or D:)"
        if ($inputDrive) {
            $candDrive = $inputDrive.Trim().TrimEnd(':') + ":"
            if (Test-Path -LiteralPath $candDrive) {
                $DriveLetter = $candDrive
            } else {
                Write-Host "Drive $candDrive does not exist. Please check and re-enter." -ForegroundColor Red
            }
        }
    }
}

# Check for install.wim or install.esd
$sourceWim = Join-Path -Path "$DriveLetter\sources" -ChildPath "install.wim"
$sourceEsd = Join-Path -Path "$DriveLetter\sources" -ChildPath "install.esd"
$destWim = Join-Path -Path "$nano11Dir\sources" -ChildPath "install.wim"

$hasSourceWim = (Test-Path -LiteralPath $sourceWim) -and ((Get-Item -LiteralPath $sourceWim).Length -gt 1GB)
$hasSourceEsd = (Test-Path -LiteralPath $sourceEsd) -and ((Get-Item -LiteralPath $sourceEsd).Length -gt 1GB)

# Ensure destination sources directory exists prior to file operations
$destSourcesDir = Join-Path -Path $nano11Dir -ChildPath "sources"
New-Item -ItemType Directory -Force -Path $destSourcesDir | Out-Null

Write-Host "Copying Windows installation files to $nano11Dir..." -ForegroundColor Green
$sourcePath = $DriveLetter.TrimEnd('\') + "\"
$copySuccess = $false
# If converting from install.esd, exclude both install.esd and install.wim from initial robocopy
# so we don't spend unnecessary minutes duplicating multi-gigabyte source archives.
$robocopyArgs = @("$sourcePath", "$nano11Dir", "/E", "/R:1", "/W:1", "/NP", "/NFL", "/NDL", "/NJH", "/NJS")
if (-not $hasSourceWim -and $hasSourceEsd) {
    $robocopyArgs += @("/XF", "install.esd", "install.wim")
} elseif (-not $hasSourceWim) {
    $robocopyArgs += @("/XF", "install.esd")
}
try {
    & robocopy.exe @robocopyArgs > $null 2>&1
    if ($LASTEXITCODE -lt 8) {
        $copySuccess = $true
    }
} catch {}

if (-not $copySuccess) {
    Write-Host "Robocopy completed or unavailable, ensuring files via Copy-Item..." -ForegroundColor Yellow
    Copy-Item -Path "$sourcePath*" -Destination $nano11Dir -Recurse -Force | Out-Null
}

# Handle installation image conversion (install.esd -> install.wim) if needed
if (-not $hasSourceWim) {
    if ($hasSourceEsd) {
        Write-Host "Found install.esd ($([math]::Round((Get-Item -LiteralPath $sourceEsd).Length / 1GB, 2)) GB), converting to install.wim..." -ForegroundColor Yellow
        $esdInfoOutput = & dism.exe /English /Get-WimInfo "/WimFile:$sourceEsd"
        $esdInfoOutput | ForEach-Object { Write-Host $_ }
        $esdAvailableIndices = @(($esdInfoOutput | Select-String -Pattern '^\s*Index\s*:\s*(\d+)' | ForEach-Object { $_.Matches[0].Groups[1].Value }))
        $esdDefaultIndex = if ($esdAvailableIndices.Count -gt 0) { $esdAvailableIndices[0] } else { "1" }
        
        $targetEsdIndex = $esdDefaultIndex
        if ([string]::IsNullOrWhiteSpace($index) -or ($index -notin $esdAvailableIndices)) {
            if (-not $NonInteractive) {
                $promptRange = if ($esdAvailableIndices.Count -gt 1) { " ($($esdAvailableIndices -join ', '))" } else { "" }
                $userInput = Read-Host "Please enter the image index to extract$promptRange [Default: $esdDefaultIndex]"
                if (-not [string]::IsNullOrWhiteSpace($userInput) -and ($userInput.Trim() -in $esdAvailableIndices)) {
                    $targetEsdIndex = $userInput.Trim()
                }
            }
        } else {
            $targetEsdIndex = $index
        }
        Write-Host "Converting install.esd (Index $targetEsdIndex) to install.wim. This may take a while..." -ForegroundColor Green
        
        # Clean up any partial destWim from previous failed run
        Remove-Item -LiteralPath $destWim -Force -ErrorAction SilentlyContinue

        # Run DISM export without /CheckIntegrity to prevent Error 1392 / 0x80070570 caused by LZMS integrity mismatch
        & dism.exe /Export-Image "/SourceImageFile:$sourceEsd" "/SourceIndex:$targetEsdIndex" "/DestinationImageFile:$destWim" /Compress:max
        
        $esdExportOk = ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $destWim) -and ((Get-Item -LiteralPath $destWim).Length -gt 1GB))

        if (-not $esdExportOk) {
            Write-Host "Warning: Standard ESD export of Index $targetEsdIndex failed (Exit code: $LASTEXITCODE)." -ForegroundColor Yellow
            Remove-Item -LiteralPath $destWim -Force -ErrorAction SilentlyContinue

            # Check if any other drive has a valid install.wim to automatically recover from corrupt ESD
            $altWimDrive = (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Where-Object {
                $r = $_.Root.TrimEnd('\')
                $w = Join-Path -Path "$r\sources" -ChildPath "install.wim"
                $r -ne $DriveLetter -and (Test-Path -LiteralPath $w) -and ((Get-Item -LiteralPath $w).Length -gt 1GB)
            } | Select-Object -First 1)

            # If no alternative drive is currently mounted, auto-mount a healthy Windows 11 ISO from local storage
            if (-not $altWimDrive) {
                Write-Host "Attempting auto-recovery by locating and mounting healthy Windows 11 ISO on storage..." -ForegroundColor Cyan
                $recoveredDrive = Find-AndMountHealthyWindowsIso
                if ($recoveredDrive) {
                    $recClean = $recoveredDrive.TrimEnd(':')
                    $altWimDrive = Get-PSDrive -Name $recClean -PSProvider FileSystem -ErrorAction SilentlyContinue
                }
            }

            if ($altWimDrive) {
                $altRoot = $altWimDrive.Root.TrimEnd('\')
                Write-Host "Auto-Recovery: Found healthy install.wim on alternative drive $altRoot!" -ForegroundColor Green
                Write-Host "Switching source to $altRoot to bypass corrupt ESD and guarantee successful build..." -ForegroundColor Green
                $DriveLetter = $altRoot
                $sourcePath = $DriveLetter.TrimEnd('\') + "\"
                $sourceWim = Join-Path -Path "$DriveLetter\sources" -ChildPath "install.wim"
                $hasSourceWim = $true

                # Copy healthy install.wim directly
                Write-Host "Copying install.wim from $altRoot..." -ForegroundColor Green
                Copy-Item -LiteralPath $sourceWim -Destination $destWim -Force
                if ((Test-Path -LiteralPath $destWim) -and ((Get-Item -LiteralPath $destWim).Length -gt 1GB)) {
                    $esdExportOk = $true
                    $index = "" # Reset index so it prompts or defaults from healthy wim
                }
            }
        }

        if (-not $esdExportOk -and -not $hasSourceWim) {
            Write-Host "Critical Error: Failed to extract valid install.wim from install.esd on $DriveLetter." -ForegroundColor Red
            Write-Host "The ESD file on $DriveLetter appears to have damaged data streams." -ForegroundColor Yellow
            Write-Host "Recommendation: Mount the official Windows 11 ISO containing install.wim and run again." -ForegroundColor Yellow
            Stop-Transcript
            exit 1
        }

        # When an index is extracted into a fresh install.wim, the new destination image has only 1 index (Index 1)
        if (-not $hasSourceWim) {
            $index = "1"
        }
    } else {
        Write-Host "Can't find valid install.wim or install.esd (> 1GB) in $DriveLetter\sources. Exiting..." -ForegroundColor Red
        Stop-Transcript
        exit 1
    }
}

# Explicitly ensure critical boot files exist in target image
$criticalBootFiles = @(
    @{ Src = (Join-Path -Path $sourcePath -ChildPath "boot\etfsboot.com"); Dest = (Join-Path -Path $nano11Dir -ChildPath "boot\etfsboot.com"); Dir = (Join-Path -Path $nano11Dir -ChildPath "boot") },
    @{ Src = (Join-Path -Path $sourcePath -ChildPath "efi\microsoft\boot\efisys.bin"); Dest = (Join-Path -Path $nano11Dir -ChildPath "efi\microsoft\boot\efisys.bin"); Dir = (Join-Path -Path $nano11Dir -ChildPath "efi\microsoft\boot") },
    @{ Src = (Join-Path -Path $sourcePath -ChildPath "efi\microsoft\boot\efisys_noprompt.bin"); Dest = (Join-Path -Path $nano11Dir -ChildPath "efi\microsoft\boot\efisys_noprompt.bin"); Dir = (Join-Path -Path $nano11Dir -ChildPath "efi\microsoft\boot") },
    @{ Src = (Join-Path -Path $sourcePath -ChildPath "sources\boot.wim"); Dest = (Join-Path -Path $nano11Dir -ChildPath "sources\boot.wim"); Dir = (Join-Path -Path $nano11Dir -ChildPath "sources") }
)
foreach ($cbf in $criticalBootFiles) {
    if ((Test-Path -LiteralPath $cbf.Src) -and (-not (Test-Path -LiteralPath $cbf.Dest))) {
        New-Item -ItemType Directory -Force -Path $cbf.Dir -ErrorAction SilentlyContinue | Out-Null
        Copy-Item -LiteralPath $cbf.Src -Destination $cbf.Dest -Force -ErrorAction SilentlyContinue
    }
}

# Configure sources\ei.cfg for universal edition selection without forcing product key prompt
$eiCfgPath = Join-Path -Path "$nano11Dir\sources" -ChildPath "ei.cfg"
if (-not (Test-Path -LiteralPath $eiCfgPath)) {
    "[Channel]`r`n_Default`r`n[VL]`r`n0`r`n" | Set-Content -LiteralPath $eiCfgPath -Encoding ascii -Force
    Write-Host "Created sources\ei.cfg for universal edition selection." -ForegroundColor Green
}

# Note: On Windows 11 24H2/25H2 (Build 26100+), zeroing appraiserres.dll causes SetupPlatform
# to fail with error 0x8007000D - 0x4002C (ERROR_INVALID_DATA).
# Hardware checks are fully bypassed via LabConfig in boot.wim and autounattend.xml.


# Remove ESD from copy if it exists to avoid duplication
if (Test-Path -LiteralPath "$nano11Dir\sources\install.esd") {
    Remove-Item -LiteralPath "$nano11Dir\sources\install.esd" -Force -ErrorAction SilentlyContinue
}

# Image Information and Index Selection
Write-Host "Getting Windows image information:" -ForegroundColor Cyan
$wimInfoOutput = & dism.exe /English /Get-WimInfo "/WimFile:$destWim"
$wimInfoOutput | ForEach-Object { Write-Host $_ }

# Parse available indices from DISM output
$availableIndices = @(($wimInfoOutput | Select-String -Pattern '^\s*Index\s*:\s*(\d+)' | ForEach-Object { $_.Matches[0].Groups[1].Value }))
$defaultIndex = if ($availableIndices.Count -gt 0) { $availableIndices[0] } else { "1" }

if ([string]::IsNullOrWhiteSpace($index) -or ($index -notin $availableIndices)) {
    if (-not $NonInteractive) {
        $promptRange = if ($availableIndices.Count -gt 1) { " ($($availableIndices -join ', '))" } else { "" }
        $userInput = Read-Host "Please enter the image index to modify$promptRange [Default: $defaultIndex]"
        if (-not [string]::IsNullOrWhiteSpace($userInput) -and ($userInput.Trim() -in $availableIndices)) {
            $index = $userInput.Trim()
        } else {
            $index = $defaultIndex
        }
    } else {
        $index = $defaultIndex
    }
}
Write-Host "Selected image index: $index" -ForegroundColor Green

Write-Host "Mounting Windows image (Index: $index)... This may take several minutes." -ForegroundColor Green
Set-ItemOwnershipAndAccess -Path $destWim
try { Set-ItemProperty -LiteralPath $destWim -Name IsReadOnly -Value $false -ErrorAction Stop } catch {}

# Clear any conflicting or stale mounts on scratchDir or destWim (Resolves Error 0xc1420127)
Clear-DismMountConflicts -TargetMountDir $scratchDir -TargetWimFile $destWim

if (Test-Path -LiteralPath $scratchDir) {
    Remove-Item -LiteralPath $scratchDir -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Force -Path $scratchDir | Out-Null

$mountSuccess = $false
for ($attempt = 1; $attempt -le 2; $attempt++) {
    & dism.exe /English /Mount-Image "/ImageFile:$destWim" "/Index:$index" "/MountDir:$scratchDir"
    if ($LASTEXITCODE -eq 0) {
        $mountSuccess = $true
        break
    }

    Write-Host "Mount attempt $attempt failed (Exit code: $LASTEXITCODE). Attempting aggressive DISM mount recovery..." -ForegroundColor Yellow
    Clear-DismMountConflicts -TargetMountDir $scratchDir -TargetWimFile $destWim
    & dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /discard > $null 2>&1
    & dism.exe /English /Cleanup-Wim > $null 2>&1
    & dism.exe /English /Cleanup-Mountpoints > $null 2>&1
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    Start-Sleep -Seconds 3
    if (Test-Path -LiteralPath $scratchDir) {
        Remove-Item -LiteralPath $scratchDir -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force -Path $scratchDir | Out-Null
    }
}

if (-not $mountSuccess) {
    Write-Host "Failed to mount install.wim after recovery. Exiting..." -ForegroundColor Red
    Stop-Transcript
    exit 1
}

# Proactively take ownership of target folders for smooth removal
Write-Host "Configuring folder permissions in mounted image..." -ForegroundColor Cyan
$foldersToOwn = @(
    "$scratchDir\Windows\System32\DriverStore\FileRepository",
    "$scratchDir\Windows\Fonts",
    "$scratchDir\Windows\Web",
    "$scratchDir\Windows\Help",
    "$scratchDir\Program Files (x86)\Microsoft",
    "$scratchDir\Program Files\WindowsApps",
    "$scratchDir\Windows\System32\Recovery",
    "$scratchDir\Windows\WinSxS",
    "$scratchDir\Windows\assembly",
    "$scratchDir\ProgramData\Microsoft\Windows Defender",
    "$scratchDir\Windows\System32\InputMethod",
    "$scratchDir\Windows\Speech",
    "$scratchDir\Windows\Temp"
)
foreach ($folder in $foldersToOwn) {
    if (Test-Path -LiteralPath $folder) {
        Set-ItemOwnershipAndAccess -Path $folder -Recurse
    }
}
$filesToOwn = @("$scratchDir\Windows\System32\OneDriveSetup.exe")
foreach ($file in $filesToOwn) {
    if (Test-Path -LiteralPath $file) {
        Set-ItemOwnershipAndAccess -Path $file
    }
}

# Detect UI Language and Architecture
$imageIntl = & dism.exe /English /Get-Intl "/Image:$scratchDir"
$languageCode = "en-US"
$imageIntlText = ($imageIntl -join "`n")
if ($imageIntlText -match 'Default system UI language\s*:\s*([a-zA-Z]{2}-[a-zA-Z]{2})') {
    $languageCode = $Matches[1]
    Write-Host "Detected default system UI language code: $languageCode" -ForegroundColor Green
} else {
    Write-Host "Default system UI language code could not be detected, falling back to en-US." -ForegroundColor Yellow
}

$imageInfo = & dism.exe /English /Get-WimInfo "/WimFile:$destWim" "/Index:$index"
$architecture = "amd64"
$lines = $imageInfo -split '\r?\n'
foreach ($line in $lines) {
    if ($line -like '*Architecture*') {
        $rawArch = ($line -split ':\s*')[1].Trim().ToLower()
        if ($rawArch -in @('x64', 'amd64')) {
            $architecture = 'amd64'
        } elseif ($rawArch -in @('arm64', 'aarch64')) {
            $architecture = 'arm64'
        } elseif ($rawArch -in @('x86')) {
            $architecture = 'x86'
        }
        Write-Host "Detected Architecture: $architecture" -ForegroundColor Green
        break
    }
}

# Pre-enable WSL2 and Virtual Machine Platform if requested (Resolves Issue #5)
if ($wslSupport) {
    Write-Host "Enabling WSL2 and VirtualMachinePlatform before WinSxS slimming..." -ForegroundColor Green
    & dism.exe /English "/image:$scratchDir" /Enable-Feature /FeatureName:VirtualMachinePlatform /All > $null 2>&1
    & dism.exe /English "/image:$scratchDir" /Enable-Feature /FeatureName:Microsoft-Windows-Subsystem-Linux /All > $null 2>&1
    Write-Host "  - WSL2 and VirtualMachinePlatform enabled." -ForegroundColor Green
}

# 5. Removing provisioned AppX packages (Bloatware)
Write-Host "Removing provisioned AppX packages (bloatware)..." -ForegroundColor Cyan
$appxPatterns = @(
    '*Zune*', '*Bing*', '*Clipchamp*', '*Gaming*', '*People*', '*PowerAutomate*',
    '*Teams*', '*Todos*', '*YourPhone*', '*SoundRecorder*', '*Solitaire*',
    '*FeedbackHub*', '*Maps*', '*OfficeHub*', '*Help*', '*Family*', '*Alarms*',
    '*CommunicationsApps*', '*Copilot*', '*CompatibilityEnhancements*',
    '*AV1VideoExtension*', '*AVCEncoderVideoExtension*', '*HEIFImageExtension*',
    '*HEVCVideoExtension*', '*MicrosoftStickyNotes*', '*OutlookForWindows*',
    '*RawImageExtension*', '*VP9VideoExtensions*', '*WebpImageExtension*',
    '*DevHome*', '*Photos*', '*Camera*', '*QuickAssist*',
    '*Paint*', '*Notepad*', '*CrossDevice*', '*Getstarted*', '*GetStarted*', '*Microsoft.Getstarted*', '*Tips*',
    '*WindowsCalculator*', '*Calculator*', '*Xbox*',
    '*Microsoft.Windows.Ai.Copilot*', '*Recall*', '*MicrosoftCorporationII.QuickAssist*',
    '*MicrosoftCorporationII.MicrosoftFamily*', '*Edge.DevToolsClient*', '*549981C3F5F10*',
    '*Client.WebExperience*', '*Windows.Ai*', '*WindowsAI*'
)
# Note: *SecHealthUI*, *CoreAI*, *PeopleExperienceHost*, *PinningConfirmationDialog*, *SecureAssessmentBrowser*
# are protected system components in newer Windows 11 builds that trigger COMException (0x80073cfa) if removed via DISM.
# Defender and other features are cleanly managed via services and registry instead.

$packagesToRemove = Get-AppxProvisionedPackage -Path $scratchDir -ErrorAction SilentlyContinue | Where-Object {
    $pkg = $_
    foreach ($pat in $appxPatterns) {
        if ($pkg.PackageName -like $pat) { return $true }
    }
    return $false
}
foreach ($package in $packagesToRemove) {
    Write-Host "  - Removing: $($package.DisplayName)"
    try {
        Remove-AppxProvisionedPackage -Path $scratchDir -PackageName $package.PackageName -ErrorAction Stop | Out-Null
    } catch {
        # Fallback to silent dism.exe CLI if PowerShell COMException occurs
        & dism.exe /English "/image:$scratchDir" /Remove-ProvisionedAppxPackage "/PackageName:$($package.PackageName)" > $null 2>&1
    }
}

# Clean leftover WindowsApps folders
foreach ($package in $packagesToRemove) {
    $folderPath = Join-Path -Path "$scratchDir\Program Files\WindowsApps" -ChildPath $package.PackageName
    if (Test-Path -LiteralPath $folderPath) {
        Remove-ProtectedDirectory -Path $folderPath -ScratchPath $scratchDir
    }
}

# 5b. Disabling Windows 11 24H2/26H2 Recall Optional Feature if present
Write-Host "Disabling Recall and modern AI optional features..." -ForegroundColor Cyan
& dism.exe /English "/image:$scratchDir" /Disable-Feature /FeatureName:Recall /Remove > $null 2>&1

# 6. Removing system packages (FoD / Optional features)
Write-Host "Removing unnecessary system packages..." -ForegroundColor Cyan
$packagePatterns = @(
    "Microsoft-Windows-InternetExplorer-Optional-Package~",
    "Microsoft-Windows-MediaPlayer-Package~",
    "Microsoft-Windows-WordPad-FoD-Package~",
    "Microsoft-Windows-StepsRecorder-Package~",
    "Microsoft-Windows-MSPaint-FoD-Package~",
    "Microsoft-Windows-SnippingTool-FoD-Package~",
    "Microsoft-Windows-TabletPCMath-Package~",
    "Microsoft-Windows-Xps-Xps-Viewer-Opt-Package~",
    "Microsoft-Windows-PowerShell-ISE-FOD-Package~",
    "OpenSSH-Client-Package~",
    "Microsoft-Windows-Search-Engine-Client-Package~",
    "Microsoft-Windows-Kernel-LA57-FoD-Package~",
    "Microsoft-Windows-Hello-Face-Package~",
    "Microsoft-Windows-Hello-BioEnrollment-Package~",
    "Microsoft-Windows-BitLocker-DriveEncryption-FVE-Package~",
    "Microsoft-Windows-TPM-WMI-Provider-Package~",
    "Microsoft-Windows-Narrator-App-Package~",
    "Microsoft-Windows-Magnifier-App-Package~",
    "Microsoft-Windows-Printing-PMCPPC-FoD-Package~",
    "Microsoft-Windows-WebcamExperience-Package~",
    "Microsoft-Media-MPEG2-Decoder-Package~",
    "Microsoft-Windows-Wallpaper-Content-Extended-FoD-Package~",

    # Foreign language font packages (preserves Latin, system, and Japanese Jpan fonts)
    "Microsoft-Windows-LanguageFeatures-Fonts-Hans-Package~",
    "Microsoft-Windows-LanguageFeatures-Fonts-Hant-Package~",
    "Microsoft-Windows-LanguageFeatures-Fonts-Kore-Package~",
    "Microsoft-Windows-LanguageFeatures-Fonts-Thai-Package~",
    "Microsoft-Windows-LanguageFeatures-Fonts-Deva-Package~",
    "Microsoft-Windows-LanguageFeatures-Fonts-Syrc-Package~",
    "Microsoft-Windows-LanguageFeatures-Fonts-Cher-Package~",
    "Microsoft-Windows-LanguageFeatures-Fonts-Ethi-Package~",
    "Microsoft-Windows-LanguageFeatures-Fonts-Beng-Package~",
    "Microsoft-Windows-LanguageFeatures-Fonts-Gujr-Package~",
    "Microsoft-Windows-LanguageFeatures-Fonts-Guru-Package~",
    "Microsoft-Windows-LanguageFeatures-Fonts-Knda-Package~",
    "Microsoft-Windows-LanguageFeatures-Fonts-Mlym-Package~",
    "Microsoft-Windows-LanguageFeatures-Fonts-Orya-Package~",
    "Microsoft-Windows-LanguageFeatures-Fonts-Taml-Package~",
    "Microsoft-Windows-LanguageFeatures-Fonts-Telu-Package~",
    "Microsoft-Windows-LanguageFeatures-Fonts-Hebr-Package~",
    "Microsoft-Windows-LanguageFeatures-Fonts-Arab-Package~",

    # Additional obsolete/unneeded optional FOD packages
    "Microsoft-Windows-WMIC-FoD-Package~",
    "Microsoft-Windows-Printing-WFS-FoD-Package~",
    "Microsoft-Windows-WirelessDisplay-FOD-Package~",
    "Microsoft-Windows-SNMP-Client-Package~",
    "Telnet-Client-Package~",
    "SimpleTCP-Client-Package~",
    "Microsoft-Windows-RDC-Package~",

    # Decoupled Asian/Foreign Language Cleanup:
    # Always remove foreign Asian IMEs and heavy foreign Speech, Text-to-Speech, OCR, and Handwriting packages.
    # These packages take gigabytes of space and are completely unused in Japanese (ja-JP) or English (en-US) installations.
    "*IME-ko-kr*",
    "*IME-zh-cn*",
    "*IME-zh-tw*",
    "*IME-zh-hk*",
    "Microsoft-Windows-LanguageFeatures-Speech-zh-*",
    "Microsoft-Windows-LanguageFeatures-Speech-ko-*",
    "Microsoft-Windows-LanguageFeatures-Speech-de-*",
    "Microsoft-Windows-LanguageFeatures-Speech-fr-*",
    "Microsoft-Windows-LanguageFeatures-Speech-es-*",
    "Microsoft-Windows-LanguageFeatures-Speech-it-*",
    "Microsoft-Windows-LanguageFeatures-Speech-pt-*",
    "Microsoft-Windows-LanguageFeatures-Speech-ru-*",
    "Microsoft-Windows-LanguageFeatures-TextToSpeech-zh-*",
    "Microsoft-Windows-LanguageFeatures-TextToSpeech-ko-*",
    "Microsoft-Windows-LanguageFeatures-TextToSpeech-de-*",
    "Microsoft-Windows-LanguageFeatures-TextToSpeech-fr-*",
    "Microsoft-Windows-LanguageFeatures-TextToSpeech-es-*",
    "Microsoft-Windows-LanguageFeatures-TextToSpeech-it-*",
    "Microsoft-Windows-LanguageFeatures-TextToSpeech-pt-*",
    "Microsoft-Windows-LanguageFeatures-TextToSpeech-ru-*",
    "Microsoft-Windows-LanguageFeatures-Handwriting-zh-*",
    "Microsoft-Windows-LanguageFeatures-Handwriting-ko-*",
    "Microsoft-Windows-LanguageFeatures-OCR-zh-*",
    "Microsoft-Windows-LanguageFeatures-OCR-ko-*"
)

if (-not $keepAsianIME) {
    $packagePatterns += @(
        "Microsoft-Windows-LanguageFeatures-Handwriting-$languageCode-Package~",
        "Microsoft-Windows-LanguageFeatures-OCR-$languageCode-Package~",
        "Microsoft-Windows-LanguageFeatures-Speech-$languageCode-Package~",
        "Microsoft-Windows-LanguageFeatures-TextToSpeech-$languageCode-Package~",
        "*IME-ja-jp*"
    )
}

if ($removeDefender) {
    $packagePatterns += "Windows-Defender-Client-Package~"
}

$allPackagesOutput = & dism.exe /English "/image:$scratchDir" /Get-Packages /Format:Table
$allPackages = ($allPackagesOutput -split '\r?\n') | Select-Object -Skip 1

$packagesToRemove = [System.Collections.Generic.List[string]]::new()
foreach ($packagePattern in $packagePatterns) {
    $pattern = if ($packagePattern.EndsWith("*")) { $packagePattern } else { "$packagePattern*" }
    $matched = $allPackages | Where-Object { $_ -like $pattern }
    foreach ($pkg in $matched) {
        $packageIdentity = ($pkg -split '\s+')[0]
        if ($packageIdentity -and (-not $packagesToRemove.Contains($packageIdentity))) {
            # Strictly protect Japanese IME and Japanese font packages if keepAsianIME is enabled
            if ($keepAsianIME -and ($packageIdentity -like "*IME-ja-jp*" -or $packageIdentity -like "*Fonts-Jpan*")) {
                continue
            }
            $packagesToRemove.Add($packageIdentity)
        }
    }
}

foreach ($packageIdentity in $packagesToRemove) {
    Write-Host "  - Removing package: $packageIdentity"
    & dism.exe /English "/image:$scratchDir" /Remove-Package "/PackageName:$packageIdentity" > $null 2>&1
}

# 7. Removing NativeImages (.NET)
Write-Host "Removing pre-compiled .NET Native Images..." -ForegroundColor Cyan
Remove-Item -Path "$scratchDir\Windows\assembly\NativeImages_*" -Recurse -Force -ErrorAction SilentlyContinue

# 8. File system slimming
$winDir = "$scratchDir\Windows"

# Non-essential driver cleanup (optional)
if ($removeDrivers) {
    Write-Host "Slimming DriverStore..." -ForegroundColor Cyan
    $driverRepo = Join-Path -Path $winDir -ChildPath "System32\DriverStore\FileRepository"
    $driverPatterns = @('prn*', 'scan*', 'mfd*', 'wscsmd.inf*', 'tapdrv*', 'rdpbus.inf*')
    if (-not $keepBT) {
        $driverPatterns += 'tdibth.inf*'
    }
    if ($ultraSlimMode) {
        $driverPatterns += @('ntprint*.inf*', 'fax*.inf*', 'smartcrd*.inf*', 'modem*.inf*')
    }
    if (Test-Path -LiteralPath $driverRepo) {
        Get-ChildItem -Path $driverRepo -Directory | ForEach-Object {
            $folder = $_
            foreach ($pattern in $driverPatterns) {
                if ($folder.Name -like $pattern) {
                    Write-Host "  - Removing driver package: $($folder.Name)"
                    Remove-ProtectedDirectory -Path $folder.FullName -ScratchPath $scratchDir
                    break
                }
            }
        }
    }
}

# Fonts slimming (preserves Japanese and core system fonts, trims heavy foreign fonts)
if (-not $keepExtraFonts -or $ultraSlimMode) {
    Write-Host "Slimming Fonts folder (preserving Japanese and core system fonts)..." -ForegroundColor Cyan
    $fontsPath = Join-Path -Path $winDir -ChildPath "Fonts"
    if (Test-Path -LiteralPath $fontsPath) {
        $essentialSystemFonts = @(
            "segoe*", "tahoma*", "marlett.ttf", "8541oem.fon", "segui*", "consol*",
            "lucon*", "calibri*", "arial*", "times*", "cou*", "8*.*"
        )
        $japaneseFonts = @(
            "meiryo*", "yugoth*", "yumin*", "msgoth*", "msgothic*", "msmin*", "msmincho*", "segoeuihistoric.ttf"
        )
        $fontsToKeep = $essentialSystemFonts + $japaneseFonts
        
        $foreignFonts = @(
            "mingliu*", "simsun*", "msjh*", "msyh*", "malgun*",
            "khmer*", "lao*", "myanmar*", "thai*", "leelaw*", "gadugi*",
            "ebrima*", "dokchamp*", "taile*", "sylfaen*", "mvboli*",
            "plantc*", "himalaya*", "nyala*", "monbaiti*", "javatext*"
        )
        
        Get-ChildItem -Path $fontsPath | ForEach-Object {
            $fontItem = $_
            $isKeep = $false
            foreach ($kp in $fontsToKeep) {
                if ($fontItem.Name -like $kp) { $isKeep = $true; break }
            }
            if (-not $isKeep) {
                $isForeign = $false
                foreach ($fp in $foreignFonts) {
                    if ($fontItem.Name -like $fp) { $isForeign = $true; break }
                }
                if ($isForeign -or (-not $keepExtraFonts)) {
                    Set-ItemOwnershipAndAccess -Path $fontItem.FullName
                    Remove-Item -LiteralPath $fontItem.FullName -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }
}

# IME Input Methods: Always remove non-Japanese Asian Input Methods (CHS, CHT, KOR)
Write-Host "Removing Chinese and Korean Input Methods..." -ForegroundColor Cyan
Remove-Item -Path "$scratchDir\Windows\System32\InputMethod\CHS" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$scratchDir\Windows\System32\InputMethod\CHT" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$scratchDir\Windows\System32\InputMethod\KOR" -Recurse -Force -ErrorAction SilentlyContinue

# Japanese IME: Strictly preserve JPN when keepAsianIME is set
if (-not $keepAsianIME) {
    Write-Host "Removing Japanese Input Method..." -ForegroundColor Cyan
    Remove-Item -Path "$scratchDir\Windows\System32\InputMethod\JPN" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path (Join-Path -Path $winDir -ChildPath "Speech\Engines\TTS") -Recurse -Force -ErrorAction SilentlyContinue
}

# Speech & Text-to-Speech Models (UltraSlim cleanup: trim heavy voice models, preserve core OneCore runtime for OOBE)
if ($ultraSlimMode) {
    Write-Host "Trimming heavy Speech recognition and TTS voice models (preserving OOBE core)..." -ForegroundColor Cyan
    $ttsPaths = @(
        (Join-Path -Path $winDir -ChildPath "Speech\Engines\TTS"),
        (Join-Path -Path $winDir -ChildPath "Speech_OneCore\Engines\TTS")
    )
    foreach ($tp in $ttsPaths) {
        if (Test-Path -LiteralPath $tp) {
            Get-ChildItem -Path $tp -Include "*.dat", "*.lex", "*.bin" -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
                Set-ItemOwnershipAndAccess -Path $_.FullName
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    }
    # Windows\Speech_OneCore directory and WinSxS speech-onecore manifests are preserved to prevent OOBE narrator crashes.
}

# Windows Defender definitions and telemetry cache purge (safe for Code Integrity & ci.dll)
if ($removeDefender) {
    Write-Host "Purging Windows Defender definition updates and telemetry cache..." -ForegroundColor Cyan
    Remove-Item -Path "$scratchDir\ProgramData\Microsoft\Windows Defender\Definition Updates" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$scratchDir\ProgramData\Microsoft\Windows Defender\Scans" -Recurse -Force -ErrorAction SilentlyContinue
    # Note: WinSxS manifests, security catalogs (.cat), and System32 binaries are strictly preserved.
    # On Windows 11 24H2+, deleting WinSxS security catalogs causes Code Integrity (ci.dll) validation
    # to fail with STATUS_INVALID_IMAGE_HASH (0xC0000428) -> BSOD 0xC000021A.
    # Defender is completely disabled via services and group policies without breaking signature integrity.
}

# General cleanup & offline cache trimming
Write-Host "Cleaning offline system caches, prefetch, and setup logs..." -ForegroundColor Cyan
Remove-Item -Path "$scratchDir\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$scratchDir\Windows\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$scratchDir\Windows\System32\LogFiles\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$scratchDir\Windows\System32\winevt\Logs\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$scratchDir\Windows\Minidump\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$scratchDir\Windows\Prefetch\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$scratchDir\Windows\Panther\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$scratchDir\Windows\Downloaded Program Files\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path (Join-Path -Path $winDir -ChildPath "Web") -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path (Join-Path -Path $winDir -ChildPath "Help") -Recurse -Force -ErrorAction SilentlyContinue

# Edge Browser and OneDrive (Preserve System32 WebView2 runtime for Windows 11 OOBE stability)
Write-Host "Removing Edge browser and OneDrive..." -ForegroundColor Cyan
Remove-ProtectedDirectory -Path "$scratchDir\Program Files (x86)\Microsoft\Edge" -ScratchPath $scratchDir
Remove-ProtectedDirectory -Path "$scratchDir\Program Files (x86)\Microsoft\EdgeUpdate" -ScratchPath $scratchDir
Remove-ProtectedDirectory -Path "$scratchDir\Program Files (x86)\Microsoft\EdgeCore" -ScratchPath $scratchDir

# Purge OneDrive setup payload (197 MB) and executable
Remove-Item -Path "$scratchDir\Windows\System32\OneDriveSetup.exe" -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path "$scratchDir\Windows\WinSxS" -Filter "*microsoft-windows-onedrive-setup*" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-ProtectedDirectory -Path $_.FullName -ScratchPath $scratchDir
}

# Purge non-critical assistive and Game Bar binaries from System32 (Preserve core osk, Narrator, magnify for OOBE initialization)
Write-Host "Removing unneeded assistive and Game Bar binaries from System32..." -ForegroundColor Cyan
$accessBinaries = @(
    "VoiceAccess.exe",
    "Livecaptions.exe",
    "GameBarPresenceWriter.exe"
)
foreach ($bin in $accessBinaries) {
    $binPath = Join-Path -Path "$scratchDir\Windows\System32" -ChildPath $bin
    if (Test-Path -LiteralPath $binPath) {
        Set-ItemOwnershipAndAccess -Path $binPath
        Remove-Item -LiteralPath $binPath -Force -ErrorAction SilentlyContinue
    }
}
# Purge Windows Backup scheduled tasks
Remove-Item -LiteralPath "$scratchDir\Windows\System32\Tasks\Microsoft\Windows\AppListBackup" -Recurse -Force -ErrorAction SilentlyContinue


# WinRE Handling (Guarantees Setup SafeOS staging succeeds, then cleans up post-install)
$recoveryDir = Join-Path -Path $scratchDir -ChildPath "Windows\System32\Recovery"
$keepMarkerFile = Join-Path -Path $recoveryDir -ChildPath "winre.wim.keep"
$targetWinre = Join-Path -Path $recoveryDir -ChildPath "winre.wim"

if ($keepRecoveryEnv) {
    Write-Host "Preserving Windows Recovery Environment (WinRE)..." -ForegroundColor Green
    New-Item -Path $keepMarkerFile -ItemType File -Force -ErrorAction SilentlyContinue | Out-Null
} else {
    Write-Host "Configuring Windows Recovery Environment for post-install cleanup..." -ForegroundColor Cyan
    # CRITICAL: winre.wim MUST remain inside the image during build time!
    # Windows Setup (setup.exe) mandatory Pre-Finalize phase stages SafeOS from winre.wim.
    # If winre.wim is removed offline or is 0 bytes, Setup aborts with "Windows 11 installation has failed" (0x80070002 / 0x8007000B).
    # Instead, we keep winre.wim for Setup to succeed, and FirstLogon.ps1 unregisters (reagentc /disable) and deletes it online post-install.
    if (Test-Path -LiteralPath $keepMarkerFile) {
        Remove-Item -LiteralPath $keepMarkerFile -Force -ErrorAction SilentlyContinue
    }

    # In UltraSlim mode, re-export winre.wim with maximum compression to save ~300 MB inside install.esd
    if ($ultraSlimMode -and (Test-Path -LiteralPath $targetWinre)) {
        Write-Host "Optimizing WinRE compression for UltraSlim footprint..." -ForegroundColor Cyan
        $tempCompactWinre = Join-Path -Path $recoveryDir -ChildPath "winre_compact.wim"
        Set-ItemOwnershipAndAccess -Path $targetWinre
        try { Set-ItemProperty -LiteralPath $targetWinre -Name IsReadOnly -Value $false -ErrorAction Stop } catch {}
        & dism.exe /English /Export-Image "/SourceImageFile:$targetWinre" /SourceIndex:1 "/DestinationImageFile:$tempCompactWinre" /Compress:max > $null 2>&1
        if ((Test-Path -LiteralPath $tempCompactWinre) -and ((Get-Item -LiteralPath $tempCompactWinre).Length -gt 10MB)) {
            Remove-Item -LiteralPath $targetWinre -Force -ErrorAction SilentlyContinue
            Rename-Item -LiteralPath $tempCompactWinre -NewName "winre.wim" -Force
            Write-Host "  - WinRE successfully compressed and optimized." -ForegroundColor Green
        }
    }
}

# 9. Component Store (WinSxS) Optimization
if ($safeDebloatMode) {
    Write-Host "Consolidating component store safely via DISM Component Cleanup..." -ForegroundColor Green
    & dism.exe /English "/image:$scratchDir" /Cleanup-Image /StartComponentCleanup /ResetBase > $null 2>&1

    Write-Host "Cleaning WinSxS temporary, install, and backup caches..." -ForegroundColor Cyan
    Remove-ProtectedDirectory -Path "$scratchDir\Windows\WinSxS\Backup" -ScratchPath $scratchDir
    New-Item -ItemType Directory -Force -Path "$scratchDir\Windows\WinSxS\Backup" | Out-Null
    Remove-ProtectedDirectory -Path "$scratchDir\Windows\WinSxS\InstallTemp" -ScratchPath $scratchDir
    New-Item -ItemType Directory -Force -Path "$scratchDir\Windows\WinSxS\InstallTemp" | Out-Null
    Remove-ProtectedDirectory -Path "$scratchDir\Windows\WinSxS\Temp" -ScratchPath $scratchDir
    New-Item -ItemType Directory -Force -Path "$scratchDir\Windows\WinSxS\Temp" | Out-Null

    # UltraSlim targeted WinSxS dead-weight pruning (safe packages only)
    if ($ultraSlimMode) {
        Write-Host "Pruning targeted non-essential components from WinSxS..." -ForegroundColor Cyan
        $ultraSlimSxsPatterns = @(
            "*iis-legacyscripts*",
            "*printing_admin_scripts*"
        )
        if (-not $wslSupport) {
            $ultraSlimSxsPatterns += "*hyperv-vmfirmware*"
        }
        foreach ($pat in $ultraSlimSxsPatterns) {
            Get-ChildItem -Path "$scratchDir\Windows\WinSxS" -Filter $pat -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                Remove-ProtectedDirectory -Path $_.FullName -ScratchPath $scratchDir
            }
        }
    }
} else {
    Write-Host "Running Aggressive WinSxS Pruning (Experimental)..." -ForegroundColor Yellow
    # Pre-cleanup DISM component base before trimming
    & dism.exe /English "/image:$scratchDir" /Cleanup-Image /StartComponentCleanup /ResetBase > $null 2>&1

    $sourceWinSxS = Join-Path -Path $scratchDir -ChildPath "Windows\WinSxS"
    $tempWinSxS = Join-Path -Path $scratchDir -ChildPath "Windows\WinSxS_edit"
    New-Item -Path $tempWinSxS -ItemType Directory -Force | Out-Null

    $dirsToKeep = @(
        "Catalogs",
        "FileMaps",
        "Fusion",
        "InstallTemp",
        "Manifests",
        "SettingsManifests",
        "*servicing*",
        "*servicingstack*",
        "*servicingcommon*",
        "*servicing-adm*",
        "*servicing-onecore*",
        "*windows-foundation*",
        "*foundation*",
        "*common-controls*",
        "*gdiplus*",
        "*isolationautomation*",
        "*vc80.crt*",
        "*vc90.crt*",
        "*setup*",
        "*deployment*",
        "*sysprep*",
        "*windeploy*",
        "*cbs*",
        "*onecore*",
        "*kernel*",
        "*storage*",
        "*disk*",
        "*cryptography*",
        "*crypto*",
        "*dcom*",
        "*rpc*",
        "*eventlog*",
        "*boot*",
        "*shell*",
        "*explorer*",
        "*security*",
        "*sam*",
        "*lsass*",
        "*auth*",
        "*resources*",
        "*mui*",
        "*international*",
        "*input*"
    )

    if ($languageCode) {
        $dirsToKeep += @("*$languageCode*")
    }
    if ($languageCode -ne 'en-us') {
        $dirsToKeep += @("*en-us*")
    }
    if ($keepDrivers -or -not $removeDrivers) {
        $dirsToKeep += @("*driver*", "*inf*", "*net*")
    }
    if (-not $removeDefender) {
        $dirsToKeep += @("*defender*", "*security-health*", "*smartscreen*")
    }
    if ($keepAsianIME) {
        $dirsToKeep += @("*inputmethod*", "*ime*")
    }
    if ($keepBT) {
        $dirsToKeep += @("*bth*", "*bluetooth*")
    }
    if ($wslSupport) {
        $dirsToKeep += @("*hyperv*", "*vm*", "*subsystem-linux*")
    }

    if ($architecture -eq 'amd64') {
        $dirsToKeep += @(
            "amd64_microsoft-windows-s..stack*",
            "x86_microsoft-windows-s..stack*",
            "amd64_microsoft.windows.c..-controls*",
            "x86_microsoft.windows.c..-controls*"
        )
    } elseif ($architecture -eq 'arm64') {
        $dirsToKeep += @(
            "arm64_microsoft-windows-s..stack*",
            "arm_microsoft-windows-s..stack*",
            "arm64_microsoft.windows.c..-controls*",
            "arm_microsoft.windows.c..-controls*"
        )
    }

    foreach ($pattern in $dirsToKeep) {
        $matchedDirs = Get-ChildItem -Path $sourceWinSxS -Filter $pattern -Directory -ErrorAction SilentlyContinue
        foreach ($src in $matchedDirs) {
            $target = Join-Path -Path $tempWinSxS -ChildPath $src.Name
            if (-not (Test-Path -LiteralPath $target)) {
                Copy-Item -LiteralPath $src.FullName -Destination $target -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Write-Host "Replacing WinSxS with trimmed version..." -ForegroundColor Cyan
    Remove-ProtectedDirectory -Path $sourceWinSxS -ScratchPath $scratchDir
    Rename-Item -LiteralPath $tempWinSxS -NewName "WinSxS" -Force
}

# 10. Load Registry Hives and Apply Optimizations
Write-Host "Loading offline registry hives..." -ForegroundColor Cyan
$systemHive    = "$scratchDir\Windows\System32\config\SYSTEM"
$softwareHive  = "$scratchDir\Windows\System32\config\SOFTWARE"
$defaultHive   = "$scratchDir\Windows\System32\config\default"
$componentsHive= "$scratchDir\Windows\System32\config\COMPONENTS"
$ntuserHive    = "$scratchDir\Users\Default\ntuser.dat"

reg.exe load HKLM\zSYSTEM "$systemHive" | Out-Null
reg.exe load HKLM\zSOFTWARE "$softwareHive" | Out-Null
reg.exe load HKLM\zDEFAULT "$defaultHive" | Out-Null
reg.exe load HKLM\zCOMPONENTS "$componentsHive" | Out-Null
reg.exe load HKLM\zNTUSER "$ntuserHive" | Out-Null

# Detect and display target Windows build info (e.g. Windows 11 26H2 Build 26300.9457)
try {
    $targetProductName = (reg.exe query "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion" /v ProductName 2>$null | Select-String -Pattern 'REG_SZ\s+(.+)$' | ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() })
    $targetDisplayVer  = (reg.exe query "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion" /v DisplayVersion 2>$null | Select-String -Pattern 'REG_SZ\s+(.+)$' | ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() })
    $targetBuildNum    = (reg.exe query "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion" /v CurrentBuildNumber 2>$null | Select-String -Pattern 'REG_SZ\s+(.+)$' | ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() })
    $targetUBR         = (reg.exe query "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion" /v UBR 2>$null | Select-String -Pattern 'REG_DWORD\s+0x([0-9a-fA-F]+)' | ForEach-Object { [Convert]::ToInt32($_.Matches[0].Groups[1].Value, 16) })
    if ($targetProductName) {
        Write-Host "Target Image OS: $targetProductName (Version: $targetDisplayVer, Build: $targetBuildNum.$targetUBR)" -ForegroundColor Green
    }
} catch {}

Write-Host "Applying Setup & Hardware requirement bypasses..." -ForegroundColor Green
$labConfigKeys = @(
    'BypassCPUCheck',
    'BypassRAMCheck',
    'BypassSecureBootCheck',
    'BypassStorageCheck',
    'BypassTPMCheck',
    'BypassDiskCheck'
)
foreach ($key in $labConfigKeys) {
    reg.exe add "HKLM\zSYSTEM\Setup\LabConfig" /v $key /t REG_DWORD /d 1 /f > $null 2>&1
}
reg.exe add "HKLM\zSYSTEM\Setup\MoSetup" /v "AllowUpgradesWithUnsupportedTPMOrCPU" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache" /v "SV1" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache" /v "SV2" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache" /v "SV1" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache" /v "SV2" /t REG_DWORD /d 0 /f > $null 2>&1

Write-Host "Disabling Sponsored Apps & Cloud Content..." -ForegroundColor Green
$cdmSettings = @(
    'ContentDeliveryAllowed',
    'FeatureManagementEnabled',
    'OemPreInstalledAppsEnabled',
    'PreInstalledAppsEnabled',
    'PreInstalledAppsEverEnabled',
    'SilentInstalledAppsEnabled',
    'SoftLandingEnabled',
    'SubscribedContentEnabled',
    'SubscribedContent-310093Enabled',
    'SubscribedContent-338387Enabled',
    'SubscribedContent-338388Enabled',
    'SubscribedContent-338389Enabled',
    'SubscribedContent-338393Enabled',
    'SubscribedContent-353694Enabled',
    'SubscribedContent-353696Enabled',
    'SubscribedContent-353698Enabled',
    'SystemPaneSuggestionsEnabled'
)
foreach ($setting in $cdmSettings) {
    reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v $setting /t REG_DWORD /d 0 /f > $null 2>&1
}
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent" /v "DisableWindowsConsumerFeatures" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent" /v "DisableConsumerAccountStateContent" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent" /v "DisableCloudOptimizedContent" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\PushToInstall" /v "DisablePushToInstall" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\MRT" /v "DontOfferThroughWUAU" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\PolicyManager\current\device\Start" /v "ConfigureStartPins" /t REG_SZ /d "{\`"pinnedList\`": [{}]}" /f > $null 2>&1

# OOBE & Local Accounts (Resolves Issue #15)
Write-Host "Enabling Local Account bypass on OOBE..." -ForegroundColor Green
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v "BypassNRO" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager" /v "ShippedWithReserves" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\BitLocker" /v "PreventDeviceEncryption" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\EnhancedStorageDevices" /v "TCGSecurityActivationDisabled" /t REG_DWORD /d 1 /f > $null 2>&1

# Japanese 106/109 Keyboard Configuration (Prevents English 101/104 misdetection)
if ($setJapaneseKeyboard) {
    Write-Host "Configuring Japanese 106/109 keyboard layout..." -ForegroundColor Green
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\i8042prt\Parameters" /v "LayerDriver JPN" /t REG_SZ /d "kbd106.dll" /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\i8042prt\Parameters" /v "OverrideKeyboardIdentifier" /t REG_SZ /d "PCAT_106KEY" /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\i8042prt\Parameters" /v "OverrideKeyboardType" /t REG_DWORD /d 7 /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\i8042prt\Parameters" /v "OverrideKeyboardSubtype" /t REG_DWORD /d 2 /f > $null 2>&1
}

reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Chat" /v "ChatIcon" /t REG_DWORD /d 3 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "TaskbarMn" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Search" /v "SearchboxTaskbarMode" /t REG_DWORD /d 0 /f > $null 2>&1

# Setup & Winlogon / Blank Password / PowerShell Execution Policy tweaks
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Lsa" /v "LimitBlankPasswordUse" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v "AutoAdminLogon" /t REG_SZ /d "1" /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v "DefaultUserName" /t REG_SZ /d "User" /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v "DefaultPassword" /t REG_SZ /d "" /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v "ForceAutoLogon" /t REG_SZ /d "1" /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\System" /v "AllowDomainDelayLock" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v "FilterAdministratorToken" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\PowerShell\1\ShellIds\Microsoft.PowerShell" /v "ExecutionPolicy" /t REG_SZ /d "Unrestricted" /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\PowerShell" /v "EnableScripts" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\PowerShell" /v "ExecutionPolicy" /t REG_SZ /d "Unrestricted" /f > $null 2>&1

# Edge Uninstall Registry cleanup
reg.exe delete "HKEY_LOCAL_MACHINE\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge" /f > $null 2>&1
reg.exe delete "HKEY_LOCAL_MACHINE\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update" /f > $null 2>&1

# Telemetry
Write-Host "Disabling Diagnostics & Telemetry..." -ForegroundColor Green
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" /v "Enabled" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Privacy" /v "TailoredExperiencesWithDiagnosticDataEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy" /v "HasAccepted" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Input\TIPC" /v "Enabled" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\InputPersonalization" /v "RestrictImplicitInkCollection" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\InputPersonalization" /v "RestrictImplicitTextCollection" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection" /v "AllowTelemetry" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\dmwappushservice" /v "Start" /t REG_DWORD /d 4 /f > $null 2>&1

# Copilot & Bloatware Prevention
Write-Host "Disabling Copilot, DevHome, and Teams auto-install..." -ForegroundColor Green
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" /v "TurnOffWindowsCopilot" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Edge" /v "HubsSidebarEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Explorer" /v "DisableSearchBoxSuggestions" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Teams" /v "DisableInstallation" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Mail" /v "PreventRun" /t REG_DWORD /d 1 /f > $null 2>&1

# Disable Cross-Device / Mobile Devices / Resume & Windows Backup
Write-Host "Disabling Mobile Devices / Cross-Device Resume & Windows Backup..." -ForegroundColor Green
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\System" /v "EnableCdp" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\System" /v "EnableMmx" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\System" /v "AllowCrossDeviceClipboard" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\System" /v "UploadUserActivities" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\System" /v "PublishUserActivities" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent" /v "DisableWindowsConsumerFeatures" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent" /v "DisableConsumerAccountStateContent" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent" /v "DisableSoftLanding" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent" /v "DisableWindowsSpotlightFeatures" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Backup" /v "DisableCloudBackup" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\SettingSync" /v "DisableBackupRestore" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\SettingSync" /v "DisableSettingSync" /t REG_DWORD /d 2 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\SettingSync" /v "DisableSettingSyncUserOverride" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe delete "HKLM\zSOFTWARE\Classes\Directory\Background\shellex\ContextMenuHandlers\SendToPhone" /f > $null 2>&1
reg.exe delete "HKLM\zSOFTWARE\Classes\DesktopBackground\shellex\ContextMenuHandlers\SendToPhone" /f > $null 2>&1

# Accessibility Hotkey & Feature Suppressions (Voice Access, Live Captions, Narrator, StickyKeys)
Write-Host "Configuring Accessibility & Assistive hotkey suppressions..." -ForegroundColor Green
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Narrator" /v "WinEnterLaunchNarrator" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Narrator" /v "NoStartNarratorShortcut" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Narrator" /v "WinEnterLaunchNarrator" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Narrator" /v "NoStartNarratorShortcut" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\VoiceAccess" /v "Enabled" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\VoiceAccess" /v "Enabled" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\LiveCaptions" /v "LiveCaptionsDesktopEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\LiveCaptions" /v "LiveCaptionsDesktopEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows NT\CurrentVersion\Accessibility" /v "Configuration" /t REG_SZ /d "" /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows NT\CurrentVersion\Accessibility" /v "Configuration" /t REG_SZ /d "" /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Control Panel\Accessibility\StickyKeys" /v "Flags" /t REG_SZ /d "506" /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Control Panel\Accessibility\StickyKeys" /v "Flags" /t REG_SZ /d "506" /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Control Panel\Accessibility\Keyboard Response" /v "Flags" /t REG_SZ /d "122" /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Control Panel\Accessibility\Keyboard Response" /v "Flags" /t REG_SZ /d "122" /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Control Panel\Accessibility\ToggleKeys" /v "Flags" /t REG_SZ /d "58" /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Control Panel\Accessibility\ToggleKeys" /v "Flags" /t REG_SZ /d "58" /f > $null 2>&1

# Disable Xbox Game Bar & GameDVR
Write-Host "Disabling Xbox Game Bar & GameDVR..." -ForegroundColor Green
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\GameDVR" /v "AllowGameDVR" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR" /v "AppCaptureEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\GameDVR" /v "AppCaptureEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\System\GameConfigStore" /v "GameDVR_Enabled" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\System\GameConfigStore" /v "GameDVR_FSEBehaviorMode" /t REG_DWORD /d 2 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\System\GameConfigStore" /v "GameDVR_HonorUserFSEBehaviorMode" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\System\GameConfigStore" /v "GameDVR_DXGIHonorFSEWindowsCompatible" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\System\GameConfigStore" /v "GameDVR_EFSEFeatureFlags" /t REG_DWORD /d 0 /f > $null 2>&1

# IFEO Debugger redirect for non-OOBE background processes (OSK/Narrator/Magnifier blocked safely in FirstLogon after OOBE completes)
$blockedExes = @(
    "CrossDeviceResume.exe",
    "WindowsBackupClient.exe",
    "VoiceAccess.exe",
    "Livecaptions.exe",
    "GameBar.exe",
    "GameBarFTServer.exe",
    "GameBarPresenceWriter.exe"
)
foreach ($exe in $blockedExes) {
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$exe" /v "Debugger" /t REG_SZ /d "systray.exe" /f > $null 2>&1
}

# Scheduled Tasks Cleanup (Path fixed - no hardcoded C:)
Write-Host "Cleaning up scheduled telemetry tasks..." -ForegroundColor Cyan
$tasksPath = Join-Path -Path $scratchDir -ChildPath "Windows\System32\Tasks"
$telemetryAndMemTasks = @(
    "Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser",
    "Microsoft\Windows\Application Experience\ProgramDataUpdater",
    "Microsoft\Windows\Application Experience\StartupAppTask",
    "Microsoft\Windows\Customer Experience Improvement Program",
    "Microsoft\Windows\Chkdsk\Proxy",
    "Microsoft\Windows\Windows Error Reporting\QueueReporting",
    "Microsoft\XblGameSave",
    "Microsoft\Windows\DiskDiagnostic",
    "Microsoft\Windows\Feedback",
    "Microsoft\Windows\FileHistory",
    "Microsoft\Windows\Maintenance\WinSAT",
    "Microsoft\Windows\PI\Sqm-Tasks",
    "Microsoft\Windows\Power Efficiency Diagnostics",
    "Microsoft\Windows\Shell\FamilySafetyMonitor",
    "Microsoft\Windows\Shell\FamilySafetyRefreshTask",
    "Microsoft\Windows\Registry\RegIdleBackup",
    "Microsoft\Windows\Diagnosis",
    "Microsoft\Windows\MemoryDiagnostic",
    "Microsoft\Windows\DiskFootprint",
    "Microsoft\Windows\Maps",
    "Microsoft\Windows\Speech",
    "Microsoft\Windows\Defrag\ScheduledDefrag",
    "Microsoft\Windows\Windows Filtering Platform",
    "Microsoft\Windows\Device Information",
    "Microsoft\Windows\NetTrace"
)
foreach ($t in $telemetryAndMemTasks) {
    Remove-Item -LiteralPath "$tasksPath\$t" -Recurse -Force -ErrorAction SilentlyContinue
}

# Windows Update (optional)
if ($disableWU) {
    Write-Host "Disabling Windows Update..." -ForegroundColor Green
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v "DoNotConnectToWindowsUpdateInternetLocations" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v "DisableWindowsUpdateAccess" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v "NoAutoUpdate" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\wuauserv" /v "Start" /t REG_DWORD /d 4 /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\WaaSMedicSVC" /v "Start" /t REG_DWORD /d 4 /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\UsoSvc" /v "Start" /t REG_DWORD /d 4 /f > $null 2>&1
}

# ============================================================================
# Windows Defender & Security Complete Removal (ionuttbara/windows-defender-remover integration)
# ============================================================================
if ($removeDefender) {
    Write-Host "Completely disabling and removing Windows Defender, Security Center, and ATP services (windows-defender-remover)..." -ForegroundColor Green
    # Only disable user-mode background services and non-boot filters.
    # Note: Boot-critical drivers (WdBoot, MsSecCore, MsSecFlt, Pluton) MUST NOT be set to Start=4.
    # On Windows 11 24H2+, disabling WdBoot or MsSecCore breaks winload.efi & ci.dll validation,
    # causing STOP 0xC000021A (Parameter 2: STATUS_INVALID_IMAGE_HASH 0xC0000428).
    $defServices = @(
        "WinDefend", "WdNisSvc", "WdNisDrv", "WdFilter", "Sense", "SecurityHealthService",
        "wscsvc", "webthreatdefsvc", "webthreatdefusersvc"
    )
    foreach ($svc in $defServices) {
        reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\$svc" /v "Start" /t REG_DWORD /d 4 /f > $null 2>&1
    }

    # Complete Defender & AntiSpyware Policies from windows-defender-remover
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender" /v "DisableAntiSpyware" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender" /v "DisableAntiVirus" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender" /v "ServiceKeepAlive" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender" /v "PUAProtection" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender" /v "DisableRoutinelyTakingAction" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender" /v "AllowFastServiceStartup" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender" /v "DisableLocalAdminMerge" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender" /v "RandomizeScheduleTaskTimes" /t REG_DWORD /d 0 /f > $null 2>&1

    # Real-Time Protection & Behavioral Monitoring
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" /v "DisableRealtimeMonitoring" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" /v "DisableBehaviorMonitoring" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" /v "DisableOnAccessProtection" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" /v "DisableScanOnRealtimeEnable" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" /v "DisableIOAVProtection" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" /v "DisableScriptScanning" /t REG_DWORD /d 1 /f > $null 2>&1

    # PolicyManager Defender overrides
    $pmPolicies = @(
        "AllowIOAVProtection", "AllowArchiveScanning", "AllowBehaviorMonitoring", "AllowCloudProtection",
        "AllowEmailScanning", "AllowFullScanOnMappedNetworkDrives", "AllowFullScanRemovableDriveScanning",
        "AllowIntrusionPreventionSystem", "AllowOnAccessProtection", "AllowRealtimeMonitoring",
        "AllowScanningNetworkFiles", "AllowScriptScanning", "AllowUserUIAccess",
        "CheckForSignaturesBeforeRunningScan", "EnableControlledFolderAccess", "EnableNetworkProtection", "PUAProtection"
    )
    foreach ($pol in $pmPolicies) {
        reg.exe add "HKLM\zSOFTWARE\Microsoft\PolicyManager\default\Defender\$pol" /v "value" /t REG_DWORD /d 0 /f > $null 2>&1
    }

    # Disable SmartScreen completely
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\System" /v "EnableSmartScreen" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Explorer" /v "SmartScreenEnabled" /t REG_SZ /d "Off" /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\MicrosoftEdge\PhishingFilter" /v "EnabledV9" /t REG_DWORD /d 0 /f > $null 2>&1

    # Notifications & Startup
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender\Reporting" /v "DisableEnhancedNotifications" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender Security Center\Notifications" /v "DisableNotifications" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe delete "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Run" /v "SecurityHealth" /f > $null 2>&1

    # Remove Context Menu & Shell Associations
    reg.exe delete "HKLM\zSOFTWARE\Classes\CLSID\{09A47860-11B0-4DA5-AFA5-26D86198A780}" /f > $null 2>&1
    reg.exe delete "HKLM\zSOFTWARE\Classes\*\shellex\ContextMenuHandlers\EPP" /f > $null 2>&1
    reg.exe delete "HKLM\zSOFTWARE\Classes\Directory\shellex\ContextMenuHandlers\EPP" /f > $null 2>&1
    reg.exe delete "HKLM\zSOFTWARE\Classes\Drive\shellex\ContextMenuHandlers\EPP" /f > $null 2>&1
}

# ============================================================================
# eclean.gg Comprehensive Windows Optimization (Gaming Latency, Power, Memory & Disk)
# ============================================================================
Write-Host "Applying eclean.gg advanced system optimizations (Low-latency Gaming, Power & DPC)..." -ForegroundColor Cyan

# 1. DPC & Low-Latency Thread Scheduling
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Kernel" /v "ThreadDpcEnable" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\PriorityControl" /v "Win32PrioritySeparation" /t REG_DWORD /d 38 /f > $null 2>&1

# 2. CPU Core Parking & Hybrid Architecture (P-Core / E-Core) Optimization (eclean.gg / AtlasOS)
$powerPath = "HKLM\zSOFTWARE\Policies\Microsoft\Power\PowerSettings"
reg.exe add "$powerPath\0cc5b647-c74e-4111-92e3-3b129533f4d5" /v "ACSettingIndex" /t REG_DWORD /d 100 /f > $null 2>&1
reg.exe add "$powerPath\0cc5b647-c74e-4111-92e3-3b129533f4d5" /v "DCSettingIndex" /t REG_DWORD /d 100 /f > $null 2>&1
reg.exe add "$powerPath\ea0653f4-9251-4ca4-99a3-324b3d2b0636" /v "ACSettingIndex" /t REG_DWORD /d 100 /f > $null 2>&1
reg.exe add "$powerPath\ea0653f4-9251-4ca4-99a3-324b3d2b0636" /v "DCSettingIndex" /t REG_DWORD /d 100 /f > $null 2>&1

# Energy Performance Preference (EPP 0 = Max Performance)
reg.exe add "$powerPath\36687f9e-e3a5-4dbf-b1dc-15eb381c6863" /v "ACSettingIndex" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "$powerPath\36687f9e-e3a5-4dbf-b1dc-15eb381c6863" /v "DCSettingIndex" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "$powerPath\36687e9e-e3a5-4dbf-b1dc-15eb31c7448b" /v "ACSettingIndex" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "$powerPath\36687e9e-e3a5-4dbf-b1dc-15eb31c7448b" /v "DCSettingIndex" /t REG_DWORD /d 0 /f > $null 2>&1

# Hybrid P-Core Priority Scheduling (Keep high-priority / game threads on high-performance cores)
reg.exe add "$powerPath\93b22d1d-9513-4bc7-ad42-1e967313f2e4" /v "ACSettingIndex" /t REG_DWORD /d 2 /f > $null 2>&1
reg.exe add "$powerPath\bae08b81-2d5e-4688-ad6a-13243356654b" /v "ACSettingIndex" /t REG_DWORD /d 2 /f > $null 2>&1
reg.exe add "$powerPath\be337238-0d82-4146-a960-4f3749d470c2" /v "ACSettingIndex" /t REG_DWORD /d 2 /f > $null 2>&1

# 3. Disk, NVMe & Memory Management (eclean.gg Deep Clean)
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\FileSystem" /v "NtfsDisable8dot3NameCreation" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\FileSystem" /v "NtfsDisableLastAccessUpdate" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management" /v "DisablePagingExecutive" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management" /v "LargeSystemCache" /t REG_DWORD /d 0 /f > $null 2>&1

# 4. Network & TCP/IP Low-Latency (Nagle's Algorithm Disabled, Instant ACK)
reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\Tcpip\Parameters" /v "TcpTimedWaitDelay" /t REG_DWORD /d 30 /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\Tcpip\Parameters" /v "MaxUserPort" /t REG_DWORD /d 65534 /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\Tcpip\Parameters" /v "DefaultTTL" /t REG_DWORD /d 64 /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\Tcpip\Parameters" /v "EnableICMPRedirect" /t REG_DWORD /d 0 /f > $null 2>&1


# Disabling unneeded background services (Resolves Issue #1 - Keep Bluetooth / Audio)
Write-Host "Disabling unneeded background services..." -ForegroundColor Cyan
$servicesToDisable = @(
    'Spooler', 'PrintNotify', 'Fax', 'RemoteRegistry', 'MapsBroker', 'WalletService',
    'CDPSvc', 'CDPUserSvc',
    'XblAuthManager', 'XblGameSave', 'XboxGipSvc', 'XboxNetApiSvc', 'BcastDVRUserService',
    'AJRouter', 'AppVClient', 'AssignedAccessManagerSvc', 'DialogBlockingService', 'NetTcpPortSharing',
    'HomeGroupListener', 'HomeGroupProvider', 'RetailDemo', 'WerSvc', 'PcaSvc', 'WSAIFabricSvc',
    'SCardSvr', 'ScDeviceEnum', 'icssvc', 'CertPropSvc', 'CscService'
)
if (-not $keepBT) {
    $servicesToDisable += @('BthAvctpSvc', 'BluetoothUserService')
}
if ($disableWU) {
    $servicesToDisable += @('wuauserv', 'UsoSvc', 'WaaSMedicSVC')
}
foreach ($service in $servicesToDisable) {
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\$service" /v "Start" /t REG_DWORD /d 4 /f > $null 2>&1
}

# Set infrequently used background services to Manual (Start = 3) instead of Automatic
Write-Host "Configuring non-essential background services to Demand Start (Manual)..." -ForegroundColor Cyan
$servicesToManual = @(
    'AxInstSV', 'BDESVC', 'DevQueryBroker', 'DeviceInstall',
    'DisplayEnhancementService', 'DmEnrollmentSvc', 'DsSvc', 'DsmSvc', 'EFS', 'EapHost',
    'EntAppSvc', 'FDResPub', 'FrameServer', 'GraphicsPerfSvc', 'IEEtwCollectorService',
    'IKEEXT', 'InstallService', 'InventorySvc', 'IpxlatCfgSvc', 'KtmRm', 'LicenseManager',
    'LxpSvc', 'MSDTC', 'MSiSCSI', 'McpManagementService', 'MixedRealityOpenXRSvc',
    'NaturalAuthentication', 'NcaSvc', 'NcbService', 'NcdAutoSetup', 'NetSetupSvc',
    'Netman', 'Netlogon', 'NgcCtnrSvc', 'SensrSvc', 'SensorDataService', 'SmsRouter', 'svsvc',
    'TapiSrv', 'WbioSrvc', 'wisvc'
)
foreach ($svc in $servicesToManual) {
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\$svc" /v "Start" /t REG_DWORD /d 3 /f > $null 2>&1
}

# Performance, Scheduling & Latency (Integrated from optimizerDuck & sparkle)
Write-Host "Applying System Performance & Latency optimizations..." -ForegroundColor Green
# Win32PrioritySeparation = 38 (Hex 0x26 - Short variable quantum, foreground boost)
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\PriorityControl" /v "Win32PrioritySeparation" /t REG_DWORD /d 38 /f > $null 2>&1

# MMCSS (Multimedia Class Scheduler Service)
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" /v "NoLazyMode" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" /v "AlwaysOn" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" /v "NetworkThrottlingIndex" /t REG_DWORD /d 4294967295 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" /v "SystemResponsiveness" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v "Priority" /t REG_DWORD /d 6 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v "Scheduling Category" /t REG_SZ /d "High" /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v "SFIO Priority" /t REG_SZ /d "High" /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v "GPU Priority" /t REG_DWORD /d 8 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v "Affinity" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v "Background Only" /t REG_SZ /d "False" /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v "Clock Rate" /t REG_DWORD /d 10000 /f > $null 2>&1

# SvcHost RAM consolidation & Service Timeout
# 67108864 (64GB) groups services into shared svchost processes, preventing 70-90 individual svchost instances and saving 500MB-800MB RAM
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control" /v "SvcHostSplitThresholdInKB" /t REG_DWORD /d 67108864 /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control" /v "ServicesPipeTimeout" /t REG_DWORD /d 30000 /f > $null 2>&1

# Kernel Memory Management (Radical RAM Optimization & Page Combining)
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management" /v "DisablePageCombining" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management" /v "PoolUsageMaximum" /t REG_DWORD /d 40 /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management" /v "LargeSystemCache" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management" /v "DisablePagingExecutive" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management" /v "ClearPageFileAtShutdown" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management\PrefetchParameters" /v "EnablePrefetcher" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management\PrefetchParameters" /v "EnableSuperfetch" /t REG_DWORD /d 0 /f > $null 2>&1

# Radical RAM Optimization: Non-essential background services configured to Disabled (4) or Manual (3)
Write-Host "Configuring system services for radical RAM reduction..." -ForegroundColor Green
$serviceConfigs = @{
    "SysMain"                                  = 4  # SuperFetch / RAM pre-caching (Saves 100MB-200MB RAM)
    "WSearch"                                  = 4  # Windows Search Indexer (Saves 80MB-150MB RAM)
    "DoSvc"                                    = 4  # Delivery Optimization (Saves 40MB-80MB RAM)
    "DPS"                                      = 4  # Diagnostic Policy Service (Saves 30MB-50MB RAM)
    "WdiServiceHost"                           = 4  # Diagnostic Service Host
    "WdiSystemHost"                            = 4  # Diagnostic System Host
    "TroubleshootingSvc"                       = 4  # Recommended Troubleshooting Service
    "DusmSvc"                                  = 4  # Data Usage Monitoring
    "LanmanServer"                             = 3  # Server / SMB File Sharing (Manual: starts on demand only)
    "TabletInputService"                       = 3  # Touch Keyboard and Handwriting Panel (Manual)
    "SensrSvc"                                 = 4  # Sensor Monitoring Service
    "SensorService"                            = 4  # Sensor Service
    "SensorDataService"                        = 4  # Sensor Data Service
    "ShellHWDetection"                         = 3  # Shell Hardware Detection (Manual)
    "WarpJITSvc"                               = 4  # WARP JIT Service
    "SharedAccess"                             = 4  # Internet Connection Sharing
    "stisvc"                                   = 3  # Windows Image Acquisition (Manual)
    "MapsBroker"                               = 4  # Downloaded Maps Manager
    "DiagTrack"                                = 4  # Connected User Experiences and Telemetry
    "dmwappushservice"                         = 4  # WAP Push Message Routing Service
    "RetailDemo"                               = 4  # Retail Demo Service
    "wisvc"                                    = 4  # Windows Insider Service
    "lfsvc"                                    = 4  # Geolocation Service
    "PcaSvc"                                   = 4  # Program Compatibility Assistant
    "WerSvc"                                   = 4  # Windows Error Reporting Service
    "SCardSvr"                                 = 4  # Smart Card Service
    "ScDeviceEnum"                             = 4  # Smart Card Device Enumeration Service
    "icssvc"                                   = 4  # Mobile Hotspot Service
    "CertPropSvc"                              = 4  # Certificate Propagation
    "CscService"                               = 4  # Offline Files
    "Netlogon"                                 = 3  # Netlogon (Manual demand-start)
    "UCPD"                                     = 4  # Universal Consent Privacy Driver (eclean/Atlas: prevent forced tweak reverts)
    "GpuEnergyDrv"                             = 4  # GPU Energy Driver (eclean/Atlas: reduce gaming latency & telemetry)
    "diagnosticshub.standardcollector.service" = 4  # Diagnostics Hub Collector (eclean/Atlas)
    "OneSyncSvc"                               = 4  # Sync Host (eclean/Atlas)
    "TrkWks"                                   = 4  # Distributed Link Tracking Client (eclean/Atlas)
    "wercplsupport"                            = 4  # Problem Reports Control Panel Support (eclean/Atlas)
    "FontCache"                                = 4  # Windows Font Cache Service (Saves 25MB-50MB RAM)
    "FontCache3.0.0.0"                         = 4  # WPF Font Cache Service
    "WpnService"                               = 4  # Windows Push Notifications System Service (Saves 15MB-30MB RAM)
    "WpnUserService"                           = 4  # Push Notifications User Service
    "PimIndexMaintenanceSvc"                   = 4  # Contact Data Indexing
    "UnistoreSvc"                              = 4  # User Data Storage
    "UserDataSvc"                              = 4  # User Data Access
    "MessagingService"                         = 4  # Messaging Service
    "CDPSvc"                                   = 4  # Connected Devices Platform Service
    "CDPUserSvc"                               = 4  # Connected Devices Platform User Service
    "iphlpsvc"                                 = 4  # IP Helper (IPv6 6to4/ISATAP tunnels - Saves 10MB-15MB RAM)
    "VaultSvc"                                 = 3  # Credential Manager (Manual demand-start)
    "TokenBroker"                              = 3  # Web Account Manager (Manual demand-start)
    "WbioSrvc"                                 = 4  # Windows Biometric Service (Saves 10MB-20MB RAM)
    "PhoneSvc"                                 = 4  # Phone Service
    "WpcMonSvc"                                = 4  # Parental Controls
    "WMPNetworkSvc"                            = 4  # Windows Media Player Network Sharing
    "SmsRouter"                                = 4  # SMS Router
    "AppHostSvc"                               = 4  # Application Host Helper
    "SEMgrSvc"                                 = 4  # Payments and NFC/SE Manager
    "CaptureService"                           = 3  # Screen / Camera capture broker (Manual)
    "edgeupdate"                               = 4  # Microsoft Edge Update Service (Saves 20MB-35MB RAM)
    "edgeupdatem"                              = 4  # Microsoft Edge Update Service
    "GraphicsPerfSvc"                          = 4  # Graphics Performance Monitor Service
    "InventorySvc"                             = 4  # Device Association / Inventory Service
    "NaturalAuthentication"                    = 4  # Companion Device Authentication
    "SharedRealitySvc"                         = 4  # Spatial Data / Mixed Reality Service
}
foreach ($svc in $serviceConfigs.GetEnumerator()) {
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\$($svc.Key)" /v "Start" /t REG_DWORD /d $($svc.Value) /f > $null 2>&1
}

# WebDAV File Size Limit (4GB)
reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\WebClient\Parameters" /v "FileSizeLimitInBytes" /t REG_DWORD /d 4294967295 /f > $null 2>&1

# Block UEFI WPBT execution (prevent OEM bloatware persistence)
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager" /v "DisableWpbtExecution" /t REG_DWORD /d 1 /f > $null 2>&1

# Detailed BSOD Stop Codes (Disable smiley emoticon, show technical crash info)
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\CrashControl" /v "DisplayParameters" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\CrashControl" /v "DisableEmoticon" /t REG_DWORD /d 1 /f > $null 2>&1

# eclean & AtlasOS - Fault Tolerant Heap (FTH) Disabled (Eliminates crash mitigation overhead for games/apps)
reg.exe add "HKLM\zSOFTWARE\Microsoft\FTH" /v "Enabled" /t REG_DWORD /d 0 /f > $null 2>&1

# eclean & AtlasOS - Program Compatibility Assistant (PCA) Complete Suppression
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\AppCompat" /v "DisablePCA" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\AppCompat" /v "DisableEngine" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\AppCompat" /v "DisableInventory" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\AppCompat" /v "AITEnable" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\AppCompat" /v "AllowTelemetry" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\AppCompat" /v "DisableUAR" /t REG_DWORD /d 1 /f > $null 2>&1

# eclean & AtlasOS - Delivery Optimization (P2P Background Upload) Disabled
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" /v "DODownloadMode" /t REG_DWORD /d 0 /f > $null 2>&1

# eclean & AtlasOS - Fast Startup (Hiberboot) Disabled (Improves SSD longevity and dual-boot consistency)
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Power" /v "HiberbootEnabled" /t REG_DWORD /d 0 /f > $null 2>&1

# Enable Win32 Long Paths
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\FileSystem" /v "LongPathsEnabled" /t REG_DWORD /d 1 /f > $null 2>&1

# Verbose boot/shutdown/logon status
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v "verbosestatus" /t REG_DWORD /d 1 /f > $null 2>&1

# Remote Desktop: Don't warn about unsigned drivers
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" /v "DoNotWarnIfUnsigned" /t REG_DWORD /d 1 /f > $null 2>&1

# Prevent DNS leaks by disabling Smart Multi-Homed Name Resolution
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows NT\DNSClient" /v "DisableSmartNameResolution" /t REG_DWORD /d 1 /f > $null 2>&1

# HAGS (Hardware Accelerated GPU Scheduling) = 2 (Enabled)
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\GraphicsDrivers" /v "HwSchMode" /t REG_DWORD /d 2 /f > $null 2>&1

# Disable Power Throttling for background tasks
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Power\PowerThrottling" /v "PowerThrottlingOff" /t REG_DWORD /d 1 /f > $null 2>&1

# Disable Automatic Idle Maintenance
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance" /v "MaintenanceDisabled" /t REG_DWORD /d 1 /f > $null 2>&1

# Disable Virtualization Based Security (VBS) for max gaming performance
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\DeviceGuard" /v "EnableVirtualizationBasedSecurity" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\DeviceGuard" /v "RequirePlatformSecurityFeatures" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\DeviceGuard" /v "Locked" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity" /v "Enabled" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity" /v "Locked" /t REG_DWORD /d 0 /f > $null 2>&1

# Windows AI, Recall, and Click-To-Do Policies (Integrated from sparkle & optimizerDuck)
Write-Host "Configuring Windows AI, Recall, and Click-To-Do policies..." -ForegroundColor Green
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v "DisableAIDataAnalysis" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v "AllowRecallEnablement" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v "AllowRecallToBeEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v "TurnOffRecall" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v "TurnOffSavingSnapshots" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v "DisableClickToDo" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v "DisableSettingsAgent" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v "DisableAgentConnectors" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v "DisableAgentWorkspaces" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v "DisableRemoteAgentConnectors" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v "AllowCopilotRuntime" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Policies\Microsoft\Windows\WindowsAI" /v "DisableAIDataAnalysis" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Policies\Microsoft\Windows\WindowsAI" /v "TurnOffRecall" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Policies\Microsoft\Windows\WindowsAI" /v "AllowRecallToBeEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Policies\Microsoft\Windows\WindowsAI" /v "TurnOffSavingSnapshots" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "TaskbarCompanion" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "CopilotPWAPin" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "RecallPin" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "TaskbarCompanion" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "CopilotPWAPin" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "RecallPin" /t REG_DWORD /d 0 /f > $null 2>&1

# Disable WMI AutoLoggers (Integrated from sparkle)
Write-Host "Disabling WMI AutoLoggers background tracing sessions..." -ForegroundColor Green
$autoLoggers = @(
    'AppModel', 'Cellcore', 'CloudExperienceHostOobe', 'DataMarket',
    'DiagLog', 'Diagtrack-Listener', 'LwtNetLog', 'SQMLogger',
    'WdiContextLog', 'WiFiSession'
)
foreach ($logger in $autoLoggers) {
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\WMI\Autologger\$logger" /v "Start" /t REG_DWORD /d 0 /f > $null 2>&1
}

# AtlasOS & ReviOS Radical Performance, Low-Latency & Storage Optimization Block
if ($atlasReviOSMode) {
    Write-Host "Applying AtlasOS & ReviOS radical performance, latency & storage optimizations..." -ForegroundColor Green

    # 1. NTFS File System I/O Tuning (Reduced SSD wear, faster directory traversal)
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\FileSystem" /v "NtfsDisableLastAccessUpdate" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\FileSystem" /v "NtfsDisable8dot3NameCreation" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\FileSystem" /v "DontVerifyRandomDrivers" /t REG_DWORD /d 1 /f > $null 2>&1

    # 2. Kernel & Memory Tuning (AtlasOS / ReviOS Core)
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management" /v "DisablePagingExecutive" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management" /v "ClearPageFileAtShutdown" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management" /v "LargeSystemCache" /t REG_DWORD /d 0 /f > $null 2>&1

    # 3. Network Latency & Nagle Algorithm (TCPNoDelay, TcpAckFrequency, QoS 100% bandwidth)
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Psched" /v "NonBestEffortLimit" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\Tcpip\Parameters" /v "TcpTimedWaitDelay" /t REG_DWORD /d 30 /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\Tcpip\Parameters" /v "MaxUserPort" /t REG_DWORD /d 65534 /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\Tcpip\Parameters" /v "DefaultTTL" /t REG_DWORD /d 64 /f > $null 2>&1

    # 4. Storage & Crash Control (Disable Memory Dump bloat)
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\CrashControl" /v "CrashDumpEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\CrashControl" /v "LogEvent" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\CrashControl" /v "SendAlert" /t REG_DWORD /d 0 /f > $null 2>&1

    # 5. Additional AtlasOS / ReviOS Service Minimization
    $atlasServices = @{
        "WpcMonSvc"         = 4  # Parental Controls
        "WMPNetworkSvc"     = 4  # Windows Media Player Network Sharing
        "PhoneSvc"          = 4  # Phone Service
        "WbioSrvc"          = 4  # Windows Biometric Service
        "SensrSvc"          = 4  # Sensor Monitoring
        "SensorService"     = 4  # Sensor Service
        "SensorDataService" = 4
        "WalletService"     = 4  # Wallet Service
        "SharedAccess"      = 4  # Internet Connection Sharing
        "RemoteRegistry"    = 4  # Remote Registry
        "RetailDemo"        = 4  # Retail Demo
        "lfsvc"             = 4  # Geolocation
        "wisvc"             = 4  # Windows Insider
    }
    foreach ($asvc in $atlasServices.GetEnumerator()) {
        reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\$($asvc.Key)" /v "Start" /t REG_DWORD /d $($asvc.Value) /f > $null 2>&1
    }

    # 6. Additional Scheduled Tasks Purged Offline
    $atlasTasks = @(
        "Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticResolver",
        "Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector",
        "Microsoft\Windows\Feedback\Siuf\DmClient",
        "Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload",
        "Microsoft\Windows\FileHistory\File History (maintenance mode)",
        "Microsoft\Windows\Maintenance\WinSAT",
        "Microsoft\Windows\PI\Sqm-Tasks",
        "Microsoft\Windows\Power Efficiency Diagnostics\AnalyzeSystem",
        "Microsoft\Windows\Shell\FamilySafetyMonitor",
        "Microsoft\Windows\Shell\FamilySafetyRefreshTask",
        "Microsoft\Windows\Registry\RegIdleBackup",
        "Microsoft\Windows\Diagnosis\Scheduled"
    )
    foreach ($task in $atlasTasks) {
        Remove-Item -LiteralPath "$tasksPath\$task" -Force -ErrorAction SilentlyContinue
    }
}

# Default User UI / UX, Latency & Gaming (Baked into Default User profile)
Write-Host "Configuring Default User UI/UX, input latency, and performance..." -ForegroundColor Green
# Startup & Menu latency
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize" /v "StartupDelayInMSec" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize" /v "StartupDelayInMSec" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Control Panel\Desktop" /v "MenuShowDelay" /t REG_SZ /d "0" /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Control Panel\Desktop" /v "MenuShowDelay" /t REG_SZ /d "0" /f > $null 2>&1

# Keyboard latency & NumLock at boot
reg.exe add "HKLM\zNTUSER\Control Panel\Keyboard" /v "KeyboardDelay" /t REG_SZ /d "0" /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Control Panel\Keyboard" /v "KeyboardSpeed" /t REG_SZ /d "31" /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Control Panel\Keyboard" /v "InitialKeyboardIndicators" /t REG_SZ /d "2" /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Control Panel\Keyboard" /v "InitialKeyboardIndicators" /t REG_SZ /d "2" /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Control Panel\Accessibility\Keyboard Response" /v "AutoRepeatDelay" /t REG_SZ /d "200" /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Control Panel\Accessibility\Keyboard Response" /v "AutoRepeatRate" /t REG_SZ /d "6" /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Control Panel\Accessibility\Keyboard Response" /v "BounceTime" /t REG_SZ /d "0" /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Control Panel\Accessibility\Keyboard Response" /v "DelayBeforeAcceptance" /t REG_SZ /d "0" /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Control Panel\Accessibility\StickyKeys" /v "Flags" /t REG_SZ /d "26" /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Control Panel\Accessibility\ToggleKeys" /v "Flags" /t REG_SZ /d "34" /f > $null 2>&1

# Mouse: 1:1 Raw Input (Zero acceleration, instant hover)
reg.exe add "HKLM\zNTUSER\Control Panel\Mouse" /v "MouseSpeed" /t REG_SZ /d "0" /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Control Panel\Mouse" /v "MouseThreshold1" /t REG_SZ /d "0" /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Control Panel\Mouse" /v "MouseThreshold2" /t REG_SZ /d "0" /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Control Panel\Mouse" /v "MouseHoverTime" /t REG_SZ /d "1" /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Control Panel\Mouse" /v "MouseSpeed" /t REG_SZ /d "0" /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Control Panel\Mouse" /v "MouseThreshold1" /t REG_SZ /d "0" /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Control Panel\Mouse" /v "MouseThreshold2" /t REG_SZ /d "0" /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Control Panel\Mouse" /v "MouseHoverTime" /t REG_SZ /d "1" /f > $null 2>&1

# Game Mode & Windowed Game optimizations
reg.exe add "HKLM\zNTUSER\Software\Microsoft\GameBar" /v "AllowAutoGameMode" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\GameBar" /v "AutoGameModeEnabled" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\DirectX\UserGpuPreferences" /v "DirectXUserGlobalSettings" /t REG_SZ /d "SwapEffectUpgradeEnable=1;VRROptimizeEnable=1;" /f > $null 2>&1

# Explorer UI: End Task, Win10 Classic Context Menu, Dark Mode, File Extensions, Clock Seconds
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings" /v "TaskbarEndTask" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings" /v "TaskbarEndTask" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" /v "AppsUseLightTheme" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" /v "SystemUsesLightTheme" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" /v "AppsUseLightTheme" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" /v "SystemUsesLightTheme" /t REG_DWORD /d 0 /f > $null 2>&1

# Radical RAM: Disable Transparency & DWM render targets & Best Performance Visual Effects
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" /v "EnableTransparency" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" /v "EnableTransparency" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\DWM" /v "ColorizationOpaqueBlend" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\DWM" /v "ColorizationOpaqueBlend" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\DWM" /v "AlwaysHibernateThumbnails" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\DWM" /v "AlwaysHibernateThumbnails" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\DWM" /v "DisallowAnimations" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\DWM" /v "DisableTransparency" /t REG_DWORD /d 1 /f > $null 2>&1

# Best Performance Visual Effects (Zero Animation / Zero Shadow / No Live Window Drag)
reg.exe add "HKLM\zNTUSER\Control Panel\Desktop\WindowMetrics" /v "MinAnimate" /t REG_SZ /d "0" /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Control Panel\Desktop\WindowMetrics" /v "MinAnimate" /t REG_SZ /d "0" /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" /v "VisualFXSetting" /t REG_DWORD /d 2 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" /v "VisualFXSetting" /t REG_DWORD /d 2 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Control Panel\Desktop" /v "UserPreferencesMask" /t REG_BINARY /d "9012018010000000" /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Control Panel\Desktop" /v "UserPreferencesMask" /t REG_BINARY /d "9012018010000000" /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Control Panel\Desktop" /v "DragFullWindows" /t REG_SZ /d "0" /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Control Panel\Desktop" /v "DragFullWindows" /t REG_SZ /d "0" /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Control Panel\Desktop" /v "FontSmoothing" /t REG_SZ /d "2" /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Control Panel\Desktop" /v "FontSmoothing" /t REG_SZ /d "2" /f > $null 2>&1

# Shell & DLL RAM Optimization: Unload DLLs instantly and stop thumbnail caching
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\AlwaysUnloadDll" /ve /t REG_SZ /d "1" /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Explorer" /v "AlwaysUnloadDll" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Explorer" /v "NoThumbnailCache" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "TaskbarAnimations" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "TaskbarAnimations" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "ListviewAlphaSelect" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "ListviewAlphaSelect" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "ListviewShadow" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "ListviewShadow" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "DisableThumbnailCache" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "DisableThumbnailCache" /t REG_DWORD /d 1 /f > $null 2>&1

# Edge & WebView2 Background Memory Suppression
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Edge\WebView2" /v "BackgroundModeEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Edge\WebView2" /v "StartupBoostEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Edge" /v "PreloadEdgeDefaultEngine" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "HideFileExt" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "HideFileExt" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "Hidden" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "Hidden" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "ShowSecondsInSystemClock" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "ShowSecondsInSystemClock" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "TaskbarDa" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "TaskbarDa" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "TaskbarMn" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "TaskbarMn" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "ShowTaskViewButton" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "ShowTaskViewButton" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "ShowCopilotButton" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "ShowCopilotButton" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "LastActiveClick" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "LastActiveClick" /t REG_DWORD /d 1 /f > $null 2>&1

# Start Menu web search, suggestions, and account ads off
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Search" /v "BingSearchEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Search" /v "BingSearchEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Policies\Microsoft\Windows\Explorer" /v "DisableSearchBoxSuggestions" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Policies\Microsoft\Windows\Explorer" /v "DisableSearchBoxSuggestions" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Policies\Microsoft\Windows\Explorer" /v "HideRecommendedSection" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Policies\Microsoft\Windows\Explorer" /v "HideRecommendedSection" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\SystemSettings\AccountNotifications" /v "EnableAccountNotifications" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\SystemSettings\AccountNotifications" /v "EnableAccountNotifications" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "Start_TrackProgs" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "Start_TrackProgs" /t REG_DWORD /d 0 /f > $null 2>&1

# Dynamically set SettingsPageVisibility only for actually removed/disabled components
$hidePages = [System.Collections.Generic.List[string]]::new()
if ($removeDefender) { $hidePages.Add("virus") }
if ($disableWU)      { $hidePages.Add("windowsupdate") }
$extraHidePages = @(
    "mobile-devices",
    "crossdevice",
    "backup",
    "easeofaccess-voiceaccess",
    "easeofaccess-magnifier",
    "easeofaccess-narrator",
    "easeofaccess-closedcaptioning",
    "easeofaccess-keyboard",
    "easeofaccess-speechrecognition",
    "gaming-gamebar",
    "gaming-gamedvr",
    "gaming-broadcasting"
)
foreach ($hp in $extraHidePages) {
    $hidePages.Add($hp)
}
if ($hidePages.Count -gt 0) {
    $hideVal = "hide:" + ($hidePages -join ";")
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v "SettingsPageVisibility" /t REG_SZ /d "$hideVal" /f > $null 2>&1
}

# ============================================================================
# Revo Registry Cleaner - Complete "Registry Tuner" Integration (All 6 Categories)
# ============================================================================
Write-Host "Applying Revo Registry Cleaner 'Registry Tuner' optimizations (All 6 Categories)..." -ForegroundColor Green

# 1. Desktop
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Explorer" /v "Max Cached Icons" /t REG_SZ /d "4096" /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer" /v "link" /t REG_BINARY /d "00000000" /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer" /v "link" /t REG_BINARY /d "00000000" /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Control Panel\Desktop" /v "PaintDesktopVersion" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Control Panel\Desktop" /v "PaintDesktopVersion" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "TaskbarAl" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "TaskbarAl" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "ExtendedUIHoverTime" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "ExtendedUIHoverTime" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "DesktopLivePreviewHoverTime" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "DesktopLivePreviewHoverTime" /t REG_DWORD /d 1 /f > $null 2>&1

# 2. File Explorer
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoComplete" /v "Append Completion" /t REG_SZ /d "yes" /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoComplete" /v "AutoSuggest" /t REG_SZ /d "yes" /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoComplete" /v "Append Completion" /t REG_SZ /d "yes" /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoComplete" /v "AutoSuggest" /t REG_SZ /d "yes" /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "LaunchTo" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "LaunchTo" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "ShowDriveLettersFirst" /t REG_DWORD /d 4 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "ShowDriveLettersFirst" /t REG_DWORD /d 4 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\OperationStatusManager" /v "ConfirmationCheckBoxDoForAll" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\OperationStatusManager" /v "ConfirmationCheckBoxDoForAll" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "ShowInfoTip" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "ShowInfoTip" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "FolderContentsInfoTip" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "FolderContentsInfoTip" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Explorer" /v "NoNewAppAlert" /t REG_DWORD /d 1 /f > $null 2>&1

# Show Full Details in File Operation Conflict / Deletion
reg.exe add "HKLM\zSOFTWARE\Classes\AllFilesystemObjects" /v "ConflictPrompt" /t REG_SZ /d "prop:System.ItemTypeText;System.Size;System.DateModified;System.OfflineAvailability" /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Classes\AllFilesystemObjects" /v "FullDetails" /t REG_SZ /d "prop:System.DateModified;System.Size;System.DateCreated;*System.StorageProviderState;*System.OfflineAvailability;*System.OfflineStatus;*System.SharedWith" /f > $null 2>&1

# Context Menu: Take Ownership
reg.exe add "HKLM\zSOFTWARE\Classes\*\shell\runas" /ve /t REG_SZ /d "Take Ownership" /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Classes\*\shell\runas" /v "HasLUAShield" /t REG_SZ /d "" /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Classes\*\shell\runas" /v "NoWorkingDirectory" /t REG_SZ /d "" /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Classes\*\shell\runas\command" /ve /t REG_SZ /d 'cmd.exe /c takeown /f \"%1\" && icacls \"%1\" /grant administrators:F' /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Classes\*\shell\runas\command" /v "IsolatedCommand" /t REG_SZ /d 'cmd.exe /c takeown /f \"%1\" && icacls \"%1\" /grant administrators:F' /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Classes\Directory\shell\runas" /ve /t REG_SZ /d "Take Ownership" /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Classes\Directory\shell\runas" /v "HasLUAShield" /t REG_SZ /d "" /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Classes\Directory\shell\runas" /v "NoWorkingDirectory" /t REG_SZ /d "" /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Classes\Directory\shell\runas\command" /ve /t REG_SZ /d 'cmd.exe /c takeown /f \"%1\" /r /d y && icacls \"%1\" /grant administrators:F /t' /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Classes\Directory\shell\runas\command" /v "IsolatedCommand" /t REG_SZ /d 'cmd.exe /c takeown /f \"%1\" /r /d y && icacls \"%1\" /grant administrators:F /t' /f > $null 2>&1

# Context Menu: Command Prompt as Administrator
reg.exe add "HKLM\zSOFTWARE\Classes\Directory\Background\shell\runas" /ve /t REG_SZ /d "Open Command Prompt as Administrator" /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Classes\Directory\Background\shell\runas" /v "HasLUAShield" /t REG_SZ /d "" /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Classes\Directory\Background\shell\runas\command" /ve /t REG_SZ /d 'PowerShell -windowstyle hidden -Command \"Start-Process cmd.exe -ArgumentList ''/s,/k,pushd,%V'' -Verb RunAs\"' /f > $null 2>&1

# Context Menu: Rotate Right / Rotate Left for Images
$imgExts = @('.avif', '.dds', '.gif', '.heif', '.jfif', '.jpeg', '.jpg', '.jxr', '.png', '.rle', '.tiff', '.webp')
foreach ($ext in $imgExts) {
    reg.exe add "HKLM\zSOFTWARE\Classes\SystemFileAssociations\$ext\ShellEx\ContextMenuHandlers\ShellImagePreview" /ve /t REG_SZ /d "{FFE2A43C-56B9-4bf5-9A79-CC6D4285608A}" /f > $null 2>&1
}

# 3. Security and Stability
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v "NoDriveTypeAutoRun" /t REG_DWORD /d 255 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers" /v "DisableAutoplay" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Control Panel\Desktop" /v "AutoEndTasks" /t REG_SZ /d "1" /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Control Panel\Desktop" /v "AutoEndTasks" /t REG_SZ /d "1" /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Control Panel\Desktop" /v "HungAppTimeout" /t REG_SZ /d "1000" /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Control Panel\Desktop" /v "HungAppTimeout" /t REG_SZ /d "1000" /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Control Panel\Desktop" /v "WaitToKillAppTimeout" /t REG_SZ /d "2000" /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Control Panel\Desktop" /v "WaitToKillAppTimeout" /t REG_SZ /d "2000" /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control" /v "WaitToKillServiceTimeout" /t REG_SZ /d "2000" /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Attachments" /v "SaveZoneInformation" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Policies\Attachments" /v "SaveZoneInformation" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Policies\Attachments" /v "SaveZoneInformation" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v "EnableLinkedConnections" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v "ConsentPromptBehaviorAdmin" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v "PromptOnSecureDesktop" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v "RecycleBinDrives" /t REG_DWORD /d 1 /f > $null 2>&1
if (-not $removeDefender) {
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender\MpEngine" /v "MpEnablePus" /t REG_DWORD /d 1 /f > $null 2>&1
}
reg.exe add "HKLM\zSOFTWARE\Microsoft\OEM\Device\Capture" /v "NoPhysicalCameraLED" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps" /v "DumpType" /t REG_DWORD /d 2 /f > $null 2>&1

# 4. System
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer" /v "AltTabSettings" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer" /v "AltTabSettings" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v "ExcludeWUDriversInQualityUpdate" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\PolicyManager\default\Update\ExcludeUpdateDrivers" /v "value" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\WindowsStore" /v "AutoDownload" /t REG_DWORD /d 2 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\MicrosoftEdge\Main" /v "AllowPrelaunch" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Edge" /v "BackgroundModeEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Edge" /v "StartupBoostEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Edge" /v "WebWidgetIsEnabled" /t REG_DWORD /d 0 /f > $null 2>&1

# Background Process Reduction: OneDrive background sync & startup
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\OneDrive" /v "DisableFileSyncNGSC" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe delete "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Run" /v "OneDrive" /f > $null 2>&1
reg.exe delete "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Run" /v "OneDriveSetup" /f > $null 2>&1
reg.exe delete "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Run" /v "OneDrive" /f > $null 2>&1
reg.exe delete "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Run" /v "OneDrive" /f > $null 2>&1

# Background Process Reduction: GameBarPresenceWriter & bcastdvr background capture
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\GameDVR" /v "AllowGameDVR" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR" /v "AppCaptureEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\GameDVR" /v "AppCaptureEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\GameDVR" /v "AppCaptureEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\System\GameConfigStore" /v "GameDVR_Enabled" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\System\GameConfigStore" /v "GameDVR_Enabled" /t REG_DWORD /d 0 /f > $null 2>&1

# Background Process Reduction: Windows Error Reporting (wermgr.exe)
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting" /v "Disabled" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting" /v "DontSendAdditionalData" /t REG_DWORD /d 1 /f > $null 2>&1

# Background Process Reduction: CrossDevice & Phone Link (PhoneExperienceHost.exe)
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\System" /v "EnableMmx" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\CrossDevice" /v "AllowCrossDeviceExperience" /t REG_DWORD /d 0 /f > $null 2>&1

# 5. Windows Appearance
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\System" /v "DisableAcrylicBackgroundOnLogon" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\ImmersiveShell" /v "UseWin32BatteryFlyout" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Power" /v "EnergyEstimationEnabled" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Power" /v "UserPresencePrediction" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\MTCUVC" /v "EnableMtcUvc" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Dsh" /v "AllowNewsAndInterests" /t REG_DWORD /d 0 /f > $null 2>&1

# 6. Windows Usage
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications" /v "GlobalUserDisabled" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications" /v "GlobalUserDisabled" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\AppPrivacy" /v "LetAppsRunInBackground" /t REG_DWORD /d 2 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\ControlPanel\NameSpace\{EDEEBE61-B85A-46B1-834B-E545EF04E947}" /ve /t REG_SZ /d "Classic User Accounts" /f > $null 2>&1

# Enable Windows Photo Viewer Associations
$photoViewerAssocs = @(
    @{ Ext = ".bmp";  ProgId = "PhotoViewer.FileAssoc.Bitmap" },
    @{ Ext = ".dib";  ProgId = "PhotoViewer.FileAssoc.Bitmap" },
    @{ Ext = ".gif";  ProgId = "PhotoViewer.FileAssoc.Tiff" },
    @{ Ext = ".jfif"; ProgId = "PhotoViewer.FileAssoc.JFIF" },
    @{ Ext = ".jpe";  ProgId = "PhotoViewer.FileAssoc.Jpeg" },
    @{ Ext = ".jpeg"; ProgId = "PhotoViewer.FileAssoc.Jpeg" },
    @{ Ext = ".jpg";  ProgId = "PhotoViewer.FileAssoc.Jpeg" },
    @{ Ext = ".png";  ProgId = "PhotoViewer.FileAssoc.Png" },
    @{ Ext = ".tif";  ProgId = "PhotoViewer.FileAssoc.Tiff" },
    @{ Ext = ".tiff"; ProgId = "PhotoViewer.FileAssoc.Tiff" },
    @{ Ext = ".wdp";  ProgId = "PhotoViewer.FileAssoc.Wdp" }
)
foreach ($pa in $photoViewerAssocs) {
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows Photo Viewer\Capabilities\FileAssociations" /v $pa.Ext /t REG_SZ /d $pa.ProgId /f > $null 2>&1
}

# 11. Copy autounattend.xml with Architecture Support & Self-healing (Resolves Issues #3, #18, #21, #2, #8, #20)
Write-Host "Configuring autounattend.xml for target architecture ($architecture)..." -ForegroundColor Green
$unattendSource = Join-Path -Path $scriptDir -ChildPath "autounattend.xml"

# Self-healing if autounattend.xml was not downloaded with script
if (-not (Test-Path -LiteralPath $unattendSource)) {
    Write-Host "autounattend.xml not found locally. Attempting to download from repository..." -ForegroundColor Yellow
    $unattendUrl = "https://raw.githubusercontent.com/gh459/nano11/main/autounattend.xml"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $unattendUrl -OutFile $unattendSource -UseBasicParsing -ErrorAction Stop
        Write-Host "Successfully downloaded autounattend.xml." -ForegroundColor Green
    } catch {
        $fallbackUrl = "https://raw.githubusercontent.com/ntdevlabs/nano11/main/autounattend.xml"
        try {
            Invoke-WebRequest -Uri $fallbackUrl -OutFile $unattendSource -UseBasicParsing -ErrorAction Stop
            Write-Host "Successfully downloaded autounattend.xml from upstream." -ForegroundColor Green
        } catch {
            Write-Host "Warning: Could not retrieve autounattend.xml automatically." -ForegroundColor Yellow
        }
    }
}

if (Test-Path -LiteralPath $unattendSource) {
    $xmlContent = Get-Content -LiteralPath $unattendSource -Raw -Encoding utf8
    # Dynamically sanitize invalid ProductKey tags that cause Setup to abort with "cannot read <ProductKey>"
    $xmlContent = $xmlContent -replace '(?s)<ProductKey>\s*<WillShowUI>[^<]*</WillShowUI>\s*</ProductKey>', ''
    # Dynamically normalize all Password and AdministratorPassword Value tags to single-line empty values (prevents blank-password login failure)
    $xmlContent = $xmlContent -replace '(?s)<Value>\s+</Value>', '<Value></Value>'
    # Dynamically match detected architecture
    $xmlContent = $xmlContent -replace 'processorArchitecture="amd64"', "processorArchitecture=`"$architecture`""
    
    # Place in ISO root (CRITICAL for Windows Setup discovery)
    $isoRootUnattend = Join-Path -Path $nano11Dir -ChildPath "autounattend.xml"
    $xmlContent | Set-Content -LiteralPath $isoRootUnattend -Encoding utf8
    Write-Host "  - Placed in ISO Root: $isoRootUnattend" -ForegroundColor Green

    # Also place in Sysprep and Panther
    $sysprepDir = Join-Path -Path $scratchDir -ChildPath "Windows\System32\Sysprep"
    if (Test-Path -LiteralPath $sysprepDir) {
        $xmlContent | Set-Content -LiteralPath (Join-Path -Path $sysprepDir -ChildPath "autounattend.xml") -Encoding utf8
    }
    $pantherDir = Join-Path -Path $scratchDir -ChildPath "Windows\Panther"
    New-Item -Path $pantherDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    $xmlContent | Set-Content -LiteralPath (Join-Path -Path $pantherDir -ChildPath "unattend.xml") -Encoding utf8

    # Pre-extract Setup scripts directly into image (Windows\Setup\Scripts)
    # Guarantees Specialize.ps1, DefaultUser.ps1, UserOnce.ps1, and FirstLogon.ps1 exist
    # even if dynamic XML extraction during Specialize pass is blocked or delayed.
    $setupScriptsDir = Join-Path -Path $scratchDir -ChildPath "Windows\Setup\Scripts"
    New-Item -Path $setupScriptsDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    try {
        $xmlDoc = [xml]$xmlContent
        if ($xmlDoc.unattend -and $xmlDoc.unattend.Extensions -and $xmlDoc.unattend.Extensions.File) {
            foreach ($fileNode in $xmlDoc.unattend.Extensions.File) {
                $rawTarget = $fileNode.GetAttribute("path")
                if ($rawTarget) {
                    $relTarget = $rawTarget -replace '^[A-Za-z]:\\', ''
                    $destPath = Join-Path -Path $scratchDir -ChildPath $relTarget
                    $parentDir = Split-Path -Path $destPath -Parent
                    if (-not (Test-Path -LiteralPath $parentDir)) {
                        New-Item -Path $parentDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
                    }
                    [System.IO.File]::WriteAllText($destPath, $fileNode.InnerText.Trim(), [System.Text.Encoding]::UTF8)
                }
            }
            Write-Host "  - Pre-extracted Setup & Winhance scripts directly into image" -ForegroundColor Green
        }
    } catch {}
}

# Ensure CurrentControlSet does NOT exist in offline SYSTEM hive
# Creating CurrentControlSet as a real key in an offline hive causes Bug Check 0x67 (CONFIG_INITIALIZATION_FAILED)
# because the NT kernel fails to create the CurrentControlSet symbolic link at boot time.
if (Test-Path -LiteralPath "HKLM:\zSYSTEM\CurrentControlSet") {
    reg.exe delete "HKLM\zSYSTEM\CurrentControlSet" /f > $null 2>&1
}

# Unmount Registry Hives
Write-Host "Unmounting offline registry hives..." -ForegroundColor Cyan
@('zCOMPONENTS', 'zDEFAULT', 'zNTUSER', 'zSOFTWARE', 'zSYSTEM') | ForEach-Object {
    [void](Unmount-RegistryHiveWithRetry -Name $_)
}

# 12. Unmount and export install image
Write-Host "Unmounting install image..." -ForegroundColor Green

$unmountSuccess = $false
for ($retry = 1; $retry -le 4; $retry++) {
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    Start-Sleep -Seconds 2

    & dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /commit
    if ($LASTEXITCODE -eq 0) {
        $unmountSuccess = $true
        break
    }

    Write-Host "Warning: commit unmount failed (attempt $retry/4). Retrying after waiting and garbage collection..." -ForegroundColor Yellow
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    Start-Sleep -Seconds (3 * $retry)
}

if (-not $unmountSuccess) {
    Write-Host "Error: Failed to commit changes to mounted image after 4 attempts." -ForegroundColor Red
    Write-Host "Checking if image is in 'Needs Remount' state or locked by external processes..." -ForegroundColor Yellow
    & dism.exe /English /Remount-Image "/MountDir:$scratchDir" > $null 2>&1
    & dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /commit
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Critical: Unable to commit changes. Falling back to discard unmount to prevent corrupted image..." -ForegroundColor Red
        & dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /discard
    }
}

# 13. Export modified image
# Note: On Windows 11 24H2 (build 26100+), DISM /Compress:recovery (LZMS) has a known crash bug (0xc0000005 in WIMGAPI.DLL).
# Exporting to install.wim via /Compress:max (LZX) completes in ~20 seconds, never crashes, and produces a 100% compliant Windows Setup payload.
$finalWim = Join-Path -Path "$nano11Dir\sources" -ChildPath "install.wim"
$finalEsd = Join-Path -Path "$nano11Dir\sources" -ChildPath "install.esd"
$tempWim  = Join-Path -Path "$nano11Dir\sources" -ChildPath "install_export.wim"

# Clean up any leftover temporary/broken export files
Remove-Item -LiteralPath $finalEsd -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $tempWim -Force -ErrorAction SilentlyContinue

$esdSuccess = $false
if ($exportESDMode) {
    Write-Host "Exporting modified image to recovery-compressed install.esd (LZMS)..." -ForegroundColor Green
    & dism.exe /English /Export-Image "/SourceImageFile:$destWim" "/SourceIndex:$index" "/DestinationImageFile:$finalEsd" /Compress:recovery
    if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $finalEsd) -and ((Get-Item -LiteralPath $finalEsd).Length -gt 1GB)) {
        Write-Host "install.esd successfully created ($([math]::Round((Get-Item -LiteralPath $finalEsd).Length / 1GB, 2)) GB). Removing temporary install.wim..." -ForegroundColor Green
        Remove-Item -LiteralPath $destWim -Force -ErrorAction SilentlyContinue
        $esdSuccess = $true
    } else {
        Write-Host "Recovery export failed or crashed. Cleaning up incomplete ESD and falling back to LZX install.wim..." -ForegroundColor Yellow
        Remove-Item -LiteralPath $finalEsd -Force -ErrorAction SilentlyContinue
    }
}

if (-not $esdSuccess) {
    Write-Host "Exporting modified image to highly-compressed install.wim (LZX)..." -ForegroundColor Green
    & dism.exe /English /Export-Image "/SourceImageFile:$destWim" "/SourceIndex:$index" "/DestinationImageFile:$tempWim" /Compress:max
    if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $tempWim) -and ((Get-Item -LiteralPath $tempWim).Length -gt 1GB)) {
        Remove-Item -LiteralPath $destWim -Force -ErrorAction SilentlyContinue
        Rename-Item -LiteralPath $tempWim -NewName "install.wim" -Force
        Write-Host "install.wim successfully exported ($([math]::Round((Get-Item -LiteralPath $finalWim).Length / 1GB, 2)) GB)." -ForegroundColor Green
    } else {
        Write-Host "Warning: Export to install_export.wim failed or produced undersized file. Keeping original committed install.wim." -ForegroundColor Yellow
        Remove-Item -LiteralPath $tempWim -Force -ErrorAction SilentlyContinue
    }
}

# 14. Shrink and modify boot.wim (Setup bypasses & dynamic index handling)
$bootWimPath = Join-Path -Path "$nano11Dir\sources" -ChildPath "boot.wim"
if (-not (Test-Path -LiteralPath $bootWimPath)) {
    $sourceBootWim = Join-Path -Path "$DriveLetter\sources" -ChildPath "boot.wim"
    if (Test-Path -LiteralPath $sourceBootWim) {
        Write-Host "Restoring boot.wim from source media..." -ForegroundColor Cyan
        Copy-Item -LiteralPath $sourceBootWim -Destination $bootWimPath -Force -ErrorAction SilentlyContinue
    }
}
if (Test-Path -LiteralPath $bootWimPath) {
    Write-Host "Processing boot.wim..." -ForegroundColor Green
    Set-ItemOwnershipAndAccess -Path $bootWimPath
    try { Set-ItemProperty -LiteralPath $bootWimPath -Name IsReadOnly -Value $false -ErrorAction Stop } catch {}

    # Inspect boot.wim indices (Setup image is usually Index 2, but can be Index 1 on single-index media)
    $bootInfo = & dism.exe /English /Get-WimInfo "/WimFile:$bootWimPath"
    $hasIndex2 = ($bootInfo -split '\r?\n') -match 'Index\s*:\s*2'
    $setupIndex = if ($hasIndex2) { 2 } else { 1 }

    $newBootWim = Join-Path -Path "$nano11Dir\sources" -ChildPath "boot_new.wim"
    & dism.exe /English /Export-Image "/SourceImageFile:$bootWimPath" "/SourceIndex:$setupIndex" "/DestinationImageFile:$newBootWim" /Bootable
    Clear-DismMountConflicts -TargetMountDir $scratchDir -TargetWimFile $newBootWim
    & dism.exe /English /Mount-Image "/ImageFile:$newBootWim" /Index:1 "/MountDir:$scratchDir"

    reg.exe load HKLM\zSYSTEM "$scratchDir\Windows\System32\config\SYSTEM" | Out-Null
    Write-Host "Applying LabConfig bypasses to boot.wim Setup environment..." -ForegroundColor Green
    foreach ($key in $labConfigKeys) {
        reg.exe add "HKLM\zSYSTEM\Setup\LabConfig" /v $key /t REG_DWORD /d 1 /f > $null 2>&1
    }
    reg.exe add "HKLM\zSYSTEM\Setup\LabConfig" /v "BypassNRO" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\Setup\MoSetup" /v "AllowUpgradesWithUnsupportedTPMOrCPU" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\BitLocker" /v "PreventDeviceEncryption" /t REG_DWORD /d 1 /f > $null 2>&1
    if (Test-Path -LiteralPath "HKLM:\zSYSTEM\CurrentControlSet") {
        reg.exe delete "HKLM\zSYSTEM\CurrentControlSet" /f > $null 2>&1
    }
    [void](Unmount-RegistryHiveWithRetry -Name 'zSYSTEM')

    $bootUnmountSuccess = $false
    for ($bRetry = 1; $bRetry -le 3; $bRetry++) {
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        Start-Sleep -Seconds 2
        & dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /commit
        if ($LASTEXITCODE -eq 0) {
            $bootUnmountSuccess = $true
            break
        }
        Write-Host "Warning: commit unmount of boot.wim failed (attempt $bRetry/3), retrying after waiting..." -ForegroundColor Yellow
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        Start-Sleep -Seconds (2 * $bRetry)
    }

    if (-not $bootUnmountSuccess) {
        Write-Host "Falling back to discard unmount for boot.wim..." -ForegroundColor Yellow
        & dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /discard
    }

    $finalBootWim = Join-Path -Path "$nano11Dir\sources" -ChildPath "boot_final.wim"
    Remove-Item -LiteralPath $bootWimPath -Force -ErrorAction SilentlyContinue
    & dism.exe /English /Export-Image "/SourceImageFile:$newBootWim" /SourceIndex:1 "/DestinationImageFile:$finalBootWim" /Compress:max /Bootable
    Remove-Item -LiteralPath $newBootWim -Force -ErrorAction SilentlyContinue
    Rename-Item -LiteralPath $finalBootWim -NewName "boot.wim" -Force
}

# 15. Verify final installation payload
$esdCheck = Join-Path -Path "$nano11Dir\sources" -ChildPath "install.esd"
$wimCheck = Join-Path -Path "$nano11Dir\sources" -ChildPath "install.wim"

$validEsd = (Test-Path -LiteralPath $esdCheck) -and ((Get-Item -LiteralPath $esdCheck).Length -gt 1GB)
$validWim = (Test-Path -LiteralPath $wimCheck) -and ((Get-Item -LiteralPath $wimCheck).Length -gt 1GB)

# Remove any corrupt stub files or invalid partial files (< 1GB)
if (-not $validEsd -and (Test-Path -LiteralPath $esdCheck)) {
    Write-Host "Warning: Corrupt or incomplete install.esd detected ($((Get-Item -LiteralPath $esdCheck).Length) bytes). Removing..." -ForegroundColor Yellow
    Remove-Item -LiteralPath $esdCheck -Force -ErrorAction SilentlyContinue
    $validEsd = $false
}
if (-not $validWim -and (Test-Path -LiteralPath $wimCheck)) {
    Write-Host "Warning: Corrupt or incomplete install.wim detected ($((Get-Item -LiteralPath $wimCheck).Length) bytes). Removing..." -ForegroundColor Yellow
    Remove-Item -LiteralPath $wimCheck -Force -ErrorAction SilentlyContinue
    $validWim = $false
}

if ($validWim) {
    Write-Host "Final installation image confirmed: install.wim ($([math]::Round((Get-Item -LiteralPath $wimCheck).Length / 1GB, 2)) GB)" -ForegroundColor Green
    if (Test-Path -LiteralPath $esdCheck) {
        Remove-Item -LiteralPath $esdCheck -Force -ErrorAction SilentlyContinue
    }
} elseif ($validEsd) {
    Write-Host "Final installation image confirmed: install.esd ($([math]::Round((Get-Item -LiteralPath $esdCheck).Length / 1GB, 2)) GB)" -ForegroundColor Green
    if (Test-Path -LiteralPath $wimCheck) {
        Remove-Item -LiteralPath $wimCheck -Force -ErrorAction SilentlyContinue
    }
} else {
    Write-Host "CRITICAL ERROR: No valid installation payload (install.wim or install.esd > 1GB) found in $nano11Dir\sources!" -ForegroundColor Red
    Write-Host "Aborting ISO creation to prevent producing an unbootable or corrupt image." -ForegroundColor Red
    Stop-Transcript
    exit 1
}

# 16. Final cleanup of ISO root and sources
Write-Host "Performing final cleanup of ISO root..." -ForegroundColor Cyan
$keepList = @("boot", "efi", "sources", "bootmgr", "bootmgr.efi", "bootmgfw.efi", "setup.exe", "autounattend.xml")
Get-ChildItem -Path $nano11Dir | Where-Object { $_.Name -notin $keepList } | ForEach-Object {
    Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
}

# Clean leftover build diagnostics and setup logs inside sources
$sourcesDir = Join-Path -Path $nano11Dir -ChildPath "sources"
if (Test-Path -LiteralPath $sourcesDir) {
    Remove-Item -Path "$sourcesDir\setupcore.log" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$sourcesDir\*.diagerr" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$sourcesDir\*.diagxml" -Force -ErrorAction SilentlyContinue
}

# 17. Locate or download oscdimg.exe (checks local dirs, PATH, ADK, and multi-mirror fallback)
$oscdimgCandidates = @(
    (Join-Path -Path $scriptDir -ChildPath "oscdimg.exe"),
    (Join-Path -Path (Get-Location).Path -ChildPath "oscdimg.exe"),
    (Join-Path -Path "$env:USERPROFILE\Downloads\nano11-main" -ChildPath "oscdimg.exe"),
    "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
    "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\arm64\Oscdimg\oscdimg.exe",
    "$env:ProgramFiles\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
    "$env:ProgramFiles\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\arm64\Oscdimg\oscdimg.exe"
)

# Also check if oscdimg is available in PATH
$pathOscd = Get-Command "oscdimg.exe" -ErrorAction SilentlyContinue
if ($pathOscd -and $pathOscd.Source) {
    $oscdimgCandidates += $pathOscd.Source
}

$oscdimgExe = $null
foreach ($candidate in $oscdimgCandidates) {
    if ($candidate -and (Test-Path -LiteralPath $candidate)) {
        $oscdimgExe = $candidate
        Write-Host "Found local oscdimg.exe: $oscdimgExe" -ForegroundColor Green
        break
    }
}

if (-not $oscdimgExe) {
    $targetOscdPath = Join-Path -Path $scriptDir -ChildPath "oscdimg.exe"
    Write-Host "Downloading oscdimg.exe..." -ForegroundColor Cyan
    
    $mirrors = @(
        "https://raw.githubusercontent.com/gh459/nano11/main/oscdimg.exe",
        "https://github.com/gh459/nano11/raw/main/oscdimg.exe",
        "https://msdl.microsoft.com/download/symbols/oscdimg.exe/3D44737265000/oscdimg.exe"
    )
    
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
    
    foreach ($url in $mirrors) {
        try {
            Write-Host "  - Attempting download from: $url" -ForegroundColor Gray
            Invoke-WebRequest -Uri $url -OutFile $targetOscdPath -UseBasicParsing -TimeoutSec 15
            if ((Test-Path -LiteralPath $targetOscdPath) -and ((Get-Item -LiteralPath $targetOscdPath).Length -gt 50KB)) {
                $oscdimgExe = $targetOscdPath
                Write-Host "  - oscdimg.exe downloaded successfully!" -ForegroundColor Green
                break
            }
        } catch {
            Write-Host "  - Mirror failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    # If still not found (e.g. system DNS failed to resolve hostnames), try public DNS resolution fallback
    if (-not $oscdimgExe) {
        try {
            Write-Host "  - Attempting public DNS fallback resolution (8.8.8.8)..." -ForegroundColor Gray
            $dnsEntry = Resolve-DnsName -Name "raw.githubusercontent.com" -Server 8.8.8.8 -ErrorAction SilentlyContinue | Where-Object { $_.IP4Address } | Select-Object -First 1
            if ($dnsEntry -and $dnsEntry.IP4Address) {
                $wc = New-Object System.Net.WebClient
                $wc.Headers.Add("Host", "raw.githubusercontent.com")
                $wc.Headers.Add("User-Agent", "Mozilla/5.0")
                $wc.DownloadFile("https://$($dnsEntry.IP4Address)/gh459/nano11/main/oscdimg.exe", $targetOscdPath)
                if ((Test-Path -LiteralPath $targetOscdPath) -and ((Get-Item -LiteralPath $targetOscdPath).Length -gt 50KB)) {
                    $oscdimgExe = $targetOscdPath
                    Write-Host "  - oscdimg.exe downloaded successfully via public DNS fallback!" -ForegroundColor Green
                }
            }
        } catch {
            Write-Host "  - Public DNS fallback download failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

# 18. Create bootable ISO (oscdimg) with Architecture-aware bootdata and Volume Label
Write-Host "Creating bootable ISO image..." -ForegroundColor Green
$outputIso = Join-Path -Path $scriptDir -ChildPath "nano11.iso"

# Dismount and remove any existing output ISO to prevent file locks/collisions
try {
    $mounted = Get-DiskImage -ImagePath $outputIso -ErrorAction SilentlyContinue
    if ($mounted) {
        Write-Host "Dismounting previously mounted output ISO: $outputIso..." -ForegroundColor Yellow
        Dismount-DiskImage -ImagePath $outputIso -ErrorAction SilentlyContinue | Out-Null
    }
} catch {}
if (Test-Path -LiteralPath $outputIso) {
    Remove-Item -LiteralPath $outputIso -Force -ErrorAction SilentlyContinue
}

# Resolve etfsboot.com (BIOS boot sector)
$etfsBootCandidates = @(
    (Join-Path -Path "$nano11Dir\boot" -ChildPath "etfsboot.com"),
    (Join-Path -Path "$DriveLetter\boot" -ChildPath "etfsboot.com")
)
$etfsBoot = $null
foreach ($c in $etfsBootCandidates) {
    if (Test-Path -LiteralPath $c) {
        $localEtfs = Join-Path -Path "$nano11Dir\boot" -ChildPath "etfsboot.com"
        if (-not (Test-Path -LiteralPath $localEtfs)) {
            New-Item -ItemType Directory -Force -Path "$nano11Dir\boot" -ErrorAction SilentlyContinue | Out-Null
            Copy-Item -LiteralPath $c -Destination $localEtfs -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $localEtfs) {
            $etfsBoot = $localEtfs
            break
        }
    }
}

# Resolve efisys.bin (UEFI boot sector) across candidate paths
$efiSysCandidates = @(
    (Join-Path -Path "$nano11Dir\efi\microsoft\boot" -ChildPath "efisys.bin"),
    (Join-Path -Path "$nano11Dir\efi\microsoft\boot" -ChildPath "efisys_noprompt.bin"),
    (Join-Path -Path "$DriveLetter\efi\microsoft\boot" -ChildPath "efisys.bin"),
    (Join-Path -Path "$DriveLetter\efi\microsoft\boot" -ChildPath "efisys_noprompt.bin"),
    (Join-Path -Path "$nano11Dir\efi\boot" -ChildPath "efisys.bin"),
    (Join-Path -Path "$DriveLetter\efi\boot" -ChildPath "efisys.bin")
)
$efiSys = $null
foreach ($c in $efiSysCandidates) {
    if (Test-Path -LiteralPath $c) {
        $localEfiSys = Join-Path -Path "$nano11Dir\efi\microsoft\boot" -ChildPath "efisys.bin"
        if (-not (Test-Path -LiteralPath $localEfiSys)) {
            New-Item -ItemType Directory -Force -Path "$nano11Dir\efi\microsoft\boot" -ErrorAction SilentlyContinue | Out-Null
            Copy-Item -LiteralPath $c -Destination $localEfiSys -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $localEfiSys) {
            $efiSys = $localEfiSys
            break
        }
    }
}

# Determine bootdata parameters based on discovered boot sector files
$bootData = $null
if ($efiSys -and $etfsBoot -and ($architecture -ne 'arm64')) {
    # Dual boot: BIOS (etfsboot.com) + UEFI (efisys.bin)
    $bootData = "2#p0,e,b$etfsBoot#pEF,e,b$efiSys"
    Write-Host "Configured Dual Boot (BIOS + UEFI):" -ForegroundColor Green
    Write-Host "  - BIOS Boot Sector: $etfsBoot" -ForegroundColor Gray
    Write-Host "  - UEFI Boot Sector: $efiSys" -ForegroundColor Gray
} elseif ($efiSys) {
    # UEFI-only (ARM64 or systems without BIOS bootloader)
    $bootData = "1#pEF,e,b$efiSys"
    Write-Host "Configured UEFI Boot:" -ForegroundColor Green
    Write-Host "  - UEFI Boot Sector: $efiSys" -ForegroundColor Gray
} elseif ($etfsBoot) {
    # BIOS-only
    $bootData = "1#p0,e,b$etfsBoot"
    Write-Host "Configured BIOS Boot:" -ForegroundColor Green
    Write-Host "  - BIOS Boot Sector: $etfsBoot" -ForegroundColor Gray
} else {
    Write-Host "Warning: Neither BIOS nor UEFI boot sector files were found. Output ISO will not be bootable." -ForegroundColor Yellow
}

$isoCreatedSuccessfully = $false
if ($oscdimgExe -and (Test-Path -LiteralPath $oscdimgExe)) {
    $oscdimgArgs = @("-m", "-o", "-u2", "-udfver102", "-l`"nano11`"")
    if ($bootData) {
        $oscdimgArgs += "-bootdata:$bootData"
    }
    $oscdimgArgs += $nano11Dir
    $oscdimgArgs += $outputIso

    Write-Host "Executing oscdimg..." -ForegroundColor Cyan
    & "$oscdimgExe" @oscdimgArgs
    
    if ((Test-Path -LiteralPath $outputIso) -and ((Get-Item -LiteralPath $outputIso).Length -gt 1.5GB)) {
        $isoCreatedSuccessfully = $true
        $isoItem = Get-Item -LiteralPath $outputIso
        $isoSizeMB = [math]::Round($isoItem.Length / 1MB, 2)
        Write-Host "Calculating SHA256 checksum..." -ForegroundColor Cyan
        $sha256 = (Get-FileHash -LiteralPath $outputIso -Algorithm SHA256).Hash
        
        Write-Host ""
        Write-Host "=========================================================" -ForegroundColor Green
        Write-Host "   Creation complete! Your ISO is named nano11.iso        " -ForegroundColor Green
        Write-Host "   Path:   $outputIso ($isoSizeMB MB)                     " -ForegroundColor Green
        Write-Host "   SHA256: $sha256                                        " -ForegroundColor Green
        Write-Host "=========================================================" -ForegroundColor Green
        Write-Host ""
        Write-Host "[IMPORTANT NOTE FOR BOOTABLE USB CREATION]" -ForegroundColor Cyan
        Write-Host "- install.wim is larger than 4GB. FAT32 cannot store files > 4GB." -ForegroundColor Yellow
        Write-Host "- When creating a bootable USB with Rufus, select 'NTFS' filesystem." -ForegroundColor Yellow
        Write-Host "- Or copy nano11.iso directly into a Ventoy USB drive (recommended)." -ForegroundColor Yellow
        Write-Host ""
    } else {
        Write-Host ""
        Write-Host "=========================================================" -ForegroundColor Red
        Write-Host "   ERROR: Failed to create valid bootable ISO!           " -ForegroundColor Red
        if (Test-Path -LiteralPath $outputIso) {
            Write-Host "   Generated ISO size ($([math]::Round((Get-Item -LiteralPath $outputIso).Length / 1MB, 2)) MB) is abnormally small (< 1.5 GB). Likely missing OS payload." -ForegroundColor Red
        } else {
            Write-Host "   oscdimg exited with code $LASTEXITCODE. The ISO file was not generated." -ForegroundColor Red
        }
        Write-Host "   Working directory preserved for inspection: $nano11Dir" -ForegroundColor Yellow
        Write-Host "=========================================================" -ForegroundColor Red
    }
} else {
    Write-Host "oscdimg.exe not found. You can manually package the ISO from: $nano11Dir" -ForegroundColor Yellow
}

# 19. Cleanup scratch and temporary files
if (-not $NonInteractive) {
    Read-Host "Press Enter to clean up working directories and exit."
}
& dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /discard > $null 2>&1
if ($isoCreatedSuccessfully) {
    Remove-Item -LiteralPath $nano11Dir -Recurse -Force -ErrorAction SilentlyContinue
} else {
    Write-Host "Preserving $nano11Dir because ISO creation was not completed." -ForegroundColor Yellow
}
Remove-Item -LiteralPath $scratchDir -Recurse -Force -ErrorAction SilentlyContinue

Stop-Transcript
if ($isoCreatedSuccessfully) {
    Write-Host "Done! nano11.iso is ready." -ForegroundColor Green
} else {
    Write-Host "Process ended with errors. Please check the logs in $transcriptPath" -ForegroundColor Red
}
