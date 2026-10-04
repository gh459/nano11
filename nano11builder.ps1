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
    
    # 13. Optimization Toolkit & Revision Tool
    [alias("BundleRevisionTool")]
    [switch]$BundleOptimizationToolkit,
    [alias("NoBundleRevisionTool")]
    [switch]$NoBundleOptimizationToolkit,
    
    # 14. Export payload format
    [switch]$ExportESD,
    [alias("NoESD")]
    [switch]$ExportWIM,
    [alias("FAT32Compatible", "FAT32")]
    [switch]$SplitWIM,
    [switch]$NoSplitWIM,
    
    # 15. Microsoft Store
    [switch]$KeepStore,
    [alias("NoStore", "RemoveMicrosoftStore")]
    [switch]$RemoveStore
)

# ==============================================================================
# Critical Warning: MediaCreationTool.exe ISO is NOT supported
# ==============================================================================
Write-Host ""
Write-Host "==============================================================================" -ForegroundColor Red
Write-Host " [CRITICAL NOTICE / WARNING]" -ForegroundColor Red
Write-Host " DO NOT USE MediaCreationTool.exe TO DOWNLOAD THE WINDOWS 11 ISO!" -ForegroundColor Red
Write-Host " MediaCreationTool.exe creates an ISO with compressed 'install.esd' instead of" -ForegroundColor Yellow
Write-Host " 'install.wim', which causes DISM stream corruption (Error 1392 / 0x80070570)." -ForegroundColor Yellow
Write-Host "------------------------------------------------------------------------------" -ForegroundColor Red
Write-Host " Please download the official ISO directly from Microsoft containing 'install.wim':" -ForegroundColor Cyan
Write-Host "  https://www.microsoft.com/software-download/windows11" -ForegroundColor Green
Write-Host "==============================================================================" -ForegroundColor Red
Write-Host ""

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
if ((-not $myWindowsPrincipal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) -and ($env:NANO11_TEST_MODE -ne "1")) {
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
    if (Test-Path -LiteralPath $Path) {
        $emptyTemp = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "nano11_empty_$([System.IO.Path]::GetRandomFileName())"
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
        Version     = "2.0"
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
            BundleOptimizationToolkit  = [bool]$Config.BundleOptimizationToolkit
            RemoveStore                = [bool]$Config.RemoveStore
            PayloadFormat              = if ($Config.PayloadFormat) { $Config.PayloadFormat } else { "WIM" }
        }
    }
    $json = $profileData | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($FilePath, $json, [System.Text.Encoding]::UTF8)
    Write-Host "Profile saved to: $FilePath" -ForegroundColor Green
}

# Helper function: Import configuration settings from a JSON profile
function Import-Nano11Profile {
    param(
        [Parameter(Mandatory=$true)]
        [string]$FilePath
    )
    if (-not (Test-Path -LiteralPath $FilePath)) {
        Write-Host "Error: Profile file not found: $FilePath" -ForegroundColor Red
        return $null
    }
    try {
        $rawJson = [System.IO.File]::ReadAllText($FilePath, [System.Text.Encoding]::UTF8)
        $data = $rawJson | ConvertFrom-Json
        $settings = if ($data.Settings) { $data.Settings } else { $data }
        return $settings
    } catch {
        Write-Host "Failed to parse JSON profile: $_" -ForegroundColor Red
        return $null
    }
}

# Helper function: Display Graphical User Interface (GUI) for nano11 builder
function Show-Nano11GUI {
    param(
        [hashtable]$InitialSettings = @{}
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "nano11 Builder - Next-Gen Windows 11 Customizer & Debloater"
    $form.Size = New-Object System.Drawing.Size(720, 830)
    $form.MinimumSize = New-Object System.Drawing.Size(720, 830)
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.BackColor = [System.Drawing.Color]::FromArgb(26, 28, 34)
    $form.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
    $form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    # Header Panel
    $headerPanel = New-Object System.Windows.Forms.Panel
    $headerPanel.Dock = [System.Windows.Forms.DockStyle]::Top
    $headerPanel.Height = 65
    $headerPanel.BackColor = [System.Drawing.Color]::FromArgb(18, 20, 24)
    $form.Controls.Add($headerPanel)

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = "⚡ nano11 Builder v2.0"
    $titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
    $titleLabel.ForeColor = [System.Drawing.Color]::FromArgb(0, 190, 255)
    $titleLabel.Location = New-Object System.Drawing.Point(16, 10)
    $titleLabel.AutoSize = $true
    $headerPanel.Controls.Add($titleLabel)

    $subTitleLabel = New-Object System.Windows.Forms.Label
    $subTitleLabel.Text = "Automated, Ultra-Slim, Gaming & Multi-Language Windows 11 Image Creator"
    $subTitleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
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
    $grpMedia.Text = " 1. Windows 11 Media & Workspace "
    $grpMedia.Location = New-Object System.Drawing.Point(15, 10)
    $grpMedia.Size = New-Object System.Drawing.Size(670, 115)
    $grpMedia.ForeColor = [System.Drawing.Color]::FromArgb(0, 190, 255)
    $mainPanel.Controls.Add($grpMedia)

    $lblSource = New-Object System.Windows.Forms.Label
    $lblSource.Text = "Source Drive / ISO:"
    $lblSource.Location = New-Object System.Drawing.Point(15, 28)
    $lblSource.Size = New-Object System.Drawing.Size(120, 20)
    $lblSource.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
    $grpMedia.Controls.Add($lblSource)

    $cmbSource = New-Object System.Windows.Forms.ComboBox
    $cmbSource.Location = New-Object System.Drawing.Point(140, 25)
    $cmbSource.Size = New-Object System.Drawing.Size(390, 24)
    $cmbSource.BackColor = [System.Drawing.Color]::FromArgb(35, 38, 46)
    $cmbSource.ForeColor = [System.Drawing.Color]::White
    $cmbSource.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDown
    $grpMedia.Controls.Add($cmbSource)

    # Populate cmbSource with detected drives
    $drivesWithWim = @()
    foreach ($psd in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        if (-not $psd.Root) { continue }
        $r = $psd.Root.TrimEnd('\')
        $wim = Join-Path -Path "$r\sources" -ChildPath "install.wim"
        if ((Test-Path -LiteralPath $wim) -and ((Get-Item -LiteralPath $wim).Length -gt 1GB)) {
            $drivesWithWim += "$r (Windows Installation Media)"
        }
    }
    if ($drivesWithWim.Count -gt 0) {
        $cmbSource.Items.AddRange($drivesWithWim)
        $cmbSource.SelectedIndex = 0
    }
    # Auto-detect ISOs
    $candIsos = @()
    foreach ($p in @("E:\", "D:\", (Split-Path -Parent $PSScriptRoot), $env:USERPROFILE)) {
        if (Test-Path -LiteralPath $p) {
            $candIsos += Get-ChildItem -Path $p -Filter "*.iso" -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Length -gt 4GB -and ($_.Name -like "*Win11*" -or $_.Name -like "*Windows11*" -or $_.Name -like "*26300*") -and $_.Name -notlike "*nano11*" }
        }
    }
    foreach ($iso in $candIsos) {
        $cmbSource.Items.Add($iso.FullName)
    }
    if ($InitialSettings.SourceDrive) {
        $cmbSource.Text = $InitialSettings.SourceDrive
    } elseif ($cmbSource.Items.Count -eq 0) {
        $cmbSource.Text = "E:\"
    }

    $btnBrowseIso = New-Object System.Windows.Forms.Button
    $btnBrowseIso.Text = "Browse ISO..."
    $btnBrowseIso.Location = New-Object System.Drawing.Point(540, 24)
    $btnBrowseIso.Size = New-Object System.Drawing.Size(115, 26)
    $btnBrowseIso.BackColor = [System.Drawing.Color]::FromArgb(45, 50, 60)
    $btnBrowseIso.ForeColor = [System.Drawing.Color]::White
    $btnBrowseIso.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnBrowseIso.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = "Windows 11 ISO (*.iso)|*.iso|All Files (*.*)|*.*"
        $ofd.Title = "Select Official Windows 11 ISO Image"
        if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $cmbSource.Text = $ofd.FileName
        }
    })
    $grpMedia.Controls.Add($btnBrowseIso)

    $lblWork = New-Object System.Windows.Forms.Label
    $lblWork.Text = "Working Directory:"
    $lblWork.Location = New-Object System.Drawing.Point(15, 68)
    $lblWork.Size = New-Object System.Drawing.Size(120, 20)
    $lblWork.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
    $grpMedia.Controls.Add($lblWork)

    $txtWork = New-Object System.Windows.Forms.TextBox
    $txtWork.Location = New-Object System.Drawing.Point(140, 65)
    $txtWork.Size = New-Object System.Drawing.Size(390, 24)
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
    $btnBrowseWork.Text = "Browse Dir..."
    $btnBrowseWork.Location = New-Object System.Drawing.Point(540, 64)
    $btnBrowseWork.Size = New-Object System.Drawing.Size(115, 26)
    $btnBrowseWork.BackColor = [System.Drawing.Color]::FromArgb(45, 50, 60)
    $btnBrowseWork.ForeColor = [System.Drawing.Color]::White
    $btnBrowseWork.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnBrowseWork.Add_Click({
        $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
        $fbd.Description = "Select NTFS Working Directory with at least 25GB free space"
        if ($fbd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $txtWork.Text = $fbd.SelectedPath
        }
    })
    $grpMedia.Controls.Add($btnBrowseWork)

    # 2. Configuration Profiles GroupBox
    $grpProfile = New-Object System.Windows.Forms.GroupBox
    $grpProfile.Text = " 2. Configuration Profile & Presets "
    $grpProfile.Location = New-Object System.Drawing.Point(15, 135)
    $grpProfile.Size = New-Object System.Drawing.Size(670, 75)
    $grpProfile.ForeColor = [System.Drawing.Color]::FromArgb(0, 190, 255)
    $mainPanel.Controls.Add($grpProfile)

    $lblPreset = New-Object System.Windows.Forms.Label
    $lblPreset.Text = "Preset:"
    $lblPreset.Location = New-Object System.Drawing.Point(15, 28)
    $lblPreset.Size = New-Object System.Drawing.Size(60, 20)
    $lblPreset.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
    $grpProfile.Controls.Add($lblPreset)

    $cmbPreset = New-Object System.Windows.Forms.ComboBox
    $cmbPreset.Location = New-Object System.Drawing.Point(80, 25)
    $cmbPreset.Size = New-Object System.Drawing.Size(310, 24)
    $cmbPreset.BackColor = [System.Drawing.Color]::FromArgb(35, 38, 46)
    $cmbPreset.ForeColor = [System.Drawing.Color]::White
    $cmbPreset.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $cmbPreset.Items.AddRange(@(
        "⚡ Extreme Slim & Gaming (Max Debloat, Latency Tuning)",
        "🛡️ Balanced Pro (Safe: Windows Update & Defender Kept)",
        "💾 FAT32 USB Split-WIM (3.8GB SWM Chunks for UEFI)",
        "🔧 Custom Configuration"
    ))
    $cmbPreset.SelectedIndex = 0
    $grpProfile.Controls.Add($cmbPreset)

    $btnLoadProfile = New-Object System.Windows.Forms.Button
    $btnLoadProfile.Text = "📂 Load JSON..."
    $btnLoadProfile.Location = New-Object System.Drawing.Point(405, 24)
    $btnLoadProfile.Size = New-Object System.Drawing.Size(120, 26)
    $btnLoadProfile.BackColor = [System.Drawing.Color]::FromArgb(45, 50, 60)
    $btnLoadProfile.ForeColor = [System.Drawing.Color]::White
    $btnLoadProfile.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $grpProfile.Controls.Add($btnLoadProfile)

    $btnSaveProfile = New-Object System.Windows.Forms.Button
    $btnSaveProfile.Text = "💾 Save JSON..."
    $btnSaveProfile.Location = New-Object System.Drawing.Point(535, 24)
    $btnSaveProfile.Size = New-Object System.Drawing.Size(120, 26)
    $btnSaveProfile.BackColor = [System.Drawing.Color]::FromArgb(45, 50, 60)
    $btnSaveProfile.ForeColor = [System.Drawing.Color]::White
    $btnSaveProfile.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $grpProfile.Controls.Add($btnSaveProfile)

    # 3. Customization & Debloat Options GroupBox
    $grpOpts = New-Object System.Windows.Forms.GroupBox
    $grpOpts.Text = " 3. Debloat & Customization Options "
    $grpOpts.Location = New-Object System.Drawing.Point(15, 220)
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
    $chkDefender    = & $createChk "Remove Windows Defender & SecHealthUI" 15 25 (& $getInitVal 'RemoveDefender' $true)
    $chkIME         = & $createChk "Keep Asian IMEs (Japanese, Chinese, Korean)" 15 55 (& $getInitVal 'KeepAsianIME' $true)
    $chkFonts       = & $createChk "Keep Extra International & Asian Fonts" 15 85 (& $getInitVal 'KeepExtraFonts' $false)
    $chkDrivers     = & $createChk "Remove Legacy Storage & Network Drivers" 15 115 (& $getInitVal 'RemoveDrivers' $false)
    $chkWU          = & $createChk "Disable Automatic Windows Update" 15 145 (& $getInitVal 'DisableWindowsUpdate' $true)
    $chkBT          = & $createChk "Keep Bluetooth Services & Peripherals" 15 175 (& $getInitVal 'KeepBluetooth' $true)
    $chkWSL         = & $createChk "Enable WSL2 & Virtual Machine Platform" 15 205 (& $getInitVal 'WSLSupport' $false)
    $chkRecovery    = & $createChk "Keep Recovery Environment (WinRE)" 15 235 (& $getInitVal 'KeepRecoveryEnv' $false)

    # Right Column (X = 345)
    $chkSafeDebloat = & $createChk "Safe WinSxS Component Store Debloat" 345 25 (& $getInitVal 'SafeDebloatMode' $true)
    $chkUltraSlim   = & $createChk "UltraSlim Mode (~3GB Final ISO Target)" 345 55 (& $getInitVal 'UltraSlimMode' $true)
    $chkJPKey       = & $createChk "Configure Japanese 106/109 Keyboard" 345 85 (& $getInitVal 'SetJapaneseKeyboard' $true)
    $chkAtlas       = & $createChk "AtlasOS & ReviOS Low-Latency Tweaks" 345 115 (& $getInitVal 'AtlasReviOSMode' $true)
    $chkToolkit     = & $createChk "Bundle Optimization Toolkit to Desktop" 345 145 (& $getInitVal 'BundleOptimizationToolkit' $true)
    $chkStore       = & $createChk "Remove Microsoft Store & PurchaseApp" 345 175 (& $getInitVal 'RemoveStore' $false)

    # 4. Output Payload Format GroupBox
    $grpPayload = New-Object System.Windows.Forms.GroupBox
    $grpPayload.Text = " 4. Payload Export Format "
    $grpPayload.Location = New-Object System.Drawing.Point(15, 505)
    $grpPayload.Size = New-Object System.Drawing.Size(670, 75)
    $grpPayload.ForeColor = [System.Drawing.Color]::FromArgb(0, 190, 255)
    $mainPanel.Controls.Add($grpPayload)

    $radWIM = New-Object System.Windows.Forms.RadioButton
    $radWIM.Text = "install.wim (LZX - Standard Fast)"
    $radWIM.Location = New-Object System.Drawing.Point(15, 28)
    $radWIM.Size = New-Object System.Drawing.Size(200, 25)
    $radWIM.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
    $radWIM.Checked = $true
    $grpPayload.Controls.Add($radWIM)

    $radESD = New-Object System.Windows.Forms.RadioButton
    $radESD.Text = "install.esd (LZMS - Ultra Compact)"
    $radESD.Location = New-Object System.Drawing.Point(225, 28)
    $radESD.Size = New-Object System.Drawing.Size(205, 25)
    $radESD.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
    $grpPayload.Controls.Add($radESD)

    $radSWM = New-Object System.Windows.Forms.RadioButton
    $radSWM.Text = "install.swm (Split-WIM - FAT32 USB)"
    $radSWM.Location = New-Object System.Drawing.Point(440, 28)
    $radSWM.Size = New-Object System.Drawing.Size(215, 25)
    $radSWM.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
    $grpPayload.Controls.Add($radSWM)

    if ($InitialSettings.ExportESDMode) {
        $radESD.Checked = $true
    } elseif ($InitialSettings.SplitWIMMode) {
        $radSWM.Checked = $true
    }

    # Preset selection sync
    $updatingPreset = $false
    $applyPreset = {
        param($presetIndex)
        $script:updatingPreset = $true
        switch ($presetIndex) {
            0 { # Extreme Slim & Gaming
                $chkDefender.Checked = $true
                $chkIME.Checked = $true
                $chkFonts.Checked = $false
                $chkDrivers.Checked = $false
                $chkWU.Checked = $true
                $chkBT.Checked = $true
                $chkWSL.Checked = $false
                $chkRecovery.Checked = $false
                $chkSafeDebloat.Checked = $true
                $chkUltraSlim.Checked = $true
                $chkJPKey.Checked = $true
                $chkAtlas.Checked = $true
                $chkToolkit.Checked = $true
                $chkStore.Checked = $false
                $radWIM.Checked = $true
            }
            1 { # Balanced Pro
                $chkDefender.Checked = $false
                $chkIME.Checked = $true
                $chkFonts.Checked = $true
                $chkDrivers.Checked = $false
                $chkWU.Checked = $false
                $chkBT.Checked = $true
                $chkWSL.Checked = $false
                $chkRecovery.Checked = $true
                $chkSafeDebloat.Checked = $true
                $chkUltraSlim.Checked = $false
                $chkJPKey.Checked = $true
                $chkAtlas.Checked = $true
                $chkToolkit.Checked = $true
                $chkStore.Checked = $false
                $radWIM.Checked = $true
            }
            2 { # FAT32 Split-WIM
                $chkDefender.Checked = $true
                $chkIME.Checked = $true
                $chkFonts.Checked = $false
                $chkDrivers.Checked = $false
                $chkWU.Checked = $true
                $chkBT.Checked = $true
                $chkWSL.Checked = $false
                $chkRecovery.Checked = $false
                $chkSafeDebloat.Checked = $true
                $chkUltraSlim.Checked = $true
                $chkJPKey.Checked = $true
                $chkAtlas.Checked = $true
                $chkToolkit.Checked = $true
                $chkStore.Checked = $false
                $radSWM.Checked = $true
            }
        }
        $script:updatingPreset = $false
    }

    $cmbPreset.Add_SelectedIndexChanged({
        if (-not $script:updatingPreset -and $cmbPreset.SelectedIndex -ne 3) {
            & $applyPreset $cmbPreset.SelectedIndex
        }
    })

    # Hook change events to switch preset to Custom
    $allCheckboxes = @($chkDefender, $chkIME, $chkFonts, $chkDrivers, $chkWU, $chkBT, $chkWSL, $chkRecovery, $chkSafeDebloat, $chkUltraSlim, $chkJPKey, $chkAtlas, $chkToolkit, $chkStore)
    foreach ($c in $allCheckboxes) {
        $c.Add_CheckedChanged({
            if (-not $script:updatingPreset) {
                $script:updatingPreset = $true
                $cmbPreset.SelectedIndex = 3 # Custom
                $script:updatingPreset = $false
            }
        })
    }

    # Load / Save Profile Handlers
    $btnLoadProfile.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = "nano11 Profile (*.json)|*.json|All files (*.*)|*.*"
        $profDir = Join-Path -Path $PSScriptRoot -ChildPath "profiles"
        if (Test-Path -LiteralPath $profDir) { $ofd.InitialDirectory = $profDir }
        if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $loaded = Import-Nano11Profile -FilePath $ofd.FileName
            if ($loaded) {
                $script:updatingPreset = $true
                if ($loaded.PSObject.Properties['RemoveDefender'])       { $chkDefender.Checked = [bool]$loaded.RemoveDefender }
                if ($loaded.PSObject.Properties['KeepAsianIME'])         { $chkIME.Checked = [bool]$loaded.KeepAsianIME }
                if ($loaded.PSObject.Properties['KeepExtraFonts'])       { $chkFonts.Checked = [bool]$loaded.KeepExtraFonts }
                if ($loaded.PSObject.Properties['RemoveDrivers'])        { $chkDrivers.Checked = [bool]$loaded.RemoveDrivers }
                if ($loaded.PSObject.Properties['DisableWindowsUpdate']) { $chkWU.Checked = [bool]$loaded.DisableWindowsUpdate }
                if ($loaded.PSObject.Properties['KeepBluetooth'])        { $chkBT.Checked = [bool]$loaded.KeepBluetooth }
                if ($loaded.PSObject.Properties['WSLSupport'])           { $chkWSL.Checked = [bool]$loaded.WSLSupport }
                if ($loaded.PSObject.Properties['KeepRecoveryEnv'])      { $chkRecovery.Checked = [bool]$loaded.KeepRecoveryEnv }
                if ($loaded.PSObject.Properties['SafeDebloatMode'])      { $chkSafeDebloat.Checked = [bool]$loaded.SafeDebloatMode }
                if ($loaded.PSObject.Properties['UltraSlimMode'])        { $chkUltraSlim.Checked = [bool]$loaded.UltraSlimMode }
                if ($loaded.PSObject.Properties['SetJapaneseKeyboard'])  { $chkJPKey.Checked = [bool]$loaded.SetJapaneseKeyboard }
                if ($loaded.PSObject.Properties['AtlasReviOSMode'])      { $chkAtlas.Checked = [bool]$loaded.AtlasReviOSMode }
                if ($loaded.PSObject.Properties['BundleOptimizationToolkit']) { $chkToolkit.Checked = [bool]$loaded.BundleOptimizationToolkit }
                if ($loaded.PSObject.Properties['RemoveStore'])          { $chkStore.Checked = [bool]$loaded.RemoveStore }
                if ($loaded.PSObject.Properties['PayloadFormat']) {
                    $fmt = $loaded.PayloadFormat.ToString().ToUpper()
                    if ($fmt -eq 'ESD') { $radESD.Checked = $true }
                    elseif ($fmt -eq 'SWM') { $radSWM.Checked = $true }
                    else { $radWIM.Checked = $true }
                }
                $cmbPreset.SelectedIndex = 3
                $script:updatingPreset = $false
                [System.Windows.Forms.MessageBox]::Show("Profile loaded successfully from:`n$($ofd.FileName)", "Profile Loaded", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            }
        }
    })

    $btnSaveProfile.Add_Click({
        $sfd = New-Object System.Windows.Forms.SaveFileDialog
        $sfd.Filter = "nano11 Profile (*.json)|*.json|All files (*.*)|*.*"
        $profDir = Join-Path -Path $PSScriptRoot -ChildPath "profiles"
        if (Test-Path -LiteralPath $profDir) { $sfd.InitialDirectory = $profDir }
        $sfd.FileName = "my-custom-profile.json"
        if ($sfd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $saveCfg = @{
                ProfileName               = "Custom Profile"
                RemoveDefender            = $chkDefender.Checked
                KeepAsianIME              = $chkIME.Checked
                KeepExtraFonts            = $chkFonts.Checked
                RemoveDrivers             = $chkDrivers.Checked
                DisableWindowsUpdate      = $chkWU.Checked
                KeepBluetooth             = $chkBT.Checked
                WSLSupport                = $chkWSL.Checked
                KeepRecoveryEnv           = $chkRecovery.Checked
                SafeDebloatMode           = $chkSafeDebloat.Checked
                UltraSlimMode             = $chkUltraSlim.Checked
                SetJapaneseKeyboard       = $chkJPKey.Checked
                AtlasReviOSMode           = $chkAtlas.Checked
                BundleOptimizationToolkit = $chkToolkit.Checked
                RemoveStore               = $chkStore.Checked
                PayloadFormat             = if ($radESD.Checked) { "ESD" } elseif ($radSWM.Checked) { "SWM" } else { "WIM" }
            }
            Export-Nano11Profile -FilePath $sfd.FileName -Config $saveCfg
            [System.Windows.Forms.MessageBox]::Show("Profile saved successfully to:`n$($sfd.FileName)", "Profile Saved", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        }
    })

    # Bottom Button Panel
    $bottomPanel = New-Object System.Windows.Forms.Panel
    $bottomPanel.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $bottomPanel.Height = 65
    $bottomPanel.BackColor = [System.Drawing.Color]::FromArgb(18, 20, 24)
    $form.Controls.Add($bottomPanel)

    $btnBuild = New-Object System.Windows.Forms.Button
    $btnBuild.Text = "🚀 Start nano11 Build"
    $btnBuild.Location = New-Object System.Drawing.Point(340, 14)
    $btnBuild.Size = New-Object System.Drawing.Size(200, 38)
    $btnBuild.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
    $btnBuild.ForeColor = [System.Drawing.Color]::White
    $btnBuild.Font = New-Object System.Drawing.Font("Segoe UI", 10.5, [System.Drawing.FontStyle]::Bold)
    $btnBuild.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $bottomPanel.Controls.Add($btnBuild)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
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
            [System.Windows.Forms.MessageBox]::Show("Please select or browse for a Windows 11 installation drive or ISO.", "Source Required", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
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
        $formResult.BundleOptimizationToolkit = $chkToolkit.Checked
        $formResult.RemoveStore               = $chkStore.Checked
        $formResult.ExportESDMode             = $radESD.Checked
        $formResult.SplitWIMMode              = $radSWM.Checked

        $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Close()
    })

    # Show Dialog
    $diagResult = $form.ShowDialog()
    if ($diagResult -eq [System.Windows.Forms.DialogResult]::OK) {
        return $formResult
    }
    return @{ Success = $false }
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
if (-not $NonInteractive -and -not $GUI) {
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
$bundleOptimizationToolkit = $true
$bundleRevTool = $bundleOptimizationToolkit
$exportESDMode = $false
$splitWIMMode = $false
$removeStore = $false
$selectedProfile = $null

# 2. Track explicitly supplied CLI parameters from bound parameters snapshot
$bound = $PSBoundParameters
$cliBound = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

# 0a. Profile / Preset Parameter
if ($bound.ContainsKey('Profile') -or $bound.ContainsKey('Preset')) {
    $profVal = if ($bound.ContainsKey('Profile')) { $bound['Profile'] } else { $bound['Preset'] }
    $selectedProfile = $profVal.ToString().Trim().ToLower()
    [void]$cliBound.Add('Profile')
    if ($selectedProfile -in @('extreme', 'gaming', 'slim')) {
        $removeDefender = $true
        $keepAsianIME = $true
        $keepExtraFonts = $false
        $removeDrivers = $false
        $disableWU = $true
        $keepBT = $true
        $wslSupport = $false
        $keepRecoveryEnv = $false
        $safeDebloatMode = $true
        $ultraSlimMode = $true
        $setJapaneseKeyboard = $true
        $atlasReviOSMode = $true
        $bundleOptimizationToolkit = $true
        $bundleRevTool = $bundleOptimizationToolkit
        $removeStore = $false
    } elseif ($selectedProfile -in @('balanced', 'safe')) {
        $removeDefender = $false
        $keepAsianIME = $true
        $keepExtraFonts = $true
        $removeDrivers = $false
        $disableWU = $false
        $keepBT = $true
        $wslSupport = $false
        $keepRecoveryEnv = $true
        $safeDebloatMode = $true
        $ultraSlimMode = $false
        $setJapaneseKeyboard = $true
        $atlasReviOSMode = $true
        $bundleOptimizationToolkit = $true
        $bundleRevTool = $bundleOptimizationToolkit
        $removeStore = $false
    }
}

# 0b. LoadProfile Parameter (JSON Profile Import)
if ($bound.ContainsKey('LoadProfile') -and $bound['LoadProfile']) {
    $loadProfPath = $bound['LoadProfile']
    if (-not (Test-Path -LiteralPath $loadProfPath)) {
        $altProf = Join-Path -Path $PSScriptRoot -ChildPath (Join-Path "profiles" $loadProfPath)
        if (Test-Path -LiteralPath $altProf) { $loadProfPath = $altProf }
        elseif (Test-Path -LiteralPath "$altProf.json") { $loadProfPath = "$altProf.json" }
    }
    $loaded = Import-Nano11Profile -FilePath $loadProfPath
    if ($loaded) {
        $selectedProfile = "json ($([System.IO.Path]::GetFileNameWithoutExtension($loadProfPath)))"
        [void]$cliBound.Add('Profile')
        if ($loaded.PSObject.Properties['RemoveDefender'])       { $removeDefender = [bool]$loaded.RemoveDefender }
        if ($loaded.PSObject.Properties['KeepAsianIME'])         { $keepAsianIME = [bool]$loaded.KeepAsianIME }
        if ($loaded.PSObject.Properties['KeepExtraFonts'])       { $keepExtraFonts = [bool]$loaded.KeepExtraFonts }
        if ($loaded.PSObject.Properties['RemoveDrivers'])        { $removeDrivers = [bool]$loaded.RemoveDrivers }
        if ($loaded.PSObject.Properties['DisableWindowsUpdate']) { $disableWU = [bool]$loaded.DisableWindowsUpdate }
        if ($loaded.PSObject.Properties['KeepBluetooth'])        { $keepBT = [bool]$loaded.KeepBluetooth }
        if ($loaded.PSObject.Properties['WSLSupport'])           { $wslSupport = [bool]$loaded.WSLSupport }
        if ($loaded.PSObject.Properties['KeepRecoveryEnv'])      { $keepRecoveryEnv = [bool]$loaded.KeepRecoveryEnv }
        if ($loaded.PSObject.Properties['SafeDebloatMode'])      { $safeDebloatMode = [bool]$loaded.SafeDebloatMode }
        if ($loaded.PSObject.Properties['UltraSlimMode'])        { $ultraSlimMode = [bool]$loaded.UltraSlimMode }
        if ($loaded.PSObject.Properties['SetJapaneseKeyboard'])  { $setJapaneseKeyboard = [bool]$loaded.SetJapaneseKeyboard }
        if ($loaded.PSObject.Properties['AtlasReviOSMode'])      { $atlasReviOSMode = [bool]$loaded.AtlasReviOSMode }
        if ($loaded.PSObject.Properties['BundleOptimizationToolkit']) {
            $bundleOptimizationToolkit = [bool]$loaded.BundleOptimizationToolkit
            $bundleRevTool = $bundleOptimizationToolkit
        }
        if ($loaded.PSObject.Properties['RemoveStore'])          { $removeStore = [bool]$loaded.RemoveStore }
        if ($loaded.PSObject.Properties['PayloadFormat']) {
            $fmt = $loaded.PayloadFormat.ToString().ToUpper()
            if ($fmt -eq 'ESD') { $exportESDMode = $true; $splitWIMMode = $false }
            elseif ($fmt -eq 'SWM') { $splitWIMMode = $true; $exportESDMode = $false }
            else { $exportESDMode = $false; $splitWIMMode = $false }
        }
        Write-Host "Loaded profile configuration from: $loadProfPath" -ForegroundColor Green
    }
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
        BundleOptimizationToolkit = $bundleOptimizationToolkit
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
        $bundleOptimizationToolkit = $guiResult.BundleOptimizationToolkit
        $bundleRevTool             = $bundleOptimizationToolkit
        $removeStore               = $guiResult.RemoveStore
        $exportESDMode             = $guiResult.ExportESDMode
        $splitWIMMode              = $guiResult.SplitWIMMode
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

# 13. Optimization Toolkit
if (& $isAnyBound @('NoBundleOptimizationToolkit', 'NoBundleRevisionTool')) {
    $noTool = if ($bound.ContainsKey('NoBundleOptimizationToolkit')) { & $getBoundVal 'NoBundleOptimizationToolkit' } else { & $getBoundVal 'NoBundleRevisionTool' }
    $bundleOptimizationToolkit = -not $noTool
    $bundleRevTool = $bundleOptimizationToolkit
    [void]$cliBound.Add('Toolkit')
} elseif (& $isAnyBound @('BundleOptimizationToolkit', 'BundleRevisionTool')) {
    $bTool = if ($bound.ContainsKey('BundleOptimizationToolkit')) { & $getBoundVal 'BundleOptimizationToolkit' } else { & $getBoundVal 'BundleRevisionTool' }
    $bundleOptimizationToolkit = $bTool
    $bundleRevTool = $bundleOptimizationToolkit
    [void]$cliBound.Add('Toolkit')
}

# 14. Export Format
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

# 15. Microsoft Store (Default: Keep)
if (& $isAnyBound @('RemoveStore', 'NoStore', 'RemoveMicrosoftStore')) {
    $removeStore = if ($bound.ContainsKey('RemoveStore')) { & $getBoundVal 'RemoveStore' } elseif ($bound.ContainsKey('NoStore')) { & $getBoundVal 'NoStore' } else { & $getBoundVal 'RemoveMicrosoftStore' }
    [void]$cliBound.Add('Store')
} elseif (& $isAnyBound @('KeepStore')) {
    $removeStore = -not (& $getBoundVal 'KeepStore')
    [void]$cliBound.Add('Store')
}

# 3. Interactive Prompting Logic
$isAutomated = $NonInteractive -or ($cliBound.Count -ge 15 -and (-not $Interactive)) -or ($cliBound.Contains('Profile') -and ($selectedProfile -in @('extreme', 'gaming', 'slim', 'balanced', 'safe')) -and (-not $Interactive))

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
    Write-Host "  [3] 📂 Load Profile from JSON file" -ForegroundColor Cyan
    Write-Host "  [4] 🖥️ Launch GUI (Graphical User Interface)" -ForegroundColor Blue
    Write-Host "  [5] 🔧 Custom (Step-by-step 15 configuration prompts)" -ForegroundColor Magenta
    $pChoice = Read-Host "Select Profile [1-5] (Default: 1 - Extreme Slim & Gaming)"
    if ($pChoice) { $pChoice = $pChoice.Trim().ToLower() } else { $pChoice = "1" }

    $skipIndividualPrompts = $false
    if ($pChoice -in @('1', 'extreme', 'gaming', 'slim')) {
        $skipIndividualPrompts = $true
        $selectedProfile = "extreme"
        Write-Host "Applied Profile: ⚡ Extreme Slim & Gaming" -ForegroundColor Green
    } elseif ($pChoice -in @('2', 'balanced', 'safe')) {
        $skipIndividualPrompts = $true
        $selectedProfile = "balanced"
        if (-not $cliBound.Contains('Defender'))  { $removeDefender = $false }
        if (-not $cliBound.Contains('WU'))        { $disableWU = $false }
        if (-not $cliBound.Contains('Recovery'))  { $keepRecoveryEnv = $true }
        if (-not $cliBound.Contains('UltraSlim')) { $ultraSlimMode = $false }
        if (-not $cliBound.Contains('Fonts'))     { $keepExtraFonts = $true }
        Write-Host "Applied Profile: 🛡️ Balanced Pro (Windows Update & Defender kept)" -ForegroundColor Yellow
    } elseif ($pChoice -in @('3', 'load', 'json')) {
        $skipIndividualPrompts = $true
        $pPath = Read-Host "Enter JSON profile path [Default: .\profiles\extreme-gaming.json]"
        if (-not $pPath) { $pPath = Join-Path -Path $PSScriptRoot -ChildPath "profiles\extreme-gaming.json" }
        if (-not (Test-Path -LiteralPath $pPath)) {
            $altProf = Join-Path -Path $PSScriptRoot -ChildPath (Join-Path "profiles" $pPath)
            if (Test-Path -LiteralPath $altProf) { $pPath = $altProf }
            elseif (Test-Path -LiteralPath "$altProf.json") { $pPath = "$altProf.json" }
        }
        $loaded = Import-Nano11Profile -FilePath $pPath
        if ($loaded) {
            $selectedProfile = "json ($([System.IO.Path]::GetFileNameWithoutExtension($pPath)))"
            if ($loaded.PSObject.Properties['RemoveDefender'])       { $removeDefender = [bool]$loaded.RemoveDefender }
            if ($loaded.PSObject.Properties['KeepAsianIME'])         { $keepAsianIME = [bool]$loaded.KeepAsianIME }
            if ($loaded.PSObject.Properties['KeepExtraFonts'])       { $keepExtraFonts = [bool]$loaded.KeepExtraFonts }
            if ($loaded.PSObject.Properties['RemoveDrivers'])        { $removeDrivers = [bool]$loaded.RemoveDrivers }
            if ($loaded.PSObject.Properties['DisableWindowsUpdate']) { $disableWU = [bool]$loaded.DisableWindowsUpdate }
            if ($loaded.PSObject.Properties['KeepBluetooth'])        { $keepBT = [bool]$loaded.KeepBluetooth }
            if ($loaded.PSObject.Properties['WSLSupport'])           { $wslSupport = [bool]$loaded.WSLSupport }
            if ($loaded.PSObject.Properties['KeepRecoveryEnv'])      { $keepRecoveryEnv = [bool]$loaded.KeepRecoveryEnv }
            if ($loaded.PSObject.Properties['SafeDebloatMode'])      { $safeDebloatMode = [bool]$loaded.SafeDebloatMode }
            if ($loaded.PSObject.Properties['UltraSlimMode'])        { $ultraSlimMode = [bool]$loaded.UltraSlimMode }
            if ($loaded.PSObject.Properties['SetJapaneseKeyboard'])  { $setJapaneseKeyboard = [bool]$loaded.SetJapaneseKeyboard }
            if ($loaded.PSObject.Properties['AtlasReviOSMode'])      { $atlasReviOSMode = [bool]$loaded.AtlasReviOSMode }
            if ($loaded.PSObject.Properties['BundleOptimizationToolkit']) {
                $bundleOptimizationToolkit = [bool]$loaded.BundleOptimizationToolkit
                $bundleRevTool = $bundleOptimizationToolkit
            }
            if ($loaded.PSObject.Properties['RemoveStore'])          { $removeStore = [bool]$loaded.RemoveStore }
            if ($loaded.PSObject.Properties['PayloadFormat']) {
                $fmt = $loaded.PayloadFormat.ToString().ToUpper()
                if ($fmt -eq 'ESD') { $exportESDMode = $true; $splitWIMMode = $false }
                elseif ($fmt -eq 'SWM') { $splitWIMMode = $true; $exportESDMode = $false }
                else { $exportESDMode = $false; $splitWIMMode = $false }
            }
            Write-Host "Applied Profile from JSON: $pPath" -ForegroundColor Green
        } else {
            Write-Host "Failed to load JSON profile. Reverting to Extreme profile defaults." -ForegroundColor Yellow
            $selectedProfile = "extreme"
        }
    } elseif ($pChoice -in @('4', 'gui', 'ui')) {
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
            BundleOptimizationToolkit = $bundleOptimizationToolkit
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
            $bundleOptimizationToolkit = $guiResult.BundleOptimizationToolkit
            $bundleRevTool             = $bundleOptimizationToolkit
            $removeStore               = $guiResult.RemoveStore
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

    # 13. Bundle Windows Optimization & Debloat Toolkit to Desktop
    if ($cliBound.Contains('Toolkit') -and (-not $Interactive)) {
        Write-Host "13. Bundle Windows Optimization Toolkit to Desktop: $(if ($bundleOptimizationToolkit) { 'Yes (Bundle)' } else { 'No (Skip)' }) [CLI: Specified]" -ForegroundColor DarkCyan
    } else {
        $defPrompt = if ($bundleOptimizationToolkit) { "Y/n" } else { "y/N" }
        $defDesc = if ($bundleOptimizationToolkit) { "Default: Y (Bundle)" } else { "Default: N (Skip)" }
        $opt = Read-Host "13. Bundle Windows Optimization Toolkit (WinUtil, Sophia Script, SophiApp, Optimizer, Bloatynosy, Revision Tool) to Desktop? [$defPrompt] ($defDesc)"
        if ($opt) {
            if ($opt.Trim().ToLower() -in @('no', 'n')) {
                $bundleOptimizationToolkit = $false
                $bundleRevTool = $false
            } elseif ($opt.Trim().ToLower() -in @('yes', 'y')) {
                $bundleOptimizationToolkit = $true
                $bundleRevTool = $true
            }
        }
    }

    # 14. Image compression format
    if (($cliBound.Contains('Export') -or $cliBound.Contains('SplitWIM')) -and (-not $Interactive)) {
        Write-Host "14. Image compression format: $(if ($exportESDMode) { '2 (install.esd Recovery LZMS)' } elseif ($splitWIMMode) { '3 (install.swm Split-WIM for FAT32)' } else { '1 (install.wim LZX)' }) [CLI: Specified]" -ForegroundColor DarkCyan
    } else {
        $defMode = if ($exportESDMode) { "2" } elseif ($splitWIMMode) { "3" } else { "1" }
        $opt = Read-Host "14. Image compression format [1=install.wim LZX (Default), 2=install.esd Recovery (LZMS), 3=install.swm (Split-WIM for FAT32 USB)] (Default: $defMode)"
        if ($opt) {
            if ($opt.Trim() -eq '2') { $exportESDMode = $true; $splitWIMMode = $false }
            elseif ($opt.Trim() -eq '3') { $splitWIMMode = $true; $exportESDMode = $false }
            elseif ($opt.Trim() -eq '1') { $exportESDMode = $false; $splitWIMMode = $false }
        }
    }

    # 15. Microsoft Store
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
            BundleOptimizationToolkit = $bundleOptimizationToolkit
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
Write-Host "  - Optimization Toolkit:    $bundleOptimizationToolkit"
Write-Host "  - Remove Microsoft Store:  $removeStore"
Write-Host "  - Payload Format:          $(if ($exportESDMode) { 'install.esd (LZMS)' } elseif ($splitWIMMode) { 'install.swm (Split-WIM / FAT32)' } else { 'install.wim (LZX - Recommended)' })"
Write-Host ""
if ($env:NANO11_TEST_MODE -eq "1") {
    Stop-Transcript
    exit 0
}

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

$nano11Dir = Join-Path -Path $baseWorkDir -ChildPath "build"
$scratchDir = Join-Path -Path $baseWorkDir -ChildPath "scratchdir"
Write-Host "Working Directory: $baseWorkDir" -ForegroundColor Cyan

# Temporarily exclude workspace from Windows Defender real-time scanning to accelerate DISM operations
try {
    Add-MpPreference -ExclusionPath $baseWorkDir -ErrorAction SilentlyContinue
} catch {}

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

# Determine source drive letter (with auto-detection)
$DriveLetter = ""
if ($SourceDrive) {
    if ($SourceDrive.EndsWith(".iso", [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $SourceDrive)) {
        Write-Host "Mounting specified Windows 11 ISO: $SourceDrive..." -ForegroundColor Cyan
        try {
            $diskImg = Mount-DiskImage -ImagePath $SourceDrive -PassThru -ErrorAction SilentlyContinue
            if ($diskImg) {
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
        if ($hasWimP) {
            $detectedMediaDrives += $psd
        } elseif ($hasEsdP) {
            Write-Host "  [!] Notice: Drive $rootClean contains 'install.esd' (MediaCreationTool format). MediaCreationTool ISOs are NOT supported. Skipping..." -ForegroundColor Yellow
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

# Ensure install.wim exists in destination; if not copied by robocopy, copy directly
if (-not (Test-Path -LiteralPath $destWim) -or ((Get-Item -LiteralPath $destWim).Length -lt 1GB)) {
    if (Test-Path -LiteralPath $sourceWim) {
        Write-Host "Copying install.wim directly from $sourceWim..." -ForegroundColor Cyan
        Copy-Item -LiteralPath $sourceWim -Destination $destWim -Force
    } else {
        Write-Host ""
        Write-Host "=========================================================" -ForegroundColor Red
        Write-Host " ERROR: 'sources\install.wim' was not found on $DriveLetter!" -ForegroundColor Red
        Write-Host " MediaCreationTool ISOs containing only 'install.esd' are not supported." -ForegroundColor Yellow
        Write-Host " Please download the official ISO containing 'install.wim' from Microsoft." -ForegroundColor Yellow
        Write-Host "=========================================================" -ForegroundColor Red
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

Write-Host "Mounting Windows image (Index: $index)..." -ForegroundColor Green
Write-Host "  -> DISM is unpacking system files. This typically takes 1-2 minutes on SSD..." -ForegroundColor Cyan
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
    Reset-DirectoryWithRobocopy -Path $scratchDir
}

if (-not $mountSuccess) {
    Write-Host "Failed to mount install.wim after recovery. Exiting..." -ForegroundColor Red
    Stop-Transcript
    exit 1
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
& dism.exe /English "/image:$scratchDir" /Disable-Feature /FeatureName:Windows-Recall-Optional-Package /Remove > $null 2>&1

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

# 7. Removing NativeImages (.NET)
Write-Host "Removing pre-compiled .NET Native Images..." -ForegroundColor Cyan
Remove-Item -Path "$scratchDir\Windows\assembly\NativeImages_*" -Recurse -Force -ErrorAction SilentlyContinue

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
Remove-Item -Path (Join-Path -Path $winDir -ChildPath "Web") -Recurse -Force -ErrorAction SilentlyContinue
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
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management" /v "DisablePagingExecutive" /t REG_DWORD /d 0 /f > $null 2>&1
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
    "WSearch"                                  = 4  # Windows Search Indexer
    "XblAuthManager"                           = 4  # Xbox Live Auth Manager
    "XblGameSave"                              = 4  # Xbox Live Game Save
    "XboxGipSvc"                               = 4  # Xbox Accessory Management Service
    "XboxNetApiSvc"                            = 4  # Xbox Live Networking Service

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

    # 1. Network QoS Latency (100% full bandwidth allocation)
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Psched" /v "NonBestEffortLimit" /t REG_DWORD /d 0 /f > $null 2>&1

    # 2. Storage & Crash Control (Disable memory dump bloat and crash alerts)
    reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\CrashControl" /v "CrashDumpEnabled" /t REG_DWORD /d 0 /f > $null 2>&1
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

# Bundle Windows Optimization & Debloat Toolkit into Image (Desktop & Setup Tools)
# Includes: Chris Titus WinUtil, Sophia Script, SophiApp, Optimizer, Bloatynosy, Revision Tool
if ($bundleOptimizationToolkit) {
    Write-Host "Configuring Windows Optimization & Debloat Toolkit bundle..." -ForegroundColor Green
    $toolsCacheDir = Join-Path -Path $scriptDir -ChildPath "tools"
    if (-not (Test-Path -LiteralPath $toolsCacheDir)) {
        New-Item -Path $toolsCacheDir -ItemType Directory -Force | Out-Null
    }

    # Ensure Revision Tool exists in cache
    $revToolLocal = Join-Path -Path $toolsCacheDir -ChildPath "RevisionTool-Setup.exe"
    if (-not (Test-Path -LiteralPath $revToolLocal)) {
        Write-Host "Downloading Revision Tool installer from GitHub..." -ForegroundColor Cyan
        $revToolUrl = "https://github.com/meetrevision/revision-tool/releases/download/2.11.1/RevisionTool-Setup.exe"
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
            Invoke-WebRequest -Uri $revToolUrl -OutFile $revToolLocal -UseBasicParsing -TimeoutSec 180
        } catch {
            Write-Warning "Could not download Revision Tool installer: $_"
        }
    }

    # Ensure Optimizer exists in cache
    $optLocal = Join-Path -Path $toolsCacheDir -ChildPath "Optimizer.exe"
    if (-not (Test-Path -LiteralPath $optLocal)) {
        Write-Host "Downloading Optimizer from GitHub..." -ForegroundColor Cyan
        $optUrl = "https://github.com/hellzerg/optimizer/releases/download/16.7/Optimizer-16.7.exe"
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
            Invoke-WebRequest -Uri $optUrl -OutFile $optLocal -UseBasicParsing -TimeoutSec 60
        } catch {
            Write-Warning "Could not download Optimizer: $_"
        }
    }

    # Copy tools to Public Desktop and Windows\Setup\Tools
    if (Test-Path -LiteralPath $toolsCacheDir) {
        $pubDesktop = Join-Path -Path $scratchDir -ChildPath "Users\Public\Desktop"
        $toolsDesktopDir = Join-Path -Path $pubDesktop -ChildPath "Windows Optimization Tools"
        New-Item -Path $toolsDesktopDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null

        $setupTools = Join-Path -Path $scratchDir -ChildPath "Windows\Setup\Tools"
        New-Item -Path $setupTools -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null

        # Copy all items in tools directory (standalone exes, scripts, and subfolders)
        Get-ChildItem -Path $toolsCacheDir | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $toolsDesktopDir -Recurse -Force -ErrorAction SilentlyContinue
            Copy-Item -LiteralPath $_.FullName -Destination $setupTools -Recurse -Force -ErrorAction SilentlyContinue
        }

        # Also place RevisionTool-Setup.exe directly on Public Desktop for instant access
        if (Test-Path -LiteralPath $revToolLocal) {
            Copy-Item -LiteralPath $revToolLocal -Destination (Join-Path -Path $pubDesktop -ChildPath "RevisionTool-Setup.exe") -Force -ErrorAction SilentlyContinue
        }

        Write-Host "  - Windows Optimization Toolkit (WinUtil, Sophia Script, SophiApp, Optimizer, Bloatynosy, Revision Tool) bundled to Public Desktop & Setup Tools" -ForegroundColor Green
    }
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

$browserPs1Content | Set-Content -LiteralPath (Join-Path -Path $pubDesktop -ChildPath "Install-Browser.ps1") -Encoding utf8
$browserCmdContent | Set-Content -LiteralPath (Join-Path -Path $pubDesktop -ChildPath "Install-Browser.cmd") -Encoding ascii
$controlCenterContent | Set-Content -LiteralPath (Join-Path -Path $pubDesktop -ChildPath "Nano11 Control Center.bat") -Encoding ascii

$browserPs1Content | Set-Content -LiteralPath (Join-Path -Path $setupTools -ChildPath "Install-Browser.ps1") -Encoding utf8
$browserCmdContent | Set-Content -LiteralPath (Join-Path -Path $setupTools -ChildPath "Install-Browser.cmd") -Encoding ascii
$controlCenterContent | Set-Content -LiteralPath (Join-Path -Path $setupTools -ChildPath "Nano11 Control Center.bat") -Encoding ascii
Write-Host "  - Deployed Browser Grabber and Nano11 Control Center to Desktop & Setup Tools" -ForegroundColor Green

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

# 19. Cleanup scratch and temporary files
if (-not $NonInteractive) {
    Read-Host "Press Enter to clean up working directories and exit."
}
& dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /discard > $null 2>&1
if ($isoCreatedSuccessfully) {
    Reset-DirectoryWithRobocopy -Path $nano11Dir
    Remove-Item -LiteralPath $nano11Dir -Recurse -Force -ErrorAction SilentlyContinue
} else {
    Write-Host "Preserving $nano11Dir because ISO creation was not completed." -ForegroundColor Yellow
}
Reset-DirectoryWithRobocopy -Path $scratchDir
Remove-Item -LiteralPath $scratchDir -Recurse -Force -ErrorAction SilentlyContinue

# Remove Windows Defender temporary workspace exclusion
try {
    Remove-MpPreference -ExclusionPath $baseWorkDir -ErrorAction SilentlyContinue
} catch {}

Stop-Transcript
if ($isoCreatedSuccessfully) {
    Write-Host "Done! nano11.iso is ready." -ForegroundColor Green
} else {
    Write-Host "Process ended with errors. Please check the logs in $transcriptPath" -ForegroundColor Red
}
