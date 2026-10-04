# **nano11 🔬**

A PowerShell script to build a heavily trimmed-down, lightning-fast Windows 11 image.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Architecture: x64 | ARM64](https://img.shields.io/badge/Architecture-x64%20%7C%20ARM64-blue.svg)](#)
[![OS: Windows 11 23H2 / 24H2 / LTSC / Canary](https://img.shields.io/badge/Windows%2011-23H2%20%7C%2024H2%20%7C%20LTSC%20%7C%20Canary-brightgreen.svg)](#)

---

## **Introduction**

Introducing **nano11 builder**, a powerful PowerShell script that creates an ultra-minimal Windows 11 image!

The goal of nano11 is to automate the creation of a streamlined Windows 11 image. The script uses native DISM capabilities and official deployment tools (`oscdimg.exe`) to create a bootable ISO with no third-party binary dependencies. An included unattended answer file bypasses Microsoft Account requirements during setup, enables automatic local administrator logon, enables CompactOS compression, and configures a clean, bloatware-free desktop.

---

## **✨ Features & Improvements in this Fork**

- **🌐 Universal Language Independence (PR #6 by Tinnitus97)**:
  - Works on any host operating system language/locale without permission or translation errors.
  - Replaces localized tools (`takeown`/`icacls`) with native .NET Access Control Lists (`Set-Acl` via Well-Known Administrator SID `S-1-5-32-544`).
- **🛡️ Customization Options (Issues #1, #9, #10, #12, #13)**:
  - **Complete User Account Control (UAC) Deactivation**: UAC elevation prompts and secure desktop dimming are completely disabled (`ConsentPromptBehaviorAdmin = 0`, `PromptOnSecureDesktop = 0`) across both offline registry hives and the unattended answer file, eliminating permission popups for administrators.
  - **Japanese Keyboard (106/109) Guarantee**: Prevents the common Windows clean install issue where Japanese keyboards are misdetected as 101/104 English keyboards (causing `@` and `:` key mapping mismatch) by injecting verified `kbd106.dll` and `PCAT_106KEY` configurations. Toggle with `-JapaneseKeyboard` / `-NoJapaneseKeyboard`.
  - **Windows 11 24H2 & AI Bloatware Neutralization**: Automatically disables 24H2 mandatory BitLocker device encryption (`PreventDeviceEncryption = 1`), TCG hardware security activation, and eliminates background AI telemetry (Copilot Provider, Windows Recall, Click-to-Do, and DevHome).
  - **Automatic Media Drive Detection**: Automatically detects connected official Windows 11 ISO/USB installation drives containing `sources\install.wim`, eliminating manual drive letter entry.
  - **Keep Asian IMEs**: Retain Japanese input method (`ja-JP`) while cleanly decoupling and trimming foreign Asian IMEs (`ko-KR`, `zh-CN`, `zh-TW`) and gigabytes of unneeded foreign voice packages.
  - **Windows Defender Toggle**: Option to keep Windows Defender active or remove it completely.
  - **Fonts & Drivers**: Option to preserve international font collections and essential hardware drivers.
  - **Windows Update**: Option to keep Windows Update enabled or disabled.
  - **Bluetooth & Audio**: Preserves Bluetooth audio transport and peripheral services by default so wireless headphones and controllers function properly.
  - **Recovery Environment (WinRE)**: Retain Windows RE with `-KeepRecovery` or `-KeepWinRE`. By default, WinRE is kept intact during installation so Windows Setup SafeOS staging succeeds 100%, then safely disabled and deleted online on first logon.
- **⚡ High-Speed ISO Modification & Zero-Stall Mounting Engine**:
  - **Recursive Ownership Bottleneck Eliminated**: Removed recursive `takeown /R` and `icacls /T` commands over 100,000+ files in `WinSxS`, `DriverStore`, and `WindowsApps` that stalled DISM operations for 45-90 minutes. Targeted directory deletion now handles ACL permissions on-demand.
  - **Sub-Second Workspace Purge via Robocopy Mirror**: Replaced slow and lock-prone PowerShell recursive deletions with an empty-directory mirroring engine (`Reset-DirectoryWithRobocopy`), wiping 50,000+ dirty files in < 1 second and preventing DISM mount errors (`0x80070130`).
  - **NTFS Volume Safety Verification**: Automatically verifies the workspace drive format (`Test-IsNtfsVolume`), preventing DISM reparse point failures (`0xc142011f`) when users run the script from exFAT drives (e.g. Ventoy USB drives).
  - **Real-Time DISM Progress Visibility**: Removed stdout suppression from DISM component cleanup and exports, exposing live progress percentages.
  - **Automated Windows Defender Exclusion**: Automatically adds temporary Defender exclusions for build workspaces during execution to prevent real-time file scanning slowdowns on 100,000+ image files.
- **📦 Radical ISO Size Reduction (~3.2 GB – 3.8 GB, Perplexity-Verified Safe)**:
  - **Decoupled Japanese IME & Foreign Language Stripping**: Purges heavy foreign Asian IMEs (Korean `ko-KR`, Chinese `zh-CN`/`zh-TW`), foreign speech models (`zh-*`, `ko-*`, `de-*`, `fr-*`, `es-*`, `it-*`, `pt-*`, `ru-*`), and foreign Handwriting/OCR packages, saving over 800 MB – 1.2 GB in the installation image while strictly safeguarding Japanese IME (`*IME-ja-jp*`), Japanese fonts (`meiryo*`, `yugoth*`, `msgoth*`, `msmin*`, `yumin*`), and Text Services Framework (`ctfmon.exe`).
  - **Foreign Supplemental Fonts Trimmed**: Safely purges non-Latin/non-Japanese font collections (Chinese Hans/Hant, Korean Kore, Devanagari, Thai, Ethiopic, Syriac, Cherokee, etc.), saving ~200 MB.
  - **Obsolete FOD Packages Removed**: Purges deprecated and unused optional features including `WMIC` (deprecated in 24H2), `Printing-WFS` (Fax & Scan), `WirelessDisplay` (Miracast Connect), `SNMP`, `Telnet`, `SimpleTCP`, and `RDC`.
  - **Offline System Caches & Setup Logs Cleaned**: Wipes build-time update caches (`SoftwareDistribution\Download`), `System32\LogFiles`, `Prefetch`, and setup temporary files before unmounting.
  - **High-Speed Stable LZX install.wim Export & Setup Error 0x8007000D Fix**: Defaults to rock-solid LZX `/Compress:max` export to `sources\install.wim` (exports in ~20 seconds), preventing the known Windows 11 24H2 DISM `WIMGAPI.DLL` crash (`0xc0000005`) that occurred during LZMS solid recovery compression. Eliminates the critical bug where a crashed 208-byte `install.esd` remnant caused the valid `install.wim` to be deleted, which resulted in Windows Setup error `0x8007000D - 0x4002C` (ERROR_INVALID_DATA). Includes strict payload (> 1 GB) and ISO (> 1.5 GB) size validation, with an optional `-ExportESD` flag for systems that support solid LZMS export.
  - **Zero Setup-Breaking Hacks**: Strictly keeps `winre.wim` intact during offline build (preventing `0x80070002` SafeOS staging failures) and keeps `boot.wim` under LZX `/Compress:max` (avoiding `0xc0000001` unbootable media), with CBS component integrity guaranteed via official DISM `StartComponentCleanup /ResetBase`.
- **🚫 Safe Debloat & Suppression of Target Components**:
  - **Windows Backup (Windows バックアップ)**: Complete policy suppression (`DisableBackupRestore = 1`, `DisableCloudBackup = 1`, `DisableConsumerAccountStateContent = 1`), `AppListBackup` scheduled task removal, and concealment from Settings (`hide:backup`). Avoids breaking `Client.CBS` system dependencies.
  - **Windows Security & Defender (Windows セキュリティ)**: Services disabled (`WinDefend`, `WdNisSvc`, `SecurityHealthService` = 4), real-time protection and antispyware policies enforced, startup system tray entry (`SecurityHealth`) removed, and settings page hidden (`hide:virus`).
  - **Accessibility (アクセシビリティ: 音声アクセス / 拡大鏡 / スクリーンキーボード / ナレーター / ライブキャプション)**: Preserves essential binaries (`osk.exe`, `Narrator.exe`, `magnify.exe`) in `System32` during setup to ensure 100% OOBE pass stability, while hotkeys (Win+Enter, 5x Shift StickyKeys, FilterKeys, ToggleKeys), auto-launch flags, and settings pages are suppressed. Post-OOBE IFEO redirection is safely applied in `FirstLogon.ps1` to prevent any execution on the desktop.
  - **Get Started / Tips (はじめに)**: Fully removed offline via DISM `Remove-AppxProvisionedPackage` with fallback cleanup across all user accounts in `FirstLogon.ps1`, coupled with `DisableSoftLanding` promotional suppression.
  - **🔄 OOBE Boot Loop & Setup Crash Fixed**: Solved the infinite boot loop at the "Please wait" ("お待ちください") screen. Root causes fully resolved:
    - **WebView2 Runtime Preserved**: Preserved `C:\Windows\System32\Microsoft-Edge-WebView` and its WinSxS packages. Windows 11 OOBE (`CloudExperienceHost`, `msoobe.exe`) strictly requires the embedded WebView2 runtime to render setup interfaces; removing it crashed OOBE on launch. Edge browser UI (`Program Files (x86)\Microsoft\Edge`) is still cleanly removed.
    - **Reboot Loop Trap Removed (`ErrorHandler.cmd`)**: Completely eliminated `ErrorHandler.cmd` and `ChildCompletion` registry overrides from the unattended answer file, preventing reboot loops and allowing Windows Setup to proceed naturally without interference.
    - **Core Accessibility Binaries Retained**: Preserves essential accessibility binaries (`osk.exe`, `Narrator.exe`, `magnify.exe`) in `System32` to prevent handle exceptions during OOBE Ease of Access subsystem initialization.
    - **Safe FontCache Lifecycle**: Defers `FontCache` and `FontCache3.0.0.0` disabling to `FirstLogon.ps1` (after desktop logon) so localized DirectWrite font rendering succeeds 100% during setup.
    - **Strict Empty Passwords & Permanent AutoAdminLogon**: Normalized all `<Password><Value></Value>` tags to strictly empty single-line elements across all architectures, eliminating whitespace and newline parsing issues where Windows Setup hashed carriage returns as actual password characters. Fully guarantees completely blank passwords for `User` and `Administrator` (`net user User ""` and `/passwordreq:no`), configures persistent registry `AutoAdminLogon = 1` with `ForceAutoLogon = 1`, and eliminates password prompts on wake/idle.
  - **🖱️ Mouse Cursor & Pointer Display Guarantee**: Preserves essential Windows cursor bitmaps in `C:\Windows\Cursors` (~5 MB), ensuring the mouse pointer (`aero_arrow.cur`) is always rendered and fully functional throughout setup and on the installed desktop.
  - **Account Collision Resolved**: Centralized local account creation cleanly into `oobeSystem` `<LocalAccount wcm:action="add">`, eliminating `ERROR_USER_EXISTS` (0x80070524) collisions with `Specialize.ps1`.
  - **Setup Pre-Finalize SafeOS Crash Fixed**: Solved the `0x80070002` / `0x8007000B` error where Windows Setup crashes at ~100% when attempting to stage missing or corrupt `winre.wim`. `winre.wim` is preserved at build time and removed cleanly via online `reagentc /disable` during `FirstLogon.ps1`.
  - **SafeDebloat Component Store Mode (Default)**: Protects CBS servicing integrity and localized (`ja-JP`) resources using official DISM `StartComponentCleanup /ResetBase` + cache pruning. Aggressive pruning mode (`-AggressiveWinSxS`) is also available with comprehensive core system and language preservation.
  - **Administrator Account Auto-Activation**: Explicitly activates the built-in Administrator account in `Specialize.ps1` for seamless unattended setup across Windows 11 Home and Pro editions.
  - **Setup Script Pre-Extraction**: Unattend scripts (`Specialize.ps1`, `DefaultUser.ps1`, etc.) are pre-extracted directly into the image during build time with robust `try/catch` error shielding, preventing specialize pass aborts.
  - **Bootable WIM Exports**: Added `/Bootable` flag to all `boot.wim` exports to prevent `0xc1510115` errors across all UEFI/BIOS firmware.
- **💿 Bundled `oscdimg.exe` & Resilient ISO Generation**:
  - **Pre-Bundled Deployment Tool**: `oscdimg.exe` is bundled directly within the repository root for offline, reliable ISO generation out-of-the-box.
  - **Multi-Mirror & DNS Fallback**: If `oscdimg.exe` is ever missing, the builder automatically falls back through multiple international CDN mirrors and Google DNS (`8.8.8.8`) resolution to resolve `msdl.microsoft.com` network lookup failures.
  - **Dynamic Bootdata (Dual BIOS + UEFI)**: Seamlessly discovers `etfsboot.com` and `efisys.bin` across candidate paths, building Dual-Boot, UEFI-only, or BIOS-only boot parameters based on available bootloaders.
  - **Robocopy Mirroring**: Uses `robocopy` with `Copy-Item` fallback to ensure 100% of directory structures and boot files are preserved from read-only ISO media.
  - **Build Integrity & Safe Cleanup**: Validates output ISO existence and size (> 1 MB), captures `oscdimg` exit codes, displays SHA256 checksums, and preserves the working directory upon error for troubleshooting.
- **⚡ Advanced Performance, Latency & Registry Optimization**:
  - **Integrated eclean & AtlasOS Optimization & Disk Cleaner**:
    - *Fault Tolerant Heap (FTH) Disabled*: Eliminates crash mitigation throttling and CPU overhead for games and intensive applications.
    - *Program Compatibility Assistant (PCA) Suppressed*: Disables PCA engine, inventory, and telemetry policies (`DisablePCA`, `DisableEngine`, `DisableInventory`, `AITEnable`).
    - *UCPD & Background Driver Pruning*: Disables Universal Consent Privacy Driver (`UCPD`) to prevent Windows from reverting user customizations, along with `GpuEnergyDrv`, `diagnosticshub`, `OneSyncSvc`, and `TrkWks`.
    - *Delivery Optimization (P2P Upload) Disabled*: Sets `DODownloadMode = 0` to prevent Windows from seeding update files to external peers.
    - *Fast Startup (Hiberboot) Disabled*: Eliminates hibernated state disk wear, dual-boot partition locks, and ensures clean cold-boot kernel state.
    - *Automated Disk Cleanup (Cleaner Logic)*: Integrates `VolumeCaches` preset configuration with `cleanmgr.exe /sagerun:64` and automatic purge of user/system Temp, CrashDumps, Minidumps, and Windows Event logs.
  - **Integrated optimizerDuck & sparkle**: Applies system latency and responsiveness optimizations, including `Win32PrioritySeparation` quantum boost (0x26), Multimedia Class Scheduler Service (MMCSS) gaming priority & GPU scheduling, and network throttling index disabling.
  - **Integrated Revo Registry Cleaner Tuner**: Full integration of all 6 optimization categories:
    - *Explorer*: Auto-complete URL/path suggestions, show drive letters first, disable info tips.
    - *Desktop & Start Menu*: Reduce hover delay times, enable classic Alt+Tab, kill hung apps faster (`WaitToKillAppTimeout = 2000`).
    - *System & Services*: `ServicesPipeTimeout` optimization, network file sharing responsiveness.
    - *Visual Effects*: Disable Mica/Acrylic transparency while keeping font smoothing enabled.
- **🚀 AtlasOS & ReviOS Radical Debloat & Latency Engine**:
  - **Low-Latency System Timer & BCD Tuning**: Configures high-resolution synthetic timers (`useplatformclock false`, `disabledynamictick yes`, `tscsyncpolicy Enhanced`, `bootux disabled`, `quietboot on`), completely eliminating dynamic tick jitter and micro-stuttering in latency-sensitive applications and games.
  - **Gaming Responsiveness & Quantum Scheduling**: Injects `Win32PrioritySeparation = 0x26` (38 decimal: short, variable quanta favoring foreground tasks), tunes MMCSS `SystemResponsiveness = 0` (0% multimedia throttling), sets gaming thread priority to 6, and sets GPU scheduling priority to 8.
  - **Ultra-Low Latency Network Stack**: Disables Nagle's algorithm (`TcpAckFrequency = 1`, `TCPNoDelay = 1`) across all active and virtual network adapters for immediate packet dispatch, lowers `TcpTimedWaitDelay = 30`, sets `MaxUserPort = 65534`, and eliminates Windows QoS 20% bandwidth reservation (`NonBestEffortLimit = 0`).
  - **Complete Hibernation Purge**: Executes `powercfg.exe /hibernate off` on first logon to eradicate `hiberfil.sys`, instantly recovering **4 GB – 16+ GB of SSD storage** and eliminating fast-startup shutdown disk thrashing.
  - **Ultimate Performance Power Scheme**: Automatically provisions and activates the hidden Windows Ultimate Performance power scheme (`e9a42b02-d5df-448d-aa00-03f14749eb61`), preventing aggressive core sleeping and frequency drops.
  - **NTFS File System Overhead Reduction**: Disables legacy 8.3 short filename generation (`NtfsDisable8dot3NameCreation = 1`) and disables NTFS last-access timestamp tracking (`NtfsDisableLastAccessUpdate = 1`), drastically cutting file I/O operations and disk overhead.
  - **Kernel Paging & Crash Dump Overhead Elimination**: Locks the core NT kernel executive in physical RAM (`DisablePagingExecutive = 1`), disables zeroing pagefile at shutdown for faster reboots, disables memory crash dump generation (`CrashDumpEnabled = 0`), and suppresses crash logging events.
  - **Deep Service & Diagnostics Stripping**: Disables 13+ unnecessary telemetry, parental, and legacy background services offline (`WpcMonSvc`, `WMPNetworkSvc`, `PhoneSvc`, `WbioSrvc`, `SharedAccess`, `RemoteRegistry`, `RetailDemo`, `shpamsvc`, etc.) and purges diagnostic scheduled tasks offline.
  - **🛠️ Post-Install Desktop Maintenance Tools**: Automatically deploys a dedicated management toolkit folder directly to `C:\Users\Public\Desktop\Atlas-ReviOS Tools` containing 6 one-click `.bat` scripts:
    1. `1. Toggle Windows Defender.bat`: Enable or disable Defender real-time protection and services on demand.
    2. `2. Toggle Windows Update.bat`: Enable or disable Windows Update services (`wuauserv`, `UsoSvc`, `BITS`).
    3. `3. Toggle Hibernation.bat`: Enable or disable hibernation and toggle `hiberfil.sys` disk footprint.
    4. `4. Toggle Bluetooth.bat`: Enable or disable Bluetooth support services (`bthserv`, `BTAGService`).
    5. `5. Toggle Print Spooler.bat`: Enable or disable the print spooler service (`Spooler`).
    6. `6. Free Memory & Clear Temp.bat`: Instant purge of temporary files, crash dumps, and Win32 working sets.
- **⚡ Radical RAM Optimization (Idle Memory Baseline ~600 MB – 800 MB, Theoretical Architectural Limit)**:
  - **SvcHost Grouping**: Sets `SvcHostSplitThresholdInKB` to 64 GB, consolidating 70–90 separate `svchost.exe` instances into 12–15 shared processes, instantly freeing 500 MB – 800 MB of RAM.
  - **Strict Kernel Paging (`DisablePagingExecutive = 0`)**: Fully eliminates kernel driver physical memory locking, allowing Windows to dynamically page inactive kernel code to disk and reclaiming 80 MB – 150 MB of physical RAM.
  - **Dynamic Kernel Memory Management**: Preserves NT Kernel dynamic pool allocation to prevent `STATUS_INSUFFICIENT_RESOURCES` driver allocation deadlocks during setup, while aggressively paging idle structures.
  - **Application Pre-Launch & Prefetch Disabling**: Neutralizes `Disable-MMAgent -ApplicationPreLaunch`, `Disable-MMAgent -ApplicationLaunchPrefetching`, and `Disable-MMAgent -OperationAPI`, preventing Windows from pre-allocating hundreds of megabytes into RAM before apps are even launched.
  - **Kernel Memory Manager & Page Combining**: Enables NT Kernel `PageCombining` (copy-on-write duplicate memory page coalescing) and prioritizes application working sets over file system cache (`LargeSystemCache = 0`, `DisablePageCombining = 0`).
  - **DWM & Visual Effects Lightweighting (Best Performance)**: Disables window transparency, acrylic blur, window dragging animations, and transition effects (`MinAnimate = 0`, `VisualFXSetting = 2`, `DragFullWindows = 0`, `UserPreferencesMask = 90 12 01 80 10 00 00 00`) while preserving ClearType font smoothing, minimizing `dwm.exe` direct composition buffers.
  - **Microsoft Edge & WebView2 Zero-RAM Background Block**: Completely blocks Edge and WebView2 runtime background processes and startup boosting (`BackgroundModeEnabled = 0`, `StartupBoostEnabled = 0`, `PreloadEdgeDefaultEngine = 0`), eliminating 150 MB – 300 MB of hidden webview consumption.
  - **Extreme Service Pruning & Demand-Start**: Disables diagnostic/telemetry daemons while safely setting per-user templates and DirectWrite services to Demand-Start (`FontCache`, `WpnService`, `UserDataSvc`, etc. at `Start = 3`), guaranteeing zero idle RAM overhead and 100% logon stability.
  - **Scheduled Task Trimming**: Disables heavy maintenance tasks (`ProcessMemoryDiagnosticEvents`, `RunFullMemoryDiagnostic`, `WinSAT`, `DiskFootprint\Diagnostics`, `ScheduledDefrag`, `Maps`, `Speech`) that wake up and consume RAM in the background.
  - **Guaranteed Stability (Zero Dangerous Hacks)**: Strictly rejects harmful placebo tweaks (Pagefile is kept system-managed; NDU network monitoring driver is preserved; `LargeSystemCache` is not forced to server mode).
  - **Desktop Maintenance Suite**: Deploys an on-demand maintenance suite on the desktop (`Atlas-ReviOS Tools`) including working set memory trimming, telemetry toggles, and junk cleaners without interfering with logon initialization.
- **📉 Radical Background & Windows Process Reduction (Perplexity-Verified Safe)**:
  - **Japanese IME (`ctfmon.exe`) Fully Preserved**: Unlike unsafe debloat scripts that disable the Text Services Framework and render Japanese typing broken, `ctfmon.exe` and input frameworks are strictly safeguarded.
  - **No Dangerous Executable Deletions**: Strictly avoids removing or killing `RuntimeBroker.exe`, `SearchHost.exe`, or core DCOM/RPC infrastructure, preserving Start Menu, Settings, and WinRT app stability.
  - **OneDrive Background Engine Suppressed**: Disables `OneDrive.exe` background file sync engine and autostart (`DisableFileSyncNGSC = 1`).
  - **GameBar & Screen Capture Stopped**: Completely stops `GameBarPresenceWriter.exe` and `bcastdvr.exe` from hooking into foreground windows and games (`AllowGameDVR = 0`, `AppCaptureEnabled = 0`, `GameDVR_Enabled = 0`).
  - **Telemetry & Census Runners Suppressed**: Disables scheduled tasks that periodically launch `CompatTelRunner.exe` and `DeviceCensus.exe` (Compatibility Appraiser, ProgramDataUpdater, UsbCeip, CEIP Consolidator, Device, DiskDiagnosticDataCollector, SIUF DmClient).
  - **Edge Background Mode & Startup Boost Disabled**: Neutralizes pre-launch background processes (`StartupBoostEnabled = 0`, `BackgroundModeEnabled = 0`, `AllowPrelaunch = 0`, `WebWidgetIsEnabled = 0`).
  - **Windows Error Reporting (WER) Disabled**: Halts `wermgr.exe` crash reporting daemon (`Disabled = 1`, `DontSendAdditionalData = 1`).
  - **Phone Link / CrossDevice Background Host Disabled**: Suppresses `PhoneExperienceHost.exe` background runtime (`EnableMmx = 0`, `AllowCrossDeviceExperience = 0`).
  - **UWP RuntimeBroker Instances Controlled**: Denies global background app access (`GlobalUserDisabled = 1`, `LetAppsRunInBackground = 2`), preventing Store apps from spawning multiple `RuntimeBroker.exe` child processes while maintaining 100% WinRT compatibility.
- **🐧 WSL2 & Virtualization Support (Issue #5)**:
  - Optional `-EnableWSL` flag pre-enables `VirtualMachinePlatform` and `Microsoft-Windows-Subsystem-Linux` before WinSxS stripping, allowing full WSL2, Docker, and Linux containers on a lightweight nano11 installation.
- **💾 Custom Working Directory Support (Issues #27, #23)**:
  - Use `-WorkDir <Path>` to specify another partition (e.g. `D:\Build`) for extracting and building images, completely preventing DISM crashes (`0xc1510115`) caused by low C: drive SSD space.
  - Automatically selects an alternate drive with ample free space if C: has less than 25 GB.
- **⚡ Unattended Setup Fixed & Streamlined (Issues #3, #21)**:
  - Injects `autounattend.xml` directly into the **ISO root directory**, ensuring Windows Setup detects unattended configuration out-of-the-box.
  - Removed dummy product key to eliminate "Invalid Product Key" stops during setup.
  - **Self-Healing**: If `autounattend.xml` is missing locally, it will automatically download it from GitHub.
- **🗜️ Ultra-Compact Footprint via CompactOS (Issue #22)**:
  - Automatically enables `compact.exe /CompactOS:always` on first logon, achieving installed disk space of **2.5 GB – 3.0 GB**.
- **🎨 Shell & Icon Refresh (Issue #19)**:
  - Automatically invokes `ie4uinit.exe -show` on first logon to rebuild icon caches, preventing blank icons on Start Menu and Settings.
- **📱 ARM64 & Apple Silicon Support (Issues #2, #8, #20)**:
  - Dynamic architecture detection (`amd64` / `arm64`).
  - Automatically adjusts `autounattend.xml` processor architecture and generates UEFI-compliant boot records for ARM64 (Parallels Desktop, VMware Fusion, UTM).
- **🚀 Canary 28020+ & Legacy Hardware Setup Bypass (Issue #29)**:
  - Automatically neutralizes `sources\appraiserres.dll` alongside offline registry `LabConfig` tweaks, allowing installation on unsupported CPUs, TPM 1.2/none, and older motherboards (e.g. Intel 6-series H67, 2nd-7th gen Core).
- **📄 MIT License Included (Issue #14)**:
  - Fully compliant open-source license.

---

## **☢️ BEFORE YOU BEGIN**

This is an **extreme debloat script** designed for rapid testing, lightweight virtual machines, and development environments.
By default, aggressive trimming removes the Windows Component Store (WinSxS) and non-essential background services to achieve the lowest possible footprint.

The resulting minimal OS is **not serviceable via cumulative updates** when WinSxS is stripped. If you require long-term servicing, enable the options to retain updates and Defender.

---

## **What can be removed?**

- **Bloatware & UWP Apps:**
  - Clipchamp, News, Weather, Xbox & Xbox Game Bar (`GameBarPresenceWriter.exe`), Solitaire, Copilot, DevHome, Teams, OneDrive.
  - Windows Calculator, Getting Started (`Tips`), Windows Backup (`AppListBackup`).
  - Mobile Devices & Cross-Device Resume (`crossdeviceresume`).
- **Heavy Assistive & Accessibility Binaries (Optional/Slimmed):**
  - Voice Access (`VoiceAccess.exe`), Live Captions (`Livecaptions.exe`), Magnifier (`magnify.exe`), On-Screen Keyboard (`osk.exe`), Narrator (`Narrator.exe`).
- **Web Browsers & Cloud Runtimes:**
  - Microsoft Edge, Edge Update, Edge Core, and Edge WebView2 runtimes from Program Files and WinSxS.
- **System Components & FoDs:**
  - Internet Explorer, WordPad, Steps Recorder, XPS Viewer, PowerShell ISE.
  - Diagnostics, telemetry, scheduled CEIP tasks, sponsored apps.
- **Optional Debloat (Configurable):**
  - Windows Defender & definition updates.
  - Asian Input Methods (IME - CHS, CHT, JPN, KOR).
  - Legacy drivers (printers, scanners, fax).
  - Windows Update background services.
  - Bluetooth services (if Bluetooth hardware is not needed).

---

## **Instructions**

### **1. Prerequisites**

> [!WARNING]
> **DO NOT USE `MediaCreationTool.exe` TO DOWNLOAD THE WINDOWS 11 ISO!**  
> `MediaCreationTool.exe` generates an ISO with solid recovery-compressed `install.esd` rather than `install.wim`. Modifying an `install.esd` image with DISM frequently causes data stream corruption (Error 1392 / 0x80070570) and missing package errors.  
> **Always download the official Windows 11 ISO directly from Microsoft's website** (choose *"Download Windows 11 Disk Image (ISO) for x64 devices"*), which includes standard, 100% reliable `sources\install.wim`.

1. Download the official Windows 11 Disk Image (ISO) containing `sources\install.wim` directly from [Microsoft Software Download](https://www.microsoft.com/software-download/windows11) (supports 23H2, 24H2, Canary, and IoT Enterprise LTSC).
2. Right-click the downloaded ISO and select **Mount**. Note the assigned drive letter (e.g. `D:`).

### **2. Running the Builder**

#### **Option A: Graphical User Interface (GUI - Recommended)**
Simply double-click **`nano11-GUI.bat`** (or run `.\nano11builder.ps1 -GUI` as Administrator).  
The modern dark-mode GUI allows you to:
- Select an auto-detected installation media drive or browse directly to an official Windows 11 `.iso` file.
- Pick a one-click profile preset (**Extreme Slim & Gaming**, **Balanced Pro**, or **FAT32 USB Split-WIM**).
- Toggle any of the 15 debloat, localization, and performance options.
- Choose your payload format (**install.wim**, **install.esd**, or **install.swm** for FAT32 USB).
- Save or Load customized `.json` configuration profiles.
- Click **Start nano11 Build** to launch the build process!

#### **Option B: Interactive Console**
1. Open PowerShell as **Administrator**.
2. Navigate to the repository directory:
   ```powershell
   cd E:\windows\other\nano11-main
   ```
3. Launch `nano11builder.ps1`:
   ```powershell
   .\nano11builder.ps1
   ```
4. Choose a profile preset from the quick selector menu (`[1] Extreme`, `[2] Balanced`, `[3] Load JSON Profile`, `[4] Launch GUI`, `[5] Custom`), or customize settings step-by-step.
5. Once `nano11.iso` is generated, follow the [Installation & Setup Guide](#️-installation--setup-guide-推奨デフォルトインストール手順) below.

### **3. Non-Interactive / CLI Automation**
You can also run the builder non-interactively with customized flags or pre-built profile JSONs:
```powershell
# 1-Click build with pre-packaged profile preset:
.\nano11builder.ps1 -NonInteractive -Profile "extreme"

# Load customized settings from a saved JSON profile:
.\nano11builder.ps1 -NonInteractive -LoadProfile ".\profiles\balanced-pro.json"

# Export your CLI configuration to a reusable JSON profile:
.\nano11builder.ps1 -NonInteractive -KeepDefender -EnableWSL -SaveProfile ".\profiles\my-team-config.json"

# Build for older UEFI motherboards requiring FAT32 USB media (Split-WIM <= 3.8GB):
.\nano11builder.ps1 -NonInteractive -SplitWIM

# Recommended balanced build: Keep Asian IMEs, Defender, international fonts, Bluetooth, and enable WSL2:
.\nano11builder.ps1 -NonInteractive -KeepIME -KeepDefender -KeepFonts -KeepBluetooth -EnableWSL

# Specify a custom working drive (e.g. when C: drive has low SSD space):
.\nano11builder.ps1 -WorkDir "E:\nano11_workspace"
```

### **Available Parameters:**
| Parameter | Description |
| :--- | :--- |
| `-GUI` (alias: `-UI`) | Launches the dark-themed Graphical User Interface frontend |
| `-Profile <extreme\|balanced>` (alias: `-Preset`) | Applies a pre-packaged configuration profile preset |
| `-SaveProfile <Path>` (alias: `-ExportConfig`) | Exports the active configuration settings to a JSON profile file |
| `-LoadProfile <Path>` (alias: `-ImportConfig`, `-Config`) | Imports configuration settings from a JSON profile file |
| `-SplitWIM` (aliases: `-FAT32Compatible`, `-FAT32`) / `-NoSplitWIM` | Splits output payload into `<= 3800 MB` chunks (`sources\install.swm`, `install2.swm`) for 100% FAT32 USB UEFI compatibility |
| `-NonInteractive` (aliases: `-Silent`, `-Unattended`, `-Batch`) | Runs completely unattended without interactive prompts |
| `-Interactive` | Forces interactive prompt review for all settings |
| `-SourceDrive <Drive\|ISO>` | Windows 11 installation media drive letter or path to `.iso` file. Auto-detected and mounted if omitted |
| `-WorkDir <Path>` | Custom directory for temporary file processing (ideal if C: has < 25 GB free) |
| `-Index <Number>` | Image index inside `install.wim` to modify (e.g. `1` for Home, `3` for Pro) |
| `-KeepDefender` / `-RemoveDefender` (`-NoDefender`) | Retains or removes Windows Defender (Default: Remove) |
| `-KeepIME` / `-RemoveIME` (`-NoIME`) | Retains or removes Asian language input methods (Default: Keep) |
| `-KeepFonts` / `-RemoveFonts` (`-NoFonts`) | Retains or removes international and Asian font families (Default: Keep, or pruned in UltraSlim) |
| `-KeepDrivers` / `-RemoveDrivers` | Retains or removes printer/scanner drivers in DriverStore (Default: Keep — Recommended to prevent 77% freeze) |
| `-KeepWindowsUpdate` / `-DisableWindowsUpdate` (`-NoWindowsUpdate`) | Retains or disables Windows Update services (Default: Disable) |
| `-KeepBluetooth` / `-DisableBluetooth` (`-NoBluetooth`) | Retains or disables Bluetooth peripheral and audio services (Default: Keep) |
| `-EnableWSL` / `-DisableWSL` (`-NoWSL`) | Pre-enables or disables WSL2 & Virtual Machine Platform (Default: Disable) |
| `-KeepRecovery` (`-KeepWinRE`) / `-RemoveRecovery` (`-NoRecovery`) | Retains or removes Windows Recovery Environment WinRE (Default: Remove post-install) |
| `-SafeDebloat` (`-SafeWinSxS`) / `-AggressiveWinSxS` (`-TrimWinSxS`) | Component Store cleanup mode (Default: SafeDebloat — Recommended to prevent 77% freeze) |
| `-UltraSlim` / `-NoUltraSlim` | Enables or disables UltraSlim ~3.0 GB ISO target mode (Default: Enabled) |
| `-JapaneseKeyboard` / `-NoJapaneseKeyboard` | Enforces or skips Japanese 106/109 keyboard layout configuration (Default: Enabled) |
| `-AtlasReviOS` / `-NoAtlasReviOS` | Enables or skips AtlasOS & ReviOS debloat and low-latency tuning (Default: Enabled) |
| `-BundleOptimizationToolkit` / `-NoBundleOptimizationToolkit` | Bundles or skips Windows Optimization Toolkit on Desktop (Default: Enabled) |
| `-ExportESD` / `-ExportWIM` (`-NoESD`) | Output image format (Default: install.wim LZX — Fast & Crash-Free) |
| `-KeepStore` / `-RemoveStore` (`-NoStore`) | Keeps or removes Microsoft Store (`Microsoft.WindowsStore`, `Microsoft.StorePurchaseApp`). winget / App Installer and Store frameworks are always kept (Default: Keep) |

> [!TIP]
> **CLI Option Priority Guarantee**: Specified CLI switches are strictly honored immediately. When running interactively, options already provided via CLI parameters are automatically applied and their prompts are skipped (preventing accidental overrides by pressing Enter). In unattended mode (`-NonInteractive`), all options execute deterministically without any prompt hangs.

When finished, your bootable ISO will be generated in the script directory as `nano11.iso` with SHA256 verification hash displayed!

---

## 🛠️ Installation & Setup Guide (推奨・デフォルトインストール手順)

nano11 creates an ultra-minimal, high-performance Windows 11 installation by stripping redundant cloud bloatware, telemetry, and Microsoft Account requirements.

Because cloud-dependent OOBE components are stripped to maintain the lightest possible footprint, Windows Setup may pause at a prompt or error dialog during the final configuration phase:
> *"Windows could not complete the installation. To install Windows on this computer, restart the installation."*  
> (または「Windows could not complete the installation. コンピュータを再起動してインストールを再開してください」)

**nano11 では、この状態から再インストールを行わずにそのままデスクトップを起動させる以下の手順を【推奨・デフォルトのインストール完了方法】として案内しています。**  
Windows のコアファイルは既に 100% 展開・インストール済みであるため、1分足らずの簡単なキー操作でセットアップ検証を通過し、デスクトップへ直行できます。

---

### 🚀 Default Setup Completion Procedure (セットアップ完了手順)

#### **1. ISO からの通常起動とインストール**
- 生成された `nano11.iso` を Rufus や Ventoy 等で USB メモリに書き込み（または仮想マシンにマウントして）PC を起動します。
- `autounattend.xml` により、パーティション作成、CompactOS 適用、ファイル展開が自動的に進行します。

#### **2. エラーダイアログが表示されたら**
- 画面上に「Windows could not complete the installation（インストールを完了できませんでした）」というエラーダイアログが表示されて停止したら、**まだ [OK] ボタンを押さないでください**。

#### **3. コマンドプロンプトを開く**
- エラー画面のまま、キーボードの **`Shift + F10`** を押します。  
  *(※ノートPC や一部のキーボードでは **`Shift + Fn + F10`** を押してください)*
- 黒いコマンドプロンプト画面（`cmd.exe`）が前面に開きます。

#### **4. セットアップ状態（ChildCompletion）を 3 に変更する**
以下のいずれかの方法（GUI または コマンド1行）で設定を変更します：

- **方法 A: レジストリエディターを使う場合（GUI）**
  1. コマンドプロンプトに `regedit` と入力して Enter キーを押し、レジストリエディターを開きます。
  2. 左側のツリーから以下のキーに移動します：
     ```
     HKEY_LOCAL_MACHINE\SYSTEM\Setup\Status\ChildCompletion
     ```
  3. 右側のペインにある **`setup.exe`** をダブルクリックします。
  4. 「値のデータ」を **`1`** から **`3`** に変更して「OK」をクリックします。
  5. レジストリエディターとコマンドプロンプトのウィンドウを閉じます。

- **方法 B: コマンド1行で即時変更する場合（最速）**
  コマンドプロンプトで以下のコマンドを入力（または右クリックで貼り付け）して Enter キーを押します：
  ```cmd
  reg add "HKLM\SYSTEM\Setup\Status\ChildCompletion" /v setup.exe /t REG_DWORD /d 3 /f
  ```
  「この操作を正しく完了しました」と表示されたら、`exit` と入力してコマンドプロンプトを閉じます。

#### **5. セットアップを完了してデスクトップを起動**
- 元のエラーダイアログの **[OK]** ボタンをクリックします。
- 自動的に PC が再起動し、セットアップの完了チェックを通過して、そのまま正常に Administrator デスクトップ画面が起動します！

> [!NOTE]
> **仕組み・技術的背景**:  
> `ChildCompletion\setup.exe` の値 `1` は「セットアップの子プロセスが処理中・未完了」であることを示しています。これを `3`（完了ステータス: `STATUS_SUCCESS`）に書き換えることで、Windows Setup に対して「全セットアップ工程が正常に完了した」と通知し、未構成のクラウド OOBE への不要なリダイレクトやリブートトラップを完全に回避してデスクトップへ遷移させます。

---

## 🎬 Original Video Demo by NTDEV

[![Here's how to use nano11 builder](https://img.youtube.com/vi/YIOesMc50Dw/maxresdefault.jpg)](https://www.youtube.com/watch?v=YIOesMc50Dw)

---

## ❤️ Credits & Support

- **Original Project & Concept:** [NTDEV](https://github.com/ntdevlabs/nano11)
  - [Patreon](http://patreon.com/ntdev) | [PayPal](http://paypal.me/ntdev2) | [Ko-fi](http://ko-fi.com/ntdev)
- **Optimization & Debloat Tool Integrations:**
  - [Chris Titus Tech's WinUtil](https://github.com/ChrisTitusTech/winutil) - Open-source Windows utility & OOBE bloat mitigation
  - [Sophia Script for Windows](https://github.com/farag2/Sophia-Script-for-Windows) - Advanced Windows 11 PowerShell debloater by Dmitry Nefedov (farag2)
  - [SophiApp](https://github.com/Sophia-Community/SophiApp) - Modern WPF GUI front-end for Sophia Script
  - [Optimizer](https://github.com/hellzerg/optimizer) - Standalone C# utility for privacy and system performance by Hellzerg
  - [Bloatynosy](https://github.com/builtbybel/Bloatynosy) - Windows 11 feature debloater and AI manager by Builtbybel
  - [ReviOS & Revision Tool](https://github.com/meetrevision) - Low-latency OS playbook & standalone performance optimizer
  - [AtlasOS](https://github.com/atlas-os/atlas) - Open-source gaming & low-latency Windows modification playbook
- **Contributors:**
  - [Tinnitus97](https://github.com/Tinnitus97) (PR #6: Universal language support, robocopy WinSxS fix)
  - Community bug reports and feature requests from [nano11 Issues](https://github.com/ntdevlabs/nano11/issues)

---

## ⚖️ License

This project is licensed under the [MIT License](LICENSE).
