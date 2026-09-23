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
    [string]$WorkDir,
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
    [switch]$UltraSlim
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

# 3. Clean up any orphaned DISM mount points and leftover registry hives from previous failed runs
Write-Host "Checking for and repairing any orphaned DISM mount points and registry hives..." -ForegroundColor Cyan
& dism.exe /English /Cleanup-Wim > $null 2>&1
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
New-Item -ItemType Directory -Force -Path (Join-Path -Path $nano11Dir -ChildPath "sources") | Out-Null

# Prompt for source drive letter
$DriveLetter = ""
while (-not $DriveLetter) {
    $inputDrive = Read-Host "Please enter the drive letter for the Windows 11 installation media (e.g. D or D:)"
    if ($inputDrive) {
        $DriveLetter = $inputDrive.Trim().TrimEnd(':') + ":"
        if (-not (Test-Path -LiteralPath $DriveLetter)) {
            Write-Host "Drive $DriveLetter does not exist. Please check and re-enter." -ForegroundColor Red
            $DriveLetter = ""
        }
    }
}

# Check for install.wim or install.esd
$sourceWim = Join-Path -Path "$DriveLetter\sources" -ChildPath "install.wim"
$sourceEsd = Join-Path -Path "$DriveLetter\sources" -ChildPath "install.esd"
$destWim = Join-Path -Path "$nano11Dir\sources" -ChildPath "install.wim"

if (-not (Test-Path -LiteralPath $sourceWim)) {
    if (Test-Path -LiteralPath $sourceEsd) {
        Write-Host "Found install.esd, converting to install.wim..." -ForegroundColor Yellow
        & dism.exe /English /Get-WimInfo "/WimFile:$sourceEsd"
        $index = Read-Host "Please enter the image index to extract"
        Write-Host "Converting install.esd (Index $index) to install.wim. This may take a while..." -ForegroundColor Green
        & dism.exe /Export-Image "/SourceImageFile:$sourceEsd" "/SourceIndex:$index" "/DestinationImageFile:$destWim" /Compress:max /CheckIntegrity
        $index = "1"
    } else {
        Write-Host "Can't find install.wim or install.esd in $DriveLetter\sources. Exiting..." -ForegroundColor Red
        Stop-Transcript
        exit 1
    }
}

Write-Host "Copying Windows installation files to $nano11Dir..." -ForegroundColor Green
$sourcePath = $DriveLetter.TrimEnd('\') + "\"
$copySuccess = $false
$robocopyArgs = @("$sourcePath", "$nano11Dir", "/E", "/R:1", "/W:1", "/NP", "/NFL", "/NDL", "/NJH", "/NJS")
if (-not (Test-Path -LiteralPath $sourceWim)) {
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

# Bypass hardware requirement checks in installer (Resolves Issue #29 - Canary 28020+, Older CPUs/TPM)
$appraiserDll = Join-Path -Path "$nano11Dir\sources" -ChildPath "appraiserres.dll"
if (Test-Path -LiteralPath $appraiserDll) {
    Set-ItemOwnershipAndAccess -Path $appraiserDll
    Set-Content -LiteralPath $appraiserDll -Value "" -NoNewline -Force
    Write-Host "Patched appraiserres.dll for legacy hardware compatibility (TPM, CPU, SecureBoot bypass)." -ForegroundColor Green
}

# Remove ESD from copy if it exists to avoid duplication
if (Test-Path -LiteralPath "$nano11Dir\sources\install.esd") {
    Remove-Item -LiteralPath "$nano11Dir\sources\install.esd" -Force -ErrorAction SilentlyContinue
}

# Image Information and Index Selection
Write-Host "Getting Windows image information:" -ForegroundColor Cyan
& dism.exe /English /Get-WimInfo "/WimFile:$destWim"
if (-not $index) {
    $index = Read-Host "Please enter the image index to modify"
}

Write-Host "Mounting Windows image (Index: $index)... This may take several minutes." -ForegroundColor Green
Set-ItemOwnershipAndAccess -Path $destWim
try { Set-ItemProperty -LiteralPath $destWim -Name IsReadOnly -Value $false -ErrorAction Stop } catch {}

if (Test-Path -LiteralPath $scratchDir) {
    Remove-Item -LiteralPath $scratchDir -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Force -Path $scratchDir | Out-Null

& dism.exe /English /Mount-Image "/ImageFile:$destWim" "/Index:$index" "/MountDir:$scratchDir"
if ($LASTEXITCODE -ne 0) {
    Write-Host "Failed to mount install.wim. Exiting..." -ForegroundColor Red
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
    '*WindowsCalculator*', '*Calculator*', '*Xbox*'
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

# Windows Defender definitions and binaries cleanup (optional)
if ($removeDefender) {
    Write-Host "Purging Windows Defender signatures and binaries from WinSxS..." -ForegroundColor Cyan
    Remove-Item -Path "$scratchDir\ProgramData\Microsoft\Windows Defender\Definition Updates" -Recurse -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path "$scratchDir\Windows\WinSxS" -Filter "*windows-defender*" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-ProtectedDirectory -Path $_.FullName -ScratchPath $scratchDir
    }
}

# General cleanup & offline cache trimming
Write-Host "Cleaning offline system caches, prefetch, and setup logs..." -ForegroundColor Cyan
Remove-Item -Path "$scratchDir\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$scratchDir\Windows\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$scratchDir\Windows\System32\LogFiles\*" -Recurse -Force -ErrorAction SilentlyContinue
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
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Chat" /v "ChatIcon" /t REG_DWORD /d 3 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "TaskbarMn" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Search" /v "SearchboxTaskbarMode" /t REG_DWORD /d 0 /f > $null 2>&1

# Setup & Winlogon / Blank Password / PowerShell Execution Policy tweaks
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Lsa" /v "LimitBlankPasswordUse" /t REG_DWORD /d 0 /f > $null 2>&1
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
Remove-Item -LiteralPath "$tasksPath\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser" -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath "$tasksPath\Microsoft\Windows\Customer Experience Improvement Program" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath "$tasksPath\Microsoft\Windows\Application Experience\ProgramDataUpdater" -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath "$tasksPath\Microsoft\Windows\Chkdsk\Proxy" -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath "$tasksPath\Microsoft\Windows\Windows Error Reporting\QueueReporting" -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath "$tasksPath\Microsoft\XblGameSave" -Recurse -Force -ErrorAction SilentlyContinue

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

# Windows Defender (optional)
if ($removeDefender) {
    Write-Host "Disabling Windows Defender & Security Health Services..." -ForegroundColor Green
    $defServices = @("WinDefend", "WdNisSvc", "WdNisDrv", "WdFilter", "Sense", "SecurityHealthService")
    foreach ($svc in $defServices) {
        reg.exe add "HKLM\zSYSTEM\ControlSet001\Services\$svc" /v "Start" /t REG_DWORD /d 4 /f > $null 2>&1
    }
    # Disable Defender Real-Time Protection and AntiSpyware policies
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender" /v "DisableAntiSpyware" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender" /v "DisableAntiVirus" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" /v "DisableRealtimeMonitoring" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" /v "DisableBehaviorMonitoring" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" /v "DisableOnAccessProtection" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" /v "DisableScanOnRealtimeEnable" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" /v "DisableIOAVProtection" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender\Reporting" /v "DisableEnhancedNotifications" /t REG_DWORD /d 1 /f > $null 2>&1
    # Remove SecurityHealth from startup Run key
    reg.exe delete "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Run" /v "SecurityHealth" /f > $null 2>&1
}

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
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" /v "SystemResponsiveness" /t REG_DWORD /d 10 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v "Priority" /t REG_DWORD /d 2 /f > $null 2>&1
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
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management" /v "PoolUsageMaximum" /t REG_DWORD /d 60 /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management" /v "LargeSystemCache" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management" /v "DisablePagingExecutive" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management\PrefetchParameters" /v "EnablePrefetcher" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management\PrefetchParameters" /v "EnableSuperfetch" /t REG_DWORD /d 0 /f > $null 2>&1

# Radical RAM Optimization: Non-essential background services configured to Disabled (4) or Manual (3)
Write-Host "Configuring system services for radical RAM reduction..." -ForegroundColor Green
$serviceConfigs = @{
    "SysMain"            = 4  # SuperFetch / RAM pre-caching (Saves 100MB-200MB RAM)
    "WSearch"            = 4  # Windows Search Indexer (Saves 80MB-150MB RAM)
    "DoSvc"              = 4  # Delivery Optimization (Saves 40MB-80MB RAM)
    "DPS"                = 4  # Diagnostic Policy Service (Saves 30MB-50MB RAM)
    "WdiServiceHost"     = 4  # Diagnostic Service Host
    "WdiSystemHost"      = 4  # Diagnostic System Host
    "TroubleshootingSvc" = 4  # Recommended Troubleshooting Service
    "DusmSvc"            = 4  # Data Usage Monitoring
    "LanmanServer"       = 3  # Server / SMB File Sharing (Manual: starts on demand only)
    "TabletInputService" = 3  # Touch Keyboard and Handwriting Panel (Manual)
    "SensrSvc"           = 4  # Sensor Monitoring Service
    "SensorService"      = 4  # Sensor Service
    "SensorDataService"  = 4  # Sensor Data Service
    "ShellHWDetection"   = 3  # Shell Hardware Detection (Manual)
    "WarpJITSvc"         = 4  # WARP JIT Service
    "SharedAccess"       = 4  # Internet Connection Sharing
    "stisvc"             = 3  # Windows Image Acquisition (Manual)
    "MapsBroker"         = 4  # Downloaded Maps Manager
    "DiagTrack"          = 4  # Connected User Experiences and Telemetry
    "dmwappushservice"   = 4  # WAP Push Message Routing Service
    "RetailDemo"         = 4  # Retail Demo Service
    "wisvc"              = 4  # Windows Insider Service
    "lfsvc"              = 4  # Geolocation Service
    "PcaSvc"             = 4  # Program Compatibility Assistant
    "WerSvc"             = 4  # Windows Error Reporting Service
    "SCardSvr"           = 4  # Smart Card Service
    "ScDeviceEnum"       = 4  # Smart Card Device Enumeration Service
    "icssvc"             = 4  # Mobile Hotspot Service
    "CertPropSvc"        = 4  # Certificate Propagation
    "CscService"         = 4  # Offline Files
    "Netlogon"           = 3  # Netlogon (Manual demand-start)
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

# Hardware Clock in UTC (Fixes dual-boot time desync with Linux)
reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\TimeZoneInformation" /v "RealTimeIsUniversal" /t REG_DWORD /d 1 /f > $null 2>&1

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
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v "TurnOffSavingSnapshots" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v "DisableClickToDo" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v "DisableSettingsAgent" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v "DisableAgentConnectors" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v "DisableAgentWorkspaces" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v "DisableRemoteAgentConnectors" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v "AllowCopilotRuntime" /t REG_DWORD /d 0 /f > $null 2>&1

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

# Radical RAM: Disable Transparency & DWM render targets
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" /v "EnableTransparency" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" /v "EnableTransparency" /t REG_DWORD /d 0 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\DWM" /v "ColorizationOpaqueBlend" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\DWM" /v "ColorizationOpaqueBlend" /t REG_DWORD /d 1 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Control Panel\Desktop\WindowMetrics" /v "MinAnimate" /t REG_SZ /d "0" /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Control Panel\Desktop\WindowMetrics" /v "MinAnimate" /t REG_SZ /d "0" /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" /v "VisualFXSetting" /t REG_DWORD /d 2 /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" /v "VisualFXSetting" /t REG_DWORD /d 2 /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Control Panel\Desktop" /v "UserPreferencesMask" /t REG_BINARY /d "9012038010000000" /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Control Panel\Desktop" /v "UserPreferencesMask" /t REG_BINARY /d "9012038010000000" /f > $null 2>&1
reg.exe add "HKLM\zNTUSER\Control Panel\Desktop" /v "FontSmoothing" /t REG_SZ /d "2" /f > $null 2>&1
reg.exe add "HKLM\zDEFAULT\Control Panel\Desktop" /v "FontSmoothing" /t REG_SZ /d "2" /f > $null 2>&1
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

# Unmount Registry Hives
Write-Host "Unmounting offline registry hives..." -ForegroundColor Cyan
@('zCOMPONENTS', 'zDEFAULT', 'zNTUSER', 'zSOFTWARE', 'zSYSTEM') | ForEach-Object {
    [void](Unmount-RegistryHiveWithRetry -Name $_)
}

# 12. Unmount and export install image
Write-Host "Unmounting install image..." -ForegroundColor Green

[GC]::Collect()
[GC]::WaitForPendingFinalizers()
Start-Sleep -Seconds 2

& dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /commit
if ($LASTEXITCODE -ne 0) {
    Write-Host "Warning: commit unmount failed, retrying after garbage collection..." -ForegroundColor Yellow
    [GC]::Collect()
    Start-Sleep -Seconds 3
    & dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /commit
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Falling back to discard unmount..." -ForegroundColor Yellow
        & dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /discard
    }
}

# Export modified image directly to recovery ESD format (LZMS compression)
$finalEsd = Join-Path -Path "$nano11Dir\sources" -ChildPath "install.esd"
Write-Host "Exporting modified image to recovery-compressed install.esd (LZMS)..." -ForegroundColor Green
& dism.exe /English /Export-Image "/SourceImageFile:$destWim" "/SourceIndex:$index" "/DestinationImageFile:$finalEsd" /Compress:recovery /CheckIntegrity

if ((Test-Path -LiteralPath $finalEsd) -and ((Get-Item -LiteralPath $finalEsd).Length -gt 100MB)) {
    Write-Host "install.esd successfully created ($([math]::Round((Get-Item -LiteralPath $finalEsd).Length / 1GB, 2)) GB). Removing temporary install.wim..." -ForegroundColor Green
    Remove-Item -LiteralPath $destWim -Force -ErrorAction SilentlyContinue
} else {
    Write-Host "Recovery export unavailable or failed, falling back to LZX install.wim..." -ForegroundColor Yellow
    $tempWim = Join-Path -Path "$nano11Dir\sources" -ChildPath "install2.wim"
    & dism.exe /English /Export-Image "/SourceImageFile:$destWim" "/SourceIndex:$index" "/DestinationImageFile:$tempWim" /Compress:max /CheckIntegrity
    Remove-Item -LiteralPath $destWim -Force -ErrorAction SilentlyContinue
    Rename-Item -LiteralPath $tempWim -NewName "install.wim" -Force
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
    & dism.exe /English /Mount-Image "/ImageFile:$newBootWim" /Index:1 "/MountDir:$scratchDir"

    reg.exe load HKLM\zSYSTEM "$scratchDir\Windows\System32\config\SYSTEM" | Out-Null
    Write-Host "Applying LabConfig bypasses to boot.wim Setup environment..." -ForegroundColor Green
    foreach ($key in $labConfigKeys) {
        reg.exe add "HKLM\zSYSTEM\Setup\LabConfig" /v $key /t REG_DWORD /d 1 /f > $null 2>&1
    }
    reg.exe add "HKLM\zSYSTEM\Setup\MoSetup" /v "AllowUpgradesWithUnsupportedTPMOrCPU" /t REG_DWORD /d 1 /f > $null 2>&1
    reg.exe unload HKLM\zSYSTEM | Out-Null

    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    & dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /commit
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Warning: commit unmount of boot.wim failed, retrying after garbage collection..." -ForegroundColor Yellow
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        Start-Sleep -Seconds 3
        & dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /commit
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
if (Test-Path -LiteralPath $esdCheck) {
    Write-Host "Final installation image confirmed: install.esd ($([math]::Round((Get-Item -LiteralPath $esdCheck).Length / 1GB, 2)) GB)" -ForegroundColor Green
    if (Test-Path -LiteralPath $wimCheck) {
        Remove-Item -LiteralPath $wimCheck -Force -ErrorAction SilentlyContinue
    }
} elseif (Test-Path -LiteralPath $wimCheck) {
    Write-Host "Final installation image confirmed: install.wim ($([math]::Round((Get-Item -LiteralPath $wimCheck).Length / 1GB, 2)) GB)" -ForegroundColor Green
}

# 16. Final cleanup of ISO root
Write-Host "Performing final cleanup of ISO root..." -ForegroundColor Cyan
$keepList = @("boot", "efi", "sources", "bootmgr", "bootmgr.efi", "bootmgfw.efi", "setup.exe", "autounattend.xml")
Get-ChildItem -Path $nano11Dir | Where-Object { $_.Name -notin $keepList } | ForEach-Object {
    Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
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

# Remove any existing output ISO to prevent file locks/collisions
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
    
    if ((Test-Path -LiteralPath $outputIso) -and ((Get-Item -LiteralPath $outputIso).Length -gt 1MB)) {
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
    } else {
        Write-Host ""
        Write-Host "=========================================================" -ForegroundColor Red
        Write-Host "   ERROR: Failed to create bootable ISO!                 " -ForegroundColor Red
        Write-Host "   oscdimg exited with code $LASTEXITCODE. The ISO file was not generated." -ForegroundColor Red
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
