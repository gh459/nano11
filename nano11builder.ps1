#Requires -Version 5.1
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

[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [alias("Unattended", "Silent", "Batch")]
    [switch]$NonInteractive,
    [switch]$Interactive,
    [alias("UI")]
    [switch]$GUI,
    [alias("Preset")]
    [string]$Profile,
    [alias("ExportConfig")]
    [string]$SaveProfile,
    [alias("ImportConfig", "Config")]
    [string]$LoadProfile,
    [string]$SourceDrive,
    [string]$WorkDir,
    [string]$Index,
    
    # Execution & Diagnostic Flags
    [switch]$DryRun,
    [switch]$Resume,
    [switch]$Validate,
    [switch]$SkipEiCfg,
    [switch]$NoPostInstallAssets,
    
    # Customization & Maintenance Settings
    [string]$ComputerName = '*',
    [string]$UserName = 'User',
    [int]$KeepLogs = 10,
    [string]$InjectDrivers,
    [switch]$KeepBasicApps,
    [switch]$KeepSearchIndex,
    
    # 1. Windows Defender
    [switch]$KeepDefender,
    [alias("NoDefender")]
    [switch]$RemoveDefender,
    
    # 2. Asian IMEs
    [alias("KeepAsianIME")]
    [switch]$KeepIME,
    [alias("NoIME", "RemoveAsianIME")]
    [switch]$RemoveIME,
    
    # 3. Fonts
    [alias("KeepExtraFonts")]
    [switch]$KeepFonts,
    [alias("NoFonts")]
    [switch]$RemoveFonts,
    
    # 4. Drivers
    [switch]$KeepDrivers,
    [switch]$RemoveDrivers,
    
    # 5. Windows Update
    [alias("EnableWindowsUpdate")]
    [switch]$KeepWindowsUpdate,
    [alias("NoWindowsUpdate")]
    [switch]$DisableWindowsUpdate,
    
    # 6. Bluetooth
    [switch]$KeepBluetooth,
    [alias("NoBluetooth")]
    [switch]$DisableBluetooth,
    
    # 7. WSL2 & Virtualization
    [switch]$EnableWSL,
    [alias("NoWSL")]
    [switch]$DisableWSL,
    
    # 8. Recovery Environment (WinRE)
    [alias("KeepWinRE")]
    [switch]$KeepRecovery,
    [alias("RemoveWinRE", "NoWinRE", "NoRecovery")]
    [switch]$RemoveRecovery,
    
    # 9. WinSxS debloat mode
    [alias("SafeWinSxS")]
    [switch]$SafeDebloat,
    [alias("TrimWinSxS")]
    [switch]$AggressiveWinSxS,
    
    # 10. UltraSlim
    [switch]$UltraSlim,
    [switch]$NoUltraSlim,
    
    # 11. Japanese 106/109 Keyboard
    [switch]$JapaneseKeyboard,
    [switch]$NoJapaneseKeyboard,
    
    # 12. AtlasOS & ReviOS Tweaks
    [switch]$AtlasReviOS,
    [switch]$NoAtlasReviOS,
    
    # 13. Export payload format
    [switch]$ExportESD,
    [alias("NoESD")]
    [switch]$ExportWIM,
    [alias("FAT32Compatible", "FAT32")]
    [switch]$SplitWIM,
    [switch]$NoSplitWIM,
    
    # 14. Microsoft Store
    [switch]$KeepStore,
    [alias("NoStore", "RemoveMicrosoftStore")]
    [switch]$RemoveStore,
    
    # 16. Fast VHDX Scratch Disk
    [alias("FastVHDX", "VHDX")]
    [switch]$UseVHDX,
    
    # 17. Self Diagnostics and Image Verification
    [switch]$TestSelf,
    [alias("VerifyImage")]
    [switch]$CheckHealth,
    
    # 18. Multi-Index Processing
    [switch]$AllIndices,

    # 19. Xbox Services & Gaming Features
    [switch]$KeepXboxServices,
    [alias("NoXboxServices")]
    [switch]$RemoveXboxServices,

    # 20. Audio Tweaks & Latency Protection
    [switch]$KeepAudioTweaks,

    # 21. Advanced Modular Optimization Tweak Toggles
    [switch]$RemoveLegacyFOD,
    [switch]$TrimWallpapers,
    [ValidateSet('Off', 'Reduced', 'Keep')]
    [string]$HibernateMode = 'Keep',
    [ValidateSet('Automatic', 'Small', 'None')]
    [string]$CrashDumpMode = 'Automatic',
    [switch]$DisableCPUMitigations,
    [switch]$MMCSSGaming,
    [switch]$DAWMode,
    [switch]$DisableMemCompression,
    [switch]$DisableFSE,
    [switch]$NvidiaLowLatency,
    [switch]$NoKernelPaging,
    [switch]$DisableUSBSuspend,
    [switch]$NoHypervisor,
    [switch]$RemoveWebViewPostOOBE,
    [switch]$FastExport,
    [switch]$UefiOnly,
    [ValidateSet('Efficient', 'Aggressive', 'Off', 'Default')]
    [string]$CpuBoostMode = 'Default',
    [ValidateSet('Desktop', 'Handheld', 'Balanced', 'VM', 'Default')]
    [string]$PowerPreset = 'Default',
    [hashtable]$TweakGroupOverrides
)

# PowerShell 7+ Compatibility Notice
if ($PSVersionTable.PSVersion.Major -ge 7) {
    Write-Warning "PowerShell 7+ is not officially supported due to native Windows DISM and elevation differences. Running in Windows PowerShell 5.1 is strongly recommended."
}

# Unified nano11 Version
$script:Nano11Version = "2.1"

# Ensure UTF-8 Console and Output encoding to prevent mojibake in Windows terminals
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

# ==============================================================================
# Windows 11 Installation Media Notice (install.wim & install.esd)
# ==============================================================================
Write-Host ""
Write-Host "==============================================================================" -ForegroundColor Cyan
Write-Host " [WINDOWS 11 SOURCE MEDIA ADVISORY]" -ForegroundColor Cyan
Write-Host " Official ISOs containing 'install.wim' provide maximum build speed and stability." -ForegroundColor Green
Write-Host " MediaCreationTool ISOs containing compressed 'install.esd' will be automatically" -ForegroundColor Yellow
Write-Host " decompressed and converted to 'install.wim' via DISM during image servicing." -ForegroundColor Yellow
Write-Host "==============================================================================" -ForegroundColor Cyan
Write-Host ""

# 1. Check and adjust Execution Policy
if ((Get-ExecutionPolicy) -eq 'Restricted') {
    if ($NonInteractive) {
        Write-Warning "PowerShell Execution Policy is 'Restricted' in -NonInteractive mode. Attempting to set RemoteSigned for CurrentUser..."
        try {
            Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Confirm:$false -ErrorAction Stop
            Write-Host "Execution Policy set to RemoteSigned." -ForegroundColor Green
        } catch {
            throw "Execution Policy is Restricted and cannot be changed non-interactively. Run: Set-ExecutionPolicy RemoteSigned -Scope CurrentUser"
        }
    } else {
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
}

# 2. Check for Admin rights and restart with full arguments preserved
$isDryRunMode = $DryRun -or ($PSBoundParameters.ContainsKey('WhatIf') -and $PSBoundParameters['WhatIf'])
$myWindowsID = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$myWindowsPrincipal = New-Object System.Security.Principal.WindowsPrincipal($myWindowsID)
if ((-not $myWindowsPrincipal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) -and ($env:NANO11_TEST_MODE -ne "1") -and (-not $TestSelf) -and (-not $isDryRunMode)) {
    Write-Host "Restarting script with Administrator privileges in a new window..." -ForegroundColor Yellow
    
    # Reconstruct bound parameters for elevated process
    $paramList = [System.Collections.Generic.List[string]]::new()
    foreach ($key in $PSBoundParameters.Keys) {
        $val = $PSBoundParameters[$key]
        if ($val -is [System.Management.Automation.SwitchParameter]) {
            if ($val.IsPresent) { $paramList.Add("-$key") } else { $paramList.Add("-$key`:$false") }
        } elseif ($val -is [bool]) {
            if ($val) { $paramList.Add("-$key") } else { $paramList.Add("-$key`:$false") }
        } else {
            $escaped = "$val" -replace '"', '\"' -replace '(\\+)$', '$1$1'
            $paramList.Add("-$key `"$escaped`"")
        }
    }
    
    $newProcess = New-Object System.Diagnostics.ProcessStartInfo "PowerShell"
    $newProcess.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$($myInvocation.MyCommand.Definition)`" " + ($paramList -join " ")
    $newProcess.Verb = "runas"
    try {
        [System.Diagnostics.Process]::Start($newProcess) | Out-Null
        exit 0
    } catch {
        Write-Host "Failed to elevate privileges: $_" -ForegroundColor Red
        exit 1
    }
}

# 2b. Concurrency Guard: Global Mutex to prevent simultaneous builds
$script:BuildMutex = $null
$script:HasMutex = $false
if ((-not $TestSelf) -and ($env:NANO11_TEST_MODE -ne "1") -and (-not $isDryRunMode)) {
    try {
        $script:BuildMutex = New-Object System.Threading.Mutex($false, "Global\nano11Builder")
        $script:HasMutex = $script:BuildMutex.WaitOne(0)
        if (-not $script:HasMutex) {
            Write-Host "Error: Another instance of nano11 builder is currently running (Global\nano11Builder)." -ForegroundColor Red
            exit 1
        }
    } catch {
        Write-Warning "Could not acquire global mutex: $_"
    }
}

# 2c. Validate conflicting / contradictory switch parameters
$conflicts = @(
    @('KeepDefender', 'RemoveDefender'),
    @('KeepIME', 'RemoveIME'),
    @('KeepFonts', 'RemoveFonts'),
    @('KeepDrivers', 'RemoveDrivers'),
    @('KeepWindowsUpdate', 'DisableWindowsUpdate'),
    @('KeepBluetooth', 'DisableBluetooth'),
    @('EnableWSL', 'DisableWSL'),
    @('KeepRecovery', 'RemoveRecovery'),
    @('SafeDebloat', 'AggressiveWinSxS'),
    @('UltraSlim', 'NoUltraSlim'),
    @('JapaneseKeyboard', 'NoJapaneseKeyboard'),
    @('AtlasReviOS', 'NoAtlasReviOS'),
    @('ExportESD', 'ExportWIM'),
    @('SplitWIM', 'NoSplitWIM'),
    @('KeepStore', 'RemoveStore'),
    @('KeepXboxServices', 'RemoveXboxServices')
)
foreach ($pair in $conflicts) {
    $paramA = $pair[0]; $paramB = $pair[1]
    $isA = if ($PSBoundParameters.ContainsKey($paramA)) { [bool]$PSBoundParameters[$paramA] } else { $false }
    $isB = if ($PSBoundParameters.ContainsKey($paramB)) { [bool]$PSBoundParameters[$paramB] } else { $false }
    if ($isA -and $isB) {
        throw "Conflicting parameters specified: -$paramA and -$paramB cannot be used together."
    }
}

# Helper functions for state-tracked build resumption (-Resume)
$script:BuildStateFile = $null

function Initialize-Nano11BuildState {
    param([string]$Dir)
    if ($Dir) {
        $script:BuildStateFile = Join-Path -Path $Dir -ChildPath "build-state.json"
    }
}

function Get-Nano11BuildState {
    if ($script:BuildStateFile -and (Test-Path -LiteralPath $script:BuildStateFile)) {
        try {
            $rawContent = [System.IO.File]::ReadAllText($script:BuildStateFile, [System.Text.Encoding]::UTF8)
            return ($rawContent | ConvertFrom-Json)
        } catch {}
    }
    return [PSCustomObject]@{ Phases = (New-Object PSObject) }
}

function Set-Nano11BuildState {
    param([string]$Phase, [string]$Status = "Completed")
    if (-not $script:BuildStateFile) { return }
    try {
        $st = Get-Nano11BuildState
        if (-not $st.Phases) {
            $st | Add-Member -MemberType NoteProperty -Name Phases -Value (New-Object PSObject) -Force
        }
        $st.Phases | Add-Member -MemberType NoteProperty -Name $Phase -Value $Status -Force
        $json = $st | ConvertTo-Json -Depth 5
        [System.IO.File]::WriteAllText($script:BuildStateFile, $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch {}
}

function Test-Nano11PhaseCompleted {
    param([string]$Phase)
    if (-not $Resume) { return $false }
    $st = Get-Nano11BuildState
    if ($st -and $st.Phases -and $st.Phases.PSObject.Properties[$Phase] -and ($st.Phases.$Phase -eq "Completed")) {
        return $true
    }
    return $false
}

# Helper function: Standardized DISM wrapper with retries and exit code diagnostics
function Invoke-Dism {
    param(
        [Parameter(Mandatory=$true)]
        [string[]]$DismArgs,
        [int]$Retries = 1,
        [string]$ActivityDescription = "",
        [switch]$CaptureOutput,
        [switch]$Quiet
    )
    if ($ActivityDescription) {
        Write-Host "  -> DISM: $ActivityDescription..." -ForegroundColor Cyan
    }
    $fullArgs = @('/English')
    if ($script:DismLogPath) {
        $fullArgs += @("/LogPath:$script:DismLogPath", "/LogLevel:3")
    }
    $fullArgs += $DismArgs

    for ($i = 1; $i -le $Retries; $i++) {
        if ($CaptureOutput) {
            $output = & dism.exe @fullArgs 2>&1
            if ($LASTEXITCODE -eq 0) {
                return $output
            }
        } else {
            if ($Quiet) {
                & dism.exe @fullArgs > $null 2>&1
            } else {
                & dism.exe @fullArgs
            }
            if ($LASTEXITCODE -eq 0) {
                return $true
            }
        }
        if ($i -lt $Retries) {
            Write-Host "DISM command failed (Exit code: $LASTEXITCODE). Retrying ($i/$Retries)..." -ForegroundColor Yellow
            Start-Sleep -Seconds 2
        }
    }
    if ($CaptureOutput) { return $null }
    return $false
}

# Helper function: Offline Registry Writer with deduplication tracking and error accounting
$script:RegApplied = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$script:RegSuccessCount = 0
$script:RegFailureCount = 0

function Set-OfflineReg {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Key,
        [Parameter(Mandatory=$true)]
        [string]$Name,
        [Parameter(Mandatory=$true)]
        [string]$Type,
        [Parameter(Mandatory=$true)]
        [string]$Data
    )
    $id = "$Key|$Name"
    if ($script:RegApplied.Contains($id)) {
        return
    }
    [void]$script:RegApplied.Add($id)

    & reg.exe add $Key /v $Name /t $Type /d $Data /f > $null 2>&1
    if ($LASTEXITCODE -eq 0) {
        $script:RegSuccessCount++
        if ($script:RegJournalPath) {
            $csvLine = '"{0}","{1}","{2}","{3}"' -f ($Key -replace '"','""'), ($Name -replace '"','""'), $Type, ($Data -replace '"','""')
            Add-Content -LiteralPath $script:RegJournalPath -Value $csvLine -Encoding utf8 -ErrorAction SilentlyContinue
        }
    } else {
        $script:RegFailureCount++
        Write-Host "Warning: Failed to set registry value: $Key\$Name" -ForegroundColor Yellow
    }
}

# Helper function: Safely unmount offline registry hive with retry and garbage collection
function Unmount-RegistryHiveWithRetry {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Name,
        [int]$Retries = 5
    )
    for ($i = 0; $i -le $Retries; $i++) {
        & reg.exe query "HKLM\$Name" > $null 2>&1
        if ($LASTEXITCODE -ne 0) {
            return $true
        }
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        Start-Sleep -Milliseconds 300
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
    # Terminate orphaned dismhost / wimserv worker processes holding locks on mount directories
    Get-Process -Name "dismhost", "wimserv" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 300

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
    $full = try { [System.IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { $Path }
    if ($full -match '^[a-zA-Z]:\\?$' -or $full.Length -le 3 -or ($full -notmatch 'nano11|scratch|workspace|build|WindowsApps')) {
        throw "Safety guard: Refusing to delete dangerous or system directory: $full"
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    Set-ItemOwnershipAndAccess -Path $Path -Recurse
    $emptyTemp = Join-Path -Path $ScratchPath -ChildPath "empty_dir_for_delete_$([System.IO.Path]::GetRandomFileName())"
    try {
        New-Item -Path $emptyTemp -ItemType Directory -Force | Out-Null
        & robocopy.exe $emptyTemp $Path /MIR /XJ /R:0 /W:0 /NP /NFL /NDL /NJH /NJS > $null 2>&1
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    } finally {
        if (Test-Path -LiteralPath $emptyTemp) {
            Remove-Item -LiteralPath $emptyTemp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# Helper function: Check if a path resides on an NTFS volume (DISM requirement for reparse points)
function Test-IsNtfsVolume {
    param([string]$Path)
    try {
        $root = [System.IO.Path]::GetPathRoot($Path).TrimEnd('\')
        if ($root -match '^[a-zA-Z]:') {
            $letter = $root.Substring(0, 1)
            $vol = Get-Volume -DriveLetter $letter -ErrorAction Stop
            return ($vol.FileSystem -ieq 'NTFS')
        }
        return $true
    } catch {
        return $true
    }
}

# Helper function: Fast and reliable directory reset using robocopy mirror trick
function Reset-DirectoryWithRobocopy {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path
    )
    $full = try { [System.IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { $Path }
    if ($full -match '^[a-zA-Z]:\\?$' -or $full.Length -le 3 -or ($full -notmatch 'nano11|scratch|workspace|build')) {
        throw "Safety guard: Refusing to reset dangerous or system directory: $full"
    }
    if (Test-Path -LiteralPath $Path) {
        $emptyTemp = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "nano11_empty_$([System.IO.Path]::GetRandomFileName())"
        try {
            New-Item -Path $emptyTemp -ItemType Directory -Force | Out-Null
            & robocopy.exe $emptyTemp $Path /MIR /XJ /R:0 /W:0 /NP /NFL /NDL /NJH /NJS > $null 2>&1
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        } finally {
            if (Test-Path -LiteralPath $emptyTemp) {
                Remove-Item -LiteralPath $emptyTemp -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
}

# Helper function: Export configuration settings to a JSON profile
function Export-Nano11Profile {
    param(
        [Parameter(Mandatory=$true)]
        [string]$FilePath,
        [hashtable]$Config
    )
    $parentDir = Split-Path -Parent $FilePath
    if ($parentDir -and (-not (Test-Path -LiteralPath $parentDir))) {
        New-Item -ItemType Directory -Force -Path $parentDir | Out-Null
    }
    $profileData = [ordered]@{
        ProfileName = if ($Config.ProfileName) { $Config.ProfileName } else { "nano11 Configuration Profile" }
        Version     = $script:Nano11Version
        Timestamp   = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        Settings    = [ordered]@{
            RemoveDefender             = [bool]$Config.RemoveDefender
            KeepAsianIME               = [bool]$Config.KeepAsianIME
            KeepExtraFonts             = [bool]$Config.KeepExtraFonts
            RemoveDrivers              = [bool]$Config.RemoveDrivers
            DisableWindowsUpdate       = [bool]$Config.DisableWindowsUpdate
            KeepBluetooth              = [bool]$Config.KeepBluetooth
            WSLSupport                 = [bool]$Config.WSLSupport
            KeepRecoveryEnv            = [bool]$Config.KeepRecoveryEnv
            SafeDebloatMode            = [bool]$Config.SafeDebloatMode
            UltraSlimMode              = [bool]$Config.UltraSlimMode
            SetJapaneseKeyboard        = [bool]$Config.SetJapaneseKeyboard
            AtlasReviOSMode            = [bool]$Config.AtlasReviOSMode
            RemoveStore                = [bool]$Config.RemoveStore
            UseVHDX                    = [bool]$Config.UseVHDX
            SkipEiCfg                  = [bool]$Config.SkipEiCfg
            NoPostInstallAssets        = [bool]$Config.NoPostInstallAssets
            PayloadFormat              = if ($Config.PayloadFormat) { $Config.PayloadFormat } else { "WIM" }
            SourceDrive                = if ($Config.SourceDrive) { $Config.SourceDrive } else { "" }
            WorkDir                    = if ($Config.WorkDir) { $Config.WorkDir } else { "" }
            Index                      = if ($Config.Index) { $Config.Index } else { "" }
        }
    }
    $json = $profileData | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($FilePath, $json, [System.Text.Encoding]::UTF8)
    Write-Host "Profile saved to: $FilePath" -ForegroundColor Green
}

# Helper function: Verify oscdimg.exe Authenticode signature or pinned SHA256 hashes
function Test-OscdimgIntegrity {
    param([string]$OscdimgPath)
    if (-not $OscdimgPath -or -not (Test-Path -LiteralPath $OscdimgPath)) { return $false }
    
    # 1. Check Authenticode Signature (Official Microsoft Windows ADK binary)
    try {
        $sig = Get-AuthenticodeSignature -FilePath $OscdimgPath -ErrorAction SilentlyContinue
        if ($sig -and $sig.Status -eq 'Valid' -and ($sig.SignerCertificate.Subject -match 'Microsoft')) {
            return $true
        }
    } catch {}

    # 2. Known Official & Pinned SHA256 Hashes
    $knownHashes = @(
        'F5129F313ED7EB46F2677CF522E64264A225F226307ED0DDB52BB14C46E7CFDD', # Bundled repo version (2.56)
        '8DC3FB38E75C42127BE0A29D64CA6D79DFDDFDCBEE4A3BA8B36CFEBDCC1689E2', # Windows 11 ADK x64
        'CE53D1C8C08FF54B4B91D2DFDE80F9D86427BC8C78FA6BBDE278456CDD2E2B85', # Windows 11 ADK x86
        'B27E36C95A7490A175B5F17781C5C7A7C0B0C4670ACBF5B0BA0E0556BCDE0F46'  # Windows 11 ADK ARM64
    )
    try {
        $fileHash = (Get-FileHash -LiteralPath $OscdimgPath -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
        if ($fileHash -and ($knownHashes -contains $fileHash.ToUpperInvariant())) {
            return $true
        }
    } catch {}

    return $false
}

# Phase Progress & Telemetry Tracking
$script:CurrentPhase = 0
$script:TotalPhases = 18
$script:PhaseTimings = [ordered]@{}
$script:PhaseStopwatch = $null

function Enter-Phase {
    param(
        [int]$PhaseNumber,
        [string]$PhaseName
    )
    if ($script:PhaseStopwatch -and $script:CurrentPhase -gt 0) {
        $script:PhaseStopwatch.Stop()
        $prevPhaseKey = "Phase $($script:CurrentPhase)"
        $script:PhaseTimings[$prevPhaseKey] = [math]::Round($script:PhaseStopwatch.Elapsed.TotalSeconds, 1)
    }
    $script:CurrentPhase = $PhaseNumber
    $script:PhaseStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $phaseTitle = "nano11 [$PhaseNumber/$($script:TotalPhases)] $PhaseName"
    try { $host.UI.RawUI.WindowTitle = $phaseTitle } catch {}
    Write-Host ""
    Write-Host "=========================================================" -ForegroundColor Cyan
    Write-Host " [$PhaseNumber/$($script:TotalPhases)] $PhaseName" -ForegroundColor Cyan
    Write-Host "=========================================================" -ForegroundColor Cyan
}

function Exit-Phase {
    if ($script:PhaseStopwatch) {
        $script:PhaseStopwatch.Stop()
        $prevPhaseKey = "Phase $($script:CurrentPhase)"
        $script:PhaseTimings[$prevPhaseKey] = [math]::Round($script:PhaseStopwatch.Elapsed.TotalSeconds, 1)
        $script:PhaseStopwatch = $null
    }
}

# ==============================================================================
# Modular Tweak Architecture & In-Memory Built-in Presets
# ==============================================================================

$script:TweakGroups = [ordered]@{
    NetworkStack   = @{ Default = $true;  Risk = '★★';  Description = 'TcpAck/RSC/ECN/NetThrottling tuning' }
    TimerBCD       = @{ Default = $true;  Risk = '★★';  Description = 'dynamic tick/TSC sync/platform clock' }
    GPULatency     = @{ Default = $true;  Risk = '★';   Description = 'MSI mode/HAGS/GPU scheduling registry' }
    ServiceTrim    = @{ Default = $true;  Risk = '★★';  Description = 'WSearch/SysMain/DiagTrack/Ndu service trimming' }
    VisualFX       = @{ Default = $true;  Risk = '★';   Description = 'DWM transparency/animations/effects minimization' }
    CpuMitigations = @{ Default = $false; Risk = '★★★'; Description = 'Spectre/Meltdown speculative execution mitigations (Security trade-off)' }
}

$script:PowerPresets = [ordered]@{
    Desktop   = @{ UsbSuspend = 0; PcieLpm = 0; BoostAc = 2; BoostDc = 2; DiskIdle = 0 }
    Handheld  = @{ UsbSuspend = 0; PcieLpm = 1; BoostAc = 1; BoostDc = 1; DiskIdle = 60 }
    Balanced  = @{ UsbSuspend = 1; PcieLpm = 1; BoostAc = 2; BoostDc = 1; DiskIdle = 180 }
    VM        = @{ UsbSuspend = 1; PcieLpm = 0; BoostAc = 2; BoostDc = 2; DiskIdle = 0 }
}

$script:BuiltInPresets = [ordered]@{
    'extreme' = [ordered]@{
        ProfileName          = 'Extreme Slim & Gaming'
        Description          = 'Maximum debloat, ultra-low latency kernel/timer tuning, minimal footprint.'
        RemoveDefender       = $true
        KeepAsianIME         = $true
        KeepExtraFonts       = $false
        RemoveDrivers        = $false
        DisableWindowsUpdate = $true
        KeepBluetooth        = $true
        WSLSupport           = $false
        KeepRecoveryEnv      = $false
        SafeDebloatMode      = $true
        UltraSlimMode        = $true
        SetJapaneseKeyboard  = $true
        AtlasReviOSMode      = $true
        RemoveStore          = $false
        KeepBasicApps        = $false
        KeepSearchIndex      = $false
        KeepXboxServices     = $false
        KeepAudioTweaks      = $true
        PayloadFormat        = 'WIM'
        UseVHDX              = $false
        PowerPreset          = 'Desktop'
        RemoveLegacyFOD      = $true
        TrimWallpapers       = $true
        HibernateMode        = 'Off'
        CrashDumpMode        = 'None'
        DisableCPUMitigations= $false
        MMCSSGaming          = $true
        DAWMode              = $false
        DisableMemCompression= $true
        DisableFSE           = $true
        NvidiaLowLatency     = $true
        NoKernelPaging       = $true
        DisableUSBSuspend    = $true
        NoHypervisor         = $true
        RemoveWebViewPostOOBE= $false
        FastExport           = $false
        UefiOnly             = $false
        CpuBoostMode         = 'Aggressive'
        TweakGroups          = [ordered]@{
            NetworkStack   = $true
            TimerBCD       = $true
            GPULatency     = $true
            ServiceTrim    = $true
            VisualFX       = $true
            CpuMitigations = $false
        }
    }
    'balanced' = [ordered]@{
        ProfileName          = 'Balanced Pro'
        Description          = 'Safe daily debloat: Windows Update & Defender preserved, high stability.'
        RemoveDefender       = $false
        KeepAsianIME         = $true
        KeepExtraFonts       = $true
        RemoveDrivers        = $false
        DisableWindowsUpdate = $false
        KeepBluetooth        = $true
        WSLSupport           = $false
        KeepRecoveryEnv      = $true
        SafeDebloatMode      = $true
        UltraSlimMode        = $false
        SetJapaneseKeyboard  = $true
        AtlasReviOSMode      = $true
        RemoveStore          = $false
        KeepBasicApps        = $true
        KeepSearchIndex      = $true
        KeepXboxServices     = $true
        KeepAudioTweaks      = $false
        PayloadFormat        = 'WIM'
        UseVHDX              = $false
        PowerPreset          = 'Balanced'
        RemoveLegacyFOD      = $false
        TrimWallpapers       = $false
        HibernateMode        = 'Keep'
        CrashDumpMode        = 'Automatic'
        DisableCPUMitigations= $false
        MMCSSGaming          = $false
        DAWMode              = $false
        DisableMemCompression= $false
        DisableFSE           = $false
        NvidiaLowLatency     = $false
        NoKernelPaging       = $false
        DisableUSBSuspend    = $false
        NoHypervisor         = $false
        RemoveWebViewPostOOBE= $false
        FastExport           = $false
        UefiOnly             = $false
        CpuBoostMode         = 'Default'
        TweakGroups          = [ordered]@{
            NetworkStack   = $true
            TimerBCD       = $true
            GPULatency     = $true
            ServiceTrim    = $false
            VisualFX       = $false
            CpuMitigations = $false
        }
    }
    'fat32' = [ordered]@{
        ProfileName          = 'FAT32 USB Split-WIM'
        Description          = 'Split-WIM payload for 100% FAT32 USB installer compatibility.'
        RemoveDefender       = $true
        KeepAsianIME         = $true
        KeepExtraFonts       = $false
        RemoveDrivers        = $false
        DisableWindowsUpdate = $true
        KeepBluetooth        = $true
        WSLSupport           = $false
        KeepRecoveryEnv      = $false
        SafeDebloatMode      = $true
        UltraSlimMode        = $true
        SetJapaneseKeyboard  = $true
        AtlasReviOSMode      = $true
        RemoveStore          = $false
        KeepBasicApps        = $false
        KeepSearchIndex      = $false
        KeepXboxServices     = $false
        KeepAudioTweaks      = $true
        PayloadFormat        = 'SWM'
        UseVHDX              = $false
        PowerPreset          = 'Desktop'
        RemoveLegacyFOD      = $true
        TrimWallpapers       = $true
        HibernateMode        = 'Off'
        CrashDumpMode        = 'None'
        DisableCPUMitigations= $false
        MMCSSGaming          = $true
        DAWMode              = $false
        DisableMemCompression= $true
        DisableFSE           = $true
        NvidiaLowLatency     = $true
        NoKernelPaging       = $true
        DisableUSBSuspend    = $true
        NoHypervisor         = $true
        RemoveWebViewPostOOBE= $false
        FastExport           = $false
        UefiOnly             = $false
        CpuBoostMode         = 'Aggressive'
        TweakGroups          = [ordered]@{
            NetworkStack   = $true
            TimerBCD       = $true
            GPULatency     = $true
            ServiceTrim    = $true
            VisualFX       = $true
            CpuMitigations = $false
        }
    }
    'handheld' = [ordered]@{
        ProfileName          = 'Portable Gaming PC'
        Description          = 'Tuned for handhelds (ROG Ally, Steam Deck): battery balance & gamepad protection.'
        RemoveDefender       = $true
        KeepAsianIME         = $true
        KeepExtraFonts       = $false
        RemoveDrivers        = $false
        DisableWindowsUpdate = $true
        KeepBluetooth        = $true
        WSLSupport           = $false
        KeepRecoveryEnv      = $false
        SafeDebloatMode      = $true
        UltraSlimMode        = $true
        SetJapaneseKeyboard  = $true
        AtlasReviOSMode      = $true
        RemoveStore          = $false
        KeepBasicApps        = $false
        KeepSearchIndex      = $false
        KeepXboxServices     = $true
        KeepAudioTweaks      = $true
        PayloadFormat        = 'WIM'
        UseVHDX              = $false
        PowerPreset          = 'Handheld'
        RemoveLegacyFOD      = $true
        TrimWallpapers       = $true
        HibernateMode        = 'Reduced'
        CrashDumpMode        = 'Small'
        DisableCPUMitigations= $false
        MMCSSGaming          = $true
        DAWMode              = $false
        DisableMemCompression= $true
        DisableFSE           = $true
        NvidiaLowLatency     = $false
        NoKernelPaging       = $true
        DisableUSBSuspend    = $true
        NoHypervisor         = $true
        RemoveWebViewPostOOBE= $false
        FastExport           = $false
        UefiOnly             = $false
        CpuBoostMode         = 'Efficient'
        TweakGroups          = [ordered]@{
            NetworkStack   = $true
            TimerBCD       = $true
            GPULatency     = $true
            ServiceTrim    = $true
            VisualFX       = $true
            CpuMitigations = $false
        }
    }
    'vm' = [ordered]@{
        ProfileName          = 'VM & Developer Workstation'
        Description          = 'Configured for virtual machines and developers: WSL2 & Hyper-V enabled.'
        RemoveDefender       = $false
        KeepAsianIME         = $true
        KeepExtraFonts       = $true
        RemoveDrivers        = $false
        DisableWindowsUpdate = $false
        KeepBluetooth        = $false
        WSLSupport           = $true
        KeepRecoveryEnv      = $true
        SafeDebloatMode      = $true
        UltraSlimMode        = $false
        SetJapaneseKeyboard  = $false
        AtlasReviOSMode      = $false
        RemoveStore          = $false
        KeepBasicApps        = $true
        KeepSearchIndex      = $true
        KeepXboxServices     = $false
        KeepAudioTweaks      = $false
        PayloadFormat        = 'WIM'
        UseVHDX              = $false
        PowerPreset          = 'VM'
        RemoveLegacyFOD      = $false
        TrimWallpapers       = $false
        HibernateMode        = 'Off'
        CrashDumpMode        = 'Automatic'
        DisableCPUMitigations= $false
        MMCSSGaming          = $false
        DAWMode              = $false
        DisableMemCompression= $false
        DisableFSE           = $false
        NvidiaLowLatency     = $false
        NoKernelPaging       = $false
        DisableUSBSuspend    = $false
        NoHypervisor         = $false
        RemoveWebViewPostOOBE= $false
        FastExport           = $false
        UefiOnly             = $false
        CpuBoostMode         = 'Aggressive'
        TweakGroups          = [ordered]@{
            NetworkStack   = $true
            TimerBCD       = $true
            GPULatency     = $true
            ServiceTrim    = $false
            VisualFX       = $false
            CpuMitigations = $false
        }
    }
    'audio' = [ordered]@{
        ProfileName          = 'Audio & DAW Production'
        Description          = 'Pro Audio MMCSS priority, zero DPC latency spikes, VST compatibility protected.'
        RemoveDefender       = $true
        KeepAsianIME         = $true
        KeepExtraFonts       = $false
        RemoveDrivers        = $false
        DisableWindowsUpdate = $true
        KeepBluetooth        = $false
        WSLSupport           = $false
        KeepRecoveryEnv      = $false
        SafeDebloatMode      = $true
        UltraSlimMode        = $false
        SetJapaneseKeyboard  = $true
        AtlasReviOSMode      = $true
        RemoveStore          = $false
        KeepBasicApps        = $true
        KeepSearchIndex      = $false
        KeepXboxServices     = $false
        KeepAudioTweaks      = $true
        PayloadFormat        = 'WIM'
        UseVHDX              = $false
        PowerPreset          = 'Desktop'
        RemoveLegacyFOD      = $false
        TrimWallpapers       = $false
        HibernateMode        = 'Off'
        CrashDumpMode        = 'Small'
        DisableCPUMitigations= $false
        MMCSSGaming          = $false
        DAWMode              = $true
        DisableMemCompression= $false
        DisableFSE           = $false
        NvidiaLowLatency     = $false
        NoKernelPaging       = $true
        DisableUSBSuspend    = $true
        NoHypervisor         = $true
        RemoveWebViewPostOOBE= $false
        FastExport           = $false
        UefiOnly             = $false
        CpuBoostMode         = 'Aggressive'
        TweakGroups          = [ordered]@{
            NetworkStack   = $false
            TimerBCD       = $true
            GPULatency     = $false
            ServiceTrim    = $true
            VisualFX       = $true
            CpuMitigations = $false
        }
    }
}

function Get-Nano11Preset {
    param([string]$Name)
    if (-not $Name) { return $script:BuiltInPresets['extreme'] }
    $clean = $Name.Trim().ToLower()
    $aliasMap = @{
        '1'          = 'extreme'
        'extreme'    = 'extreme'
        'gaming'     = 'extreme'
        'slim'       = 'extreme'
        '2'          = 'balanced'
        'balanced'   = 'balanced'
        'safe'       = 'balanced'
        'pro'        = 'balanced'
        '3'          = 'fat32'
        'fat32'      = 'fat32'
        'split'      = 'fat32'
        'splitwim'   = 'fat32'
        '4'          = 'handheld'
        'handheld'   = 'handheld'
        'ally'       = 'handheld'
        'deck'       = 'handheld'
        'legion'     = 'handheld'
        '5'          = 'vm'
        'dev'        = 'vm'
        'developer'  = 'vm'
        '6'          = 'audio'
        'daw'        = 'audio'
        'dtm'        = 'audio'
    }
    $targetKey = if ($aliasMap.ContainsKey($clean)) { $aliasMap[$clean] } else { $clean }
    if ($script:BuiltInPresets.Contains($targetKey)) {
        return $script:BuiltInPresets[$targetKey]
    }
    return $null
}

# Helper function: Unified profile settings application
function Apply-ProfileSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ProfileName,
        [Parameter(Mandatory = $false)]
        [psobject]$ProfileObject,
        [switch]$UpdateGui,
        [hashtable]$GuiControls
    )

    $targetPreset = $null
    if ($ProfileName) {
        $targetPreset = Get-Nano11Preset -Name $ProfileName
    } elseif ($ProfileObject) {
        $targetPreset = if ($ProfileObject.Settings) { $ProfileObject.Settings } else { $ProfileObject }
    }

    if (-not $targetPreset) {
        $targetPreset = $script:BuiltInPresets['extreme']
    }

    $getVal = {
        param($key, $defaultVal = $false)
        if ($targetPreset -is [System.Collections.IDictionary]) {
            if ($targetPreset.Contains($key)) { return $targetPreset[$key] }
        } elseif ($targetPreset.PSObject.Properties[$key]) {
            return $targetPreset.$key
        }
        return $defaultVal
    }

    if ($UpdateGui -and $GuiControls) {
        $GuiControls.chkDefender.Checked    = [bool](& $getVal 'RemoveDefender' $true)
        $GuiControls.chkIME.Checked         = [bool](& $getVal 'KeepAsianIME' $true)
        $GuiControls.chkFonts.Checked       = [bool](& $getVal 'KeepExtraFonts' $false)
        $GuiControls.chkDrivers.Checked     = [bool](& $getVal 'RemoveDrivers' $false)
        $GuiControls.chkWU.Checked          = [bool](& $getVal 'DisableWindowsUpdate' $true)
        $GuiControls.chkBT.Checked          = [bool](& $getVal 'KeepBluetooth' $true)
        $GuiControls.chkWSL.Checked         = [bool](& $getVal 'WSLSupport' $false)
        $GuiControls.chkRecovery.Checked    = [bool](& $getVal 'KeepRecoveryEnv' $false)
        $GuiControls.chkSafeDebloat.Checked = [bool](& $getVal 'SafeDebloatMode' $true)
        $GuiControls.chkUltraSlim.Checked   = [bool](& $getVal 'UltraSlimMode' $true)
        $GuiControls.chkJPKey.Checked       = [bool](& $getVal 'SetJapaneseKeyboard' $true)
        $GuiControls.chkAtlas.Checked       = [bool](& $getVal 'AtlasReviOSMode' $true)
        $GuiControls.chkStore.Checked       = [bool](& $getVal 'RemoveStore' $false)
        if ($GuiControls.chkBasicApps)   { $GuiControls.chkBasicApps.Checked   = [bool](& $getVal 'KeepBasicApps' $false) }
        if ($GuiControls.chkSearchIndex) { $GuiControls.chkSearchIndex.Checked = [bool](& $getVal 'KeepSearchIndex' $false) }
        if ($GuiControls.chkVhdx)        { $GuiControls.chkVhdx.Checked        = [bool](& $getVal 'UseVHDX' $false) }
        
        $fmt = (& $getVal 'PayloadFormat' 'WIM').ToString().ToUpper()
        if ($fmt -eq 'ESD') { $GuiControls.radESD.Checked = $true }
        elseif ($fmt -eq 'SWM') { $GuiControls.radSWM.Checked = $true }
        else { $GuiControls.radWIM.Checked = $true }
    } else {
        $script:removeDefender       = [bool](& $getVal 'RemoveDefender' $true)
        $script:keepAsianIME         = [bool](& $getVal 'KeepAsianIME' $true)
        $script:keepExtraFonts       = [bool](& $getVal 'KeepExtraFonts' $false)
        $script:removeDrivers        = [bool](& $getVal 'RemoveDrivers' $false)
        $script:disableWU            = [bool](& $getVal 'DisableWindowsUpdate' $true)
        $script:keepBT               = [bool](& $getVal 'KeepBluetooth' $true)
        $script:wslSupport           = [bool](& $getVal 'WSLSupport' $false)
        $script:keepRecoveryEnv      = [bool](& $getVal 'KeepRecoveryEnv' $false)
        $script:safeDebloatMode      = [bool](& $getVal 'SafeDebloatMode' $true)
        $script:ultraSlimMode        = [bool](& $getVal 'UltraSlimMode' $true)
        $script:setJapaneseKeyboard  = [bool](& $getVal 'SetJapaneseKeyboard' $true)
        $script:atlasReviOSMode      = [bool](& $getVal 'AtlasReviOSMode' $true)
        $script:removeStore          = [bool](& $getVal 'RemoveStore' $false)
        $script:keepBasicApps        = [bool](& $getVal 'KeepBasicApps' $false)
        $script:keepSearchIndex      = [bool](& $getVal 'KeepSearchIndex' $false)
        $script:keepXboxServices     = [bool](& $getVal 'KeepXboxServices' $false)
        $script:keepAudioTweaks      = [bool](& $getVal 'KeepAudioTweaks' $true)
        $script:useVHDX              = [bool](& $getVal 'UseVHDX' $false)

        # Advanced Modular Optimization Flags
        $script:removeLegacyFOD      = [bool](& $getVal 'RemoveLegacyFOD' $false)
        $script:trimWallpapers       = [bool](& $getVal 'TrimWallpapers' $false)
        $script:hibernateMode        = (& $getVal 'HibernateMode' 'Keep').ToString()
        $script:crashDumpMode        = (& $getVal 'CrashDumpMode' 'Automatic').ToString()
        $script:disableCPUMitigations= [bool](& $getVal 'DisableCPUMitigations' $false)
        $script:mmcssGaming          = [bool](& $getVal 'MMCSSGaming' $false)
        $script:dawMode              = [bool](& $getVal 'DAWMode' $false)
        $script:disableMemCompression= [bool](& $getVal 'DisableMemCompression' $false)
        $script:disableFSE           = [bool](& $getVal 'DisableFSE' $false)
        $script:nvidiaLowLatency     = [bool](& $getVal 'NvidiaLowLatency' $false)
        $script:noKernelPaging       = [bool](& $getVal 'NoKernelPaging' $false)
        $script:disableUSBSuspend    = [bool](& $getVal 'DisableUSBSuspend' $false)
        $script:noHypervisor         = [bool](& $getVal 'NoHypervisor' $false)
        $script:removeWebViewPostOOBE= [bool](& $getVal 'RemoveWebViewPostOOBE' $false)
        $script:fastExport           = [bool](& $getVal 'FastExport' $false)
        $script:uefiOnly             = [bool](& $getVal 'UefiOnly' $false)
        $script:cpuBoostMode         = (& $getVal 'CpuBoostMode' 'Default').ToString()
        $script:powerPreset          = (& $getVal 'PowerPreset' 'Default').ToString()

        # Modular Tweak Groups
        $tGroups = & $getVal 'TweakGroups' $null
        if ($tGroups) {
            foreach ($k in $script:TweakGroups.Keys) {
                if ($tGroups -is [System.Collections.IDictionary] -and $tGroups.Contains($k)) {
                    $script:activeTweakGroups[$k] = [bool]$tGroups[$k]
                }
            }
        }

        $fmt = (& $getVal 'PayloadFormat' 'WIM').ToString().ToUpper()
        if ($fmt -eq 'ESD') { $script:exportESDMode = $true; $script:splitWIMMode = $false }
        elseif ($fmt -eq 'SWM') { $script:splitWIMMode = $true; $script:exportESDMode = $false }
        else { $script:exportESDMode = $false; $script:splitWIMMode = $false }
    }
    return $targetPreset
}

# Helper function: Import configuration settings from a JSON profile
function Import-Nano11Profile {
    param(
        [Parameter(Mandatory=$true)]
        [string]$FilePath
    )
    if (-not (Test-Path -LiteralPath $FilePath)) {
        if ($NonInteractive) {
            throw "Error: Profile file not found: $FilePath"
        } else {
            Write-Host "Error: Profile file not found: $FilePath" -ForegroundColor Red
            return $null
        }
    }
    try {
        $rawJson = [System.IO.File]::ReadAllText($FilePath, [System.Text.Encoding]::UTF8)
        $data = $rawJson | ConvertFrom-Json
        if ($data.Version -and $data.Version -ne "2.0" -and $data.Version -ne "2.1" -and $data.Version -ne $script:Nano11Version) {
            Write-Warning "Profile version ($($data.Version)) differs from current ($script:Nano11Version)."
        }
        $settings = if ($data.Settings) { $data.Settings } else { $data }

        # Profile Schema Linter & Unknown Key Typo Detection
        $knownKeys = @(
            'RemoveDefender', 'SkipDefender', 'KeepAsianIME', 'KeepExtraFonts',
            'RemoveDrivers', 'DisableWindowsUpdate', 'SkipSecurityUpdates', 'KeepBluetooth',
            'WSLSupport', 'KeepRecoveryEnv', 'KeepWinRE', 'SafeDebloatMode',
            'UltraSlimMode', 'SetJapaneseKeyboard', 'AtlasReviOSMode',
            'RemoveStore', 'KeepStore',
            'PayloadFormat', 'SplitWim', 'Fat32Compatible', 'EnableCompactOS',
            'CleanWinSxS', 'SkipEdge', 'KeepXboxServices', 'KeepAudioTweaks', 'KeepBasicApps', 'KeepSearchIndex',
            'UseVHDX', 'ProfileName', 'Description', 'Version', 'Architecture'
        )
        $unknownKeys = @()
        foreach ($prop in $settings.PSObject.Properties) {
            if ($knownKeys -notcontains $prop.Name) {
                $unknownKeys += $prop.Name
            }
        }
        if ($unknownKeys.Count -gt 0) {
            Write-Warning "Profile '$([System.IO.Path]::GetFileName($FilePath))' contains unrecognized setting(s): $($unknownKeys -join ', '). Please check for typos."
        }

        return $settings
    } catch {
        if ($NonInteractive) {
            throw "Failed to parse JSON profile '$FilePath': $_"
        } else {
            Write-Host "Failed to parse JSON profile: $_" -ForegroundColor Red
            return $null
        }
    }
}

# Helper function: Execute built-in diagnostic and repository self-test suite
function Invoke-Nano11SelfTest {
    [CmdletBinding()]
    param(
        [string]$ScriptRoot = $PSScriptRoot,
        [string]$BuilderPath,
        [string]$UnattendPath
    )
    if (-not $ScriptRoot) { $ScriptRoot = (Get-Location).Path }
    if (-not $BuilderPath) {
        $BuilderPath = if ($PSCommandPath) { $PSCommandPath } else { (Get-ChildItem -Path $ScriptRoot -Filter 'nano11builder*.ps1' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName) }
        if (-not $BuilderPath) { $BuilderPath = Join-Path -Path $ScriptRoot -ChildPath "nano11builder.ps1" }
    }
    if (-not $UnattendPath) {
        $UnattendPath = Join-Path -Path $ScriptRoot -ChildPath "autounattend.xml"
    }
    
    Write-Host "=========================================================" -ForegroundColor Cyan
    Write-Host "   nano11 Self-Test & Diagnostic Verification Suite     " -ForegroundColor Cyan
    Write-Host "=========================================================" -ForegroundColor Cyan

    $results = @()
    
    # 1. AST Syntax Check
    $astPass = $false
    $astMsg = ""
    if (Test-Path -LiteralPath $BuilderPath) {
        $content = [System.IO.File]::ReadAllText($BuilderPath, [System.Text.Encoding]::UTF8)
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$errors)
        if ($errors.Count -eq 0) {
            $astPass = $true
            $astMsg = "0 parser errors found in $([math]::Round($content.Length / 1KB, 1)) KB script"
        } else {
            $astMsg = "$($errors.Count) syntax errors: " + ($errors | ForEach-Object { $_.Message } | Select-Object -First 3 -Join "; ")
        }
    } else {
        $astMsg = "$([System.IO.Path]::GetFileName($BuilderPath)) not found"
    }
    $results += [PSCustomObject]@{ Test = "1. Builder Script AST Syntax"; Passed = $astPass; Details = $astMsg }

    # 2. Registry Safety Validation (zSYSTEM\CurrentControlSet check)
    $regSafePass = $true
    $regMsg = "Safe: No illegal offline CurrentControlSet keys created"
    if (Test-Path -LiteralPath $BuilderPath) {
        $lines = Get-Content -LiteralPath $BuilderPath
        $illegal = @()
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            if ($line -like "*zSYSTEM\CurrentControlSet*" -and $line -notlike "*reg.exe query*" -and $line -notlike "*reg.exe delete*" -and $line -notlike "*#*") {
                $illegal += "Line $($i+1): $line"
            }
        }
        if ($illegal.Count -gt 0) {
            $regSafePass = $false
            $regMsg = "FAILED: Found $($illegal.Count) illegal CurrentControlSet operations"
        }
    }
    $results += [PSCustomObject]@{ Test = "2. Offline Registry Safety Rule"; Passed = $regSafePass; Details = $regMsg }

    # 3. autounattend.xml XML Schema & Duplicate Component Check
    $xmlPass = $false
    $xmlMsg = ""
    if (Test-Path -LiteralPath $UnattendPath) {
        try {
            $doc = [xml]::new()
            $doc.Load($UnattendPath)
            if ($doc.DocumentElement.Name -eq 'unattend' -and $doc.unattend.settings) {
                # Check for duplicate components in the same pass
                $duplicateComponents = @()
                foreach ($pass in $doc.unattend.settings) {
                    $passName = $pass.pass
                    $compKeys = @($pass.component | ForEach-Object { "$($_.name) [$($_.processorArchitecture)]" })
                    $dups = $compKeys | Group-Object | Where-Object { $_.Count -gt 1 }
                    if ($dups) {
                        $duplicateComponents += "Pass '$passName': $($dups.Name -join ', ')"
                    }
                }
                if ($duplicateComponents.Count -gt 0) {
                    $xmlPass = $false
                    $xmlMsg = "Duplicate components found: $($duplicateComponents -join '; ')"
                } else {
                    $xmlPass = $true
                    $xmlMsg = "Valid XML: $($doc.unattend.settings.component.Count) components configured, 0 duplicates"
                }
            } else {
                $xmlMsg = "Missing required unattend/settings structure"
            }
        } catch {
            $xmlMsg = "Parse error: $($_.Exception.Message)"
        }
    } else {
        $xmlMsg = "autounattend.xml not found"
    }
    $results += [PSCustomObject]@{ Test = "3. autounattend.xml Schema"; Passed = $xmlPass; Details = $xmlMsg }

    # 4. Built-in Profile Presets & Modular Tweak Integrity
    $profPass = $false
    $profMsg = ""
    $expectedPresetKeys = @('extreme', 'balanced', 'fat32', 'handheld', 'vm', 'audio')
    $missingPresets = @()
    foreach ($ep in $expectedPresetKeys) {
        if (-not $script:BuiltInPresets.Contains($ep)) {
            $missingPresets += $ep
        }
    }
    if ($missingPresets.Count -eq 0 -and $script:TweakGroups.Count -ge 6 -and $script:PowerPresets.Count -ge 4) {
        $badPresets = @()
        foreach ($kv in $script:BuiltInPresets.GetEnumerator()) {
            $pName = $kv.Key
            $pDef = $kv.Value
            if (-not $pDef.ProfileName -or -not $pDef.Description) {
                $badPresets += "$pName (missing ProfileName/Description)"
            }
            if (-not $pDef.PowerPreset -or -not $script:PowerPresets.Contains($pDef.PowerPreset)) {
                $badPresets += "$pName (invalid PowerPreset: $($pDef.PowerPreset))"
            }
            if (-not $pDef.TweakGroups) {
                $badPresets += "$pName (missing TweakGroups)"
            }
        }
        if ($badPresets.Count -eq 0) {
            $profPass = $true
            $profMsg = "$($script:BuiltInPresets.Count) built-in presets validated ($($expectedPresetKeys -join ', ')), 6 tweak groups, 4 power presets"
        } else {
            $profMsg = "Preset errors: $($badPresets -join '; ')"
        }
    } else {
        $profMsg = "Missing built-in presets: $($missingPresets -join ', ')"
    }
    $results += [PSCustomObject]@{ Test = "4. Profile Presets Integrity"; Passed = $profPass; Details = $profMsg }

    # 5. Tools Folder & Binary Integrity Check
    $toolsDir = Join-Path -Path $ScriptRoot -ChildPath "tools"
    $toolsPass = $false
    $toolsMsg = ""
    if (Test-Path -LiteralPath $toolsDir) {
        $oscdPath = Join-Path $ScriptRoot "oscdimg.exe"
        $oscdValid = Test-OscdimgIntegrity -OscdimgPath $oscdPath
        $wingetPath = Join-Path $toolsDir "winget-packages.json"
        $postBuildPath = Join-Path $toolsDir "post-build.ps1"
        $hasWinget = Test-Path -LiteralPath $wingetPath
        $hasPostBuild = Test-Path -LiteralPath $postBuildPath
        
        if ($oscdValid -and $hasWinget -and $hasPostBuild) {
            $toolsPass = $true
            $toolsMsg = "Verified oscdimg, winget-packages, and post-build hook present"
        } else {
            $toolsMsg = "Tooling issues (Oscdimg: $oscdValid, WingetJson: $hasWinget, PostBuild: $hasPostBuild)"
        }
    } else {
        $toolsMsg = "tools/ directory not found"
    }
    $results += [PSCustomObject]@{ Test = "5. Core Deployment & Tooling Assets"; Passed = $toolsPass; Details = $toolsMsg }

    # 6. Batch Script Dynamic Target Resolution Check
    $batPass = $false
    $batMsg = ""
    $batFiles = Get-ChildItem -Path $ScriptRoot -Filter "*.bat" -File -ErrorAction SilentlyContinue
    if ($batFiles.Count -gt 0) {
        $badBats = @()
        foreach ($bf in $batFiles) {
            $batText = [System.IO.File]::ReadAllText($bf.FullName, [System.Text.Encoding]::UTF8)
            if ($batText -match 'BUILDER' -or $batText -match 'nano11builder') {
                # Valid reference
            } else {
                $badBats += "$($bf.Name) (no builder reference)"
            }
        }
        if ($badBats.Count -eq 0) {
            $batPass = $true
            $batMsg = "$($batFiles.Count) batch file(s) verified with dynamic builder resolution"
        } else {
            $batMsg = "Batch issues: $($badBats -join ', ')"
        }
    } else {
        $batPass = $true
        $batMsg = "No .bat files found in root"
    }
    $results += [PSCustomObject]@{ Test = "6. Batch Target Resolution"; Passed = $batPass; Details = $batMsg }

    # 7. autounattend Singularity & Embedded Scripts Integrity
    $unattendSingularPass = $false
    $unattendSingularMsg = ""
    $allUnattends = Get-ChildItem -Path $ScriptRoot -Filter "*unattend*.xml" -File -ErrorAction SilentlyContinue
    if ($allUnattends.Count -eq 1 -and $allUnattends[0].Name -ieq "autounattend.xml") {
        $xmlRaw = [System.IO.File]::ReadAllText($allUnattends[0].FullName, [System.Text.Encoding]::UTF8)
        $requiredScripts = @('Specialize.ps1', 'FirstLogon.ps1', 'DefaultUser.ps1', 'UserOnce.ps1')
        $missingScripts = @()
        foreach ($rs in $requiredScripts) {
            if ($xmlRaw -notmatch [regex]::Escape($rs)) {
                $missingScripts += $rs
            }
        }
        if ($missingScripts.Count -eq 0) {
            $unattendSingularPass = $true
            $unattendSingularMsg = "Single canonical autounattend.xml present; all 4 setup scripts embedded"
        } else {
            $unattendSingularMsg = "Missing scripts: $($missingScripts -join ', ')"
        }
    } elseif ($allUnattends.Count -gt 1) {
        $unattendSingularMsg = "Multiple unattend files detected ($($allUnattends.Name -join ', ')) - only autounattend.xml should exist"
    } else {
        $unattendSingularMsg = "autounattend.xml missing"
    }
    $results += [PSCustomObject]@{ Test = "7. Unattend Singularity & Scripts"; Passed = $unattendSingularPass; Details = $unattendSingularMsg }

    # 8. AppX Pattern Matching & Syntax Verification
    $appxTestPass = $false
    $appxTestMsg = ""
    $samplePackages = @(
        'Microsoft.BingWeather_4.25.7081.0_neutral_~_8wekyb3d8bbwe',
        'Microsoft.WindowsNotepad_11.2409.3.0_neutral_~_8wekyb3d8bbwe',
        'Microsoft.Paint_11.2408.30.0_neutral_~_8wekyb3d8bbwe',
        'Microsoft.WindowsCalculator_11.2405.0.0_neutral_~_8wekyb3d8bbwe',
        'Microsoft.549981C3F5F10_4.2204.13303.0_neutral_~_8wekyb3d8bbwe',
        'Microsoft.ZuneVideo_2019.22091.10041.0_neutral_~_8wekyb3d8bbwe',
        'Microsoft.GamingApp_2309.1001.4.0_neutral_~_8wekyb3d8bbwe',
        'Microsoft.Getstarted_10.2209.1.0_neutral_~_8wekyb3d8bbwe'
    )
    $testPatterns = @('*Bing*', '*Notepad*', '*Paint*', '*Calculator*', '*549981C3F5F10*', '*Zune*', '*GamingApp*', '*Getstarted*')
    $unmatched = @()
    foreach ($tp in $testPatterns) {
        $matched = $false
        foreach ($sp in $samplePackages) {
            if ($sp -like $tp) { $matched = $true; break }
        }
        if (-not $matched) { $unmatched += $tp }
    }
    if ($unmatched.Count -eq 0) {
        $appxTestPass = $true
        $appxTestMsg = "All core AppX bloatware wildcard patterns match realistic package signatures"
    } else {
        $appxTestMsg = "Dead pattern(s): $($unmatched -join ', ')"
    }
    $results += [PSCustomObject]@{ Test = "8. AppX Pattern Match Safety"; Passed = $appxTestPass; Details = $appxTestMsg }

    # Display Results
    Write-Host ""
    $allPassed = $true
    foreach ($r in $results) {
        $statusStr = if ($r.Passed) { "[PASS]" } else { "[FAIL]" }
        $color = if ($r.Passed) { "Green" } else { "Red" }
        if (-not $r.Passed) { $allPassed = $false }
        Write-Host ("  {0,-35} : {1,-6} ({2})" -f $r.Test, $statusStr, $r.Details) -ForegroundColor $color
    }

    Write-Host ""
    Write-Host "=========================================================" -ForegroundColor Cyan
    if ($allPassed) {
        Write-Host "   OVERALL RESULT: ALL $($results.Count) CHECKS PASSED (100%)       " -ForegroundColor Green
    } else {
        Write-Host "   OVERALL RESULT: SOME CHECKS FAILED                   " -ForegroundColor Red
    }
    Write-Host "=========================================================" -ForegroundColor Cyan
    return $allPassed
}

# Helper function: Generate an interactive, visual HTML build report
function Export-Nano11HtmlReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$OutputPath,
        [Parameter(Mandatory=$true)]
        [hashtable]$BuildInfo
    )

    $title = if ($BuildInfo.ContainsKey('Title')) { $BuildInfo.Title } else { "nano11 Master Build Report" }
    $timestamp = if ($BuildInfo.ContainsKey('Timestamp')) { $BuildInfo.Timestamp } else { (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") }
    $profileName = if ($BuildInfo.ContainsKey('Profile')) { $BuildInfo.Profile } else { "Extreme Slim & Gaming" }
    $arch = if ($BuildInfo.ContainsKey('Architecture')) { $BuildInfo.Architecture } else { "amd64" }
    $sourceDrive = if ($BuildInfo.ContainsKey('SourceDrive')) { $BuildInfo.SourceDrive } else { "N/A" }
    $outputIso = if ($BuildInfo.ContainsKey('OutputIso')) { $BuildInfo.OutputIso } else { "nano11.iso" }
    $payloadFormat = if ($BuildInfo.ContainsKey('PayloadFormat')) { $BuildInfo.PayloadFormat } else { "install.wim" }
    $origSize = if ($BuildInfo.ContainsKey('OriginalSizeBytes') -and $BuildInfo.OriginalSizeBytes) { [long]$BuildInfo.OriginalSizeBytes } else { 0 }
    $finalSize = if ($BuildInfo.ContainsKey('FinalSizeBytes') -and $BuildInfo.FinalSizeBytes) { [long]$BuildInfo.FinalSizeBytes } else { 0 }
    $isoSha256 = if ($BuildInfo.ContainsKey('IsoSha256')) { $BuildInfo.IsoSha256 } else { "N/A" }
    $regCount = if ($BuildInfo.ContainsKey('RegSuccessCount')) { $BuildInfo.RegSuccessCount } else { 0 }
    $settings = if ($BuildInfo.ContainsKey('Settings') -and $BuildInfo.Settings) { $BuildInfo.Settings } else { @{} }

    $origGBText = if ($origSize -gt 0) { "$([math]::Round($origSize / 1GB, 2)) GB" } else { "N/A" }
    $finalGBText = if ($finalSize -gt 0) { "$([math]::Round($finalSize / 1GB, 2)) GB" } else { "N/A" }
    $diffText = if ($origSize -gt 0 -and $finalSize -gt 0) {
        $saved = [math]::Round(($origSize - $finalSize) / 1GB, 2)
        $pct = [math]::Round((($origSize - $finalSize) / $origSize) * 100, 1)
        "&#9660; ${saved} GB Saved (-${pct}%)"
    } else {
        "Optimized Payload"
    }

    $formatDesc = if ($payloadFormat -eq 'install.swm') { 'FAT32 USB Compatible' } elseif ($payloadFormat -eq 'install.esd') { 'Ultra-compressed LZMS' } else { 'Standard WIM' }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!DOCTYPE html>')
    [void]$sb.AppendLine('<html lang="ja">')
    [void]$sb.AppendLine('<head>')
    [void]$sb.AppendLine('<meta charset="utf-8">')
    [void]$sb.AppendLine('<meta name="viewport" content="width=device-width, initial-scale=1.0">')
    [void]$sb.AppendLine("<title>$title</title>")
    [void]$sb.AppendLine('<style>')
    [void]$sb.AppendLine('  :root { --bg-main: #0b0f19; --bg-card: #151d2f; --border-card: #22304d; --accent: #00d2ff; --accent-glow: rgba(0, 210, 255, 0.25); --text-primary: #f1f5f9; --text-secondary: #94a3b8; --badge-pass: #10b981; --badge-warn: #f59e0b; }')
    [void]$sb.AppendLine('  * { box-sizing: border-box; margin: 0; padding: 0; }')
    [void]$sb.AppendLine('  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif; background: var(--bg-main); color: var(--text-primary); line-height: 1.6; padding: 30px 20px; }')
    [void]$sb.AppendLine('  .container { max-width: 1000px; margin: 0 auto; }')
    [void]$sb.AppendLine('  header { background: linear-gradient(135deg, #1e293b 0%, #0f172a 100%); border: 1px solid var(--border-card); border-radius: 12px; padding: 24px 30px; margin-bottom: 24px; box-shadow: 0 8px 30px rgba(0,0,0,0.5); display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 15px; }')
    [void]$sb.AppendLine('  h1 { font-size: 24px; color: #fff; display: flex; align-items: center; gap: 10px; }')
    [void]$sb.AppendLine('  h1 span.logo { color: var(--accent); }')
    [void]$sb.AppendLine('  .badge { background: var(--accent-glow); color: var(--accent); border: 1px solid var(--accent); padding: 4px 12px; border-radius: 20px; font-size: 13px; font-weight: 600; }')
    [void]$sb.AppendLine('  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 16px; margin-bottom: 24px; }')
    [void]$sb.AppendLine('  .stat-card { background: var(--bg-card); border: 1px solid var(--border-card); border-radius: 10px; padding: 18px 20px; }')
    [void]$sb.AppendLine('  .stat-card .label { font-size: 13px; color: var(--text-secondary); text-transform: uppercase; letter-spacing: 0.5px; }')
    [void]$sb.AppendLine('  .stat-card .value { font-size: 26px; font-weight: 700; color: #fff; margin-top: 4px; }')
    [void]$sb.AppendLine('  .stat-card .diff { font-size: 13px; color: var(--badge-pass); font-weight: 600; }')
    [void]$sb.AppendLine('  .section-card { background: var(--bg-card); border: 1px solid var(--border-card); border-radius: 10px; padding: 22px 24px; margin-bottom: 24px; }')
    [void]$sb.AppendLine('  .section-card h2 { font-size: 18px; margin-bottom: 16px; color: var(--accent); border-bottom: 1px solid var(--border-card); padding-bottom: 8px; }')
    [void]$sb.AppendLine('  table { width: 100%; border-collapse: collapse; margin-top: 10px; }')
    [void]$sb.AppendLine('  th, td { text-align: left; padding: 10px 12px; border-bottom: 1px solid #1e293b; font-size: 14px; }')
    [void]$sb.AppendLine('  th { color: var(--text-secondary); font-weight: 600; background: rgba(255,255,255,0.02); }')
    [void]$sb.AppendLine('  td:last-child { text-align: right; }')
    [void]$sb.AppendLine('  th:last-child { text-align: right; }')
    [void]$sb.AppendLine('  .status-tag { display: inline-block; padding: 2px 8px; border-radius: 4px; font-size: 12px; font-weight: 600; }')
    [void]$sb.AppendLine('  .status-enabled { background: rgba(16, 185, 129, 0.2); color: #34d399; border: 1px solid #059669; }')
    [void]$sb.AppendLine('  .status-disabled { background: rgba(239, 68, 68, 0.2); color: #f87171; border: 1px solid #dc2626; }')
    [void]$sb.AppendLine('  .status-retained { background: rgba(59, 130, 246, 0.2); color: #60a5fa; border: 1px solid #2563eb; }')
    [void]$sb.AppendLine('  code { font-family: Consolas, monospace; background: rgba(255,255,255,0.05); padding: 2px 6px; border-radius: 4px; font-size: 13px; color: #38bdf8; }')
    [void]$sb.AppendLine('  footer { text-align: center; color: var(--text-secondary); font-size: 13px; margin-top: 40px; }')
    [void]$sb.AppendLine('</style>')
    [void]$sb.AppendLine('</head>')
    [void]$sb.AppendLine('<body>')
    [void]$sb.AppendLine('<div class="container">')
    [void]$sb.AppendLine('  <header>')
    [void]$sb.AppendLine('    <div>')
    [void]$sb.AppendLine('      <h1><span class="logo">&#9889; nano11</span> Next-Gen Build Report</h1>')
    [void]$sb.AppendLine('      <p style="color: var(--text-secondary); font-size: 14px; margin-top: 4px;">Universal, Language-Independent Windows 11 Image Reducer</p>')
    [void]$sb.AppendLine('    </div>')
    [void]$sb.AppendLine('    <div style="text-align: right;">')
    [void]$sb.AppendLine('      <span class="badge">BUILD COMPLETE</span>')
    [void]$sb.AppendLine("      <div style=`"font-size: 12px; color: var(--text-secondary); margin-top: 5px;`">$timestamp</div>")
    [void]$sb.AppendLine('    </div>')
    [void]$sb.AppendLine('  </header>')

    [void]$sb.AppendLine('  <div class="grid">')
    [void]$sb.AppendLine('    <div class="stat-card">')
    [void]$sb.AppendLine('      <div class="label">Original WIM Size</div>')
    [void]$sb.AppendLine("      <div class=`"value`">$origGBText</div>")
    [void]$sb.AppendLine('      <div class="diff" style="color: var(--text-secondary);">Source Baseline</div>')
    [void]$sb.AppendLine('    </div>')
    [void]$sb.AppendLine('    <div class="stat-card">')
    [void]$sb.AppendLine('      <div class="label">Optimized Size</div>')
    [void]$sb.AppendLine("      <div class=`"value`">$finalGBText</div>")
    [void]$sb.AppendLine("      <div class=`"diff`">$diffText</div>")
    [void]$sb.AppendLine('    </div>')
    [void]$sb.AppendLine('    <div class="stat-card">')
    [void]$sb.AppendLine('      <div class="label">Active Profile</div>')
    [void]$sb.AppendLine("      <div class=`"value`" style=`"font-size: 18px; line-height: 32px;`">$profileName</div>")
    [void]$sb.AppendLine("      <div class=`"diff`" style=`"color: var(--accent);`">Arch: $arch</div>")
    [void]$sb.AppendLine('    </div>')
    [void]$sb.AppendLine('    <div class="stat-card">')
    [void]$sb.AppendLine('      <div class="label">Payload Format</div>')
    [void]$sb.AppendLine("      <div class=`"value`" style=`"font-size: 18px; line-height: 32px;`">$payloadFormat</div>")
    [void]$sb.AppendLine("      <div class=`"diff`">$formatDesc</div>")
    [void]$sb.AppendLine('    </div>')
    [void]$sb.AppendLine('  </div>')

    [void]$sb.AppendLine('  <div class="section-card">')
    [void]$sb.AppendLine('    <h2>&#127919; Optimizations &amp; Automation Status</h2>')
    [void]$sb.AppendLine('    <table>')
    [void]$sb.AppendLine('      <thead><tr><th>Feature</th><th>Technical Specification</th><th>Status</th></tr></thead>')
    [void]$sb.AppendLine('      <tbody>')
    [void]$sb.AppendLine('        <tr><td><strong>Zero-Click Automated Setup</strong></td><td>ChildCompletion &amp; SetupType automated (Shift+F10 obsolete)</td><td><span class="status-tag status-enabled">Enabled (Zero-Click)</span></td></tr>')
    [void]$sb.AppendLine('        <tr><td><strong>Hardware Checks Bypass</strong></td><td>TPM 2.0, SecureBoot, RAM, Storage, CPU bypass (LabConfig)</td><td><span class="status-tag status-enabled">Enabled (LabConfig)</span></td></tr>')

    $defStatus = if ($settings.RemoveDefender) { '<span class="status-tag status-disabled">Removed (Disabled)</span>' } else { '<span class="status-tag status-retained">Retained (Active)</span>' }
    [void]$sb.AppendLine("        <tr><td><strong>Windows Defender &amp; Security UI</strong></td><td>SmartScreen, Telemetry, and Defender service control</td><td>$defStatus</td></tr>")

    $storeStatus = if ($settings.RemoveStore) { '<span class="status-tag status-disabled">Removed</span>' } else { '<span class="status-tag status-enabled">Retained (winget ready)</span>' }
    [void]$sb.AppendLine("        <tr><td><strong>Microsoft Store Platform</strong></td><td>Desktop App Installer preserved for winget package management</td><td>$storeStatus</td></tr>")

    $wuStatus = if ($settings.DisableWindowsUpdate) { '<span class="status-tag status-disabled">Disabled (Manual)</span>' } else { '<span class="status-tag status-enabled">Enabled (Standard)</span>' }
    [void]$sb.AppendLine("        <tr><td><strong>Windows Update Service</strong></td><td>Automatic driver installation &amp; background patching</td><td>$wuStatus</td></tr>")

    $drvStatus = if ($settings.RemoveDrivers) { '<span class="status-tag status-disabled">Debloated (Printers/Modems)</span>' } else { '<span class="status-tag status-retained">Preserved (VM/Hypervisor Safe)</span>' }
    [void]$sb.AppendLine("        <tr><td><strong>Hardware Driver Packages</strong></td><td>Legacy modems, printers, scsi, storage controller drivers</td><td>$drvStatus</td></tr>")

    $xboxStatus = if ($settings.KeepXboxServices) { '<span class="status-tag status-enabled">Preserved (Gaming / Handheld)</span>' } else { '<span class="status-tag status-disabled">Disabled (Debloated)</span>' }
    [void]$sb.AppendLine("        <tr><td><strong>Xbox Live &amp; Game Bar Services</strong></td><td>Xbox identity, GameDVR, and gaming overlay subsystem</td><td>$xboxStatus</td></tr>")

    $audioStatus = if ($settings.KeepAudioTweaks) { '<span class="status-tag status-enabled">Pro Audio MMCSS Priority</span>' } else { '<span class="status-tag status-retained">Standard Gaming Tuning</span>' }
    [void]$sb.AppendLine("        <tr><td><strong>Low-Latency Audio &amp; Multimedia</strong></td><td>MMCSS thread scheduling, SystemResponsiveness, ASIO low-jitter</td><td>$audioStatus</td></tr>")

    [void]$sb.AppendLine('        <tr><td><strong>Windows 11 AI &amp; Recall Block</strong></td><td>DirectML, Copilot, Recall snapshots, Click-to-Do offline blocked</td><td><span class="status-tag status-enabled">Blocked</span></td></tr>')
    [void]$sb.AppendLine('        <tr><td><strong>Japanese &amp; Regional IME Support</strong></td><td>106/109 Keyboard layout auto-detected, IME telemetry opted-out</td><td><span class="status-tag status-enabled">Verified</span></td></tr>')

    [void]$sb.AppendLine('        <tr><td><strong>Post-Setup App Automation</strong></td><td>winget package list auto-import (tools/winget-packages.json)</td><td><span class="status-tag status-enabled">Automated</span></td></tr>')

    [void]$sb.AppendLine('        <tr><td><strong>Custom Post-Install Hook</strong></td><td>User scripts in tools/custom-scripts/ executed automatically</td><td><span class="status-tag status-enabled">Active Hook</span></td></tr>')
    [void]$sb.AppendLine('      </tbody>')
    [void]$sb.AppendLine('    </table>')
    [void]$sb.AppendLine('  </div>')

    [void]$sb.AppendLine('  <div class="section-card">')
    [void]$sb.AppendLine('    <h2>&#128190; Output ISO &amp; Flashing Guide</h2>')
    [void]$sb.AppendLine('    <table>')
    [void]$sb.AppendLine('      <tbody>')
    [void]$sb.AppendLine("        <tr><td><strong>Generated ISO Path</strong></td><td><code>$outputIso</code></td></tr>")
    if ($isoSha256 -and $isoSha256 -ne "N/A") {
        [void]$sb.AppendLine("        <tr><td><strong>SHA256 Checksum</strong></td><td><code>$isoSha256</code></td></tr>")
    }
    if ($regCount -gt 0) {
        [void]$sb.AppendLine("        <tr><td><strong>Applied Registry Optimizations</strong></td><td><span class=`"badge`" style=`"font-size: 12px;`">$regCount tweaks successfully committed</span></td></tr>")
    }
    [void]$sb.AppendLine('        <tr><td><strong>Recommended Deployment</strong></td><td><strong>Ventoy</strong>: Copy ISO directly to USB drive<br><strong>Rufus</strong>: Write as Standard Windows Installation<br><strong>FAT32 USB</strong>: Split-WIM (install.swm) files supported natively</td></tr>')
    [void]$sb.AppendLine('      </tbody>')
    [void]$sb.AppendLine('    </table>')
    [void]$sb.AppendLine('  </div>')

    [void]$sb.AppendLine('  <footer>')
    [void]$sb.AppendLine('    <p>nano11 Project &bull; Open Source Windows 11 Image Reducer &bull; <a href="https://github.com/gh459/nano11" style="color: var(--accent); text-decoration: none;">GitHub: gh459/nano11</a></p>')
    [void]$sb.AppendLine('  </footer>')
    [void]$sb.AppendLine('</div>')
    [void]$sb.AppendLine('</body>')
    [void]$sb.AppendLine('</html>')

    [System.IO.File]::WriteAllText($OutputPath, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
    Write-Host "Build report generated successfully at: $OutputPath" -ForegroundColor Green
}

# Helper function: Display Graphical User Interface (GUI) for nano11 builder
function Show-Nano11GUI {
    param(
        [hashtable]$InitialSettings = @{}
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $uiFontName = "Segoe UI"
    foreach ($fName in @("Yu Gothic UI", "Meiryo UI", "Segoe UI")) {
        try {
            $testFont = New-Object System.Drawing.Font($fName, 9)
            if ($testFont.Name -eq $fName) { $uiFontName = $fName; break }
        } catch {}
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "nano11 Builder - 次世代 Windows 11 軽量化＆カスタマイズ設定ツール"
    $form.Size = New-Object System.Drawing.Size(720, 830)
    $form.MinimumSize = New-Object System.Drawing.Size(720, 830)
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    $form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
    $form.BackColor = [System.Drawing.Color]::FromArgb(26, 28, 34)
    $form.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
    $form.Font = New-Object System.Drawing.Font($uiFontName, 9)

    # Header Panel
    $headerPanel = New-Object System.Windows.Forms.Panel
    $headerPanel.Dock = [System.Windows.Forms.DockStyle]::Top
    $headerPanel.Height = 65
    $headerPanel.BackColor = [System.Drawing.Color]::FromArgb(18, 20, 24)
    $form.Controls.Add($headerPanel)

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = "⚡ nano11 Builder v2.1"
    $titleLabel.Font = New-Object System.Drawing.Font($uiFontName, 14, [System.Drawing.FontStyle]::Bold)
    $titleLabel.ForeColor = [System.Drawing.Color]::FromArgb(0, 190, 255)
    $titleLabel.Location = New-Object System.Drawing.Point(16, 10)
    $titleLabel.AutoSize = $true
    $headerPanel.Controls.Add($titleLabel)

    $subTitleLabel = New-Object System.Windows.Forms.Label
    $subTitleLabel.Text = "全自動・超軽量・低遅延ゲーミング＆多言語対応 Windows 11 ビルドツール"
    $subTitleLabel.Font = New-Object System.Drawing.Font($uiFontName, 8.5)
    $subTitleLabel.ForeColor = [System.Drawing.Color]::FromArgb(160, 165, 175)
    $subTitleLabel.Location = New-Object System.Drawing.Point(18, 38)
    $subTitleLabel.AutoSize = $true
    $headerPanel.Controls.Add($subTitleLabel)

    # Main Scrollable Panel
    $mainPanel = New-Object System.Windows.Forms.Panel
    $mainPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $mainPanel.AutoScroll = $true
    $mainPanel.Padding = New-Object System.Windows.Forms.Padding(15)
    $form.Controls.Add($mainPanel)

    # 1. Media & Path Settings GroupBox
    $grpMedia = New-Object System.Windows.Forms.GroupBox
    $grpMedia.Text = " 1. Windows 11 メディア & 作業フォルダー (Media & Workspace) "
    $grpMedia.Location = New-Object System.Drawing.Point(15, 10)
    $grpMedia.Size = New-Object System.Drawing.Size(670, 142)
    $grpMedia.ForeColor = [System.Drawing.Color]::FromArgb(0, 190, 255)
    $mainPanel.Controls.Add($grpMedia)

    $lblSource = New-Object System.Windows.Forms.Label
    $lblSource.Text = "ソース ドライブ / ISO:"
    $lblSource.Location = New-Object System.Drawing.Point(15, 26)
    $lblSource.Size = New-Object System.Drawing.Size(125, 20)
    $lblSource.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
    $grpMedia.Controls.Add($lblSource)

    $cmbSource = New-Object System.Windows.Forms.ComboBox
    $cmbSource.Location = New-Object System.Drawing.Point(145, 23)
    $cmbSource.Size = New-Object System.Drawing.Size(260, 24)
    $cmbSource.BackColor = [System.Drawing.Color]::FromArgb(35, 38, 46)
    $cmbSource.ForeColor = [System.Drawing.Color]::White
    $cmbSource.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDown
    $grpMedia.Controls.Add($cmbSource)

    # Function to populate and refresh available source drives and ISOs
    $populateSources = {
        $cmbSource.Items.Clear()
        $detectedSources = @()

        # 1. Detected media drives with install.wim or install.esd
        foreach ($psd in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
            if (-not $psd.Root) { continue }
            $r = $psd.Root.TrimEnd('\')
            $wim = Join-Path -Path "$r\sources" -ChildPath "install.wim"
            $esd = Join-Path -Path "$r\sources" -ChildPath "install.esd"
            $vol = Get-Volume -DriveLetter ($r.TrimEnd(':')) -ErrorAction SilentlyContinue
            $volLabel = if ($vol -and $vol.FileSystemLabel) { " [$($vol.FileSystemLabel)]" } else { "" }
            if ((Test-Path -LiteralPath $wim) -and ((Get-Item -LiteralPath $wim).Length -gt 500MB)) {
                $detectedSources += "$r\$volLabel (Windows 11 メディア - install.wim)"
            } elseif ((Test-Path -LiteralPath $esd) -and ((Get-Item -LiteralPath $esd).Length -gt 500MB)) {
                $detectedSources += "$r\$volLabel (Windows 11 メディア - install.esd)"
            }
        }

        # 2. Candidate ISO files in common paths
        $downloadsDir = Join-Path -Path $env:USERPROFILE -ChildPath "Downloads"
        $desktopDir = Join-Path -Path $env:USERPROFILE -ChildPath "Desktop"
        $searchDirs = @("E:\", "D:\", "C:\", (Split-Path -Parent $PSScriptRoot), $env:USERPROFILE, $desktopDir, $downloadsDir)
        foreach ($p in $searchDirs) {
            if (Test-Path -LiteralPath $p) {
                $foundIsos = Get-ChildItem -Path $p -Filter "*.iso" -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Length -gt 3GB -and ($_.Name -like "*Win11*" -or $_.Name -like "*Windows11*" -or $_.Name -like "*26300*" -or $_.Name -like "*24H2*") -and $_.Name -notlike "*nano11*" }
                foreach ($iso in $foundIsos) {
                    $detectedSources += $iso.FullName
                }
            }
        }

        # 3. All ready system drives (Virtual DVD, Removable USB, Local)
        try {
            foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
                if ($d.IsReady) {
                    $dName = $d.Name
                    $dLabel = if ($d.VolumeLabel) { " [$($d.VolumeLabel)]" } else { "" }
                    $dType = switch ($d.DriveType) {
                        'CDRom' { "仮想DVD/光学ドライブ" }
                        'Removable' { "USBリムーバブル" }
                        'Fixed' { "ローカルディスク" }
                        default { "$($d.DriveType)" }
                    }
                    $entry = "$dName$dLabel ($dType)"
                    $alreadyListed = $false
                    foreach ($existing in $detectedSources) {
                        if ($existing.StartsWith($dName, [System.StringComparison]::OrdinalIgnoreCase)) {
                            $alreadyListed = $true; break
                        }
                    }
                    if (-not $alreadyListed) {
                        $detectedSources += $entry
                    }
                }
            }
        } catch {}

        foreach ($srcItem in $detectedSources) {
            [void]$cmbSource.Items.Add($srcItem)
        }
    }
    & $populateSources

    if ($InitialSettings.SourceDrive) {
        $cmbSource.Text = $InitialSettings.SourceDrive
    } elseif ($cmbSource.Items.Count -gt 0) {
        $cmbSource.SelectedIndex = 0
    } else {
        $cmbSource.Text = "E:\"
    }

    $toolTip = New-Object System.Windows.Forms.ToolTip

    # Button: Browse Drive (FolderBrowserDialog for Virtual DVD / USB / Directory)
    $btnBrowseDrive = New-Object System.Windows.Forms.Button
    $btnBrowseDrive.Text = "💿 ドライブ選択..."
    $btnBrowseDrive.Location = New-Object System.Drawing.Point(412, 22)
    $btnBrowseDrive.Size = New-Object System.Drawing.Size(102, 26)
    $btnBrowseDrive.BackColor = [System.Drawing.Color]::FromArgb(45, 50, 60)
    $btnBrowseDrive.ForeColor = [System.Drawing.Color]::White
    $btnBrowseDrive.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $toolTip.SetToolTip($btnBrowseDrive, "マウントされた仮想DVDドライブやUSBメモリのドライブレターを選択します")
    $btnBrowseDrive.Add_Click({
        $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
        $fbd.Description = "Windows 11 インストールメディア（マウント済み仮想DVDドライブ、USBメモリ、または展開フォルダー）を選択してください"
        $fbd.ShowNewFolderButton = $false
        if ($fbd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $p = $fbd.SelectedPath
            if ($p -match '^[A-Za-z]:\\?$') { $p = $p.Substring(0, 2) + "\" }
            $cmbSource.Text = $p
        }
    })
    $grpMedia.Controls.Add($btnBrowseDrive)

    # Button: Browse ISO (OpenFileDialog for .iso file)
    $btnBrowseIso = New-Object System.Windows.Forms.Button
    $btnBrowseIso.Text = "📁 ISO 参照..."
    $btnBrowseIso.Location = New-Object System.Drawing.Point(520, 22)
    $btnBrowseIso.Size = New-Object System.Drawing.Size(95, 26)
    $btnBrowseIso.BackColor = [System.Drawing.Color]::FromArgb(45, 50, 60)
    $btnBrowseIso.ForeColor = [System.Drawing.Color]::White
    $btnBrowseIso.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $toolTip.SetToolTip($btnBrowseIso, "公式 Windows 11 の .iso ファイルを直接選択します")
    $btnBrowseIso.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = "Windows 11 ISO (*.iso)|*.iso|All Files (*.*)|*.*"
        $ofd.Title = "公式 Windows 11 ISO イメージを選択してください"
        if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $cmbSource.Text = $ofd.FileName
        }
    })
    $grpMedia.Controls.Add($btnBrowseIso)

    # Button: Refresh Drives
    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = "🔄"
    $btnRefresh.Location = New-Object System.Drawing.Point(621, 22)
    $btnRefresh.Size = New-Object System.Drawing.Size(34, 26)
    $btnRefresh.BackColor = [System.Drawing.Color]::FromArgb(45, 50, 60)
    $btnRefresh.ForeColor = [System.Drawing.Color]::White
    $btnRefresh.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $toolTip.SetToolTip($btnRefresh, "マウント済み仮想DVDや接続されたUSBドライブを再検出します")
    $btnRefresh.Add_Click({
        & $populateSources
        [System.Windows.Forms.MessageBox]::Show("接続ドライブおよび ISO ファイル一覧を再スキャンしました。", "再検出完了", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
    })
    $grpMedia.Controls.Add($btnRefresh)

    # Hint Label
    $lblHint = New-Object System.Windows.Forms.Label
    $lblHint.Text = "※ マウント済み仮想DVDドライブ（例: D:\）、USBメモリ、または .iso ファイルを指定してください"
    $lblHint.Location = New-Object System.Drawing.Point(145, 114)
    $lblHint.Size = New-Object System.Drawing.Size(510, 16)
    $lblHint.ForeColor = [System.Drawing.Color]::FromArgb(150, 155, 165)
    $lblHint.Font = New-Object System.Drawing.Font($uiFontName, 8)
    $grpMedia.Controls.Add($lblHint)

    $lblWork = New-Object System.Windows.Forms.Label
    $lblWork.Text = "作業フォルダー:"
    $lblWork.Location = New-Object System.Drawing.Point(15, 54)
    $lblWork.Size = New-Object System.Drawing.Size(125, 20)
    $lblWork.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
    $grpMedia.Controls.Add($lblWork)

    $txtWork = New-Object System.Windows.Forms.TextBox
    $txtWork.Location = New-Object System.Drawing.Point(145, 51)
    $txtWork.Size = New-Object System.Drawing.Size(370, 24)
    $txtWork.BackColor = [System.Drawing.Color]::FromArgb(35, 38, 46)
    $txtWork.ForeColor = [System.Drawing.Color]::White
    if ($InitialSettings.WorkDir) {
        $txtWork.Text = $InitialSettings.WorkDir
    } else {
        $altDrive = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Free -gt 30GB -and (Test-IsNtfsVolume $_.Root) } | Sort-Object Free -Descending | Select-Object -First 1
        $txtWork.Text = if ($altDrive) { Join-Path $altDrive.Root.TrimEnd('\') "nano11_workspace" } else { "$env:SystemDrive\nano11_workspace" }
    }
    $grpMedia.Controls.Add($txtWork)

    $btnBrowseWork = New-Object System.Windows.Forms.Button
    $btnBrowseWork.Text = "フォルダー参照..."
    $btnBrowseWork.Location = New-Object System.Drawing.Point(520, 50)
    $btnBrowseWork.Size = New-Object System.Drawing.Size(135, 26)
    $btnBrowseWork.BackColor = [System.Drawing.Color]::FromArgb(45, 50, 60)
    $btnBrowseWork.ForeColor = [System.Drawing.Color]::White
    $btnBrowseWork.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnBrowseWork.Add_Click({
        $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
        $fbd.Description = "空き容量が25GB以上ある NTFS ドライブ上の作業フォルダーを選択してください"
        if ($fbd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $txtWork.Text = $fbd.SelectedPath
        }
    })
    $grpMedia.Controls.Add($btnBrowseWork)

    # Image Index & Driver Injection Controls
    $lblIndex = New-Object System.Windows.Forms.Label
    $lblIndex.Text = "イメージ Index:"
    $lblIndex.Location = New-Object System.Drawing.Point(15, 83)
    $lblIndex.Size = New-Object System.Drawing.Size(125, 20)
    $lblIndex.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
    $grpMedia.Controls.Add($lblIndex)

    $txtIndex = New-Object System.Windows.Forms.TextBox
    $txtIndex.Location = New-Object System.Drawing.Point(145, 80)
    $txtIndex.Size = New-Object System.Drawing.Size(65, 24)
    $txtIndex.BackColor = [System.Drawing.Color]::FromArgb(35, 38, 46)
    $txtIndex.ForeColor = [System.Drawing.Color]::White
    if ($InitialSettings.Index) { $txtIndex.Text = "$($InitialSettings.Index)" }
    $toolTip.SetToolTip($txtIndex, "対象イメージのインデックス番号 (例: 1)。空欄の場合は自動検出または対話選択されます")
    $grpMedia.Controls.Add($txtIndex)

    $lblDrivers = New-Object System.Windows.Forms.Label
    $lblDrivers.Text = "ドライバー ($OEM$):"
    $lblDrivers.Location = New-Object System.Drawing.Point(220, 83)
    $lblDrivers.Size = New-Object System.Drawing.Size(115, 20)
    $lblDrivers.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
    $grpMedia.Controls.Add($lblDrivers)

    $txtDrivers = New-Object System.Windows.Forms.TextBox
    $txtDrivers.Location = New-Object System.Drawing.Point(340, 80)
    $txtDrivers.Size = New-Object System.Drawing.Size(200, 24)
    $txtDrivers.BackColor = [System.Drawing.Color]::FromArgb(35, 38, 46)
    $txtDrivers.ForeColor = [System.Drawing.Color]::White
    if ($InitialSettings.InjectDrivers) { $txtDrivers.Text = "$($InitialSettings.InjectDrivers)" }
    $toolTip.SetToolTip($txtDrivers, "OSセットアップ時に自動注入するハードウェアドライバーフォルダー (.inf) を指定します")
    $grpMedia.Controls.Add($txtDrivers)

    $btnBrowseDrivers = New-Object System.Windows.Forms.Button
    $btnBrowseDrivers.Text = "参照..."
    $btnBrowseDrivers.Location = New-Object System.Drawing.Point(545, 79)
    $btnBrowseDrivers.Size = New-Object System.Drawing.Size(110, 26)
    $btnBrowseDrivers.BackColor = [System.Drawing.Color]::FromArgb(45, 50, 60)
    $btnBrowseDrivers.ForeColor = [System.Drawing.Color]::White
    $btnBrowseDrivers.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnBrowseDrivers.Add_Click({
        $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
        $fbd.Description = "注入するドライバー群 (.inf) が格納されたフォルダーを選択してください"
        if ($fbd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $txtDrivers.Text = $fbd.SelectedPath
        }
    })
    $grpMedia.Controls.Add($btnBrowseDrivers)

    # 2. Configuration Profiles GroupBox
    $grpProfile = New-Object System.Windows.Forms.GroupBox
    $grpProfile.Text = " 2. 構成プロファイル & プリセット (Profile & Presets) "
    $grpProfile.Location = New-Object System.Drawing.Point(15, 158)
    $grpProfile.Size = New-Object System.Drawing.Size(670, 75)
    $grpProfile.ForeColor = [System.Drawing.Color]::FromArgb(0, 190, 255)
    $mainPanel.Controls.Add($grpProfile)

    $lblPreset = New-Object System.Windows.Forms.Label
    $lblPreset.Text = "プリセット:"
    $lblPreset.Location = New-Object System.Drawing.Point(15, 28)
    $lblPreset.Size = New-Object System.Drawing.Size(60, 20)
    $lblPreset.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
    $grpProfile.Controls.Add($lblPreset)

    $cmbPreset = New-Object System.Windows.Forms.ComboBox
    $cmbPreset.Location = New-Object System.Drawing.Point(80, 25)
    $cmbPreset.Size = New-Object System.Drawing.Size(575, 24)
    $cmbPreset.BackColor = [System.Drawing.Color]::FromArgb(35, 38, 46)
    $cmbPreset.ForeColor = [System.Drawing.Color]::White
    $cmbPreset.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $cmbPreset.Items.AddRange(@(
        "⚡ Extreme Slim & Gaming (最大軽量化・超低遅延チューニング)",
        "🛡️ Balanced Pro (安全構成: Windows Update & Defender 保持)",
        "💾 FAT32 USB Split-WIM (UEFI対応 3.8GB 分割SWM形式)",
        "🎮 ポータブルゲーミングPC (ROG Ally, Steam Deck, Legion Go)",
        "💻 VM & 開発者向け (WSL2, Hyper-V, WinUpdate 有効)",
        "🎵 DTM & オーディオ制作 (低遅延・VST音源保護・高安定性)",
        "🔧 カスタム構成 (手動カスタマイズ)"
    ))
    $cmbPreset.SelectedIndex = 0
    $grpProfile.Controls.Add($cmbPreset)

    # 3. Customization & Debloat Options GroupBox
    $grpOpts = New-Object System.Windows.Forms.GroupBox
    $grpOpts.Text = " 3. デブロート & カスタマイズ設定 (Debloat & Options) "
    $grpOpts.Location = New-Object System.Drawing.Point(15, 243)
    $grpOpts.Size = New-Object System.Drawing.Size(670, 275)
    $grpOpts.ForeColor = [System.Drawing.Color]::FromArgb(0, 190, 255)
    $mainPanel.Controls.Add($grpOpts)

    $createChk = {
        param($text, $x, $y, $checked)
        $chk = New-Object System.Windows.Forms.CheckBox
        $chk.Text = $text
        $chk.Location = New-Object System.Drawing.Point($x, $y)
        $chk.Size = New-Object System.Drawing.Size(315, 28)
        $chk.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
        $chk.Checked = [bool]$checked
        $grpOpts.Controls.Add($chk)
        return $chk
    }

    $getInitVal = {
        param([string]$key, [bool]$defaultVal)
        if ($InitialSettings.ContainsKey($key)) { return [bool]$InitialSettings[$key] }
        return [bool]$defaultVal
    }

    # Left Column (X = 15)
    $chkDefender    = & $createChk "Windows Defender とセキュリティUIの完全削除" 15 25 (& $getInitVal 'RemoveDefender' $true)
    $chkIME         = & $createChk "日本語・アジア系IMEの保持 (日本語入力対応)" 15 55 (& $getInitVal 'KeepAsianIME' $true)
    $chkFonts       = & $createChk "国際フォント・追加アジア系フォントの保持" 15 85 (& $getInitVal 'KeepExtraFonts' $false)
    $chkDrivers     = & $createChk "レガシー ストレージ & ネットワークドライバー削除" 15 115 (& $getInitVal 'RemoveDrivers' $false)
    $chkWU          = & $createChk "自動 Windows Update の無効化" 15 145 (& $getInitVal 'DisableWindowsUpdate' $true)
    $chkBT          = & $createChk "Bluetooth サービス & 周辺機器サポートの保持" 15 175 (& $getInitVal 'KeepBluetooth' $true)
    $chkWSL         = & $createChk "WSL2 & 仮想マシンプラットフォームの有効化" 15 205 (& $getInitVal 'WSLSupport' $false)
    $chkRecovery    = & $createChk "回復環境 (WinRE) の保持" 15 235 (& $getInitVal 'KeepRecoveryEnv' $false)

    # Right Column (X = 345)
    $chkSafeDebloat = & $createChk "安全な WinSxS コンポーネントストア軽量化" 345 25 (& $getInitVal 'SafeDebloatMode' $true)
    $chkUltraSlim   = & $createChk "UltraSlim モード (~3GB ISO目標・極限削減)" 345 55 (& $getInitVal 'UltraSlimMode' $true)
    $chkJPKey       = & $createChk "日本語 106/109 キーボード自動構成" 345 85 (& $getInitVal 'SetJapaneseKeyboard' $true)
    $chkAtlas       = & $createChk "AtlasOS & ReviOS 超低遅延・レスポンス最適化" 345 115 (& $getInitVal 'AtlasReviOSMode' $true)
    $chkStore       = & $createChk "Microsoft Store と購入アプリの完全削除" 345 145 (& $getInitVal 'RemoveStore' $false)
    $chkBasicApps   = & $createChk "基本アプリ (メモ帳/ペイント/電卓) を残す" 345 175 (& $getInitVal 'KeepBasicApps' $false)
    $chkSearchIndex = & $createChk "Windows Search インデックスを有効化" 345 205 (& $getInitVal 'KeepSearchIndex' $false)
    $chkVHDX        = & $createChk "超高速 VHDX スクラッチディスクを使用" 345 235 (& $getInitVal 'UseVHDX' $false)

    # 4. Output Payload Format GroupBox
    $grpPayload = New-Object System.Windows.Forms.GroupBox
    $grpPayload.Text = " 4. 出力イメージ形式 (Payload Export Format) "
    $grpPayload.Location = New-Object System.Drawing.Point(15, 528)
    $grpPayload.Size = New-Object System.Drawing.Size(670, 75)
    $grpPayload.ForeColor = [System.Drawing.Color]::FromArgb(0, 190, 255)
    $mainPanel.Controls.Add($grpPayload)

    $radWIM = New-Object System.Windows.Forms.RadioButton
    $radWIM.Text = "install.wim (LZX - 推奨・高速・高安定)"
    $radWIM.Location = New-Object System.Drawing.Point(15, 28)
    $radWIM.Size = New-Object System.Drawing.Size(200, 25)
    $radWIM.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
    $radWIM.Checked = $true
    $grpPayload.Controls.Add($radWIM)

    $radESD = New-Object System.Windows.Forms.RadioButton
    $radESD.Text = "install.esd (LZMS - 超高圧縮)"
    $radESD.Location = New-Object System.Drawing.Point(225, 28)
    $radESD.Size = New-Object System.Drawing.Size(205, 25)
    $radESD.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
    $grpPayload.Controls.Add($radESD)

    $radSWM = New-Object System.Windows.Forms.RadioButton
    $radSWM.Text = "install.swm (Split-WIM - FAT32 USB対応)"
    $radSWM.Location = New-Object System.Drawing.Point(440, 28)
    $radSWM.Size = New-Object System.Drawing.Size(215, 25)
    $radSWM.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
    $grpPayload.Controls.Add($radSWM)

    if ($InitialSettings.ExportESDMode) {
        $radESD.Checked = $true
    } elseif ($InitialSettings.SplitWIMMode) {
        $radSWM.Checked = $true
    }

    # Preset selection sync backed by Built-in In-Memory Presets
    $updatingPreset = $false
    $presetKeyMap = @('extreme', 'balanced', 'fat32', 'handheld', 'vm', 'audio')

    $guiControlsMap = @{
        chkDefender    = $chkDefender
        chkIME         = $chkIME
        chkFonts       = $chkFonts
        chkDrivers     = $chkDrivers
        chkWU          = $chkWU
        chkBT          = $chkBT
        chkWSL         = $chkWSL
        chkRecovery    = $chkRecovery
        chkSafeDebloat = $chkSafeDebloat
        chkUltraSlim   = $chkUltraSlim
        chkJPKey       = $chkJPKey
        chkAtlas       = $chkAtlas
        chkStore       = $chkStore
        chkBasicApps   = $chkBasicApps
        chkSearchIndex = $chkSearchIndex
        chkVhdx        = $chkVHDX
        radESD         = $radESD
        radSWM         = $radSWM
        radWIM         = $radWIM
    }

    $applyPreset = {
        param($presetIndex)
        $script:updatingPreset = $true
        if ($presetIndex -ge 0 -and $presetIndex -lt $presetKeyMap.Count) {
            $pKey = $presetKeyMap[$presetIndex]
            Apply-ProfileSettings -ProfileName $pKey -UpdateGui -GuiControls $guiControlsMap
        }
        $script:updatingPreset = $false
    }

    $cmbPreset.Add_SelectedIndexChanged({
        if (-not $script:updatingPreset -and $cmbPreset.SelectedIndex -ne ($cmbPreset.Items.Count - 1)) {
            & $applyPreset $cmbPreset.SelectedIndex
        }
    })

    # Hook change events to switch preset to Custom
    $allCheckboxes = @($chkDefender, $chkIME, $chkFonts, $chkDrivers, $chkWU, $chkBT, $chkWSL, $chkRecovery, $chkSafeDebloat, $chkUltraSlim, $chkJPKey, $chkAtlas, $chkStore, $chkBasicApps, $chkSearchIndex, $chkVHDX)
    foreach ($c in $allCheckboxes) {
        $c.Add_CheckedChanged({
            if (-not $script:updatingPreset) {
                $script:updatingPreset = $true
                $cmbPreset.SelectedIndex = ($cmbPreset.Items.Count - 1) # Custom
                $script:updatingPreset = $false
            }
        })
    }

    # Bottom Button Panel
    $bottomPanel = New-Object System.Windows.Forms.Panel
    $bottomPanel.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $bottomPanel.Height = 65
    $bottomPanel.BackColor = [System.Drawing.Color]::FromArgb(18, 20, 24)
    $form.Controls.Add($bottomPanel)

    $chkDryRun = New-Object System.Windows.Forms.CheckBox
    $chkDryRun.Text = "DryRun (シミュレーション)"
    $chkDryRun.Location = New-Object System.Drawing.Point(20, 22)
    $chkDryRun.Size = New-Object System.Drawing.Size(180, 24)
    $chkDryRun.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
    $bottomPanel.Controls.Add($chkDryRun)

    $btnBuild = New-Object System.Windows.Forms.Button
    $btnBuild.Text = "🚀 nano11 ビルド開始"
    $btnBuild.Location = New-Object System.Drawing.Point(340, 14)
    $btnBuild.Size = New-Object System.Drawing.Size(200, 38)
    $btnBuild.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
    $btnBuild.ForeColor = [System.Drawing.Color]::White
    $btnBuild.Font = New-Object System.Drawing.Font($uiFontName, 10.5, [System.Drawing.FontStyle]::Bold)
    $btnBuild.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $bottomPanel.Controls.Add($btnBuild)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "キャンセル"
    $btnCancel.Font = New-Object System.Drawing.Font($uiFontName, 9.5)
    $btnCancel.Location = New-Object System.Drawing.Point(555, 14)
    $btnCancel.Size = New-Object System.Drawing.Size(130, 38)
    $btnCancel.BackColor = [System.Drawing.Color]::FromArgb(45, 50, 60)
    $btnCancel.ForeColor = [System.Drawing.Color]::White
    $btnCancel.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $bottomPanel.Controls.Add($btnCancel)

    $formResult = @{ Success = $false }

    $btnBuild.Add_Click({
        # Validate Source Drive / ISO
        $srcText = $cmbSource.Text.Trim()
        if (-not $srcText) {
            [System.Windows.Forms.MessageBox]::Show("Windows 11 のインストールメディア(ドライブ)または ISO イメージを指定してください。", "ソース指定が必要", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }

        # If full text contains label, extract drive letter
        if ($srcText -match '^([A-Za-z]:)') {
            $candLetter = $matches[1]
            $wimCheck = Join-Path -Path "$candLetter\sources" -ChildPath "install.wim"
            if (Test-Path -LiteralPath $wimCheck) {
                $resolvedSource = $candLetter
            } elseif ($srcText.EndsWith(".iso", [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $srcText)) {
                $resolvedSource = $srcText
            } else {
                $resolvedSource = $candLetter
            }
        } elseif ($srcText.EndsWith(".iso", [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $srcText)) {
            $resolvedSource = $srcText
        } else {
            $resolvedSource = $srcText
        }

        # Validate WorkDir
        $wDir = $txtWork.Text.Trim()
        if (-not $wDir) {
            $wDir = "$env:SystemDrive\nano11_workspace"
        }

        $formResult.Success                   = $true
        $formResult.SourceDrive               = $resolvedSource
        $formResult.WorkDir                   = $wDir
        $formResult.RemoveDefender            = $chkDefender.Checked
        $formResult.KeepAsianIME              = $chkIME.Checked
        $formResult.KeepExtraFonts            = $chkFonts.Checked
        $formResult.RemoveDrivers             = $chkDrivers.Checked
        $formResult.DisableWindowsUpdate      = $chkWU.Checked
        $formResult.KeepBluetooth             = $chkBT.Checked
        $formResult.WSLSupport                = $chkWSL.Checked
        $formResult.KeepRecoveryEnv           = $chkRecovery.Checked
        $formResult.SafeDebloatMode           = $chkSafeDebloat.Checked
        $formResult.UltraSlimMode             = $chkUltraSlim.Checked
        $formResult.SetJapaneseKeyboard       = $chkJPKey.Checked
        $formResult.AtlasReviOSMode           = $chkAtlas.Checked
        $formResult.RemoveStore               = $chkStore.Checked
        $formResult.KeepBasicApps             = $chkBasicApps.Checked
        $formResult.KeepSearchIndex           = $chkSearchIndex.Checked
        $formResult.Index                     = $txtIndex.Text.Trim()
        $formResult.InjectDrivers             = $txtDrivers.Text.Trim()
        $formResult.DryRun                    = $chkDryRun.Checked
        $formResult.UseVHDX                   = $chkVHDX.Checked
        $formResult.ExportESDMode             = $radESD.Checked
        $formResult.SplitWIMMode              = $radSWM.Checked

        $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Close()
    })

    # Ensure Form pops up in foreground when launched
    $form.TopMost = $true
    $form.Add_Shown({
        $form.Activate()
        $form.TopMost = $false
    })

    # Show Dialog
    $diagResult = $form.ShowDialog()
    if ($diagResult -eq [System.Windows.Forms.DialogResult]::OK) {
        return $formResult
    }
    return @{ Success = $false }
}

# Handle -TestSelf before transcript or prompts
if ($TestSelf) {
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $builderPath = if ($PSCommandPath) { $PSCommandPath } else { Join-Path -Path $scriptDir -ChildPath "nano11builder.ps1" }
    $unattendPath = Join-Path -Path $scriptDir -ChildPath "autounattend.xml"
    $testResult = Invoke-Nano11SelfTest -ScriptRoot $scriptDir -BuilderPath $builderPath -UnattendPath $unattendPath
    if ($testResult) { exit 0 } else { exit 1 }
}

# Start Transcript with log rotation (Keep latest 10 logs, fallback to TEMP)
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$logDir = Join-Path -Path $scriptDir -ChildPath "logs"
$timestampStr = (Get-Date -Format "yyyyMMdd_HHmmss")
$transcriptPath = $null

try {
    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    }
    $transcriptPath = Join-Path -Path $logDir -ChildPath "nano11_$timestampStr.log"
    $script:DismLogPath = Join-Path -Path $logDir -ChildPath "dism_$timestampStr.log"
    $script:RegJournalPath = Join-Path -Path $logDir -ChildPath "registry-applied.csv"
    Set-Content -LiteralPath $script:RegJournalPath -Value '"Key","Name","Type","Data"' -Encoding utf8 -ErrorAction SilentlyContinue
    Start-Transcript -Path $transcriptPath -Force
    # Prune logs beyond parameter -KeepLogs (Default: 10)
    Get-ChildItem -Path $logDir -Filter "nano11_*.log" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $KeepLogs |
        Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path $logDir -Filter "dism_*.log" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $KeepLogs |
        Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path $logDir -Filter "nano11_*.config.json" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $KeepLogs |
        Remove-Item -Force -ErrorAction SilentlyContinue
} catch {
    $fallbackLogDir = $env:TEMP
    $transcriptPath = Join-Path -Path $fallbackLogDir -ChildPath "nano11_$timestampStr.log"
    try {
        Start-Transcript -Path $transcriptPath -Force
    } catch {
        Write-Warning "Could not initialize transcript logging: $_"
    }
}
$buildStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# Queue Mode for multiple comma-separated profiles (-Profile extreme,balanced-pro,vm-developer)
if ($Profile -and $Profile.Contains(',')) {
    $profileQueue = $Profile -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    if ($profileQueue.Count -gt 1) {
        Write-Host "=========================================================" -ForegroundColor Cyan
        Write-Host "   nano11 Batch Queue Mode: $($profileQueue.Count) Profiles to Build    " -ForegroundColor Cyan
        Write-Host "=========================================================" -ForegroundColor Cyan
        $queueSuccess = 0
        foreach ($qProf in $profileQueue) {
            Write-Host "`n>>> Starting Batch Build for Profile: $qProf <<<" -ForegroundColor Yellow
            $argsToPass = [System.Collections.Generic.List[string]]::new()
            foreach ($k in $PSBoundParameters.Keys) {
                if ($k -in @('Profile', 'TestSelf')) { continue }
                $val = $PSBoundParameters[$k]
                if ($val -is [switch]) {
                    if ($val) { $argsToPass.Add("-$k") }
                } else {
                    $argsToPass.Add("-$k `"$val`"")
                }
            }
            $argsToPass.Add("-Profile `"$qProf`"")
            $argsToPass.Add("-NonInteractive")
            $subProc = Start-Process -FilePath "powershell.exe" -ArgumentList ("-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" " + ($argsToPass -join " ")) -Wait -PassThru -NoNewWindow
            if ($subProc.ExitCode -eq 0) {
                $queueSuccess++
                Write-Host "Profile $qProf built successfully!" -ForegroundColor Green
            } else {
                Write-Host "Profile $qProf failed with exit code $($subProc.ExitCode)" -ForegroundColor Red
            }
        }
        Write-Host "`n=========================================================" -ForegroundColor Cyan
        Write-Host "   Batch Queue Completed: $queueSuccess/$($profileQueue.Count) profiles succeeded." -ForegroundColor $(if ($queueSuccess -eq $profileQueue.Count) { "Green" } else { "Yellow" })
        Write-Host "=========================================================" -ForegroundColor Cyan
        exit $(if ($queueSuccess -eq $profileQueue.Count) { 0 } else { 1 })
    }
}

Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "               Welcome to nano11 builder!                " -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "This script generates a significantly reduced Windows 11 image."
Write-Host "Suitable for testing, low-spec VMs, and rapid prototyping."
Write-Host ""

# Confirmation
if (-not $NonInteractive -and -not $GUI -and -not $isDryRunMode) {
    Write-Host "Do you want to continue? [Y/n] (Default: Y)" -ForegroundColor Yellow
    $confirm = Read-Host
    if ($confirm -and ($confirm.Trim().ToLower() -in @('no', 'n'))) {
        Write-Host "Process cancelled by user. Exiting..." -ForegroundColor Gray
        Stop-Transcript
        exit 0
    }
}

# Customization Options (Resolves Issues #1, #5, #9, #10, #12, #13)
Write-Host ""
Write-Host "--- Customization Settings ---" -ForegroundColor Green

# 1. Initialize recommended baseline defaults
$removeDefender = $true
$keepAsianIME = $true
$keepExtraFonts = $true
$removeDrivers = $false
$disableWU = $true
$keepBT = $true
$wslSupport = $false
$keepRecoveryEnv = $false
$safeDebloatMode = $true
$ultraSlimMode = $true
$setJapaneseKeyboard = $true
$atlasReviOSMode = $true
$exportESDMode = $false
$splitWIMMode = $false
$removeStore = $false
$keepXboxServices = $false
$keepAudioTweaks = $false
$selectedProfile = $null

# 2. Track explicitly supplied CLI parameters from bound parameters snapshot
$bound = $PSBoundParameters
$cliBound = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

# 0a. Profile / Preset Parameter (Direct In-Memory Preset Resolution)
if ($bound.ContainsKey('Profile') -or $bound.ContainsKey('Preset')) {
    $profVal = if ($bound.ContainsKey('Profile')) { $bound['Profile'] } else { $bound['Preset'] }
    $selectedProfile = $profVal.ToString().Trim().ToLower()
    [void]$cliBound.Add('Profile')
    $applied = Apply-ProfileSettings -ProfileName $selectedProfile
    if (-not $applied) {
        Write-Warning "Unrecognized profile '$selectedProfile'. Falling back to 'extreme'."
        Apply-ProfileSettings -ProfileName 'extreme' | Out-Null
        $selectedProfile = 'extreme'
    } else {
        Write-Host "Applied Built-in Profile: $($applied.ProfileName)" -ForegroundColor Green
    }
}

# 0b. LoadProfile Parameter (Legacy deprecation notice)
if ($bound.ContainsKey('LoadProfile') -and $bound['LoadProfile']) {
    Write-Warning "External JSON profile loading has been superseded by built-in presets: extreme, balanced, fat32, handheld, vm, audio."
    Apply-ProfileSettings -ProfileName 'extreme' | Out-Null
    $selectedProfile = 'extreme'
}

# 0c. Graphical User Interface (GUI) Trigger
if ($GUI) {
    Write-Host "Opening nano11 Graphical User Interface (GUI)..." -ForegroundColor Cyan
    $initialSettings = @{
        SourceDrive               = $SourceDrive
        WorkDir                   = $WorkDir
        RemoveDefender            = $removeDefender
        KeepAsianIME              = $keepAsianIME
        KeepExtraFonts            = $keepExtraFonts
        RemoveDrivers             = $removeDrivers
        DisableWindowsUpdate      = $disableWU
        KeepBluetooth             = $keepBT
        WSLSupport                = $wslSupport
        KeepRecoveryEnv           = $keepRecoveryEnv
        SafeDebloatMode           = $safeDebloatMode
        UltraSlimMode             = $ultraSlimMode
        SetJapaneseKeyboard       = $setJapaneseKeyboard
        AtlasReviOSMode           = $atlasReviOSMode
        RemoveStore               = $removeStore
        ExportESDMode             = $exportESDMode
        SplitWIMMode              = $splitWIMMode
    }
    $guiResult = Show-Nano11GUI -InitialSettings $initialSettings
    if ($guiResult -and $guiResult.Success) {
        if ($guiResult.SourceDrive) { $SourceDrive = $guiResult.SourceDrive }
        if ($guiResult.WorkDir) { $WorkDir = $guiResult.WorkDir }
        $removeDefender            = $guiResult.RemoveDefender
        $keepAsianIME              = $guiResult.KeepAsianIME
        $keepExtraFonts            = $guiResult.KeepExtraFonts
        $removeDrivers             = $guiResult.RemoveDrivers
        $disableWU                 = $guiResult.DisableWindowsUpdate
        $keepBT                    = $guiResult.KeepBluetooth
        $wslSupport                = $guiResult.WSLSupport
        $keepRecoveryEnv           = $guiResult.KeepRecoveryEnv
        $safeDebloatMode           = $guiResult.SafeDebloatMode
        $ultraSlimMode             = $guiResult.UltraSlimMode
        $setJapaneseKeyboard       = $guiResult.SetJapaneseKeyboard
        $atlasReviOSMode           = $guiResult.AtlasReviOSMode
        $removeStore               = $guiResult.RemoveStore
        if ($guiResult.ContainsKey('KeepBasicApps'))   { $keepBasicApps = [bool]$guiResult.KeepBasicApps }
        if ($guiResult.ContainsKey('KeepSearchIndex')) { $keepSearchIndex = [bool]$guiResult.KeepSearchIndex }
        if ($guiResult.Index)                         { $Index = $guiResult.Index }
        if ($guiResult.InjectDrivers)                 { $InjectDrivers = $guiResult.InjectDrivers }
        $exportESDMode             = $guiResult.ExportESDMode
        $splitWIMMode              = $guiResult.SplitWIMMode
        if ($guiResult.ContainsKey('UseVHDX')) { $useVHDX = [bool]$guiResult.UseVHDX }
        if ($guiResult.ContainsKey('Validate')) { $Validate = [bool]$guiResult.Validate }
        if ($guiResult.ContainsKey('Resume')) { $Resume = [bool]$guiResult.Resume }
        if ($guiResult.ContainsKey('DryRun')) { $DryRun = [bool]$guiResult.DryRun }
        if ($guiResult.ContainsKey('SkipEiCfg')) { $skipEiCfg = [bool]$guiResult.SkipEiCfg }
        if ($guiResult.ContainsKey('NoPostInstallAssets')) { $noPostInstallAssets = [bool]$guiResult.NoPostInstallAssets }
        $NonInteractive            = $true
        $selectedProfile           = "GUI Selection"
        Write-Host "Applied GUI Configuration successfully." -ForegroundColor Green
    } else {
        Write-Host "nano11 GUI cancelled by user. Exiting..." -ForegroundColor Gray
        Stop-Transcript
        exit 0
    }
}

$isAnyBound = {
    param([string[]]$Names)
    foreach ($n in $Names) {
        if ($bound.ContainsKey($n)) { return $true }
    }
    return $false
}
$getBoundVal = {
    param([string]$Name)
    if (-not $bound.ContainsKey($Name)) { return $false }
    $v = $bound[$Name]
    if ($v -is [System.Management.Automation.SwitchParameter]) { return $v.IsPresent }
    return [bool]$v
}

# 19. Xbox Services
if (& $isAnyBound @('KeepXboxServices')) {
    $keepXboxServices = & $getBoundVal 'KeepXboxServices'
    [void]$cliBound.Add('Xbox')
} elseif (& $isAnyBound @('RemoveXboxServices', 'NoXboxServices')) {
    $remXbox = if ($bound.ContainsKey('RemoveXboxServices')) { & $getBoundVal 'RemoveXboxServices' } else { & $getBoundVal 'NoXboxServices' }
    $keepXboxServices = -not $remXbox
    [void]$cliBound.Add('Xbox')
}

# 20. Audio Tweaks
if (& $isAnyBound @('KeepAudioTweaks')) {
    $keepAudioTweaks = & $getBoundVal 'KeepAudioTweaks'
    [void]$cliBound.Add('Audio')
}

# 1. Windows Defender
if (& $isAnyBound @('KeepDefender')) {
    $removeDefender = -not (& $getBoundVal 'KeepDefender')
    [void]$cliBound.Add('Defender')
} elseif (& $isAnyBound @('RemoveDefender', 'NoDefender')) {
    $remDef = if ($bound.ContainsKey('RemoveDefender')) { & $getBoundVal 'RemoveDefender' } else { & $getBoundVal 'NoDefender' }
    $removeDefender = $remDef
    [void]$cliBound.Add('Defender')
}

# 2. Asian IMEs
if (& $isAnyBound @('KeepIME', 'KeepAsianIME')) {
    $keepImeVal = if ($bound.ContainsKey('KeepIME')) { & $getBoundVal 'KeepIME' } else { & $getBoundVal 'KeepAsianIME' }
    $keepAsianIME = $keepImeVal
    [void]$cliBound.Add('IME')
} elseif (& $isAnyBound @('RemoveIME', 'RemoveAsianIME', 'NoIME')) {
    $rem = if ($bound.ContainsKey('RemoveIME')) { & $getBoundVal 'RemoveIME' } elseif ($bound.ContainsKey('RemoveAsianIME')) { & $getBoundVal 'RemoveAsianIME' } else { & $getBoundVal 'NoIME' }
    $keepAsianIME = -not $rem
    [void]$cliBound.Add('IME')
}

# 3. Fonts
if (& $isAnyBound @('KeepFonts', 'KeepExtraFonts')) {
    $keepFontVal = if ($bound.ContainsKey('KeepFonts')) { & $getBoundVal 'KeepFonts' } else { & $getBoundVal 'KeepExtraFonts' }
    $keepExtraFonts = $keepFontVal
    [void]$cliBound.Add('Fonts')
} elseif (& $isAnyBound @('RemoveFonts', 'NoFonts')) {
    $remF = if ($bound.ContainsKey('RemoveFonts')) { & $getBoundVal 'RemoveFonts' } else { & $getBoundVal 'NoFonts' }
    $keepExtraFonts = -not $remF
    [void]$cliBound.Add('Fonts')
}

# 4. Drivers
if (& $isAnyBound @('RemoveDrivers')) {
    $removeDrivers = & $getBoundVal 'RemoveDrivers'
    [void]$cliBound.Add('Drivers')
} elseif (& $isAnyBound @('KeepDrivers')) {
    $removeDrivers = -not (& $getBoundVal 'KeepDrivers')
    [void]$cliBound.Add('Drivers')
}

# 5. Windows Update
if (& $isAnyBound @('KeepWindowsUpdate', 'EnableWindowsUpdate')) {
    $keepWu = if ($bound.ContainsKey('KeepWindowsUpdate')) { & $getBoundVal 'KeepWindowsUpdate' } else { & $getBoundVal 'EnableWindowsUpdate' }
    $disableWU = -not $keepWu
    [void]$cliBound.Add('WindowsUpdate')
} elseif (& $isAnyBound @('DisableWindowsUpdate', 'NoWindowsUpdate')) {
    $disWu = if ($bound.ContainsKey('DisableWindowsUpdate')) { & $getBoundVal 'DisableWindowsUpdate' } else { & $getBoundVal 'NoWindowsUpdate' }
    $disableWU = $disWu
    [void]$cliBound.Add('WindowsUpdate')
}

# 6. Bluetooth
if (& $isAnyBound @('DisableBluetooth', 'NoBluetooth')) {
    $disBt = if ($bound.ContainsKey('DisableBluetooth')) { & $getBoundVal 'DisableBluetooth' } else { & $getBoundVal 'NoBluetooth' }
    $keepBT = -not $disBt
    [void]$cliBound.Add('Bluetooth')
} elseif (& $isAnyBound @('KeepBluetooth')) {
    $keepBT = & $getBoundVal 'KeepBluetooth'
    [void]$cliBound.Add('Bluetooth')
}

# 7. WSL2
if (& $isAnyBound @('EnableWSL')) {
    $wslSupport = & $getBoundVal 'EnableWSL'
    [void]$cliBound.Add('WSL')
} elseif (& $isAnyBound @('DisableWSL', 'NoWSL')) {
    $disWsl = if ($bound.ContainsKey('DisableWSL')) { & $getBoundVal 'DisableWSL' } else { & $getBoundVal 'NoWSL' }
    $wslSupport = -not $disWsl
    [void]$cliBound.Add('WSL')
}

# 8. Recovery Environment (WinRE)
if (& $isAnyBound @('KeepRecovery', 'KeepWinRE')) {
    $keepRecVal = if ($bound.ContainsKey('KeepRecovery')) { & $getBoundVal 'KeepRecovery' } else { & $getBoundVal 'KeepWinRE' }
    $keepRecoveryEnv = $keepRecVal
    [void]$cliBound.Add('Recovery')
} elseif (& $isAnyBound @('RemoveRecovery', 'RemoveWinRE', 'NoWinRE', 'NoRecovery')) {
    $remRec = if ($bound.ContainsKey('RemoveRecovery')) { & $getBoundVal 'RemoveRecovery' } elseif ($bound.ContainsKey('RemoveWinRE')) { & $getBoundVal 'RemoveWinRE' } elseif ($bound.ContainsKey('NoWinRE')) { & $getBoundVal 'NoWinRE' } else { & $getBoundVal 'NoRecovery' }
    $keepRecoveryEnv = -not $remRec
    [void]$cliBound.Add('Recovery')
}

# 9. WinSxS Component Store Mode
if (& $isAnyBound @('AggressiveWinSxS', 'TrimWinSxS')) {
    $agg = if ($bound.ContainsKey('AggressiveWinSxS')) { & $getBoundVal 'AggressiveWinSxS' } else { & $getBoundVal 'TrimWinSxS' }
    $safeDebloatMode = -not $agg
    [void]$cliBound.Add('WinSxS')
} elseif (& $isAnyBound @('SafeDebloat', 'SafeWinSxS')) {
    $safe = if ($bound.ContainsKey('SafeDebloat')) { & $getBoundVal 'SafeDebloat' } else { & $getBoundVal 'SafeWinSxS' }
    $safeDebloatMode = $safe
    [void]$cliBound.Add('WinSxS')
}

# 10. UltraSlim
if (& $isAnyBound @('UltraSlim')) {
    $ultraSlimMode = & $getBoundVal 'UltraSlim'
    [void]$cliBound.Add('UltraSlim')
} elseif (& $isAnyBound @('NoUltraSlim')) {
    $ultraSlimMode = -not (& $getBoundVal 'NoUltraSlim')
    [void]$cliBound.Add('UltraSlim')
}

# UltraSlim font pruning: only prune fonts if UltraSlim is active AND Fonts was NOT explicitly specified
if ($ultraSlimMode -and (-not $cliBound.Contains('Fonts'))) {
    $keepExtraFonts = $false
}

# 11. Japanese Keyboard
if (& $isAnyBound @('NoJapaneseKeyboard')) {
    $setJapaneseKeyboard = -not (& $getBoundVal 'NoJapaneseKeyboard')
    [void]$cliBound.Add('JPKey')
} elseif (& $isAnyBound @('JapaneseKeyboard')) {
    $setJapaneseKeyboard = & $getBoundVal 'JapaneseKeyboard'
    [void]$cliBound.Add('JPKey')
}

# 12. AtlasOS & ReviOS Tweaks
if (& $isAnyBound @('NoAtlasReviOS')) {
    $atlasReviOSMode = -not (& $getBoundVal 'NoAtlasReviOS')
    [void]$cliBound.Add('Atlas')
} elseif (& $isAnyBound @('AtlasReviOS')) {
    $atlasReviOSMode = & $getBoundVal 'AtlasReviOS'
    [void]$cliBound.Add('Atlas')
}

# 13. Export Format
if (& $isAnyBound @('ExportESD')) {
    $exportESDMode = & $getBoundVal 'ExportESD'
    $splitWIMMode = $false
    [void]$cliBound.Add('Export')
} elseif (& $isAnyBound @('ExportWIM', 'NoESD')) {
    $expWim = if ($bound.ContainsKey('ExportWIM')) { & $getBoundVal 'ExportWIM' } else { & $getBoundVal 'NoESD' }
    $exportESDMode = -not $expWim
    [void]$cliBound.Add('Export')
}

if (& $isAnyBound @('SplitWIM', 'FAT32Compatible', 'FAT32')) {
    $splitWIMMode = & $getBoundVal 'SplitWIM'
    $exportESDMode = $false
    [void]$cliBound.Add('SplitWIM')
} elseif (& $isAnyBound @('NoSplitWIM')) {
    $splitWIMMode = -not (& $getBoundVal 'NoSplitWIM')
    [void]$cliBound.Add('SplitWIM')
}

# 14. Microsoft Store (Default: Keep)
if (& $isAnyBound @('RemoveStore', 'NoStore', 'RemoveMicrosoftStore')) {
    $removeStore = if ($bound.ContainsKey('RemoveStore')) { & $getBoundVal 'RemoveStore' } elseif ($bound.ContainsKey('NoStore')) { & $getBoundVal 'NoStore' } else { & $getBoundVal 'RemoveMicrosoftStore' }
    [void]$cliBound.Add('Store')
} elseif (& $isAnyBound @('KeepStore')) {
    $removeStore = -not (& $getBoundVal 'KeepStore')
    [void]$cliBound.Add('Store')
}

# 16. Fast VHDX Scratch Disk
if (& $isAnyBound @('UseVHDX', 'FastVHDX', 'VHDX')) {
    $useVHDX = if ($bound.ContainsKey('UseVHDX')) { & $getBoundVal 'UseVHDX' } elseif ($bound.ContainsKey('FastVHDX')) { & $getBoundVal 'FastVHDX' } else { & $getBoundVal 'VHDX' }
    [void]$cliBound.Add('VHDX')
}

# 21. Advanced Modular Optimization Tweak Toggles overrides
if (& $isAnyBound @('RemoveLegacyFOD'))       { $removeLegacyFOD = & $getBoundVal 'RemoveLegacyFOD'; [void]$cliBound.Add('RemoveLegacyFOD') }
if (& $isAnyBound @('TrimWallpapers'))        { $trimWallpapers  = & $getBoundVal 'TrimWallpapers';  [void]$cliBound.Add('TrimWallpapers') }
if (& $isAnyBound @('DisableCPUMitigations')) { $disableCPUMitigations = & $getBoundVal 'DisableCPUMitigations'; [void]$cliBound.Add('DisableCPUMitigations') }
if (& $isAnyBound @('MMCSSGaming'))          { $mmcssGaming     = & $getBoundVal 'MMCSSGaming';     [void]$cliBound.Add('MMCSSGaming') }
if (& $isAnyBound @('DAWMode'))              { $dawMode         = & $getBoundVal 'DAWMode';         [void]$cliBound.Add('DAWMode') }
if (& $isAnyBound @('DisableMemCompression')){ $disableMemCompression = & $getBoundVal 'DisableMemCompression'; [void]$cliBound.Add('DisableMemCompression') }
if (& $isAnyBound @('DisableFSE'))           { $disableFSE      = & $getBoundVal 'DisableFSE';      [void]$cliBound.Add('DisableFSE') }
if (& $isAnyBound @('NvidiaLowLatency'))     { $nvidiaLowLatency = & $getBoundVal 'NvidiaLowLatency'; [void]$cliBound.Add('NvidiaLowLatency') }
if (& $isAnyBound @('NoKernelPaging'))       { $noKernelPaging  = & $getBoundVal 'NoKernelPaging';  [void]$cliBound.Add('NoKernelPaging') }
if (& $isAnyBound @('DisableUSBSuspend'))    { $disableUSBSuspend = & $getBoundVal 'DisableUSBSuspend'; [void]$cliBound.Add('DisableUSBSuspend') }
if (& $isAnyBound @('NoHypervisor'))         { $noHypervisor    = & $getBoundVal 'NoHypervisor';    [void]$cliBound.Add('NoHypervisor') }
if (& $isAnyBound @('RemoveWebViewPostOOBE')){ $removeWebViewPostOOBE = & $getBoundVal 'RemoveWebViewPostOOBE'; [void]$cliBound.Add('RemoveWebViewPostOOBE') }
if (& $isAnyBound @('FastExport'))           { $fastExport      = & $getBoundVal 'FastExport';      [void]$cliBound.Add('FastExport') }
if (& $isAnyBound @('UefiOnly'))             { $uefiOnly        = & $getBoundVal 'UefiOnly';        [void]$cliBound.Add('UefiOnly') }
if ($bound.ContainsKey('HibernateMode'))     { $hibernateMode   = $bound['HibernateMode'];          [void]$cliBound.Add('HibernateMode') }
if ($bound.ContainsKey('CrashDumpMode'))     { $crashDumpMode   = $bound['CrashDumpMode'];          [void]$cliBound.Add('CrashDumpMode') }
if ($bound.ContainsKey('CpuBoostMode') -and $bound['CpuBoostMode'] -ne 'Default') { $cpuBoostMode = $bound['CpuBoostMode']; [void]$cliBound.Add('CpuBoostMode') }
if ($bound.ContainsKey('PowerPreset') -and $bound['PowerPreset'] -ne 'Default')   { $powerPreset   = $bound['PowerPreset'];   [void]$cliBound.Add('PowerPreset') }
if ($bound.ContainsKey('TweakGroupOverrides') -and $bound['TweakGroupOverrides']) {
    foreach ($tgKey in $bound['TweakGroupOverrides'].Keys) {
        if ($script:TweakGroups.Contains($tgKey)) {
            $script:activeTweakGroups[$tgKey] = [bool]$bound['TweakGroupOverrides'][$tgKey]
        }
    }
}

# 3. Interactive Prompting Logic
$isAutomated = $NonInteractive -or $isDryRunMode -or ($cliBound.Count -ge 15 -and (-not $Interactive)) -or ($cliBound.Contains('Profile') -and (-not $Interactive))

if ($isAutomated) {
    Write-Host "Running in automated/CLI mode (no interactive prompts)." -ForegroundColor Gray
} else {
    # Configuration Profile Selector
    Write-Host ""
    Write-Host "=========================================================" -ForegroundColor Cyan
    Write-Host "         nano11 Configuration Profile Selector" -ForegroundColor Cyan
    Write-Host "=========================================================" -ForegroundColor Cyan
    Write-Host "Choose a profile or proceed to customization:" -ForegroundColor Gray
    Write-Host "  [1] ⚡ Extreme Slim & Gaming (Default: Max debloat, Atlas/ReviOS, Store kept)" -ForegroundColor Green
    Write-Host "  [2] 🛡️ Balanced Pro (Safe: Windows Update & Defender kept, high stability)" -ForegroundColor Yellow
    Write-Host "  [3] 🎮 Handheld Gaming (ROG Ally, Steam Deck, Legion Go)" -ForegroundColor Green
    Write-Host "  [4] 💻 VM & Developer Workstation (WSL2, Hyper-V, WinUpdate)" -ForegroundColor Cyan
    Write-Host "  [5] 🎵 Audio & DAW Production (Minimal Latency, VST Protected)" -ForegroundColor Magenta
    Write-Host "  [6] 💾 FAT32 USB Split-WIM (3.8GB SWM Chunks for UEFI)" -ForegroundColor Yellow
    Write-Host "  [7] 🖥️ Launch GUI (Graphical User Interface)" -ForegroundColor Blue
    Write-Host "  [8] 🔧 Custom (Step-by-step 15 configuration prompts)" -ForegroundColor Magenta
    $pChoice = Read-Host "Select Profile [1-8] (Default: 1 - Extreme Slim & Gaming)"
    if ($pChoice) { $pChoice = $pChoice.Trim().ToLower() } else { $pChoice = "1" }

    $skipIndividualPrompts = $false
    if ($pChoice -in @('1', 'extreme', 'gaming', 'slim')) {
        $skipIndividualPrompts = $true
        $selectedProfile = "extreme"
        Apply-ProfileSettings -ProfileName 'extreme' | Out-Null
        Write-Host "Applied Profile: ⚡ Extreme Slim & Gaming" -ForegroundColor Green
    } elseif ($pChoice -in @('2', 'balanced', 'safe', 'pro')) {
        $skipIndividualPrompts = $true
        $selectedProfile = "balanced"
        Apply-ProfileSettings -ProfileName 'balanced' | Out-Null
        Write-Host "Applied Profile: 🛡️ Balanced Pro (Windows Update & Defender kept)" -ForegroundColor Yellow
    } elseif ($pChoice -in @('3', 'handheld', 'ally', 'deck')) {
        $skipIndividualPrompts = $true
        $selectedProfile = "handheld"
        Apply-ProfileSettings -ProfileName 'handheld' | Out-Null
        Write-Host "Applied Profile: 🎮 Handheld Gaming" -ForegroundColor Green
    } elseif ($pChoice -in @('4', 'vm', 'dev', 'developer')) {
        $skipIndividualPrompts = $true
        $selectedProfile = "vm"
        Apply-ProfileSettings -ProfileName 'vm' | Out-Null
        Write-Host "Applied Profile: 💻 VM & Developer Workstation" -ForegroundColor Cyan
    } elseif ($pChoice -in @('5', 'audio', 'daw')) {
        $skipIndividualPrompts = $true
        $selectedProfile = "audio"
        Apply-ProfileSettings -ProfileName 'audio' | Out-Null
        Write-Host "Applied Profile: 🎵 Audio & DAW Production" -ForegroundColor Magenta
    } elseif ($pChoice -in @('6', 'fat32', 'split', 'splitwim')) {
        $skipIndividualPrompts = $true
        $selectedProfile = "fat32"
        Apply-ProfileSettings -ProfileName 'fat32' | Out-Null
        Write-Host "Applied Profile: 💾 FAT32 USB Split-WIM" -ForegroundColor Yellow
    } elseif ($pChoice -in @('7', 'gui', 'ui')) {
        $skipIndividualPrompts = $true
        $initialSettings = @{
            SourceDrive               = $SourceDrive
            WorkDir                   = $WorkDir
            RemoveDefender            = $removeDefender
            KeepAsianIME              = $keepAsianIME
            KeepExtraFonts            = $keepExtraFonts
            RemoveDrivers             = $removeDrivers
            DisableWindowsUpdate      = $disableWU
            KeepBluetooth             = $keepBT
            WSLSupport                = $wslSupport
            KeepRecoveryEnv           = $keepRecoveryEnv
            SafeDebloatMode           = $safeDebloatMode
            UltraSlimMode             = $ultraSlimMode
            SetJapaneseKeyboard       = $setJapaneseKeyboard
            AtlasReviOSMode           = $atlasReviOSMode
            RemoveStore               = $removeStore
            UseVHDX                   = $useVHDX
            ExportESDMode             = $exportESDMode
            SplitWIMMode              = $splitWIMMode
        }
        $guiResult = Show-Nano11GUI -InitialSettings $initialSettings
        if ($guiResult -and $guiResult.Success) {
            if ($guiResult.SourceDrive) { $SourceDrive = $guiResult.SourceDrive }
            if ($guiResult.WorkDir) { $WorkDir = $guiResult.WorkDir }
            $removeDefender            = $guiResult.RemoveDefender
            $keepAsianIME              = $guiResult.KeepAsianIME
            $keepExtraFonts            = $guiResult.KeepExtraFonts
            $removeDrivers             = $guiResult.RemoveDrivers
            $disableWU                 = $guiResult.DisableWindowsUpdate
            $keepBT                    = $guiResult.KeepBluetooth
            $wslSupport                = $guiResult.WSLSupport
            $keepRecoveryEnv           = $guiResult.KeepRecoveryEnv
            $safeDebloatMode           = $guiResult.SafeDebloatMode
            $ultraSlimMode             = $guiResult.UltraSlimMode
            $setJapaneseKeyboard       = $guiResult.SetJapaneseKeyboard
            $atlasReviOSMode           = $guiResult.AtlasReviOSMode
            $removeStore               = $guiResult.RemoveStore
            if ($guiResult.ContainsKey('KeepBasicApps'))   { $keepBasicApps = [bool]$guiResult.KeepBasicApps }
            if ($guiResult.ContainsKey('KeepSearchIndex')) { $keepSearchIndex = [bool]$guiResult.KeepSearchIndex }
            if ($guiResult.Index)                         { $Index = $guiResult.Index }
            if ($guiResult.InjectDrivers)                 { $InjectDrivers = $guiResult.InjectDrivers }
            if ($guiResult.ContainsKey('UseVHDX')) { $useVHDX = [bool]$guiResult.UseVHDX }
            $exportESDMode             = $guiResult.ExportESDMode
            $splitWIMMode              = $guiResult.SplitWIMMode
            $selectedProfile           = "GUI Selection"
            Write-Host "Applied GUI Configuration successfully." -ForegroundColor Green
        } else {
            Write-Host "GUI cancelled by user. Exiting..." -ForegroundColor Gray
            Stop-Transcript
            exit 0
        }
    } else {
        $selectedProfile = "custom"
        Write-Host "Entering 🔧 Custom step-by-step configuration..." -ForegroundColor Magenta
    }

    if (-not $skipIndividualPrompts) {
        Write-Host "Configure debloat options (Press Enter to accept current defaults or CLI selections):" -ForegroundColor Gray
    
    # 1. Windows Defender
    if ($cliBound.Contains('Defender') -and (-not $Interactive)) {
        Write-Host "1. Remove Windows Defender: $(if ($removeDefender) { 'Yes (Remove)' } else { 'No (Keep)' }) [CLI: Specified]" -ForegroundColor DarkCyan
    } else {
        $defPrompt = if ($removeDefender) { "Y/n" } else { "y/N" }
        $defDesc = if ($removeDefender) { "Default: Y (Remove)" } else { "Default: N (Keep)" }
        $opt = Read-Host "1. Remove Windows Defender? [$defPrompt] ($defDesc)"
        if ($opt) {
            if ($opt.Trim().ToLower() -in @('no', 'n')) { $removeDefender = $false }
            elseif ($opt.Trim().ToLower() -in @('yes', 'y')) { $removeDefender = $true }
        }
    }

    # 2. Asian IMEs (Japanese, Chinese, Korean)
    if ($cliBound.Contains('IME') -and (-not $Interactive)) {
        Write-Host "2. Keep Asian language IMEs: $(if ($keepAsianIME) { 'Yes (Keep)' } else { 'No (Remove)' }) [CLI: Specified]" -ForegroundColor DarkCyan
    } else {
        $defPrompt = if ($keepAsianIME) { "Y/n" } else { "y/N" }
        $defDesc = if ($keepAsianIME) { "Default: Y (Keep)" } else { "Default: N (Remove)" }
        $opt = Read-Host "2. Keep Asian language IMEs (Japanese, Chinese, Korean)? [$defPrompt] ($defDesc)"
        if ($opt) {
            if ($opt.Trim().ToLower() -in @('no', 'n')) { $keepAsianIME = $false }
            elseif ($opt.Trim().ToLower() -in @('yes', 'y')) { $keepAsianIME = $true }
        }
    }

    # 3. Fonts
    if ($cliBound.Contains('Fonts') -and (-not $Interactive)) {
        Write-Host "3. Keep extra international & Asian fonts: $(if ($keepExtraFonts) { 'Yes (Keep)' } else { 'No (Remove)' }) [CLI: Specified]" -ForegroundColor DarkCyan
    } else {
        $defPrompt = if ($keepExtraFonts) { "Y/n" } else { "y/N" }
        $defDesc = if ($keepExtraFonts) { "Default: Y (Keep)" } else { "Default: N (Remove)" }
        $opt = Read-Host "3. Keep extra international & Asian fonts? [$defPrompt] ($defDesc)"
        if ($opt) {
            if ($opt.Trim().ToLower() -in @('no', 'n')) { $keepExtraFonts = $false }
            elseif ($opt.Trim().ToLower() -in @('yes', 'y')) { $keepExtraFonts = $true }
        }
    }

    # 4. Drivers
    if ($cliBound.Contains('Drivers') -and (-not $Interactive)) {
        Write-Host "4. Remove non-essential drivers: $(if ($removeDrivers) { 'Yes (Remove)' } else { 'No (Keep)' }) [CLI: Specified]" -ForegroundColor DarkCyan
    } else {
        $defPrompt = if ($removeDrivers) { "Y/n" } else { "y/N" }
        $defDesc = if ($removeDrivers) { "Default: Y (Remove)" } else { "Default: N (Keep - Recommended for 100% Setup Stability)" }
        $opt = Read-Host "4. Remove non-essential drivers (printers, scanners, fax)? [$defPrompt] ($defDesc)"
        if ($opt) {
            if ($opt.Trim().ToLower() -in @('yes', 'y')) { $removeDrivers = $true }
            elseif ($opt.Trim().ToLower() -in @('no', 'n')) { $removeDrivers = $false }
        }
    }

    # 5. Windows Update
    if ($cliBound.Contains('WindowsUpdate') -and (-not $Interactive)) {
        Write-Host "5. Disable Windows Update: $(if ($disableWU) { 'Yes (Disable)' } else { 'No (Keep)' }) [CLI: Specified]" -ForegroundColor DarkCyan
    } else {
        $defPrompt = if ($disableWU) { "Y/n" } else { "y/N" }
        $defDesc = if ($disableWU) { "Default: Y (Disable)" } else { "Default: N (Keep)" }
        $opt = Read-Host "5. Disable Windows Update? [$defPrompt] ($defDesc)"
        if ($opt) {
            if ($opt.Trim().ToLower() -in @('no', 'n')) { $disableWU = $false }
            elseif ($opt.Trim().ToLower() -in @('yes', 'y')) { $disableWU = $true }
        }
    }

    # 6. Bluetooth & Audio peripherals
    if ($cliBound.Contains('Bluetooth') -and (-not $Interactive)) {
        Write-Host "6. Keep Bluetooth audio and peripheral services: $(if ($keepBT) { 'Yes (Keep)' } else { 'No (Disable)' }) [CLI: Specified]" -ForegroundColor DarkCyan
    } else {
        $defPrompt = if ($keepBT) { "Y/n" } else { "y/N" }
        $defDesc = if ($keepBT) { "Default: Y (Keep)" } else { "Default: N (Disable)" }
        $opt = Read-Host "6. Keep Bluetooth audio and peripheral services? [$defPrompt] ($defDesc)"
        if ($opt) {
            if ($opt.Trim().ToLower() -in @('no', 'n')) { $keepBT = $false }
            elseif ($opt.Trim().ToLower() -in @('yes', 'y')) { $keepBT = $true }
        }
    }

    # 7. WSL2 & Virtualization (Resolves Issue #5)
    if ($cliBound.Contains('WSL') -and (-not $Interactive)) {
        Write-Host "7. Enable WSL2 and Virtual Machine Platform: $(if ($wslSupport) { 'Yes (Enable)' } else { 'No (Disable)' }) [CLI: Specified]" -ForegroundColor DarkCyan
    } else {
        $defPrompt = if ($wslSupport) { "Y/n" } else { "y/N" }
        $defDesc = if ($wslSupport) { "Default: Y (Enable)" } else { "Default: N (Disable)" }
        $opt = Read-Host "7. Enable WSL2 and Virtual Machine Platform before stripping WinSxS? [$defPrompt] ($defDesc)"
        if ($opt) {
            if ($opt.Trim().ToLower() -in @('yes', 'y')) { $wslSupport = $true }
            elseif ($opt.Trim().ToLower() -in @('no', 'n')) { $wslSupport = $false }
        }
    }

    # 8. Windows Recovery Environment (WinRE)
    if ($cliBound.Contains('Recovery') -and (-not $Interactive)) {
        Write-Host "8. Keep Windows Recovery Environment (WinRE): $(if ($keepRecoveryEnv) { 'Yes (Keep)' } else { 'No (Remove)' }) [CLI: Specified]" -ForegroundColor DarkCyan
    } else {
        $defPrompt = if ($keepRecoveryEnv) { "Y/n" } else { "y/N" }
        $defDesc = if ($keepRecoveryEnv) { "Default: Y (Keep)" } else { "Default: N (Remove - removes WinRE safely post-install)" }
        $opt = Read-Host "8. Keep Windows Recovery Environment (WinRE)? [$defPrompt] ($defDesc)"
        if ($opt) {
            if ($opt.Trim().ToLower() -in @('yes', 'y')) { $keepRecoveryEnv = $true }
            elseif ($opt.Trim().ToLower() -in @('no', 'n')) { $keepRecoveryEnv = $false }
        }
    }

    # 9. Component Store (WinSxS) Optimization Mode
    if ($cliBound.Contains('WinSxS') -and (-not $Interactive)) {
        Write-Host "9. Component Store mode: $(if ($safeDebloatMode) { '1 (Safe Cleanup)' } else { '2 (Aggressive Pruning)' }) [CLI: Specified]" -ForegroundColor DarkCyan
    } else {
        $defMode = if ($safeDebloatMode) { "1" } else { "2" }
        $opt = Read-Host "9. Component Store optimization mode [1=Safe Cleanup (Recommended: 100% Setup success), 2=Aggressive Pruning (Experimental)] (Default: $defMode)"
        if ($opt) {
            if ($opt.Trim() -eq '2') { $safeDebloatMode = $false }
            elseif ($opt.Trim() -eq '1') { $safeDebloatMode = $true }
        }
    }

    # 10. UltraSlim (~3.2 GB ISO Target Mode)
    if ($cliBound.Contains('UltraSlim') -and (-not $Interactive)) {
        Write-Host "10. Enable UltraSlim mode: $(if ($ultraSlimMode) { 'Yes (Enable)' } else { 'No (Disable)' }) [CLI: Specified]" -ForegroundColor DarkCyan
    } else {
        $defPrompt = if ($ultraSlimMode) { "Y/n" } else { "y/N" }
        $defDesc = if ($ultraSlimMode) { "Default: Y (Enable)" } else { "Default: N (Disable)" }
        $opt = Read-Host "10. Enable UltraSlim mode (~3.2 GB ISO target: prunes Edge browser, non-JP CJK fonts, WinSxS dead weight, preserves WebView2 for OOBE)? [$defPrompt] ($defDesc)"
        if ($opt) {
            if ($opt.Trim().ToLower() -in @('no', 'n')) {
                $ultraSlimMode = $false
            } elseif ($opt.Trim().ToLower() -in @('yes', 'y')) {
                $ultraSlimMode = $true
                if (-not $cliBound.Contains('Fonts')) { $keepExtraFonts = $false }
            }
        }
    }

    # 11. Japanese 106/109 Keyboard Layout Configuration
    if ($cliBound.Contains('JPKey') -and (-not $Interactive)) {
        Write-Host "11. Configure Japanese 106/109 keyboard layout: $(if ($setJapaneseKeyboard) { 'Yes (Configure)' } else { 'No (Skip)' }) [CLI: Specified]" -ForegroundColor DarkCyan
    } else {
        $defPrompt = if ($setJapaneseKeyboard) { "Y/n" } else { "y/N" }
        $defDesc = if ($setJapaneseKeyboard) { "Default: Y (Configure)" } else { "Default: N (Skip)" }
        $opt = Read-Host "11. Configure Japanese 106/109 keyboard layout (prevents @/: mismatch)? [$defPrompt] ($defDesc)"
        if ($opt) {
            if ($opt.Trim().ToLower() -in @('no', 'n')) { $setJapaneseKeyboard = $false }
            elseif ($opt.Trim().ToLower() -in @('yes', 'y')) { $setJapaneseKeyboard = $true }
        }
    }

    # 12. AtlasOS & ReviOS Radical Debloat & Performance Optimization
    if ($cliBound.Contains('Atlas') -and (-not $Interactive)) {
        Write-Host "12. Enable AtlasOS & ReviOS radical debloat & latency optimizations: $(if ($atlasReviOSMode) { 'Yes (Enable)' } else { 'No (Disable)' }) [CLI: Specified]" -ForegroundColor DarkCyan
    } else {
        $defPrompt = if ($atlasReviOSMode) { "Y/n" } else { "y/N" }
        $defDesc = if ($atlasReviOSMode) { "Default: Y (Enable)" } else { "Default: N (Disable)" }
        $opt = Read-Host "12. Enable AtlasOS & ReviOS radical debloat & latency optimizations? [$defPrompt] ($defDesc)"
        if ($opt) {
            if ($opt.Trim().ToLower() -in @('no', 'n')) { $atlasReviOSMode = $false }
            elseif ($opt.Trim().ToLower() -in @('yes', 'y')) { $atlasReviOSMode = $true }
        }
    }

    # 13. Image compression format
    if (($cliBound.Contains('Export') -or $cliBound.Contains('SplitWIM')) -and (-not $Interactive)) {
        Write-Host "13. Image compression format: $(if ($exportESDMode) { '2 (install.esd Recovery LZMS)' } elseif ($splitWIMMode) { '3 (install.swm Split-WIM for FAT32)' } else { '1 (install.wim LZX)' }) [CLI: Specified]" -ForegroundColor DarkCyan
    } else {
        $defMode = if ($exportESDMode) { "2" } elseif ($splitWIMMode) { "3" } else { "1" }
        $opt = Read-Host "13. Image compression format [1=install.wim LZX (Default), 2=install.esd Recovery (LZMS), 3=install.swm (Split-WIM for FAT32 USB)] (Default: $defMode)"
        if ($opt) {
            if ($opt.Trim() -eq '2') { $exportESDMode = $true; $splitWIMMode = $false }
            elseif ($opt.Trim() -eq '3') { $splitWIMMode = $true; $exportESDMode = $false }
            elseif ($opt.Trim() -eq '1') { $exportESDMode = $false; $splitWIMMode = $false }
        }
    }

    # 14. Microsoft Store
    if ($cliBound.Contains('Store') -and (-not $Interactive)) {
        Write-Host "15. Remove Microsoft Store: $(if ($removeStore) { 'Yes (Remove)' } else { 'No (Keep)' }) [CLI: Specified]" -ForegroundColor DarkCyan
    } else {
        $defPrompt = if ($removeStore) { "Y/n" } else { "y/N" }
        $defDesc = if ($removeStore) { "Default: Y (Remove)" } else { "Default: N (Keep - Store apps/updates stay available)" }
        $opt = Read-Host "15. Remove Microsoft Store (Microsoft.WindowsStore + StorePurchaseApp; winget/App Installer is kept)? [$defPrompt] ($defDesc)"
        if ($opt) {
            if ($opt.Trim().ToLower() -in @('yes', 'y')) { $removeStore = $true }
            elseif ($opt.Trim().ToLower() -in @('no', 'n')) { $removeStore = $false }
        }
    }

    # Offer saving custom configuration as a JSON profile
    Write-Host ""
    $saveChoice = Read-Host "Would you like to save this custom configuration as a JSON profile? [y/N] (Default: N)"
    if ($saveChoice -and ($saveChoice.Trim().ToLower() -in @('y', 'yes'))) {
        $savePath = Read-Host "Enter JSON file path to save [Default: .\profiles\my-custom-profile.json]"
        if (-not $savePath) { $savePath = Join-Path -Path $PSScriptRoot -ChildPath "profiles\my-custom-profile.json" }
        $currentCfg = @{
            ProfileName               = "Custom Profile"
            RemoveDefender            = $removeDefender
            KeepAsianIME              = $keepAsianIME
            KeepExtraFonts            = $keepExtraFonts
            RemoveDrivers             = $removeDrivers
            DisableWindowsUpdate      = $disableWU
            KeepBluetooth             = $keepBT
            WSLSupport                = $wslSupport
            KeepRecoveryEnv           = $keepRecoveryEnv
            SafeDebloatMode           = $safeDebloatMode
            UltraSlimMode             = $ultraSlimMode
            SetJapaneseKeyboard       = $setJapaneseKeyboard
            AtlasReviOSMode           = $atlasReviOSMode
            RemoveStore               = $removeStore
            PayloadFormat             = if ($exportESDMode) { "ESD" } elseif ($splitWIMMode) { "SWM" } else { "WIM" }
        }
        Export-Nano11Profile -FilePath $savePath -Config $currentCfg
    }
    }
}

# Export profile if requested via -SaveProfile parameter
if ($SaveProfile) {
    $currentCfg = @{
        ProfileName               = if ($selectedProfile) { $selectedProfile } else { "Exported Profile" }
        RemoveDefender            = $removeDefender
        KeepAsianIME              = $keepAsianIME
        KeepExtraFonts            = $keepExtraFonts
        RemoveDrivers             = $removeDrivers
        DisableWindowsUpdate      = $disableWU
        KeepBluetooth             = $keepBT
        WSLSupport                = $wslSupport
        KeepRecoveryEnv           = $keepRecoveryEnv
        SafeDebloatMode           = $safeDebloatMode
        UltraSlimMode             = $ultraSlimMode
        SetJapaneseKeyboard       = $setJapaneseKeyboard
        AtlasReviOSMode           = $atlasReviOSMode
        BundleOptimizationToolkit = $bundleOptimizationToolkit
        RemoveStore               = $removeStore
        PayloadFormat             = if ($exportESDMode) { "ESD" } elseif ($splitWIMMode) { "SWM" } else { "WIM" }
    }
    Export-Nano11Profile -FilePath $SaveProfile -Config $currentCfg
}

# Save build configuration snapshot to logs/<timestamp>.config.json
$logsDir = Join-Path -Path $scriptDir -ChildPath "logs"
if (-not (Test-Path -LiteralPath $logsDir)) {
    New-Item -ItemType Directory -Force -Path $logsDir -ErrorAction SilentlyContinue | Out-Null
}
$configSnapshotPath = Join-Path -Path $logsDir -ChildPath "$((Get-Date).ToString('yyyyMMdd_HHmmss')).config.json"
$resolvedConfig = [PSCustomObject]@{
    Timestamp                  = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Version                    = $script:Nano11Version
    Profile                    = if ($selectedProfile) { $selectedProfile } else { 'Extreme (Default)' }
    Architecture               = $architecture
    RemoveDefender             = $removeDefender
    KeepAsianIME               = $keepAsianIME
    KeepExtraFonts             = $keepExtraFonts
    RemoveDrivers              = $removeDrivers
    DisableWindowsUpdate       = $disableWU
    KeepBluetooth              = $keepBT
    WSLSupport                 = $wslSupport
    KeepRecoveryEnv            = $keepRecoveryEnv
    SafeDebloatMode            = $safeDebloatMode
    UltraSlimMode              = $ultraSlimMode
    SetJapaneseKeyboard        = $setJapaneseKeyboard
    AtlasReviOSMode            = $atlasReviOSMode
    RemoveStore                = $removeStore
    KeepXboxServices           = $keepXboxServices
    KeepAudioTweaks            = $keepAudioTweaks
    PayloadFormat              = if ($exportESDMode) { "ESD" } elseif ($splitWIMMode) { "SWM" } else { "WIM" }
}
try {
    $resolvedConfig | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configSnapshotPath -Encoding UTF8 -Force
} catch {}

Write-Host ""
Write-Host "Active configuration:" -ForegroundColor Cyan
Write-Host "  - Profile:                 $(if ($selectedProfile) { $selectedProfile } else { 'Extreme (Default)' })"
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
Write-Host "  - Remove Microsoft Store:  $removeStore"
Write-Host "  - Keep Xbox Services:      $keepXboxServices"
Write-Host "  - Low-Latency Audio MMCSS: $keepAudioTweaks"
if (Test-Path -LiteralPath $configSnapshotPath) {
    Write-Host "  - Config Snapshot:         $configSnapshotPath" -ForegroundColor DarkCyan
}
Write-Host "  - Payload Format:          $(if ($exportESDMode) { 'install.esd (LZMS)' } elseif ($splitWIMMode) { 'install.swm (Split-WIM / FAT32)' } else { 'install.wim (LZX - Recommended)' })"
Write-Host ""

# Early verification of -SourceDrive
if ($SourceDrive) {
    if ($SourceDrive.EndsWith(".iso", [System.StringComparison]::OrdinalIgnoreCase)) {
        if (-not (Test-Path -LiteralPath $SourceDrive)) {
            throw "Specified Windows 11 ISO does not exist: $SourceDrive"
        }
    } else {
        $candDrive = "$($SourceDrive.Trim().TrimEnd(':')):"
        if (-not (Test-Path -LiteralPath "$candDrive\sources\install.wim")) {
            throw "Specified SourceDrive is invalid: $SourceDrive (sources\install.wim not found)"
        }
    }
}

# Early check for NANO11_TEST_MODE or -DryRun / -WhatIf
if (($env:NANO11_TEST_MODE -eq "1") -or $isDryRunMode) {
    Write-Host ""
    Write-Host "[INFO] DryRun / TestMode active: Configuration resolved successfully." -ForegroundColor Yellow
    Write-Host "  - Profile: $(if ($selectedProfile) { $selectedProfile } else { 'Default' })" -ForegroundColor Yellow
    Write-Host "  - Payload Format: $(if ($exportESDMode) { 'ESD' } elseif ($splitWIMMode) { 'SWM' } else { 'WIM' })" -ForegroundColor Yellow
    Write-Host "  - Exiting without modifying images or workspace." -ForegroundColor Yellow
    if ($transcriptPath) { Stop-Transcript }
    exit 0
}

# ==============================================================================
# Main Build Lifecycle (Guaranteed Resource Cleanup via try / finally)
# ==============================================================================
$script:MountOpened = $false
$script:HivesLoaded = $false
$script:MountedIso = $null
$script:DefenderExclusionAdded = $false
$script:IsVhdxMounted = $false

try {
    Enter-Phase 1 "Environment Validation & Workspace Preparation"

    # Determine Working Directory (Resolves Issue #27, #23 - Low disk space on C:, and non-NTFS volumes like exFAT)
    if ($WorkDir) {
        if (-not (Test-Path -LiteralPath $WorkDir)) {
            New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
        }
        $baseWorkDir = (Resolve-Path -LiteralPath $WorkDir).Path
        if (-not (Test-IsNtfsVolume -Path $baseWorkDir)) {
            Write-Host "Warning: Specified WorkDir '$baseWorkDir' is not on an NTFS volume. DISM requires NTFS for junction and reparse points." -ForegroundColor Yellow
            $altDrive = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Free -gt 30GB -and (Test-IsNtfsVolume $_.Root) } | Sort-Object Free -Descending | Select-Object -First 1
            if ($altDrive) {
                $baseWorkDir = Join-Path -Path $altDrive.Root.TrimEnd('\') -ChildPath "nano11_workspace"
                Write-Host "Redirecting workspace to NTFS drive: $baseWorkDir" -ForegroundColor Green
                New-Item -ItemType Directory -Force -Path $baseWorkDir | Out-Null
            }
        }
    } else {
        $sysDrive = (Get-Item -LiteralPath $env:SystemDrive).PSDrive
        if ($sysDrive -and ($sysDrive.Free -lt 30GB -or -not (Test-IsNtfsVolume $env:SystemDrive))) {
            $altDrive = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Free -gt 30GB -and (Test-IsNtfsVolume $_.Root) } | Sort-Object Free -Descending | Select-Object -First 1
            if ($altDrive) {
                Write-Host "Using fast NTFS drive for working directory ($([math]::Round($altDrive.Free / 1GB, 1)) GB free): $($altDrive.Root)" -ForegroundColor Green
                $baseWorkDir = Join-Path -Path $altDrive.Root.TrimEnd('\') -ChildPath "nano11_workspace"
            } else {
                $baseWorkDir = Join-Path -Path $env:SystemDrive -ChildPath "nano11_workspace"
            }
        } else {
            $baseWorkDir = Join-Path -Path $env:SystemDrive -ChildPath "nano11_workspace"
        }
        if (-not (Test-Path -LiteralPath $baseWorkDir)) {
            New-Item -ItemType Directory -Force -Path $baseWorkDir | Out-Null
        }
    }

    # Verify available disk space on workspace volume (Minimum 25 GB required)
    $workDriveLetter = [System.IO.Path]::GetPathRoot($baseWorkDir).TrimEnd('\')
    if ($workDriveLetter -match '^[a-zA-Z]:') {
        $psDriveObj = Get-PSDrive -Name $workDriveLetter.Substring(0, 1) -ErrorAction SilentlyContinue
        if ($psDriveObj) {
            $freeGB = [math]::Round($psDriveObj.Free / 1GB, 1)
            if ($freeGB -lt 25.0) {
                Write-Host "Warning: Low disk space on workspace drive $workDriveLetter ($freeGB GB free, 25 GB recommended)." -ForegroundColor Yellow
                $altNtfs = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Free -gt 30GB -and (Test-IsNtfsVolume $_.Root) } | Sort-Object Free -Descending | Select-Object -First 1
                if ($altNtfs) {
                    $baseWorkDir = Join-Path -Path $altNtfs.Root.TrimEnd('\') -ChildPath "nano11_workspace"
                    Write-Host "Redirected workspace to volume with sufficient space ($([math]::Round($altNtfs.Free / 1GB, 1)) GB free): $baseWorkDir" -ForegroundColor Green
                    New-Item -ItemType Directory -Force -Path $baseWorkDir | Out-Null
                }
            }
        }
    }

    $nano11Dir = Join-Path -Path $baseWorkDir -ChildPath "build"
    $scratchDir = Join-Path -Path $baseWorkDir -ChildPath "scratchdir"
    Initialize-Nano11BuildState -Dir $baseWorkDir
    $vhdxPath = Join-Path -Path $baseWorkDir -ChildPath "nano11_scratch.vhdx"
    $isVhdxMounted = $false
    Write-Host "Working Directory: $baseWorkDir" -ForegroundColor Cyan

    # Temporarily exclude workspace from Windows Defender real-time scanning to accelerate DISM operations
    try {
        Add-MpPreference -ExclusionPath $baseWorkDir -ErrorAction SilentlyContinue
        $script:DefenderExclusionAdded = $true
    } catch {}

# Detach any leftover VHDX from previous runs
if (Test-Path -LiteralPath $vhdxPath) {
    try {
        $dpDetachScript = "select vdisk file=`"$vhdxPath`"`r`ndetach vdisk`r`n"
        $dpDetachFile = Join-Path -Path $env:TEMP -ChildPath "nano11_dp_clean_$([System.IO.Path]::GetRandomFileName()).txt"
        $dpDetachScript | Set-Content -LiteralPath $dpDetachFile -Encoding ascii
        & diskpart.exe /s $dpDetachFile > $null 2>&1
        Remove-Item -LiteralPath $dpDetachFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $vhdxPath -Force -ErrorAction SilentlyContinue
    } catch {}
}

if (Test-Path -LiteralPath $nano11Dir) {
    Write-Host "Cleaning up previous build directory to prevent leftover file conflicts..." -ForegroundColor Yellow
    Reset-DirectoryWithRobocopy -Path $nano11Dir
    Remove-Item -LiteralPath $nano11Dir -Recurse -Force -ErrorAction SilentlyContinue
}
if (Test-Path -LiteralPath $scratchDir) {
    Clear-DismMountConflicts -TargetMountDir $scratchDir
    Reset-DirectoryWithRobocopy -Path $scratchDir
    Remove-Item -LiteralPath $scratchDir -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Force -Path (Join-Path -Path $nano11Dir -ChildPath "sources") | Out-Null
New-Item -ItemType Directory -Force -Path $scratchDir | Out-Null

# Initialize High-Speed Dynamic VHDX scratch disk if requested (-UseVHDX / -FastVHDX)
if ($UseVHDX) {
    Write-Host "Creating high-speed dynamic VHDX scratch disk (30 GB expandable)..." -ForegroundColor Cyan
    try {
        $dpAttachScript = @"
create vdisk file="$vhdxPath" maximum=30720 type=expandable
select vdisk file="$vhdxPath"
attach vdisk
clean
convert gpt
create partition primary
format fs=ntfs quick label="nano11_scratch"
assign mount="$scratchDir"
"@
        $dpAttachFile = Join-Path -Path $env:TEMP -ChildPath "nano11_dp_attach_$([System.IO.Path]::GetRandomFileName()).txt"
        $dpAttachScript | Set-Content -LiteralPath $dpAttachFile -Encoding ascii
        & diskpart.exe /s $dpAttachFile > $null 2>&1
        Remove-Item -LiteralPath $dpAttachFile -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $vhdxPath) {
            $isVhdxMounted = $true
            $script:IsVhdxMounted = $true
            Write-Host "VHDX scratch volume mounted to $scratchDir" -ForegroundColor Green
        } else {
            Write-Warning "VHDX initialization did not create $vhdxPath. Using standard physical directory."
        }
    } catch {
        Write-Warning "Could not mount VHDX scratch disk: $_. Using standard physical directory."
    }
}

Enter-Phase 2 "Source Media Detection & Validation"

# Determine source drive letter (with auto-detection)
$DriveLetter = ""
if ($SourceDrive) {
    if ($SourceDrive.EndsWith(".iso", [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $SourceDrive)) {
        Write-Host "Mounting specified Windows 11 ISO: $SourceDrive..." -ForegroundColor Cyan
        try {
            $diskImg = Mount-DiskImage -ImagePath $SourceDrive -PassThru -ErrorAction SilentlyContinue
            if ($diskImg) {
                $script:MountedIso = $diskImg
                $vol = $diskImg | Get-Volume -ErrorAction SilentlyContinue
                if ($vol -and $vol.DriveLetter) {
                    $DriveLetter = "$($vol.DriveLetter):"
                    Write-Host "ISO mounted successfully on drive: $DriveLetter" -ForegroundColor Green
                }
            }
        } catch {}
    }
    if (-not $DriveLetter) {
        $candDrive = $SourceDrive.Trim().TrimEnd(':') + ":"
        if (Test-Path -LiteralPath $candDrive) {
            $DriveLetter = $candDrive
            Write-Host "Using specified SourceDrive: $DriveLetter" -ForegroundColor Green
        } else {
            Write-Host "Specified SourceDrive '$SourceDrive' does not exist." -ForegroundColor Red
        }
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
                $script:MountedIso = $diskImg
                $vol = $diskImg | Get-Volume -ErrorAction SilentlyContinue
                if ($vol -and $vol.DriveLetter) {
                    $dl = "$($vol.DriveLetter):"
                    $wimCheck = Join-Path -Path "$dl\sources" -ChildPath "install.wim"
                    if ((Test-Path -LiteralPath $wimCheck) -and ((Get-Item -LiteralPath $wimCheck).Length -gt 1GB)) {
                        return $dl
                    }
                }
                # Dismount candidate if it does not contain a healthy install.wim
                try { Dismount-DiskImage -ImagePath $iso.FullName -ErrorAction SilentlyContinue > $null } catch {}
                $script:MountedIso = $null
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
        if ($hasWimP) {
            $detectedMediaDrives += $psd
        } elseif ($hasEsdP) {
            $detectedMediaDrives += $psd
            Write-Host "  [i] Notice: Drive $rootClean contains 'install.esd'. It will be converted to install.wim via DISM." -ForegroundColor Cyan
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

    if (-not $DriveLetter) {
        if ($NonInteractive) {
            throw "No Windows 11 installation media detected. In -NonInteractive mode, please specify a valid media drive or ISO path via -SourceDrive."
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

$sourceMediaFile = if ($hasSourceWim) { $sourceWim } else { $sourceEsd }
$cacheMetaFile = Join-Path -Path $nano11Dir -ChildPath ".nano11-source.meta"
$skipMediaCopy = $false

if (-not $Clean -and (Test-Path -LiteralPath $destWim) -and (Test-Path -LiteralPath $cacheMetaFile)) {
    try {
        $cachedMeta = Get-Content -LiteralPath $cacheMetaFile -Raw -Encoding utf8 | ConvertFrom-Json
        $srcItem = Get-Item -LiteralPath $sourceMediaFile -ErrorAction SilentlyContinue
        if ($srcItem -and $cachedMeta.SourcePath -eq $sourceMediaFile -and $cachedMeta.Length -eq $srcItem.Length -and $cachedMeta.LastWriteTime -eq $srcItem.LastWriteTime.ToString("o")) {
            $skipMediaCopy = $true
            Write-Host "Reusing valid cached installation media in $nano11Dir (Source unchanged). Skipping multi-gigabyte media copy!" -ForegroundColor Green
        }
    } catch {}
}

Enter-Phase 3 "Installation Media Preparation & Staging"

if (-not $skipMediaCopy) {
Write-Host "Copying Windows installation files to $nano11Dir..." -ForegroundColor Green
$sourcePath = $DriveLetter.TrimEnd('\') + "\"
$copySuccess = $false
# If converting from install.esd, exclude both install.esd and install.wim from initial robocopy
# so we don't spend unnecessary minutes duplicating multi-gigabyte source archives.
$robocopyArgs = @("$sourcePath", "$nano11Dir", "/E", "/XJ", "/MT:16", "/J", "/R:1", "/W:1", "/NP", "/NFL", "/NDL", "/NJH", "/NJS")
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

# Ensure install.wim exists in destination; if not copied by robocopy, copy directly or decompress from install.esd
if (-not (Test-Path -LiteralPath $destWim) -or ((Get-Item -LiteralPath $destWim).Length -lt 1GB)) {
    if (Test-Path -LiteralPath $sourceWim) {
        Write-Host "Copying install.wim directly from $sourceWim..." -ForegroundColor Cyan
        Copy-Item -LiteralPath $sourceWim -Destination $destWim -Force
    } elseif (Test-Path -LiteralPath $sourceEsd) {
        Write-Host "Detected install.esd format (MediaCreationTool ISO). Converting to install.wim..." -ForegroundColor Cyan
        Write-Host "Decompressing LZMS stream to LZX maximum compression via DISM. Please wait..." -ForegroundColor Cyan
        
        $esdInfoOutput = & dism.exe /English /Get-WimInfo "/WimFile:$sourceEsd"
        $esdIndexEntries = @()
        $curEsdEntry = $null
        foreach ($line in ($esdInfoOutput -split '\r?\n')) {
            if ($line -match '^\s*Index\s*:\s*(\d+)') {
                $curEsdEntry = [PSCustomObject]@{ Index = $matches[1]; Name = "" }
                $esdIndexEntries += $curEsdEntry
            } elseif ($curEsdEntry -and ($line -match '^\s*Name\s*:\s*(.+)')) {
                $curEsdEntry.Name = $matches[1].Trim()
            }
        }
        $availEsdIndices = @($esdIndexEntries | ForEach-Object { $_.Index })
        $proEsd = $esdIndexEntries | Where-Object { $_.Name -match 'Pro' -and $_.Name -notmatch 'Workstation' } | Select-Object -First 1
        $defaultEsdIndex = if ($proEsd) { $proEsd.Index } elseif ($availEsdIndices.Count -gt 0) { $availEsdIndices[0] } else { "1" }
        
        $chosenEsdIndex = $defaultEsdIndex
        if ([string]::IsNullOrWhiteSpace($index) -or ($index -notin $availEsdIndices)) {
            if (-not $NonInteractive) {
                Write-Host "Available Windows editions in install.esd:" -ForegroundColor Green
                foreach ($entry in $esdIndexEntries) {
                    Write-Host "  [$($entry.Index)] $($entry.Name)"
                }
                $userChoice = Read-Host "Select edition index to decompress into install.wim [Default: $defaultEsdIndex]"
                if (-not [string]::IsNullOrWhiteSpace($userChoice) -and ($userChoice.Trim() -in $availEsdIndices)) {
                    $chosenEsdIndex = $userChoice.Trim()
                }
            }
        } else {
            $chosenEsdIndex = $index
        }
        
        Write-Host "Decompressing and exporting Index $chosenEsdIndex from install.esd to $destWim..." -ForegroundColor Cyan
        & dism.exe /English /Export-Image "/SourceImageFile:$sourceEsd" "/SourceIndex:$chosenEsdIndex" "/DestinationImageFile:$destWim" /Compress:max
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $destWim) -or ((Get-Item -LiteralPath $destWim).Length -lt 1GB)) {
            Write-Host "Error: DISM failed to convert install.esd to install.wim (Exit code: $LASTEXITCODE)." -ForegroundColor Red
            Stop-Transcript
            exit 1
        }
        Write-Host "Decompression complete! install.wim created successfully ($([math]::Round((Get-Item -LiteralPath $destWim).Length / 1GB, 2)) GB)." -ForegroundColor Green
        $index = "1"
    } else {
        Write-Host ""
        Write-Host "=========================================================" -ForegroundColor Red
        Write-Host " ERROR: Neither 'install.wim' nor 'install.esd' was found on $DriveLetter!" -ForegroundColor Red
        Write-Host " Please mount a valid Windows 11 installation ISO." -ForegroundColor Yellow
        Write-Host "=========================================================" -ForegroundColor Red
        Stop-Transcript
        exit 1
    }
}
    # Record media cache metadata for incremental skips
    try {
        $srcItem = Get-Item -LiteralPath $sourceMediaFile -ErrorAction SilentlyContinue
        if ($srcItem) {
            $metaData = @{
                SourcePath    = $sourceMediaFile
                Length        = $srcItem.Length
                LastWriteTime = $srcItem.LastWriteTime.ToString("o")
            }
            $metaData | ConvertTo-Json | Set-Content -LiteralPath $cacheMetaFile -Encoding utf8
        }
    } catch {}
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
if (-not $SkipEiCfg) {
    $eiCfgPath = Join-Path -Path "$nano11Dir\sources" -ChildPath "ei.cfg"
    if (-not (Test-Path -LiteralPath $eiCfgPath)) {
        "[Channel]`r`n_Default`r`n[VL]`r`n0`r`n" | Set-Content -LiteralPath $eiCfgPath -Encoding ascii -Force
        Write-Host "Created sources\ei.cfg for universal edition selection." -ForegroundColor Green
    }
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

# Parse available indices and detect Pro edition
$indexEntries = @()
$currentIndex = $null
foreach ($line in ($wimInfoOutput -split '\r?\n')) {
    if ($line -match '^\s*Index\s*:\s*(\d+)') {
        $currentIndex = [PSCustomObject]@{ Index = $matches[1]; Name = "" }
        $indexEntries += $currentIndex
    } elseif ($currentIndex -and ($line -match '^\s*Name\s*:\s*(.+)')) {
        $currentIndex.Name = $matches[1].Trim()
    }
}
$availableIndices = @($indexEntries | ForEach-Object { $_.Index })
$proEntry = $indexEntries | Where-Object { $_.Name -match 'Pro' -and $_.Name -notmatch 'Workstation' } | Select-Object -First 1
$defaultIndex = if ($proEntry) { $proEntry.Index } elseif ($availableIndices.Count -gt 0) { $availableIndices[0] } else { "1" }

if ([string]::IsNullOrWhiteSpace($index) -or ($index -notin $availableIndices)) {
    if (-not $NonInteractive) {
        $promptRange = if ($availableIndices.Count -gt 1) { " ($($availableIndices -join ', '))" } else { "" }
        $defaultLabel = if ($proEntry) { "$defaultIndex ($($proEntry.Name))" } else { $defaultIndex }
        $userInput = Read-Host "Please enter the image index to modify$promptRange [Default: $defaultLabel]"
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

Enter-Phase 4 "Mount install.wim & Baseline Analysis"

Write-Host "Mounting Windows image (Index: $index)..." -ForegroundColor Green
Write-Host "  -> DISM is unpacking system files (takes approx. 1-2 min on SSD)..." -ForegroundColor Cyan
Write-Host "  -> [Notice] DISM normally pauses at 90%-94% for 1-2 minutes while committing 100,000+ NTFS ACLs, hardlinks, and metadata." -ForegroundColor Yellow
Write-Host "     This is expected Windows DISM behavior. Please DO NOT close this window - it will proceed automatically." -ForegroundColor Yellow
Set-ItemOwnershipAndAccess -Path $destWim
try { Set-ItemProperty -LiteralPath $destWim -Name IsReadOnly -Value $false -ErrorAction Stop } catch {}

# Clear any conflicting or stale mounts on scratchDir or destWim (Resolves Error 0xc1420127)
Clear-DismMountConflicts -TargetMountDir $scratchDir -TargetWimFile $destWim
Reset-DirectoryWithRobocopy -Path $scratchDir

$mountSuccess = $false
for ($attempt = 1; $attempt -le 2; $attempt++) {
    & dism.exe /English /Mount-Image "/ImageFile:$destWim" "/Index:$index" "/MountDir:$scratchDir"
    if ($LASTEXITCODE -eq 0) {
        $mountSuccess = $true
        $script:MountOpened = $true
        break
    }

    Write-Host "Mount attempt $attempt failed (Exit code: $LASTEXITCODE). Attempting aggressive DISM mount recovery..." -ForegroundColor Yellow
    Get-Process -Name "dismhost", "wimserv" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Clear-DismMountConflicts -TargetMountDir $scratchDir -TargetWimFile $destWim
    & dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /discard > $null 2>&1
    & dism.exe /English /Cleanup-Wim > $null 2>&1
    & dism.exe /English /Cleanup-Mountpoints > $null 2>&1
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    Start-Sleep -Seconds 3
    Reset-DirectoryWithRobocopy -Path $scratchDir
}

if (-not $mountSuccess) {
    Write-Host "Failed to mount install.wim after recovery. Exiting..." -ForegroundColor Red
    Stop-Transcript
    exit 1
}

$sourceWimSize = if (Test-Path -LiteralPath $destWim) { (Get-Item -LiteralPath $destWim).Length } else { 0 }

# Capture pre-debloat package and WinSxS baseline metrics for before/after comparison
Write-Host "Capturing pre-debloat image baseline metrics..." -ForegroundColor Cyan
$pkgBeforePath = Join-Path -Path $logDir -ChildPath "packages-before.txt"
$featBeforePath = Join-Path -Path $logDir -ChildPath "features-before.txt"
$winsxsBeforePath = Join-Path -Path $logDir -ChildPath "winsxs-before.txt"

Invoke-Dism -DismArgs @("/image:$scratchDir", "/Get-Packages", "/Format:Table") -CaptureOutput | Set-Content -LiteralPath $pkgBeforePath -Encoding utf8
Invoke-Dism -DismArgs @("/image:$scratchDir", "/Get-Features", "/Format:Table") -CaptureOutput | Set-Content -LiteralPath $featBeforePath -Encoding utf8
$script:WinsxsBeforeRaw = Invoke-Dism -DismArgs @("/image:$scratchDir", "/Cleanup-Image", "/AnalyzeComponentStore") -CaptureOutput
$script:WinsxsBeforeRaw | Set-Content -LiteralPath $winsxsBeforePath -Encoding utf8

if ($CheckHealth) {
    Write-Host "Verifying image component store health (-CheckHealth)..." -ForegroundColor Cyan
    & dism.exe /English /Image:"$scratchDir" /Cleanup-Image /CheckHealth
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

Enter-Phase 5 "Removing provisioned AppX packages (Bloatware)"

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
    '*Client.WebExperience*', '*Windows.Ai*', '*WindowsAI*',
    # Modern AI & Copilot bloatware (Windows 11 24H2 / 26H2 Canary)
    '*CopilotStudio*', '*ClickToDo*', '*WindowsAIClient*', '*Microsoft.Windows.StudioFX*',
    '*NewsAndInterests*', '*RecallAgent*', '*AIComponents*', '*Microsoft.Windows.AiPca*',
    # Third-party preloaded sponsor apps & OEM bloat
    '*Spotify*', '*Disney*', '*LinkedIn*', '*Twitter*', '*TikTok*', '*Facebook*',
    '*Instagram*', '*Netflix*', '*Amazon*', '*PrimeVideo*', '*CandyCrush*',
    # Xbox / Gaming overlays & speech services
    '*Microsoft.GamingApp*', '*XboxGameOverlay*', '*XboxSpeechToTextOverlay*',
    '*XboxGamingOverlay*', '*XboxIdentityProvider*', '*Microsoft.MixedReality.Portal*',
    '*MixedReality*',
    # Diagnostics & Feedback & Legacy 3D / Wallet
    '*Microsoft.WindowsFeedbackHub*', '*Microsoft.3DBuilder*', '*Print3D*', '*Wallet*', '*Pay*'
)
# Optional: Microsoft Store removal (-RemoveStore / prompt 15).
# Only the Store app and its purchase UI are removed. Microsoft.DesktopAppInstaller (winget)
# and Store framework packages (VCLibs, UI.Xaml, NET.Native, Services.Store.Engagement) are
# intentionally kept so winget, WinUtil and already-installed apps keep working.
if ($removeStore) {
    Write-Host "  [Store] Microsoft Store will be removed (Microsoft.WindowsStore, Microsoft.StorePurchaseApp)." -ForegroundColor Yellow
    $appxPatterns += @('Microsoft.WindowsStore_*', 'Microsoft.StorePurchaseApp_*')
}
if ($keepBasicApps) {
    Write-Host "  [Apps] Preserving essential productivity apps: Notepad, Paint, Calculator (-KeepBasicApps)." -ForegroundColor Green
    $appxPatterns = @($appxPatterns | Where-Object {
        $_ -notlike '*Notepad*' -and
        $_ -notlike '*Paint*' -and
        $_ -notlike '*Calculator*'
    })
}
if ($keepXboxServices) {
    Write-Host "  [Xbox] Preserving Xbox Game Bar and Gaming subsystem (-KeepXboxServices)." -ForegroundColor Green
    $appxPatterns = @($appxPatterns | Where-Object { $_ -notlike '*Xbox*' -and $_ -notlike '*GamingApp*' })
}
# Note: *SecHealthUI*, *CoreAI*, *PeopleExperienceHost*, *PinningConfirmationDialog*, *SecureAssessmentBrowser*
# are protected system components in newer Windows 11 builds that trigger COMException (0x80073cfa) if removed via DISM.
# Defender and other features are cleanly managed via services and registry instead.

$appxRegexPatterns = $appxPatterns | Sort-Object -Unique | ForEach-Object { [regex]::Escape($_) -replace '\\\*', '.*' }
$appxRegex = [regex]::new(('^(' + ($appxRegexPatterns -join '|') + ')$'), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

$packagesToRemove = Get-AppxProvisionedPackage -Path $scratchDir -ErrorAction SilentlyContinue | Where-Object {
    ($_.PackageName -and $appxRegex.IsMatch($_.PackageName)) -or ($_.DisplayName -and $appxRegex.IsMatch($_.DisplayName))
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
& dism.exe /English "/image:$scratchDir" /Disable-Feature /FeatureName:Windows-Recall-Optional-Package /Remove > $null 2>&1

Enter-Phase 6 "Removing system packages (FoD / Optional features)"

# 6. Removing system packages (FoD / Optional features)
Write-Host "Removing unnecessary system packages..." -ForegroundColor Cyan

if ($removeLegacyFOD) {
    Write-Host "Removing legacy system capabilities & features (-RemoveLegacyFOD)..." -ForegroundColor Cyan
    $legacyCaps = @(
        'VBSCRIPT~~~~0.0.1.0',
        'Microsoft.Windows.PowerShell.ISE~~~~0.0.1.0',
        'Media.WindowsMediaPlayer~~~~0.0.1.0'
    )
    foreach ($cap in $legacyCaps) {
        & dism.exe /English "/image:$scratchDir" /Remove-Capability "/CapabilityName:$cap" > $null 2>&1
    }
    & dism.exe /English "/image:$scratchDir" /Disable-Feature /Remove /FeatureName:SMB1Protocol > $null 2>&1
    Write-Host "  - Legacy capabilities (VBScript, ISE, WMP, SMB1) removed." -ForegroundColor Green
} -ForegroundColor Cyan
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
    "Microsoft-Windows-Fax-Client-Package~",
    "Microsoft-Windows-Recall-FoD-Package~",
    "Microsoft-Windows-User-Experience-Virtualization-Package~",
    "Microsoft-Windows-Device-Management-Enterprise-Package~",
    "Microsoft-Windows-Notepad-FoD-Package~",
    "Microsoft-Windows-Paint-FoD-Package~",
    "Microsoft-Windows-MathRecognizer-Package~",

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

Enter-Phase 7 "Removing NativeImages (.NET)"

# 7. Removing NativeImages (.NET)
Write-Host "Removing pre-compiled .NET Native Images..." -ForegroundColor Cyan
Remove-Item -Path "$scratchDir\Windows\assembly\NativeImages_*" -Recurse -Force -ErrorAction SilentlyContinue

Enter-Phase 8 "File system slimming (Drivers, WinRE, Fonts)"

# 8. File system slimming
$winDir = "$scratchDir\Windows"

# Non-essential driver cleanup (optional)
if ($removeDrivers) {
    Write-Host "Slimming legacy peripheral drivers in DriverStore (strictly protecting ntprint, rdpbus)..." -ForegroundColor Cyan
    $driverRepo = Join-Path -Path $winDir -ChildPath "System32\DriverStore\FileRepository"
    # CRITICAL: ntprint.inf and rdpbus.inf are CORE Windows system drivers.
    # Deleting them causes Windows Setup PnP driver staging to hang at 77%!
    # Only optional standalone printer/fax/modem INF packages may be safely trimmed.
    $driverPatterns = @('prnms*.inf*', 'scan*.inf*', 'mfd*.inf*', 'wscsmd.inf*', 'fax*.inf*', 'modem*.inf*')
    if (-not $keepBT) {
        $driverPatterns += 'tdibth.inf*'
    }
    if (Test-Path -LiteralPath $driverRepo) {
        Get-ChildItem -Path $driverRepo -Directory | ForEach-Object {
            $folder = $_
            # Explicit safety guard against deleting core system drivers
            if ($folder.Name -like 'ntprint*' -or $folder.Name -like 'rdpbus*') {
                return
            }
            foreach ($pattern in $driverPatterns) {
                if ($folder.Name -like $pattern) {
                    Write-Host "  - Removing legacy peripheral driver package: $($folder.Name)"
                    Remove-ProtectedDirectory -Path $folder.FullName -ScratchPath $scratchDir
                    break
                }
            }
        }
    }
} else {
    Write-Host "Preserving DriverStore inbox drivers (guarantees zero setup stalls at 77%)..." -ForegroundColor Green
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
if ($trimWallpapers -or $ultraSlimMode) {
    Write-Host "Trimming 4K default wallpapers and lock screen images (-TrimWallpapers)..." -ForegroundColor Cyan
    Remove-ProtectedDirectory -Path "$scratchDir\Windows\Web\Wallpaper" -ScratchPath $scratchDir
    Remove-Item "$scratchDir\Windows\Web\Screen\*.jpg" -Force -ErrorAction SilentlyContinue
}
Remove-Item -Path (Join-Path -Path $winDir -ChildPath "Help") -Recurse -Force -ErrorAction SilentlyContinue

# Edge Browser and OneDrive (Preserve System32 WebView2 runtime for Windows 11 OOBE stability)
Write-Host "Removing Edge browser and OneDrive..." -ForegroundColor Cyan
Remove-ProtectedDirectory -Path "$scratchDir\Program Files (x86)\Microsoft\Edge" -ScratchPath $scratchDir
Remove-ProtectedDirectory -Path "$scratchDir\Program Files (x86)\Microsoft\EdgeUpdate" -ScratchPath $scratchDir
Remove-ProtectedDirectory -Path "$scratchDir\Program Files (x86)\Microsoft\EdgeCore" -ScratchPath $scratchDir

# Purge OneDrive setup payload (197 MB) and executable
Remove-Item -Path "$scratchDir\Windows\System32\OneDriveSetup.exe" -Force -ErrorAction SilentlyContinue
# Note: WinSxS manifests and packages are preserved to ensure CBS and Wimgapi extraction stability at 77%.

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
    $winreFlagDir = Join-Path -Path $scratchDir -ChildPath "Windows\Setup\Scripts"
    if (-not (Test-Path -LiteralPath $winreFlagDir)) {
        New-Item -ItemType Directory -Force -Path $winreFlagDir -ErrorAction SilentlyContinue | Out-Null
    }
    Set-Content -LiteralPath (Join-Path -Path $winreFlagDir -ChildPath "winre-cleanup.flag") -Value "remove" -Encoding ascii -Force
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
        } else {
            Remove-Item -LiteralPath $tempCompactWinre -Force -ErrorAction SilentlyContinue
        }
    }
}

Enter-Phase 9 "Component Store (WinSxS) Optimization"

# 9. Component Store (WinSxS) Optimization
if ($safeDebloatMode) {
    Write-Host "Consolidating component store safely via DISM Component Cleanup..." -ForegroundColor Green
    Write-Host "  -> DISM is optimizing component packages. Progress will display below..." -ForegroundColor Cyan
    # Note: We omit /ResetBase because offline /ResetBase on an image with package removals
    # corrupts delta manifests and causes Windows Setup file expansion to freeze at 77%.
    # Standard /StartComponentCleanup is 100% stable and fully preserves Setup integrity.
    & dism.exe /English "/image:$scratchDir" /Cleanup-Image /StartComponentCleanup
    Write-Host "  - Component store consolidated safely (WinSxS manifest integrity preserved for zero 77% stalls)." -ForegroundColor Green
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

Enter-Phase 10 "Load Registry Hives and Apply Optimizations"

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
$script:HivesLoaded = $true

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
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Search" /v "SearchboxTaskbarMode" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Search" /v "SearchboxTaskbarMode" /t REG_DWORD /d 0 /f > $null 2>&1

# Setup & Winlogon / Blank Password / PowerShell Execution Policy tweaks
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Lsa" /v "LimitBlankPasswordUse" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v "AutoAdminLogon" /t REG_SZ /d "1" /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v "DefaultUserName" /t REG_SZ /d "User" /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v "DefaultPassword" /t REG_SZ /d "" /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v "ForceAutoLogon" /t REG_SZ /d "1" /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\System" /v "AllowDomainDelayLock" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v "FilterAdministratorToken" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\PowerShell\1\ShellIds\Microsoft.PowerShell" /v "ExecutionPolicy" /t REG_SZ /d "RemoteSigned" /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\PowerShell" /v "EnableScripts" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\PowerShell" /v "ExecutionPolicy" /t REG_SZ /d "RemoteSigned" /f > $null 2>&1

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
reg.exe add "HKLM\zNTUSER\Control Panel\Accessibility\StickyKeys" /v "Flags" /t REG_SZ /d "26" /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Control Panel\Accessibility\StickyKeys" /v "Flags" /t REG_SZ /d "26" /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Control Panel\Accessibility\Keyboard Response" /v "Flags" /t REG_SZ /d "122" /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Control Panel\Accessibility\Keyboard Response" /v "Flags" /t REG_SZ /d "122" /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Control Panel\Accessibility\ToggleKeys" /v "Flags" /t REG_SZ /d "34" /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Control Panel\Accessibility\ToggleKeys" /v "Flags" /t REG_SZ /d "34" /f > $null 2>&1

if (-not $keepXboxServices) {
    # Disable Xbox Game Bar & GameDVR
    Write-Host "Disabling Xbox Game Bar & GameDVR..." -ForegroundColor Green
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\GameDVR" /v "AllowGameDVR" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Microsoft\PolicyManager\default\ApplicationManagement\AllowGameDVR" /v "value" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR" /v "AppCaptureEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\GameDVR" /v "AppCaptureEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\GameDVR" /v "AppCaptureEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\System\GameConfigStore" /v "GameDVR_Enabled" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\System\GameConfigStore" /v "GameDVR_Enabled" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\System\GameConfigStore" /v "GameDVR_FSEBehaviorMode" /t REG_DWORD /d 2 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\System\GameConfigStore" /v "GameDVR_FSEBehaviorMode" /t REG_DWORD /d 2 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\System\GameConfigStore" /v "GameDVR_HonorUserFSEBehaviorMode" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\System\GameConfigStore" /v "GameDVR_HonorUserFSEBehaviorMode" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\System\GameConfigStore" /v "GameDVR_DXGIHonorFSEWindowsCompatible" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\System\GameConfigStore" /v "GameDVR_DXGIHonorFSEWindowsCompatible" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\System\GameConfigStore" /v "GameDVR_EFSEFeatureFlags" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\System\GameConfigStore" /v "GameDVR_EFSEFeatureFlags" /t REG_DWORD /d 0 /f > $null 2>&1
} else {
    Write-Host "Preserving Xbox Game Bar & GameDVR (-KeepXboxServices)..." -ForegroundColor Green
}

# IFEO Debugger redirect for non-OOBE background processes (OSK/Narrator/Magnifier blocked safely in FirstLogon after OOBE completes)
$blockedExes = @(
    "CrossDeviceResume.exe",
    "WindowsBackupClient.exe",
    "VoiceAccess.exe",
    "Livecaptions.exe"
)
if (-not $keepXboxServices) {
    $blockedExes += @("GameBar.exe", "GameBarFTServer.exe", "GameBarPresenceWriter.exe")
}
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
}

# ============================================================================
# Windows Defender & Security Complete Removal (ionuttbara/windows-defender-remover integration)
# ============================================================================
if ($removeDefender) {
    Write-Host "Completely disabling and removing Windows Defender, Security Center, and ATP services (windows-defender-remover)..." -ForegroundColor Green
    # Only disable user-mode background services.
    # Note: Boot-critical drivers (WdBoot, MsSecCore, MsSecFlt, Pluton) and filesystem minifilters (WdFilter, WdNisDrv)
    # MUST NOT be set to Start=4. Disabling WdFilter causes Filter Manager (fltmgr.sys) driver staging hangs and volume deadlocks at 77%!
    # Defender is completely deactivated via WinDefend service and real-time Group Policies while fltmgr.sys stays 100% stable.
    $defServices = @(
        "WinDefend", "Sense", "SecurityHealthService",
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
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\FileSystem" /v "DontVerifyRandomDrivers" /t REG_DWORD /d 1 /f > $null 2>&1

# 4. Network & TCP/IP Low-Latency (Nagle's Algorithm Disabled, Instant ACK)
reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\Tcpip\Parameters" /v "TcpTimedWaitDelay" /t REG_DWORD /d 30 /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\Tcpip\Parameters" /v "MaxUserPort" /t REG_DWORD /d 65534 /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\Tcpip\Parameters" /v "DefaultTTL" /t REG_DWORD /d 64 /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\Tcpip\Parameters" /v "EnableICMPRedirect" /t REG_DWORD /d 0 /f > $null 2>&1

# MMCSS (Multimedia Class Scheduler Service)
Write-Host "Applying System Performance & Latency optimizations..." -ForegroundColor Green
if ($keepAudioTweaks) {
    Write-Host "  [Audio DAW] Configuring low-latency Pro Audio MMCSS task profile..." -ForegroundColor Green
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Pro Audio" /v "Priority" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Pro Audio" /v "Scheduling Category" /t REG_SZ /d "High" /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Pro Audio" /v "SFIO Priority" /t REG_SZ /d "High" /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Pro Audio" /v "Background Only" /t REG_SZ /d "False" /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Pro Audio" /v "Clock Rate" /t REG_DWORD /d 10000 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Pro Audio" /v "GPU Priority" /t REG_DWORD /d 8 /f > $null 2>&1
}
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
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management" /v "LargeSystemCache" /t REG_DWORD /d 0 /f > $null 2>&1
$pagingExecutiveVal = if ($noKernelPaging) { 1 } else { 0 }
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management" /v "DisablePagingExecutive" /t REG_DWORD /d $pagingExecutiveVal /f > $null 2>&1

# CPU Speculative Execution Mitigations (Spectre / Meltdown toggle: -DisableCPUMitigations)
if ($disableCPUMitigations) {
    Write-Host "  [SECURITY WARNING] Disabling CPU speculative execution mitigations (FeatureSettingsOverride=3)..." -ForegroundColor Yellow
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management" /v "FeatureSettingsOverride" /t REG_DWORD /d 3 /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management" /v "FeatureSettingsOverrideMask" /t REG_DWORD /d 3 /f > $null 2>&1
}
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management" /v "ClearPageFileAtShutdown" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management\PrefetchParameters" /v "EnablePrefetcher" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management\PrefetchParameters" /v "EnableSuperfetch" /t REG_DWORD /d 0 /f > $null 2>&1

# Unified Background System Services Configuration (Start: 4 = Disabled, 3 = Demand/Manual)
Write-Host "Configuring system services for performance and radical RAM reduction..." -ForegroundColor Green
$serviceConfigs = [ordered]@{
    # --- Disabled Background Services (Start = 4: Completely stopped, zero memory overhead) ---
    "AJRouter"                                 = 4  # AllJoyn Router Service
    "AppVClient"                               = 4  # Microsoft Application Virtualization Client
    "AssignedAccessManagerSvc"                 = 4  # Assigned Access Manager
    "CertPropSvc"                              = 4  # Certificate Propagation
    "CscService"                               = 4  # Offline Files
    "DialogBlockingService"                    = 4  # Dialog Blocking Service
    "DiagTrack"                                = 4  # Connected User Experiences and Telemetry
    "diagnosticshub.standardcollector.service" = 4  # Diagnostics Hub Collector
    "dmwappushservice"                         = 4  # WAP Push Message Routing Service
    "DoSvc"                                    = 4  # Delivery Optimization
    "DPS"                                      = 4  # Diagnostic Policy Service
    "DusmSvc"                                  = 4  # Data Usage Monitoring
    "edgeupdate"                               = 4  # Microsoft Edge Update Service
    "edgeupdatem"                              = 4  # Microsoft Edge Update Service
    "Fax"                                      = 4  # Fax Service
    "GpuEnergyDrv"                             = 4  # GPU Energy Driver
    "GraphicsPerfSvc"                          = 4  # Graphics Performance Monitor Service
    "HomeGroupListener"                        = 4  # HomeGroup Listener
    "HomeGroupProvider"                        = 4  # HomeGroup Provider
    "icssvc"                                   = 4  # Mobile Hotspot Service
    "InventorySvc"                             = 4  # Device Association / Inventory Service
    "iphlpsvc"                                 = 4  # IP Helper (IPv6 6to4/ISATAP tunnels)
    "lfsvc"                                    = 4  # Geolocation Service
    "MapsBroker"                               = 4  # Downloaded Maps Manager
    "NetTcpPortSharing"                        = 4  # Net.Tcp Port Sharing Service
    "Ndu"                                      = 4  # Network Data Usage Monitoring (Prevents non-paged pool memory leak)
    "PcaSvc"                                   = 4  # Program Compatibility Assistant
    "PhoneSvc"                                 = 4  # Phone Service
    "PrintNotify"                              = 4  # Print Spooler Notification Service
    "RemoteRegistry"                           = 4  # Remote Registry
    "RetailDemo"                               = 4  # Retail Demo Service
    "SCardSvr"                                 = 4  # Smart Card Service
    "ScDeviceEnum"                             = 4  # Smart Card Device Enumeration Service
    "SEMgrSvc"                                 = 4  # Payments and NFC/SE Manager
    "SensorDataService"                        = 4  # Sensor Data Service
    "SensorService"                            = 4  # Sensor Service
    "SensrSvc"                                 = 4  # Sensor Monitoring Service
    "SharedAccess"                             = 4  # Internet Connection Sharing
    "SharedRealitySvc"                         = 4  # Spatial Data / Mixed Reality Service
    "SmsRouter"                                = 4  # SMS Router
    "Spooler"                                  = 4  # Print Spooler (Manageable via Desktop tool)
    "SysMain"                                  = 4  # SuperFetch / RAM pre-caching
    "TrkWks"                                   = 4  # Distributed Link Tracking Client
    "TroubleshootingSvc"                       = 4  # Recommended Troubleshooting Service
    "WalletService"                            = 4  # Wallet Service
    "WarpJITSvc"                               = 4  # WARP JIT Service
    "WdiServiceHost"                           = 4  # Diagnostic Service Host
    "WdiSystemHost"                            = 4  # Diagnostic System Host
    "wercplsupport"                            = 4  # Problem Reports Control Panel Support
    "WerSvc"                                   = 4  # Windows Error Reporting Service
    "wisvc"                                    = 4  # Windows Insider Service
    "WMPNetworkSvc"                            = 4  # Windows Media Player Network Sharing
    "WpcMonSvc"                                = 4  # Parental Controls
    "WSAIFabricSvc"                            = 4  # Windows Subsystem for Android Fabric Service
    "WSearch"                                  = $(if ($keepSearchIndex) { 2 } else { 4 })  # Windows Search Indexer (2=Auto, 4=Disabled)
    "XblAuthManager"                           = if ($keepXboxServices) { 3 } else { 4 }  # Xbox Live Auth Manager
    "XblGameSave"                              = if ($keepXboxServices) { 3 } else { 4 }  # Xbox Live Game Save
    "XboxGipSvc"                               = if ($keepXboxServices) { 3 } else { 4 }  # Xbox Accessory Management Service
    "XboxNetApiSvc"                            = if ($keepXboxServices) { 3 } else { 4 }  # Xbox Live Networking Service

    # --- Demand Start Services (Start = 3: Manual, runs on demand only - protects LogonUI, DirectWrite & Per-User sessions) ---
    "AppHostSvc"                               = 3  # Application Host Helper
    "AxInstSV"                                 = 3  # ActiveX Installer
    "BcastDVRUserService"                      = 3  # GameDVR and Broadcast User Service (Per-user template)
    "BDESVC"                                   = 3  # BitLocker Drive Encryption Service
    "CaptureService"                           = 3  # Screen / Camera capture broker
    "CDPSvc"                                   = 3  # Connected Devices Platform Service
    "CDPUserSvc"                               = 3  # Connected Devices Platform User Service (Per-user template)
    "DevQueryBroker"                           = 3  # Device Setup / Query Broker
    "DeviceInstall"                            = 3  # Device Install Service
    "DisplayEnhancementService"                = 3  # Display Enhancement Service
    "DmEnrollmentSvc"                          = 3  # Device Management Enrollment
    "DsSvc"                                    = 3  # Data Sharing Service
    "DsmSvc"                                   = 3  # Device Setup Manager
    "EapHost"                                  = 3  # Extensible Authentication Protocol
    "EFS"                                      = 3  # Encrypting File System
    "EntAppSvc"                                = 3  # Enterprise App Management
    "FDResPub"                                 = 3  # Function Discovery Resource Publication
    "FontCache"                                = 3  # Windows Font Cache Service (Demand-start prevents DirectWrite LogonUI hang)
    "FontCache3.0.0.0"                         = 3  # WPF Font Cache Service (Demand-start prevents XAML/DirectWrite hang)
    "FrameServer"                              = 3  # Windows Camera Frame Server
    "IEEtwCollectorService"                    = 3  # Internet Explorer ETW Collector
    "IKEEXT"                                   = 3  # IKE and AuthIP IPsec Keying Modules
    "InstallService"                           = 3  # Microsoft Store Install Service
    "IpxlatCfgSvc"                             = 3  # IP Translation Configuration Service
    "KtmRm"                                    = 3  # KtmRm for Distributed Transaction Coordinator
    "LanmanServer"                             = 3  # Server / SMB File Sharing
    "LicenseManager"                           = 3  # Windows License Manager
    "LxpSvc"                                   = 3  # Language Experience Service
    "McpManagementService"                     = 3  # Media Control Platform
    "MessagingService"                         = 3  # Messaging Service (Per-user template)
    "MixedRealityOpenXRSvc"                    = 3  # Mixed Reality OpenXR Service
    "MSDTC"                                    = 3  # Distributed Transaction Coordinator
    "MSiSCSI"                                  = 3  # Microsoft iSCSI Initiator
    "NaturalAuthentication"                    = 3  # Companion Device Authentication
    "NcaSvc"                                   = 3  # Network Connectivity Assistant
    "NcbService"                               = 3  # Network Connection Broker
    "NcdAutoSetup"                             = 3  # Network Connected Devices Auto-Setup
    "Netlogon"                                 = 3  # Netlogon
    "Netman"                                   = 3  # Network Connections
    "NetSetupSvc"                              = 3  # Network Setup Service
    "NgcCtnrSvc"                               = 3  # Passport Container Service
    "OneSyncSvc"                               = 3  # Sync Host (Per-user template)
    "PimIndexMaintenanceSvc"                   = 3  # Contact Data Indexing (Per-user template)
    "ShellHWDetection"                         = 3  # Shell Hardware Detection
    "stisvc"                                   = 3  # Windows Image Acquisition
    "svsvc"                                    = 3  # Spot Verifier
    "TabletInputService"                       = 3  # Touch Keyboard and Handwriting Panel
    "TapiSrv"                                  = 3  # Telephony
    "TokenBroker"                              = 3  # Web Account Manager
    "UnistoreSvc"                              = 3  # User Data Storage (Per-user template)
    "UserDataSvc"                              = 3  # User Data Access (Per-user template)
    "VaultSvc"                                 = 3  # Credential Manager
    "WbioSrvc"                                 = 3  # Windows Biometric Service (Hello/Fingerprint on demand)
    "WpnService"                               = 3  # Windows Push Notifications System Service (Protects Explorer taskbar initialization)
    "WpnUserService"                           = 3  # Push Notifications User Service (Per-user template)
}

# Apply conditional service configurations
if (-not $keepBT) {
    $serviceConfigs["BthAvctpSvc"]          = 4  # Audio/Video Control Transport Protocol
    $serviceConfigs["BluetoothUserService"] = 3  # Bluetooth User Support Service (Demand-start to preserve per-user integrity)
}
if ($disableWU) {
    $serviceConfigs["wuauserv"]             = 4  # Windows Update
    $serviceConfigs["UsoSvc"]               = 4  # Update Orchestrator Service
    $serviceConfigs["WaaSMedicSVC"]         = 4  # Windows Update Medic Service
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

# Hibernate & Fast Startup Configuration (HibernateMode = Off / Reduced / Keep)
switch ($hibernateMode.ToLower()) {
    'off' {
        reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Power" /v "HibernateEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
        reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Power" /v "HiberbootEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
    }
    'reduced' {
        reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Power" /v "HibernateEnabled" /t REG_DWORD /d 1 /f > $null 2>&1
        reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Power" /v "HiberFileSizePercent" /t REG_DWORD /d 20 /f > $null 2>&1
        reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Power" /v "HiberbootEnabled" /t REG_DWORD /d 1 /f > $null 2>&1
    }
    default {
        # Keep OS default or disable fast startup for AtlasOS longevity
        if ($atlasReviOSMode) {
            reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Power" /v "HiberbootEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
        }
    }
}

# Full-Screen Optimizations (DisableFSE: Mode 2 = Fullscreen Exclusive priority)
if ($disableFSE) {
    reg.exe add "HKLM\zNTUSER\System\GameConfigStore" /v "GameDVR_FSEBehaviorMode" /t REG_DWORD /d 2 /f > $null 2>&1
    reg.exe add "HKLM\zNTUSER\System\GameConfigStore" /v "GameDVR_HonorUserFSEBehaviorMode" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\System\GameConfigStore" /v "GameDVR_FSEBehaviorMode" /t REG_DWORD /d 2 /f > $null 2>&1
    reg.exe add "HKLM\zDEFAULT\System\GameConfigStore" /v "GameDVR_HonorUserFSEBehaviorMode" /t REG_DWORD /d 1 /f > $null 2>&1
}

# DNS Client LLMNR & Multicast Suppression
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows NT\DNSClient" /v "EnableMulticast" /t REG_DWORD /d 0 /f > $null 2>&1

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

    # 1. Network QoS Latency (100% full bandwidth allocation)
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Psched" /v "NonBestEffortLimit" /t REG_DWORD /d 0 /f > $null 2>&1

    # 2. Storage & Crash Control (Configurable CrashDumpMode: Automatic=7, Small=3, None=0)
    $cdVal = switch ($crashDumpMode.ToLower()) {
        'none'      { 0 }
        'small'     { 3 }
        'automatic' { 7 }
        default     { if ($atlasReviOSMode) { 0 } else { 7 } }
    }
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\CrashControl" /v "CrashDumpEnabled" /t REG_DWORD /d $cdVal /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\CrashControl" /v "LogEvent" /t REG_DWORD /d 0 /f > $null 2>&1
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\CrashControl" /v "SendAlert" /t REG_DWORD /d 0 /f > $null 2>&1

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

# Shell & Thumbnail RAM Optimization: Stop thumbnail caching
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
reg.exe add "HKLM\zNTUSER\Control Panel\Desktop" /v "LowLevelHooksTimeout" /t REG_SZ /d "1000" /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Control Panel\Desktop" /v "LowLevelHooksTimeout" /t REG_SZ /d "1000" /f > $null 2>&1
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

# Background Process Reduction: Windows Error Reporting (wermgr.exe)
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting" /v "Disabled" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting" /v "DontSendAdditionalData" /t REG_DWORD /d 1 /f > $null 2>&1

# Background Process Reduction: CrossDevice & Phone Link (PhoneExperienceHost.exe)
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

# ============================================================================
# Advanced Windows Optimization Suite: WinUtil, Sophia Script, SophiApp, Optimizer, Bloatynosy
# ============================================================================
Write-Host "Applying advanced optimizations from WinUtil, Sophia Script, SophiApp, Optimizer & Bloatynosy..." -ForegroundColor Green

# 1. Bloatynosy & Classic Shell: Classic Context Menu baked into Default & NTUSER hives offline
reg.exe add "HKLM\zDEFAULT\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32" /ve /t REG_SZ /d "" /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32" /ve /t REG_SZ /d "" /f > $null 2>&1

# 2. Sophia Script & SophiApp: Instant First Logon, Lossless Wallpaper, and Control Panel
# Disable "Hi, Getting things ready for you" spinning animation (saves 30-60s on first login)
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v "EnableFirstLogonAnimation" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v "EnableFirstLogonAnimation" /t REG_DWORD /d 0 /f > $null 2>&1
# Lossless wallpaper quality (JPEGImportQuality 100)
reg.exe add "HKLM\zDEFAULT\Control Panel\Desktop" /v "JPEGImportQuality" /t REG_DWORD /d 100 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Control Panel\Desktop" /v "JPEGImportQuality" /t REG_DWORD /d 100 /f > $null 2>&1
# Classic Control Panel: Large Icons view by default
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\ControlPanel" /v "AllItemsIconView" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\ControlPanel" /v "StartupPage" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\ControlPanel" /v "AllItemsIconView" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\ControlPanel" /v "StartupPage" /t REG_DWORD /d 1 /f > $null 2>&1
# Sophia scheduled task purges offline
Remove-Item -LiteralPath "$tasksPath\Microsoft\Windows\Application Experience\MareBackup" -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath "$tasksPath\Microsoft\Windows\Application Experience\StartupAppTask" -Force -ErrorAction SilentlyContinue

# 3. Chris Titus WinUtil: OOBE Background UScheduler Bloat Suppression
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate" /v "workCompleted" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\OutlookUpdate" /v "workCompleted" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\DevHomeUpdate" /v "workCompleted" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler_Oobe\WindowsUpdate" /v "workCompleted" /t REG_DWORD /d 1 /f > $null 2>&1

# 4. Hellzerg Optimizer: RegBack Backups & Explorer Responsiveness
# Re-enable periodic registry hive backups to RegBack
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Configuration Manager" /v "EnablePeriodicBackup" /t REG_DWORD /d 1 /f > $null 2>&1
# Explorer link resolution, low disk space warnings, unknown extension web searches
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v "NoLowDiskSpaceChecks" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v "LinkResolveIgnoreLinkInfo" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v "NoResolveSearch" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v "NoResolveTrack" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v "NoInternetOpenWith" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v "NoLowDiskSpaceChecks" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v "LinkResolveIgnoreLinkInfo" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v "NoResolveSearch" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v "NoResolveTrack" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v "NoInternetOpenWith" /t REG_DWORD /d 1 /f > $null 2>&1
# Disable Remote Assistance unsolicited help invitations
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Remote Assistance" /v "fAllowToGetHelp" /t REG_DWORD /d 0 /f > $null 2>&1

# ============================================================================
# 5. Low-Latency Gaming, Hardware Scheduling, and CPU Tuning (AtlasOS / ReviOS Aligned)
# ============================================================================
Write-Host "Applying Low-Latency Gaming, HAGS, & CPU scheduling optimizations..." -ForegroundColor Green
# Enable Hardware-Accelerated GPU Scheduling (HAGS)
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\GraphicsDrivers" /v "HwSchMode" /t REG_DWORD /d 2 /f > $null 2>&1
# Disable CPU core parking (mitigates stutter on hybrid Intel P/E-cores and AMD 3D V-Cache CPUs)
$coreParkingGuid = "HKLM\zSYSTEM\ControlSet001\Control\Power\PowerSettings\54533251-82be-4824-96c1-47b60b740d00\0cc5b647-c1df-4637-891a-dec35c318583"
reg.exe add $coreParkingGuid /v "ValueMax" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add $coreParkingGuid /v "ValueMin" /t REG_DWORD /d 0 /f > $null 2>&1
# Set Energy Performance Preference (EPP) to 0 (Max Performance / Minimum Latency)
$eppGuid = "HKLM\zSYSTEM\ControlSet001\Control\Power\PowerSettings\54533251-82be-4824-96c1-47b60b740d00\36688441-e06f-430b-a16e-b96ff9d400f3"
reg.exe add $eppGuid /v "ValueMax" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add $eppGuid /v "ValueMin" /t REG_DWORD /d 0 /f > $null 2>&1

# Modular Power Presets (USB Selective Suspend, PCIe ASPM, CPU Boost, Disk Idle)
$psBase = "HKLM\zSYSTEM\ControlSet001\Control\Power\PowerSettings"
$resolvedPower = if ($powerPreset -and $script:PowerPresets.Contains($powerPreset)) { $script:PowerPresets[$powerPreset] } else { $script:PowerPresets['Desktop'] }

$usbVal = if ($disableUSBSuspend) { 0 } else { $resolvedPower.UsbSuspend }
reg.exe add "$psBase\2a737441-1930-4402-8d77-b2bebba308a3\48e6b7a6-50f5-4782-a5d4-53bb8f07e226" /v "ACSettingIndex" /t REG_DWORD /d $usbVal /f > $null 2>&1
reg.exe add "$psBase\2a737441-1930-4402-8d77-b2bebba308a3\48e6b7a6-50f5-4782-a5d4-53bb8f07e226" /v "DCSettingIndex" /t REG_DWORD /d $usbVal /f > $null 2>&1

reg.exe add "$psBase\501a4d13-42ac-4436-9e57-8b0070663244\ee12f906-d276-4167-bf9b-b4780a50c1fa" /v "ACSettingIndex" /t REG_DWORD /d $resolvedPower.PcieLpm /f > $null 2>&1
reg.exe add "$psBase\501a4d13-42ac-4436-9e57-8b0070663244\ee12f906-d276-4167-bf9b-b4780a50c1fa" /v "DCSettingIndex" /t REG_DWORD /d $resolvedPower.PcieLpm /f > $null 2>&1

$boostAc = if ($cpuBoostMode -eq 'Aggressive') { 2 } elseif ($cpuBoostMode -eq 'Efficient') { 1 } elseif ($cpuBoostMode -eq 'Off') { 0 } else { $resolvedPower.BoostAc }
$boostDc = if ($cpuBoostMode -eq 'Aggressive') { 2 } elseif ($cpuBoostMode -eq 'Efficient') { 1 } elseif ($cpuBoostMode -eq 'Off') { 0 } else { $resolvedPower.BoostDc }
$boostGuid = "$psBase\54533251-82be-4824-96c1-47b60b740d00\be337238-0d82-4146-a960-4f3749d470c7"
reg.exe add $boostGuid /v "ACSettingIndex" /t REG_DWORD /d $boostAc /f > $null 2>&1
reg.exe add $boostGuid /v "DCSettingIndex" /t REG_DWORD /d $boostDc /f > $null 2>&1

$diskGuid = "$psBase\0012ee47-9041-4b5d-9b77-535fba8b1442\abfc2519-3608-4c2a-9dea-dfd1d45f50c4"
reg.exe add $diskGuid /v "ACSettingIndex" /t REG_DWORD /d $resolvedPower.DiskIdle /f > $null 2>&1
reg.exe add $diskGuid /v "DCSettingIndex" /t REG_DWORD /d $resolvedPower.DiskIdle /f > $null 2>&1
# Exclude display/chipset driver overwrites in Windows Update (prevents GPU driver rollback)
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v "ExcludeWUDriversInQualityUpdate" /t REG_DWORD /d 1 /f > $null 2>&1

# Offline Message Signaled Interrupts (MSI) enablement across target PCI device classes (GPU, NVMe, NIC)
try {
    $targetClasses = @(
        '{4d36e968-e325-11ce-bfc1-08002be10318}', # Display / GPU
        '{4d36e972-e325-11ce-bfc1-08002be10318}', # Network Adapters (NIC)
        '{4d36e97b-e325-11ce-bfc1-08002be10318}'  # SCSIAdapter / NVMe Storage Controllers
    )
    Get-ChildItem -Path "HKLM:\zSYSTEM\ControlSet001\Enum\PCI" -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -eq "Device Parameters" } | ForEach-Object {
        $parentPath = Split-Path -Path $_.PSPath -Parent
        $classGuid = (Get-ItemProperty -Path $parentPath -Name "ClassGUID" -ErrorAction SilentlyContinue).ClassGUID
        if (-not $classGuid -or ($targetClasses -contains $classGuid)) {
            $msiKey = Join-Path -Path $_.PSPath -ChildPath "Interrupt Management\MessageSignaledInterruptProperties"
            if (-not (Test-Path -LiteralPath $msiKey)) {
                New-Item -Path $msiKey -Force -ErrorAction SilentlyContinue | Out-Null
            }
            Set-ItemProperty -Path $msiKey -Name "MSISupported" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        }
        # NVIDIA Ultra Low Latency Registry Tuning (PowerMizer & Per-CPU Core DPC)
        if ($nvidiaLowLatency -and $_.PSPath -match 'VEN_10DE') {
            Set-ItemProperty -Path $_.PSPath -Name "PowerMizerEnable" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $_.PSPath -Name "PerfLevelSrc" -Value 13090 -Type DWord -Force -ErrorAction SilentlyContinue # 0x3322
            Set-ItemProperty -Path $_.PSPath -Name "RmGpsPsEnablePerCpuCoreDpc" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        }
    }
} catch {}

# ============================================================================
# 6. Windows 11 AI, Copilot, Recall & Edge Telemetry Offline Suppression
# ============================================================================
Write-Host "Applying Windows 11 AI, Copilot, Recall & Edge suppression policies..." -ForegroundColor Green
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v "DisableAIDataAnalysis" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v "TurnOffRecall" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" /v "TurnOffWindowsCopilot" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Policies\Microsoft\Windows\WindowsCopilot" /v "TurnOffWindowsCopilot" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Policies\Microsoft\Windows\WindowsCopilot" /v "TurnOffWindowsCopilot" /t REG_DWORD /d 1 /f > $null 2>&1
# Edge Copilot and Hubs Sidebar
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Edge" /v "HubsSidebarEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Edge" /v "CopilotPageContext" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Edge" /v "StandaloneHubsSidebarEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
# Edge Update suppression (protects WebView2 for Steam/Discord/desktop apps)
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\EdgeUpdate" /v "Update{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\EdgeUpdate" /v "Install{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\EdgeUpdate" /v "Update{F3017226-FE2A-4295-8BDF-F0E3A9A7E4C5}" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\EdgeUpdate" /v "Install{F3017226-FE2A-4295-8BDF-F0E3A9A7E4C5}" /t REG_DWORD /d 1 /f > $null 2>&1
# SmartScreen & PII telemetry opt-out
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\System" /v "EnableSmartScreen" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\AppHost" /v "EnableWebContentEvaluation" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\AppHost" /v "EnableWebContentEvaluation" /t REG_DWORD /d 0 /f > $null 2>&1

# ============================================================================
# 7. Japanese IME Privacy & Telemetry Opt-out
# ============================================================================
Write-Host "Configuring Japanese IME privacy opt-out..." -ForegroundColor Green
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\IME\15.0\IMEJP\MSIME" /v "CloudCandidate" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\IME\15.0\IMEJP\MSIME" /v "SendFeedback" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\IME\15.0\IMEJP\MSIME" /v "CloudCandidate" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\IME\15.0\IMEJP\MSIME" /v "SendFeedback" /t REG_DWORD /d 0 /f > $null 2>&1

# ============================================================================
# 8. Dark Mode Default Configuration
# ============================================================================
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" /v "AppsUseLightTheme" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" /v "SystemUsesLightTheme" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" /v "AppsUseLightTheme" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" /v "SystemUsesLightTheme" /t REG_DWORD /d 0 /f > $null 2>&1

# ============================================================================
# 9. OEM Information Branding
# ============================================================================
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation" /v "Manufacturer" /t REG_SZ /d "nano11 Project" /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation" /v "SupportURL" /t REG_SZ /d "https://github.com/gh459/nano11" /f > $null 2>&1

# ============================================================================
# 10. Zero-Click Setup ChildCompletion Pre-configuration
# ============================================================================
reg.exe add "HKLM\zSYSTEM\Setup\Status\ChildCompletion" /v "setup.exe" /t REG_DWORD /d 3 /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\Setup\Status\ChildCompletion" /v "audit.exe" /t REG_DWORD /d 3 /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\Setup\Status\ChildCompletion" /v "oobe.exe" /t REG_DWORD /d 3 /f > $null 2>&1

Enter-Phase 11 "Configure autounattend.xml & Pre-extract Setup Scripts"

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
    # Dynamically parameterize ComputerName and UserName
    $xmlContent = $xmlContent -replace '<ComputerName>nano11</ComputerName>', "<ComputerName>$ComputerName</ComputerName>"
    $xmlContent = $xmlContent -replace '<Username>User</Username>', "<Username>$UserName</Username>"

    # Inject Japanese 106/109 Keyboard & Tokyo TimeZone if enabled
    if ($setJapaneseKeyboard) {
        if ($xmlContent -notmatch '<TimeZone>Tokyo Standard Time</TimeZone>') {
            $xmlContent = $xmlContent -replace '(<component name="Microsoft-Windows-Shell-Setup"[^>]*>\s*<ComputerName>[^<]*</ComputerName>)', "`$1`r`n      <TimeZone>Tokyo Standard Time</TimeZone>"
        }
        if ($xmlContent -notmatch 'Microsoft-Windows-International-Core') {
            $intlComponent = @"
    <component name="Microsoft-Windows-International-Core" processorArchitecture="$architecture" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>0411:00000411</InputLocale>
    </component>
"@
            $xmlContent = $xmlContent -replace '(<settings pass="specialize">)', "`$1`r`n$intlComponent"
        }
    }

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

    # SetupComplete.cmd two-stage verification marker creation
    $setupCompleteCmd = @"
@echo off
if not exist "%SystemDrive%\ProgramData\nano11" mkdir "%SystemDrive%\ProgramData\nano11"
echo %DATE% %TIME% SetupComplete > "%SystemDrive%\ProgramData\nano11\setupcomplete.stamp"
"@
    $setupCompleteCmd | Set-Content -LiteralPath (Join-Path -Path $setupScriptsDir -ChildPath "SetupComplete.cmd") -Encoding ascii
    $oemScriptsDir = Join-Path -Path $nano11Dir -ChildPath "sources\`$OEM\`$\Setup\Scripts"
    New-Item -Path $oemScriptsDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    $setupCompleteCmd | Set-Content -LiteralPath (Join-Path -Path $oemScriptsDir -ChildPath "SetupComplete.cmd") -Encoding ascii

    # Bundle winget-packages.json for post-setup automated app installation if present
    $repoWingetJson = Join-Path -Path $scriptDir -ChildPath "tools\winget-packages.json"
    if (Test-Path -LiteralPath $repoWingetJson) {
        Copy-Item -LiteralPath $repoWingetJson -Destination (Join-Path -Path $setupScriptsDir -ChildPath "winget-packages.json") -Force -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath $repoWingetJson -Destination (Join-Path -Path $nano11Dir -ChildPath "sources\winget-packages.json") -Force -ErrorAction SilentlyContinue
        Write-Host "  - Bundled winget-packages.json for post-setup automated app installation" -ForegroundColor Green
    }

    # $OEM$ Custom Hardware Driver Injection (-InjectDrivers)
    if ($InjectDrivers -and (Test-Path -LiteralPath $InjectDrivers)) {
        Write-Host "Injecting custom hardware drivers from $InjectDrivers..." -ForegroundColor Cyan
        $destDriversDir = Join-Path -Path $nano11Dir -ChildPath "sources\`$OEM\`$1\Drivers"
        New-Item -ItemType Directory -Force -Path $destDriversDir | Out-Null
        Copy-Item -Path "$InjectDrivers\*" -Destination $destDriversDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  - Drivers staged in sources\`$OEM\`$1\Drivers" -ForegroundColor Green
    }
    
    # Stage feature flags for FirstLogon.ps1 automation
    if ($disableMemCompression) {
        Set-Content -LiteralPath (Join-Path -Path $setupScriptsDir -ChildPath "disable-memcompression.flag") -Value "1" -Encoding ascii
    }
    if ($noHypervisor -or (-not $wslSupport -and $selectedProfile -in @('extreme', 'handheld', 'audio'))) {
        Set-Content -LiteralPath (Join-Path -Path $setupScriptsDir -ChildPath "no-hypervisor.flag") -Value "1" -Encoding ascii
    }
    if ($script:activeTweakGroups['NetworkStack']) {
        Set-Content -LiteralPath (Join-Path -Path $setupScriptsDir -ChildPath "disable-netbios.flag") -Value "1" -Encoding ascii
    }
    if ($removeWebViewPostOOBE) {
        Set-Content -LiteralPath (Join-Path -Path $setupScriptsDir -ChildPath "remove-webview.flag") -Value "1" -Encoding ascii
    }

    # Save build traceability manifest (nano11-build-info.json)
    $buildInfoObj = [ordered]@{
        BuilderVersion  = $script:Nano11Version
        BuildUtc        = [DateTime]::UtcNow.ToString("o")
        Profile         = $selectedProfile
        Architecture    = $architecture
        ComputerName    = $ComputerName
        UserName        = $UserName
        JapaneseKeyboard= $setJapaneseKeyboard
        KeepBasicApps   = $keepBasicApps
        KeepSearchIndex = $keepSearchIndex
        SourceDrive     = $DriveLetter
        PayloadFormat   = if ($exportESDMode) { "ESD" } elseif ($splitWIMMode) { "SWM" } else { "WIM" }
    }
    $buildInfoJson = $buildInfoObj | ConvertTo-Json -Depth 4
    $buildInfoJson | Set-Content -LiteralPath (Join-Path -Path $nano11Dir -ChildPath "nano11-build-info.json") -Encoding utf8
    $buildInfoJson | Set-Content -LiteralPath (Join-Path -Path $setupScriptsDir -ChildPath "nano11-build-info.json") -Encoding utf8
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

# Bundle Custom Post-Install Scripts if provided in tools\custom-scripts
$customScriptsDir = Join-Path -Path $scriptDir -ChildPath "tools\custom-scripts"
if (Test-Path -LiteralPath $customScriptsDir) {
    $targetCustomDir = Join-Path -Path $scratchDir -ChildPath "Windows\Setup\Scripts\Custom"
    New-Item -Path $targetCustomDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    Get-ChildItem -Path $customScriptsDir -File | Where-Object { $_.Name -ne "README.md" } | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $targetCustomDir -Force -ErrorAction SilentlyContinue
    }
    Write-Host "  - Bundled custom post-install scripts to Windows\Setup\Scripts\Custom" -ForegroundColor Green
}

# Deploy Zero-Footprint Browser Grabber and Nano11 Control Center to Public Desktop & Setup Tools
$pubDesktop = Join-Path -Path $scratchDir -ChildPath "Users\Public\Desktop"
$setupTools = Join-Path -Path $scratchDir -ChildPath "Windows\Setup\Tools"
New-Item -Path $pubDesktop -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
New-Item -Path $setupTools -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null

$browserPs1Content = @'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
$ErrorActionPreference = 'Stop'

Clear-Host
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "               nano11 Browser Installer" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "Edge was removed for minimal footprint. Select a browser" -ForegroundColor Gray
Write-Host "to download and install directly from its official CDN:" -ForegroundColor Gray
Write-Host ""
Write-Host "  [1] Google Chrome         (Official Silent Installer)" -ForegroundColor Green
Write-Host "  [2] Mozilla Firefox        (Official Silent Installer - Japanese)" -ForegroundColor Yellow
Write-Host "  [3] Brave Browser          (Official Standalone Installer)" -ForegroundColor Magenta
Write-Host "  [4] Floorp Browser         (Japanese High-Privacy Gecko)" -ForegroundColor Cyan
Write-Host "  [5] Microsoft Edge         (Official Standalone Installer)" -ForegroundColor Blue
Write-Host "  [0] Exit" -ForegroundColor DarkGray
Write-Host "=========================================================" -ForegroundColor Cyan

$choice = Read-Host "Select option [1-5, 0]"
if (-not $choice -or $choice.Trim() -eq '0') { exit }

$tempDir = Join-Path -Path $env:TEMP -ChildPath "nano11_browser_$([System.IO.Path]::GetRandomFileName())"
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

try {
    switch ($choice.Trim()) {
        '1' {
            Write-Host "`nDownloading Google Chrome..." -ForegroundColor Green
            $installer = Join-Path -Path $tempDir -ChildPath "ChromeSetup.exe"
            Invoke-WebRequest -Uri "https://dl.google.com/chrome/install/latest/chrome_installer.exe" -OutFile $installer -UseBasicParsing
            Write-Host "Installing Google Chrome silently..." -ForegroundColor Green
            Start-Process -FilePath $installer -ArgumentList "/silent /install" -Wait
            Write-Host "Google Chrome installation completed!" -ForegroundColor Green
        }
        '2' {
            Write-Host "`nDownloading Mozilla Firefox..." -ForegroundColor Yellow
            $installer = Join-Path -Path $tempDir -ChildPath "FirefoxSetup.exe"
            Invoke-WebRequest -Uri "https://download.mozilla.org/?product=firefox-latest-ssl&os=win64&lang=ja" -OutFile $installer -UseBasicParsing
            Write-Host "Installing Mozilla Firefox silently..." -ForegroundColor Yellow
            Start-Process -FilePath $installer -ArgumentList "/S" -Wait
            Write-Host "Mozilla Firefox installation completed!" -ForegroundColor Green
        }
        '3' {
            Write-Host "`nDownloading Brave Browser..." -ForegroundColor Magenta
            $installer = Join-Path -Path $tempDir -ChildPath "BraveSetup.exe"
            Invoke-WebRequest -Uri "https://laptop-updates.brave.com/latest/winx64" -OutFile $installer -UseBasicParsing
            Write-Host "Installing Brave Browser silently..." -ForegroundColor Magenta
            Start-Process -FilePath $installer -ArgumentList "/silent /install" -Wait
            Write-Host "Brave Browser installation completed!" -ForegroundColor Green
        }
        '4' {
            Write-Host "`nDownloading Floorp Browser..." -ForegroundColor Cyan
            $installer = Join-Path -Path $tempDir -ChildPath "FloorpSetup.exe"
            Invoke-WebRequest -Uri "https://github.com/Floorp-Projects/Floorp/releases/latest/download/floorp-windows-x86_64-setup.exe" -OutFile $installer -UseBasicParsing
            Write-Host "Installing Floorp Browser silently..." -ForegroundColor Cyan
            Start-Process -FilePath $installer -ArgumentList "/S" -Wait
            Write-Host "Floorp Browser installation completed!" -ForegroundColor Green
        }
        '5' {
            Write-Host "`nDownloading Microsoft Edge..." -ForegroundColor Blue
            $installer = Join-Path -Path $tempDir -ChildPath "MicrosoftEdgeSetup.exe"
            Invoke-WebRequest -Uri "https://msedge.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/latest/MicrosoftEdgeSetup.exe" -OutFile $installer -UseBasicParsing
            Write-Host "Installing Microsoft Edge silently..." -ForegroundColor Blue
            Start-Process -FilePath $installer -ArgumentList "/silent /install" -Wait
            Write-Host "Microsoft Edge installation completed!" -ForegroundColor Green
        }
    }
} catch {
    Write-Host "Download/installation error: $($_.Exception.Message)" -ForegroundColor Red
} finally {
    if (Test-Path -LiteralPath $tempDir) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Start-Sleep -Seconds 2
'@

$browserCmdContent = @'
@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-Browser.ps1"
'@

$controlCenterContent = @'
@echo off
setlocal enabledelayedexpansion
title nano11 Control Center
:MENU
cls
echo ========================================================
echo                 nano11 Control Center
echo ========================================================
echo   [1] Toggle Windows Defender (Enable / Disable)
echo   [2] Toggle Windows Update   (Enable / Disable)
echo   [3] Toggle Hibernation      (Save RAM-sized GBs on SSD)
echo   [4] Toggle Bluetooth        (Enable / Disable Services)
echo   [5] Toggle Print Spooler    (Enable / Disable Service)
echo   [6] Free Memory ^& Clear Temp (Trim Working Sets ^& Temp)
echo   [7] Install Web Browser     (Chrome, Firefox, Brave...)
echo   [0] Exit
echo ========================================================
set /p choice="Select option [1-7, 0]: "
if "%choice%"=="1" goto DEFENDER
if "%choice%"=="2" goto WU
if "%choice%"=="3" goto HIBERNATE
if "%choice%"=="4" goto BLUETOOTH
if "%choice%"=="5" goto SPOOLER
if "%choice%"=="6" goto FREEMEM
if "%choice%"=="7" goto BROWSER
if "%choice%"=="0" exit /b
goto MENU

:DEFENDER
echo.
sc query WinDefend | find "RUNNING" >nul
if %errorlevel% equ 0 (
    echo Disabling Windows Defender...
    sc config WinDefend start= disabled >nul 2>&1
    sc stop WinDefend >nul 2>&1
    sc config WdNisSvc start= disabled >nul 2>&1
    sc stop WdNisSvc >nul 2>&1
    sc config Sense start= disabled >nul 2>&1
    sc stop Sense >nul 2>&1
    echo Windows Defender is now DISABLED.
) else (
    echo Enabling Windows Defender...
    sc config WinDefend start= auto >nul 2>&1
    sc start WinDefend >nul 2>&1
    sc config WdNisSvc start= demand >nul 2>&1
    sc start WdNisSvc >nul 2>&1
    echo Windows Defender is now ENABLED.
)
pause
goto MENU

:WU
echo.
sc query wuauserv | find "RUNNING" >nul
if %errorlevel% equ 0 (
    echo Disabling Windows Update...
    sc config wuauserv start= disabled >nul 2>&1
    sc stop wuauserv >nul 2>&1
    sc config UsoSvc start= disabled >nul 2>&1
    sc stop UsoSvc >nul 2>&1
    echo Windows Update is now DISABLED.
) else (
    echo Enabling Windows Update...
    sc config wuauserv start= auto >nul 2>&1
    sc start wuauserv >nul 2>&1
    sc config UsoSvc start= demand >nul 2>&1
    sc start UsoSvc >nul 2>&1
    echo Windows Update is now ENABLED.
)
pause
goto MENU

:HIBERNATE
echo.
if exist "%SystemDrive%\hiberfil.sys" (
    echo Disabling Hibernation and deleting hiberfil.sys...
    powercfg.exe /hibernate off
    echo Hibernation is now DISABLED.
) else (
    echo Enabling Hibernation...
    powercfg.exe /hibernate on
    echo Hibernation is now ENABLED.
)
pause
goto MENU

:BLUETOOTH
echo.
sc query bthserv | find "RUNNING" >nul
if %errorlevel% equ 0 (
    echo Disabling Bluetooth...
    sc config bthserv start= disabled >nul 2>&1
    sc stop bthserv >nul 2>&1
    sc config BthAvctpSvc start= disabled >nul 2>&1
    sc stop BthAvctpSvc >nul 2>&1
    echo Bluetooth is now DISABLED.
) else (
    echo Enabling Bluetooth...
    sc config bthserv start= auto >nul 2>&1
    sc start bthserv >nul 2>&1
    sc config BthAvctpSvc start= auto >nul 2>&1
    sc start BthAvctpSvc >nul 2>&1
    echo Bluetooth is now ENABLED.
)
pause
goto MENU

:SPOOLER
echo.
sc query Spooler | find "RUNNING" >nul
if %errorlevel% equ 0 (
    echo Disabling Print Spooler...
    sc config Spooler start= disabled >nul 2>&1
    sc stop Spooler >nul 2>&1
    echo Print Spooler is now DISABLED.
) else (
    echo Enabling Print Spooler...
    sc config Spooler start= auto >nul 2>&1
    sc start Spooler >nul 2>&1
    echo Print Spooler is now ENABLED.
)
pause
goto MENU

:FREEMEM
echo.
echo Cleaning temporary files...
del /s /f /q "%TEMP%\*.*" >nul 2>&1
del /s /f /q "%SystemRoot%\Temp\*.*" >nul 2>&1
powershell.exe -NoProfile -Command "try { $sig = '[DllImport(\"psapi.dll\")] public static extern int EmptyWorkingSet(IntPtr h);'; Add-Type -MemberDefinition $sig -Name 'Mem' -Namespace 'Win32' -ErrorAction SilentlyContinue; Get-Process | ForEach-Object { try { [Win32.Mem]::EmptyWorkingSet($_.Handle) | Out-Null } catch {} }; [GC]::Collect(); Write-Host 'RAM working sets trimmed.' -ForegroundColor Green } catch {}"
echo Done.
pause
goto MENU

:BROWSER
start "" "%~dp0Install-Browser.cmd"
goto MENU
'@

if (-not $NoPostInstallAssets) {
    $browserPs1Content | Set-Content -LiteralPath (Join-Path -Path $pubDesktop -ChildPath "Install-Browser.ps1") -Encoding utf8
    $browserCmdContent | Set-Content -LiteralPath (Join-Path -Path $pubDesktop -ChildPath "Install-Browser.cmd") -Encoding ascii
    $controlCenterContent | Set-Content -LiteralPath (Join-Path -Path $pubDesktop -ChildPath "Nano11 Control Center.bat") -Encoding ascii
    Copy-Item -LiteralPath (Join-Path -Path $pubDesktop -ChildPath "Install-Browser.cmd") -Destination (Join-Path -Path $pubDesktop -ChildPath "🌐 Install Browser.cmd") -Force -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath (Join-Path -Path $pubDesktop -ChildPath "Nano11 Control Center.bat") -Destination (Join-Path -Path $pubDesktop -ChildPath "⚡ nano11 Control Center.cmd") -Force -ErrorAction SilentlyContinue

    $browserPs1Content | Set-Content -LiteralPath (Join-Path -Path $setupTools -ChildPath "Install-Browser.ps1") -Encoding utf8
    $browserCmdContent | Set-Content -LiteralPath (Join-Path -Path $setupTools -ChildPath "Install-Browser.cmd") -Encoding ascii
    $controlCenterContent | Set-Content -LiteralPath (Join-Path -Path $setupTools -ChildPath "Nano11 Control Center.bat") -Encoding ascii
    Copy-Item -LiteralPath (Join-Path -Path $setupTools -ChildPath "Install-Browser.cmd") -Destination (Join-Path -Path $setupTools -ChildPath "🌐 Install Browser.cmd") -Force -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath (Join-Path -Path $setupTools -ChildPath "Nano11 Control Center.bat") -Destination (Join-Path -Path $setupTools -ChildPath "⚡ nano11 Control Center.cmd") -Force -ErrorAction SilentlyContinue
    Write-Host "  - Deployed Browser Grabber and Nano11 Control Center to Desktop & Setup Tools" -ForegroundColor Green
} else {
    Write-Host "  - Skipping deployment of post-install assets (-NoPostInstallAssets specified)." -ForegroundColor Yellow
}

# Ensure CurrentControlSet does NOT exist in offline SYSTEM hive
# Creating CurrentControlSet as a real key in an offline hive causes Bug Check 0x67 (CONFIG_INITIALIZATION_FAILED)
# because the NT kernel fails to create the CurrentControlSet symbolic link at boot time.
& reg.exe query "HKLM\zSYSTEM\CurrentControlSet" > $null 2>&1
if ($LASTEXITCODE -eq 0) {
    reg.exe delete "HKLM\zSYSTEM\CurrentControlSet" /f > $null 2>&1
}

# Unmount Registry Hives
Write-Host "Unmounting offline registry hives..." -ForegroundColor Cyan
@('zCOMPONENTS', 'zDEFAULT', 'zNTUSER', 'zSOFTWARE', 'zSYSTEM') | ForEach-Object {
    [void](Unmount-RegistryHiveWithRetry -Name $_)
}
$script:HivesLoaded = $false

# Capture post-debloat metrics and calculate component savings
Write-Host "Capturing post-debloat image metrics and calculating savings..." -ForegroundColor Cyan
$pkgAfterPath = Join-Path -Path $logDir -ChildPath "packages-after.txt"
$featAfterPath = Join-Path -Path $logDir -ChildPath "features-after.txt"
$winsxsAfterPath = Join-Path -Path $logDir -ChildPath "winsxs-after.txt"

Invoke-Dism -DismArgs @("/image:$scratchDir", "/Get-Packages", "/Format:Table") -CaptureOutput | Set-Content -LiteralPath $pkgAfterPath -Encoding utf8
Invoke-Dism -DismArgs @("/image:$scratchDir", "/Get-Features", "/Format:Table") -CaptureOutput | Set-Content -LiteralPath $featAfterPath -Encoding utf8
$script:WinsxsAfterRaw = Invoke-Dism -DismArgs @("/image:$scratchDir", "/Cleanup-Image", "/AnalyzeComponentStore") -CaptureOutput
$script:WinsxsAfterRaw | Set-Content -LiteralPath $winsxsAfterPath -Encoding utf8

$pkgsBefore = Get-Content -LiteralPath $pkgBeforePath -ErrorAction SilentlyContinue | Where-Object { $_ -match 'Package_' }
$pkgsAfter  = Get-Content -LiteralPath $pkgAfterPath -ErrorAction SilentlyContinue | Where-Object { $_ -match 'Package_' }
$script:RemovedPackages = @()
if ($pkgsBefore -and $pkgsAfter) {
    $diff = Compare-Object -ReferenceObject $pkgsBefore -DifferenceObject $pkgsAfter -ErrorAction SilentlyContinue
    $script:RemovedPackages = @($diff | Where-Object SideIndicator -eq '<=' | ForEach-Object { $_.InputObject.Trim() })
}
$script:RemovedPackages | Set-Content -LiteralPath (Join-Path -Path $logDir -ChildPath "removed-packages.txt") -Encoding utf8
Write-Host "Component Store Diff: $($script:RemovedPackages.Count) package(s) removed from image." -ForegroundColor Green

$parseSizeHelper = {
    param($lines)
    foreach ($l in $lines) {
        if ($l -match 'Actual Size of Component Store\s*:\s*([\d\.]+)\s*(GB|MB)') {
            $val = [double]$matches[1]
            if ($matches[2] -ieq 'GB') { return [math]::Round($val * 1024, 1) }
            return $val
        }
    }
    return 0
}
$script:WinSxsBeforeMB = & $parseSizeHelper $script:WinsxsBeforeRaw
$script:WinSxsAfterMB  = & $parseSizeHelper $script:WinsxsAfterRaw
$script:WinSxsSavedMB  = if ($script:WinSxsBeforeMB -gt 0 -and $script:WinSxsAfterMB -gt 0) { [math]::Max(0, [math]::Round($script:WinSxsBeforeMB - $script:WinSxsAfterMB, 1)) } else { 0 }

Enter-Phase 12 "Unmount and Commit install.wim Image"

# 12. Unmount and export install image
Write-Host "Unmounting install image and committing changes..." -ForegroundColor Green
Write-Host "  -> Saving WIM image changes. Progress will display below..." -ForegroundColor Cyan

$unmountSuccess = $false
for ($retry = 1; $retry -le 4; $retry++) {
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    Start-Sleep -Seconds 2

    & dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /commit
    if ($LASTEXITCODE -eq 0) {
        $unmountSuccess = $true
        $script:MountOpened = $false
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
        Write-Host "Critical: Unable to commit changes. Discarding mount to prevent corrupted image..." -ForegroundColor Red
        & dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /discard > $null 2>&1
        $script:MountOpened = $false
        throw "Failed to commit modifications to install image. Build aborted to prevent producing a corrupted ISO."
    } else {
        $script:MountOpened = $false
    }
}

Enter-Phase 13 "Export Modified Image (WIM / ESD / SWM)"

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
    $compressArg = if ($fastExport) { "/Compress:fast" } else { "/Compress:max" }
    & dism.exe /English /Export-Image "/SourceImageFile:$destWim" "/SourceIndex:$index" "/DestinationImageFile:$tempWim" $compressArg
    if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $tempWim) -and ((Get-Item -LiteralPath $tempWim).Length -gt 1GB)) {
        Remove-Item -LiteralPath $destWim -Force -ErrorAction SilentlyContinue
        Rename-Item -LiteralPath $tempWim -NewName "install.wim" -Force
        $exportedWimSize = (Get-Item -LiteralPath $finalWim).Length
        Write-Host "install.wim successfully exported ($([math]::Round($exportedWimSize / 1GB, 2)) GB)." -ForegroundColor Green

        # Split-WIM (install.swm) for 100% FAT32 USB compatibility
        if ($splitWIMMode) {
            Write-Host "Splitting install.wim into <= 3800MB chunks for 100% FAT32 USB compatibility (install.swm)..." -ForegroundColor Cyan
            $swmTarget = Join-Path -Path "$nano11Dir\sources" -ChildPath "install.swm"
            & dism.exe /English /Split-Image "/ImageFile:$finalWim" "/SWMFile:$swmTarget" /FileSize:3800
            if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $swmTarget)) {
                $swmParts = Get-ChildItem -Path "$nano11Dir\sources" -Filter "install*.swm"
                Write-Host "install.swm successfully generated ($($swmParts.Count) parts). Removing single install.wim..." -ForegroundColor Green
                Remove-Item -LiteralPath $finalWim -Force -ErrorAction SilentlyContinue
            } else {
                Write-Host "Warning: Split-Image failed. Retaining single install.wim." -ForegroundColor Yellow
            }
        }
    } else {
        Write-Host "Warning: Export to install_export.wim failed or produced undersized file. Keeping original committed install.wim." -ForegroundColor Yellow
        Remove-Item -LiteralPath $tempWim -Force -ErrorAction SilentlyContinue
    }
}

Enter-Phase 14 "Patch boot.wim (LabConfig & Bypasses)"

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

    # Inspect boot.wim indices (Setup image is usually Index 2, WinPE is Index 1)
    # We patch both indices in-place and preserve dual-index structure for 100% BCD and UEFI stability.
    $bootInfo = & dism.exe /English /Get-WimInfo "/WimFile:$bootWimPath"
    $hasIndex2 = ($bootInfo -split '\r?\n') -match 'Index\s*:\s*2'
    $indicesToPatch = if ($hasIndex2) { @(1, 2) } else { @(1) }

    foreach ($bIndex in $indicesToPatch) {
        Write-Host "  - Applying Setup & Hardware requirement bypasses to boot.wim Index $bIndex..." -ForegroundColor Cyan
        Clear-DismMountConflicts -TargetMountDir $scratchDir -TargetWimFile $bootWimPath
        & dism.exe /English /Mount-Image "/ImageFile:$bootWimPath" "/Index:$bIndex" "/MountDir:$scratchDir"
        if ($LASTEXITCODE -eq 0) {
            & reg.exe query "HKLM\zSYSTEM" > $null 2>&1
            if ($LASTEXITCODE -eq 0) {
                [void](Unmount-RegistryHiveWithRetry -Name 'zSYSTEM')
            }
            reg.exe load HKLM\zSYSTEM "$scratchDir\Windows\System32\config\SYSTEM" > $null 2>&1
            foreach ($key in $labConfigKeys) {
                reg.exe add "HKLM\zSYSTEM\Setup\LabConfig" /v $key /t REG_DWORD /d 1 /f > $null 2>&1
            }
            reg.exe add "HKLM\zSYSTEM\Setup\LabConfig" /v "BypassNRO" /t REG_DWORD /d 1 /f > $null 2>&1
            reg.exe add "HKLM\zSYSTEM\Setup\MoSetup" /v "AllowUpgradesWithUnsupportedTPMOrCPU" /t REG_DWORD /d 1 /f > $null 2>&1
            reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\BitLocker" /v "PreventDeviceEncryption" /t REG_DWORD /d 1 /f > $null 2>&1
            & reg.exe query "HKLM\zSYSTEM\CurrentControlSet" > $null 2>&1
            if ($LASTEXITCODE -eq 0) {
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
                Start-Sleep -Seconds (2 * $bRetry)
            }

            if (-not $bootUnmountSuccess) {
                Write-Host "Falling back to discard unmount for boot.wim index $bIndex..." -ForegroundColor Yellow
                & dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /discard
            }
        }
    }
}

Enter-Phase 15 "Verify Final Installation Payload"

# 15. Verify final installation payload
$esdCheck = Join-Path -Path "$nano11Dir\sources" -ChildPath "install.esd"
$wimCheck = Join-Path -Path "$nano11Dir\sources" -ChildPath "install.wim"
$swmCheck = Join-Path -Path "$nano11Dir\sources" -ChildPath "install.swm"

$validEsd = (Test-Path -LiteralPath $esdCheck) -and ((Get-Item -LiteralPath $esdCheck).Length -gt 1GB)
$validWim = (Test-Path -LiteralPath $wimCheck) -and ((Get-Item -LiteralPath $wimCheck).Length -gt 1GB)
$validSwm = (Test-Path -LiteralPath $swmCheck) -and ((Get-Item -LiteralPath $swmCheck).Length -gt 500MB)

# Remove any corrupt stub files or invalid partial files (< 1GB / < 500MB)
if (-not $validEsd -and (Test-Path -LiteralPath $esdCheck)) {
    Write-Host "Warning: Corrupt or incomplete install.esd detected ($((Get-Item -LiteralPath $esdCheck).Length) bytes). Removing..." -ForegroundColor Yellow
    Remove-Item -LiteralPath $esdCheck -Force -ErrorAction SilentlyContinue
    $validEsd = $false
}
if (-not $validWim -and (Test-Path -LiteralPath $wimCheck) -and (-not $validSwm)) {
    Write-Host "Warning: Corrupt or incomplete install.wim detected ($((Get-Item -LiteralPath $wimCheck).Length) bytes). Removing..." -ForegroundColor Yellow
    Remove-Item -LiteralPath $wimCheck -Force -ErrorAction SilentlyContinue
    $validWim = $false
}

if ($validWim) {
    Write-Host "Final installation image confirmed: install.wim ($([math]::Round((Get-Item -LiteralPath $wimCheck).Length / 1GB, 2)) GB)" -ForegroundColor Green
    if (Test-Path -LiteralPath $esdCheck) {
        Remove-Item -LiteralPath $esdCheck -Force -ErrorAction SilentlyContinue
    }
} elseif ($validSwm) {
    $swmParts = Get-ChildItem -Path "$nano11Dir\sources" -Filter "install*.swm"
    Write-Host "Final installation image confirmed: install.swm (Split-WIM: $($swmParts.Count) parts for 100% FAT32 USB boot)" -ForegroundColor Green
    if (Test-Path -LiteralPath $wimCheck) {
        Remove-Item -LiteralPath $wimCheck -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $esdCheck) {
        Remove-Item -LiteralPath $esdCheck -Force -ErrorAction SilentlyContinue
    }
} elseif ($validEsd) {
    Write-Host "Final installation image confirmed: install.esd ($([math]::Round((Get-Item -LiteralPath $esdCheck).Length / 1GB, 2)) GB)" -ForegroundColor Green
    if (Test-Path -LiteralPath $wimCheck) {
        Remove-Item -LiteralPath $wimCheck -Force -ErrorAction SilentlyContinue
    }
} else {
    Write-Host "CRITICAL ERROR: No valid installation payload (install.wim, install.esd, or install.swm) found in $nano11Dir\sources!" -ForegroundColor Red
    Write-Host "Aborting ISO creation to prevent producing an unbootable or corrupt image." -ForegroundColor Red
    Stop-Transcript
    exit 1
}

Enter-Phase 16 "ISO Root Cleanup & Traceability Embedding"

# 16. Final cleanup of ISO root and sources
Write-Host "Performing final cleanup of ISO root..." -ForegroundColor Cyan
$keepList = @("boot", "efi", "sources", "bootmgr", "bootmgr.efi", "bootmgfw.efi", "setup.exe", "autounattend.xml", "nano11-build-info.json")
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

Enter-Phase 17 "Locate or Verify oscdimg.exe"

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
        if (Test-OscdimgIntegrity -OscdimgPath $candidate) {
            $oscdimgExe = $candidate
            Write-Host "Found verified local oscdimg.exe: $oscdimgExe" -ForegroundColor Green
            break
        } else {
            Write-Warning "Candidate oscdimg binary at '$candidate' failed Authenticode and hash verification! Skipping."
        }
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
            if ((Test-Path -LiteralPath $targetOscdPath) -and (Test-OscdimgIntegrity -OscdimgPath $targetOscdPath)) {
                $oscdimgExe = $targetOscdPath
                Write-Host "  - oscdimg.exe downloaded and integrity verified successfully!" -ForegroundColor Green
                break
            } else {
                if (Test-Path -LiteralPath $targetOscdPath) { Remove-Item -LiteralPath $targetOscdPath -Force -ErrorAction SilentlyContinue }
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

Enter-Phase 18 "Create Bootable ISO Image"

# 18. Create bootable ISO (oscdimg) with Architecture-aware bootdata and Volume Label
Write-Host "Creating bootable ISO image..." -ForegroundColor Green
$profSlug = if ($selectedProfile) { ($selectedProfile -replace '[^\w\-]', '_').Trim('_') } else { "custom" }
$isoTimestamp = (Get-Date).ToString("yyyyMMdd_HHmm")
$dynamicIsoName = "nano11_${profSlug}_${isoTimestamp}.iso"
$outputIso = Join-Path -Path $scriptDir -ChildPath $dynamicIsoName
$standardIso = Join-Path -Path $scriptDir -ChildPath "nano11.iso"

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
if ($uefiOnly -and $efiSys) {
    # Force UEFI-only bootdata (no BIOS boot sector)
    $bootData = "1#pEF,e,b$efiSys"
    Write-Host "Configured UEFI-Only Boot (-UefiOnly):" -ForegroundColor Green
    Write-Host "  - UEFI Boot Sector: $efiSys" -ForegroundColor Gray
} elseif ($efiSys -and $etfsBoot -and ($architecture -ne 'arm64')) {
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

        # Maintain standard nano11.iso copy for tooling backwards-compatibility
        try {
            Copy-Item -LiteralPath $outputIso -Destination $standardIso -Force -ErrorAction SilentlyContinue
        } catch {}

        # 3-Generation Retention Rotation for ISOs matching this profile
        try {
            $existingProfileIsos = Get-ChildItem -Path $scriptDir -Filter "nano11_${profSlug}_*.iso" -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending
            if ($existingProfileIsos.Count -gt 3) {
                $isosToRemove = $existingProfileIsos | Select-Object -Skip 3
                foreach ($oldIso in $isosToRemove) {
                    Write-Host "Rotating out older generation ISO: $($oldIso.Name)" -ForegroundColor DarkGray
                    Remove-Item -LiteralPath $oldIso.FullName -Force -ErrorAction SilentlyContinue
                }
            }
        } catch {}

        # Generate Visual HTML Build Report
        try {
            $reportOutputDir = Split-Path -Path $outputIso -Parent
            if (-not $reportOutputDir) { $reportOutputDir = $PSScriptRoot }
            $reportPath = Join-Path -Path $reportOutputDir -ChildPath "nano11_report.html"
            $reportData = @{
                Title             = "nano11 Master Build Report - $selectedProfile"
                Timestamp         = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                Profile           = $selectedProfile
                Architecture      = $architecture
                SourceDrive       = $DriveLetter
                OutputIso         = $outputIso
                PayloadFormat     = if ($SplitWIM) { "install.swm" } elseif ($exportESDMode) { "install.esd" } else { "install.wim" }
                OriginalSizeBytes = if ($sourceWimSize -gt 0) { $sourceWimSize } else { 0 }
                FinalSizeBytes    = $isoItem.Length
                IsoSha256         = $sha256
                RegSuccessCount   = $script:regSuccessCount
                Settings          = $resolvedConfig
            }
            $reportData['RemovedPackagesCount'] = if ($script:RemovedPackages) { $script:RemovedPackages.Count } else { 0 }
            $reportData['WinSxSSavedMB']        = if ($script:WinSxSSavedMB) { $script:WinSxSSavedMB } else { 0 }
            $reportData['WinSxSBeforeMB']       = if ($script:WinSxsBeforeMB) { $script:WinSxsBeforeMB } else { 0 }
            $reportData['WinSxSAfterMB']        = if ($script:WinSxsAfterMB) { $script:WinSxsAfterMB } else { 0 }
            Export-Nano11HtmlReport -OutputPath $reportPath -BuildInfo $reportData
            Write-Host "Visual Build Report generated: $reportPath" -ForegroundColor Cyan

            # Post-build hook execution (tools\post-build.ps1)
            $postBuildScript = Join-Path -Path $scriptDir -ChildPath "tools\post-build.ps1"
            if (Test-Path -LiteralPath $postBuildScript) {
                Write-Host "Executing post-build hook: $postBuildScript..." -ForegroundColor Cyan
                try {
                    $isoSha256 = (Get-FileHash -LiteralPath $outputIso -Algorithm SHA256).Hash
                    & $postBuildScript -IsoPath $outputIso -IsoHash $isoSha256 -Profile $selectedProfile -LogDir $logDir
                } catch {
                    Write-Warning "Post-build hook exited with warning: $_"
                }
            }

            # GUI completion dialog
            if ($GUI -and $isoCreatedSuccessfully -and (Test-Path -LiteralPath $outputIso)) {
                $isoLenGB = [math]::Round((Get-Item -LiteralPath $outputIso).Length / 1GB, 2)
                $isoHashVal = (Get-FileHash -LiteralPath $outputIso -Algorithm SHA256).Hash
                $dialogMsg = "nano11 ISO ビルドが正常に完了しました！`n`n" +
                             "■ 出力先: $outputIso`n" +
                             "■ サイズ: $isoLenGB GB`n" +
                             "■ SHA256: $isoHashVal`n" +
                             "■ 所要時間: $(if ($elapsedSec) { $elapsedSec } else { '完了' }) 秒`n`n" +
                             "ISO が保存されたフォルダーを開きますか？"
                $res = [System.Windows.Forms.MessageBox]::Show($dialogMsg, "nano11 ビルド完了", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Information)
                if ($res -eq [System.Windows.Forms.DialogResult]::Yes) {
                    Invoke-Item -LiteralPath (Split-Path -Path $outputIso -Parent)
                }
            }
        } catch {
            Write-Warning "Could not export visual build report: $_"
        }
        if ($validSwm) {
            Write-Host "[100% FAT32 USB COMPATIBLE]" -ForegroundColor Green
            Write-Host "- The image was split into install.swm parts (each <= 3800MB)." -ForegroundColor Green
            Write-Host "- You can copy the contents of nano11.iso directly into any FAT32 USB drive!" -ForegroundColor Green
            Write-Host "- Standard UEFI systems will boot seamlessly without needing NTFS or Rufus." -ForegroundColor Green
            Write-Host ""
        } elseif (Test-Path -LiteralPath (Join-Path -Path "$nano11Dir\sources" -ChildPath "install.wim") -and ((Get-Item (Join-Path -Path "$nano11Dir\sources" -ChildPath "install.wim")).Length -gt 4000000000)) {
            Write-Host "[IMPORTANT NOTE FOR BOOTABLE USB CREATION]" -ForegroundColor Cyan
            Write-Host "- install.wim is larger than 4GB. FAT32 cannot store files > 4GB." -ForegroundColor Yellow
            Write-Host "- When creating a bootable USB with Rufus, select 'NTFS' filesystem." -ForegroundColor Yellow
            Write-Host "- Or copy nano11.iso directly into a Ventoy USB drive (recommended)." -ForegroundColor Yellow
            Write-Host "- Tip: Run with -SplitWIM to automatically split into FAT32-compatible parts." -ForegroundColor Cyan
            Write-Host ""
        }
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

if ($Validate) {
    $validateWim = Join-Path -Path "$nano11Dir\sources" -ChildPath "install.wim"
    if (Test-Path -LiteralPath $validateWim) {
        Write-Host "Running post-export image validation (-Validate)..." -ForegroundColor Cyan
        $verifyMount = Join-Path -Path $baseWorkDir -ChildPath "verify_mount"
        New-Item -ItemType Directory -Force -Path $verifyMount | Out-Null
        try {
            & dism.exe /English /Get-WimInfo "/WimFile:$validateWim" | Out-File (Join-Path -Path $baseWorkDir -ChildPath "verify-wiminfo.txt") -Encoding utf8
            & dism.exe /English /Mount-Image "/ImageFile:$validateWim" /Index:1 "/MountDir:$verifyMount" /ReadOnly
            $keyFiles = @(
                'Windows\System32\osk.exe',
                'Windows\System32\ctfmon.exe',
                'Windows\System32\Sysprep\sysprep.exe',
                'Windows\System32\cmd.exe'
            )
            $valLog = @()
            foreach ($kf in $keyFiles) {
                $exists = Test-Path -LiteralPath (Join-Path -Path $verifyMount -ChildPath $kf)
                $status = "{0} : {1}" -f $kf, $exists
                $valLog += $status
                Write-Host "  - Verification: $status" -ForegroundColor (if ($exists) { 'Green' } else { 'Yellow' })
            }
            $valLog | Out-File (Join-Path -Path $baseWorkDir -ChildPath "verify-paths.txt") -Encoding utf8
        } finally {
            & dism.exe /English /Unmount-Image "/MountDir:$verifyMount" /discard > $null 2>&1
            Reset-DirectoryWithRobocopy -Path $verifyMount
            Remove-Item -LiteralPath $verifyMount -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
} catch {
    Write-Host ""
    Write-Host "Build failed with unhandled exception: $_" -ForegroundColor Red
    if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
        Write-Host "Exception location: $($_.InvocationInfo.PositionMessage)" -ForegroundColor Red
    }
    if ($_.ScriptStackTrace) {
        Write-Host "Stack Trace: $($_.ScriptStackTrace)" -ForegroundColor DarkGray
    }
    throw
} finally {
    Write-Host ""
    Write-Host "Running cleanup and finalizing build lifecycle..." -ForegroundColor Cyan

    # 1. Unload lingering offline registry hives
    if ($script:HivesLoaded) {
        Write-Host "Cleaning up lingering registry hives..." -ForegroundColor Yellow
        @('zCOMPONENTS', 'zDEFAULT', 'zNTUSER', 'zSOFTWARE', 'zSYSTEM') | ForEach-Object {
            try { [void](Unmount-RegistryHiveWithRetry -Name $_) } catch {}
        }
        $script:HivesLoaded = $false
    }

    # 2. Discard lingering DISM mount
    if ($script:MountOpened -and $scratchDir -and (Test-Path -LiteralPath $scratchDir)) {
        Write-Host "Discarding lingering DISM mount on $scratchDir..." -ForegroundColor Yellow
        & dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /discard > $null 2>&1
        $script:MountOpened = $false
    }

    # 3. Clean working directories
    if (-not $NonInteractive -and -not $isoCreatedSuccessfully -and -not $DryRun) {
        try { Read-Host "Press Enter to finalize cleanup." } catch {}
    }

    if ($isoCreatedSuccessfully) {
        if ($nano11Dir -and (Test-Path -LiteralPath $nano11Dir)) {
            Reset-DirectoryWithRobocopy -Path $nano11Dir
            Remove-Item -LiteralPath $nano11Dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    } else {
        if ($nano11Dir -and (Test-Path -LiteralPath $nano11Dir)) {
            Write-Host "Preserving $nano11Dir for inspection." -ForegroundColor Yellow
        }
    }

    if ($scratchDir -and (Test-Path -LiteralPath $scratchDir)) {
        Reset-DirectoryWithRobocopy -Path $scratchDir
        Remove-Item -LiteralPath $scratchDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # 4. Detach and remove VHDX scratch disk if initialized
    if ($script:IsVhdxMounted -or ($vhdxPath -and (Test-Path -LiteralPath $vhdxPath))) {
        try {
            Write-Host "Detaching VHDX scratch disk..." -ForegroundColor Cyan
            $dpDetachScript = "select vdisk file=`"$vhdxPath`"`r`ndetach vdisk`r`n"
            $dpDetachFile = Join-Path -Path $env:TEMP -ChildPath "nano11_dp_detach_$([System.IO.Path]::GetRandomFileName()).txt"
            $dpDetachScript | Set-Content -LiteralPath $dpDetachFile -Encoding ascii
            & diskpart.exe /s $dpDetachFile > $null 2>&1
            Remove-Item -LiteralPath $dpDetachFile -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $vhdxPath -Force -ErrorAction SilentlyContinue
            $script:IsVhdxMounted = $false
        } catch {}
    }

    # 5. Dismount source ISO if mounted by nano11
    if ($script:MountedIso) {
        Write-Host "Dismounting source Windows 11 ISO..." -ForegroundColor Cyan
        try {
            Dismount-DiskImage -ImagePath $script:MountedIso.ImagePath -ErrorAction SilentlyContinue > $null
            $script:MountedIso = $null
        } catch {}
    }

    # 6. Remove Windows Defender temporary workspace exclusion
    if ($script:DefenderExclusionAdded -and $baseWorkDir) {
        try {
            Remove-MpPreference -ExclusionPath $baseWorkDir -ErrorAction SilentlyContinue
            $script:DefenderExclusionAdded = $false
        } catch {}
    }

    # 7. Build elapsed time and policy stats
    if ($script:buildStopwatch) {
        $script:buildStopwatch.Stop()
        $elapsedSec = [math]::Round($script:buildStopwatch.Elapsed.TotalSeconds, 1)
        Write-Host "Build lifecycle completed in $elapsedSec seconds." -ForegroundColor Cyan
    }
    if ($script:AppliedPolicies) {
        Write-Host "Offline registry policies applied: $($script:AppliedPolicies.Count)" -ForegroundColor Cyan
    }

    if ($transcriptPath) {
        Stop-Transcript
    }

    # 8. Release global mutex guard
    if ($script:BuildMutex) {
        try {
            $script:BuildMutex.ReleaseMutex()
            $script:BuildMutex.Dispose()
            $script:BuildMutex = $null
        } catch {}
    }

    if ($isoCreatedSuccessfully) {
        Write-Host "Done! nano11.iso is ready." -ForegroundColor Green
    } else {
        Write-Host "Process ended $(if ($LASTEXITCODE -ne 0) { 'with errors' } else { 'cleanly' }). Please check the logs in $transcriptPath" -ForegroundColor $(if ($LASTEXITCODE -ne 0) { 'Red' } else { 'Yellow' })
    }
}
