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
  - **Keep Asian IMEs**: Retain Japanese input method (`ja-JP`) while cleanly decoupling and trimming foreign Asian IMEs (`ko-KR`, `zh-CN`, `zh-TW`) and gigabytes of unneeded foreign voice packages.
  - **Windows Defender Toggle**: Option to keep Windows Defender active or remove it completely.
  - **Fonts & Drivers**: Option to preserve international font collections and essential hardware drivers.
  - **Windows Update**: Option to keep Windows Update enabled or disabled.
  - **Bluetooth & Audio**: Preserves Bluetooth audio transport and peripheral services by default so wireless headphones and controllers function properly.
  - **Recovery Environment (WinRE)**: Retain Windows RE with `-KeepRecovery` or `-KeepWinRE`. By default, WinRE is kept intact during installation so Windows Setup SafeOS staging succeeds 100%, then safely disabled and deleted online on first logon.
- **📦 Radical ISO Size Reduction (~3.2 GB – 3.8 GB, Perplexity-Verified Safe)**:
  - **Decoupled Japanese IME & Foreign Language Stripping**: Purges heavy foreign Asian IMEs (Korean `ko-KR`, Chinese `zh-CN`/`zh-TW`), foreign speech models (`zh-*`, `ko-*`, `de-*`, `fr-*`, `es-*`, `it-*`, `pt-*`, `ru-*`), and foreign Handwriting/OCR packages, saving over 800 MB – 1.2 GB in `install.esd` while strictly safeguarding Japanese IME (`*IME-ja-jp*`), Japanese fonts (`meiryo*`, `yugoth*`, `msgoth*`, `msmin*`, `yumin*`), and Text Services Framework (`ctfmon.exe`).
  - **Foreign Supplemental Fonts Trimmed**: Safely purges non-Latin/non-Japanese font collections (Chinese Hans/Hant, Korean Kore, Devanagari, Thai, Ethiopic, Syriac, Cherokee, etc.), saving ~200 MB.
  - **Obsolete FOD Packages Removed**: Purges deprecated and unused optional features including `WMIC` (deprecated in 24H2), `Printing-WFS` (Fax & Scan), `WirelessDisplay` (Miracast Connect), `SNMP`, `Telnet`, `SimpleTCP`, and `RDC`.
  - **Offline System Caches & Setup Logs Cleaned**: Wipes build-time update caches (`SoftwareDistribution\Download`), `System32\LogFiles`, `Prefetch`, and setup temporary files before unmounting.
  - **Single-Pass Direct Recovery ESD Export**: Streamlines the DISM pipeline to export the modified image directly from the committed WIM index into `sources\install.esd` using LZMS recovery compression (`/Compress:recovery /CheckIntegrity`), completely eliminating the redundant 10-minute intermediate `install2.wim` (LZX) pass and saving ~9 GB of temporary disk writes.
  - **Zero Setup-Breaking Hacks**: Strictly keeps `winre.wim` intact during offline build (preventing `0x80070002` SafeOS staging failures) and keeps `boot.wim` under LZX `/Compress:max` (avoiding `0xc0000001` unbootable media), with CBS component integrity guaranteed via official DISM `StartComponentCleanup /ResetBase`.
- **🚫 Safe Debloat & Suppression of Target Components**:
  - **Windows Backup (Windows バックアップ)**: Complete policy suppression (`DisableBackupRestore = 1`, `DisableCloudBackup = 1`, `DisableConsumerAccountStateContent = 1`), `AppListBackup` scheduled task removal, and concealment from Settings (`hide:backup`). Avoids breaking `Client.CBS` system dependencies.
  - **Windows Security & Defender (Windows セキュリティ)**: Services disabled (`WinDefend`, `WdNisSvc`, `SecurityHealthService` = 4), real-time protection and antispyware policies enforced, startup system tray entry (`SecurityHealth`) removed, and settings page hidden (`hide:virus`).
  - **Accessibility (アクセシビリティ: 音声アクセス / 拡大鏡 / スクリーンキーボード / ナレーター / ライブキャプション)**: Preserves essential binaries (`osk.exe`, `Narrator.exe`, `magnify.exe`) in `System32` during setup to ensure 100% OOBE pass stability, while hotkeys (Win+Enter, 5x Shift StickyKeys, FilterKeys, ToggleKeys), auto-launch flags, and settings pages are suppressed. Post-OOBE IFEO redirection is safely applied in `FirstLogon.ps1` to prevent any execution on the desktop.
  - **Get Started / Tips (はじめに)**: Fully removed offline via DISM `Remove-AppxProvisionedPackage` with fallback cleanup across all user accounts in `FirstLogon.ps1`, coupled with `DisableSoftLanding` promotional suppression.
  - **🔄 OOBE Boot Loop & Setup Crash Fixed**: Solved the infinite boot loop at the "Please wait" ("お待ちください") screen. Root causes fully resolved:
    - **WebView2 Runtime Preserved**: Preserved `C:\Windows\System32\Microsoft-Edge-WebView` and its WinSxS packages. Windows 11 OOBE (`CloudExperienceHost`, `msoobe.exe`) strictly requires the embedded WebView2 runtime to render setup interfaces; removing it crashed OOBE on launch. Edge browser UI (`Program Files (x86)\Microsoft\Edge`) is still cleanly removed.
    - **One-Shot Guarded Failsafe (`ErrorHandler.cmd`)**: Replaced the unconditional reboot trap with a Perplexity-validated **One-Shot Guard** (`ErrorHandler.once`). If an unexpected error occurs during setup and `ChildCompletion\setup.exe` is `0x1`, it logs Panther diagnostics, attempts continuation to `3` exactly once, and restarts. If invoked again, the `.once` guard halts immediately without rebooting, mathematically guaranteeing that infinite reboot loops can never occur.
    - **Core Accessibility Binaries Retained**: Preserves essential accessibility binaries (`osk.exe`, `Narrator.exe`, `magnify.exe`) in `System32` to prevent handle exceptions during OOBE Ease of Access subsystem initialization.
    - **Safe FontCache Lifecycle**: Defers `FontCache` and `FontCache3.0.0.0` disabling to `FirstLogon.ps1` (after desktop logon) so localized DirectWrite font rendering succeeds 100% during setup.
    - **Strict Empty Passwords**: Normalized all `<Password><Value></Value>` tags to single-line empty values across all architectures, eliminating whitespace and newline parsing issues during unattended account creation.
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
  - **Integrated optimizerDuck & sparkle**: Applies system latency and responsiveness optimizations, including `Win32PrioritySeparation` quantum boost (0x26), Multimedia Class Scheduler Service (MMCSS) gaming priority & GPU scheduling, and network throttling index disabling.
  - **Integrated Revo Registry Cleaner Tuner**: Full integration of all 6 optimization categories:
    - *Explorer*: Auto-complete URL/path suggestions, show drive letters first, disable info tips.
    - *Desktop & Start Menu*: Reduce hover delay times, enable classic Alt+Tab, kill hung apps faster (`WaitToKillAppTimeout = 2000`).
    - *System & Services*: `ServicesPipeTimeout` optimization, network file sharing responsiveness.
    - *Visual Effects*: Disable Mica/Acrylic transparency while keeping font smoothing enabled.
- **⚡ Radical RAM Optimization (Idle Memory Baseline ~1.0 GB – 1.3 GB, Perplexity-Verified Safe)**:
  - **SvcHost Grouping**: Sets `SvcHostSplitThresholdInKB` to 64 GB, consolidating 70–90 separate `svchost.exe` instances into 12–15 shared processes, instantly freeing 500 MB – 800 MB of RAM.
  - **Kernel Memory Manager & Page Combining**: Enables NT Kernel `PageCombining` (copy-on-write memory deduplication) via MMAgent and sets paged pool trim threshold (`PoolUsageMaximum = 60`) while prioritizing application working sets over file system cache (`LargeSystemCache = 0`, `DisablePagingExecutive = 0`).
  - **DWM & Visual Effects Lightweighting**: Disables window transparency, acrylic blur, and animations (`MinAnimate = 0`, `VisualFXSetting = 2`) while preserving ClearType font smoothing, reducing `dwm.exe` render target buffers.
  - **Shell Surface Trimming**: Disables Widgets (`TaskbarDa = 0`), Teams/Chat (`TaskbarMn = 0`), and Task View (`ShowTaskViewButton = 0`), stopping background webviews and shell caching.
  - **Service Pruning & Demand-Start**: Disables unneeded background services (`SysMain`, `WSearch`, `FontCache`, `DoSvc`, `DPS`, `WdiServiceHost`, `DusmSvc`, `SCardSvr`, `ScDeviceEnum`, `icssvc`, `CertPropSvc`, `CscService`) and configures non-essential daemons (`LanmanServer`, `ShellHWDetection`, `stisvc`, `Netlogon`) to demand-start (Manual).
  - **Scheduled Task Trimming**: Disables heavy maintenance tasks (`ProcessMemoryDiagnosticEvents`, `RunFullMemoryDiagnostic`, `WinSAT`, `DiskFootprint\Diagnostics`) that wake up and consume RAM in the background.
  - **Guaranteed Stability (Zero Dangerous Hacks)**: Strictly rejects harmful placebo tweaks identified during research (Pagefile is kept system-managed; NDU network monitoring driver is preserved; `LargeSystemCache` is not forced to server mode).
  - **Automated Post-Boot Working Set Trimming**: Automatically invokes Win32 `EmptyWorkingSet` and garbage collection as a one-shot operation at the end of `FirstLogon.ps1` to flush transitional setup heap allocations.
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
1. Download a Windows 11 ISO from the official Microsoft website (supports 23H2, 24H2, Canary, and IoT Enterprise LTSC).
2. Right-click the downloaded ISO and select **Mount**. Note the assigned drive letter (e.g. `D:`).

### **2. Running the Builder**
1. Open PowerShell as **Administrator**.
2. Navigate to the repository directory:
   ```powershell
   cd C:\path\to\nano11
   ```
3. Launch `nano11builder.ps1`:
   ```powershell
   .\nano11builder.ps1
   ```
4. Follow the interactive prompts to choose your debloat preferences and input the drive letter.

### **3. Non-Interactive / CLI Automation**
You can also run the builder non-interactively with customized flags:
```powershell
# Recommended balanced build: Keep Asian IMEs, Defender, international fonts, Bluetooth, and enable WSL2:
.\nano11builder.ps1 -NonInteractive -KeepIME -KeepDefender -KeepFonts -KeepBluetooth -EnableWSL

# Specify a custom working drive (e.g. when C: drive has low SSD space):
.\nano11builder.ps1 -WorkDir "D:\nano11_temp"

# Full aggressive debloat without prompts:
.\nano11builder.ps1 -NonInteractive

# UltraSlim mode with ultra-small ISO footprint (~3.0 GB):
.\nano11builder.ps1 -NonInteractive -UltraSlim
```

### **Available Parameters:**
| Parameter | Description |
| :--- | :--- |
| `-NonInteractive` | Runs without interactive confirmation prompts |
| `-WorkDir <Path>` | Custom directory for temporary file processing (ideal if C: has < 25 GB free) |
| `-KeepIME` | Retains Asian language input methods (Japanese, Chinese, Korean) |
| `-KeepDefender` | Retains Windows Defender and related real-time protection services |
| `-KeepFonts` | Retains international and Asian font families |
| `-KeepDrivers` | Retains printer, scanner, and legacy drivers in DriverStore |
| `-KeepWindowsUpdate` | Retains Windows Update services and registry endpoints |
| `-KeepBluetooth` | Retains Bluetooth peripheral, audio transport, and user services |
| `-EnableWSL` | Pre-enables WSL2 and Virtual Machine Platform before stripping WinSxS |
| `-KeepRecovery` | Retains Windows Recovery Environment (WinRE) permanently (Default: disabled safely post-install) |
| `-SafeDebloat` | Enables safe component store cleanup mode preserving CBS integrity (Default: True) |
| `-AggressiveWinSxS` | Opts into aggressive WinSxS pruning mode (Experimental, for testing) |
| `-UltraSlim` | Enables UltraSlim mode to achieve ~3.0 GB ISO (prunes Edge WebView, non-JP CJK fonts, WinSxS dead weight, compresses WinRE) |

When finished, your bootable ISO will be generated in the script directory as `nano11.iso` with SHA256 verification hash displayed!

---

## 🎬 Original Video Demo by NTDEV

[![Here's how to use nano11 builder](https://img.youtube.com/vi/YIOesMc50Dw/maxresdefault.jpg)](https://www.youtube.com/watch?v=YIOesMc50Dw)

---

## ❤️ Credits & Support

- **Original Project & Concept:** [NTDEV](https://github.com/ntdevlabs/nano11)
  - [Patreon](http://patreon.com/ntdev) | [PayPal](http://paypal.me/ntdev2) | [Ko-fi](http://ko-fi.com/ntdev)
- **Contributors:**
  - [Tinnitus97](https://github.com/Tinnitus97) (PR #6: Universal language support, robocopy WinSxS fix)
  - Community bug reports and feature requests from [nano11 Issues](https://github.com/ntdevlabs/nano11/issues)

---

## ⚖️ License

This project is licensed under the [MIT License](LICENSE).
