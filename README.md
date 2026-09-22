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
  - **Keep Asian IMEs**: Retain Japanese, Chinese (Simplified/Traditional), and Korean input methods (Default: Keep).
  - **Windows Defender Toggle**: Option to keep Windows Defender active or remove it completely.
  - **Fonts & Drivers**: Option to preserve international font collections and essential hardware drivers.
  - **Windows Update**: Option to keep Windows Update enabled or disabled.
  - **Bluetooth & Audio**: Preserves Bluetooth audio transport and peripheral services by default so wireless headphones and controllers function properly.
  - **Recovery Environment (WinRE)**: Retain Windows RE with `-KeepRecovery` or `-KeepWinRE`. By default, WinRE is kept intact during installation so Windows Setup SafeOS staging succeeds 100%, then safely disabled and deleted online on first logon.
- **🔧 Windows 11 Installation Failure Fixed (Resolves Issue #11 & Setup Rollbacks)**:
  - **Setup Pre-Finalize SafeOS Crash Fixed**: Solved the `0x80070002` / `0x8007000B` error where Windows Setup crashes at ~100% when attempting to stage missing or corrupt `winre.wim`. `winre.wim` is preserved at build time and removed cleanly via online `reagentc /disable` during `FirstLogon.ps1`.
  - **SafeDebloat Component Store Mode (Default)**: Protects CBS servicing integrity and localized (`ja-JP`) resources using official DISM `StartComponentCleanup /ResetBase` + cache pruning. Aggressive pruning mode (`-AggressiveWinSxS`) is also available with comprehensive core system and language preservation.
  - **Administrator Account Auto-Activation**: Explicitly activates the built-in Administrator account in `Specialize.ps1` for seamless unattended setup across Windows 11 Home and Pro editions.
  - **Setup Script Pre-Extraction**: Unattend scripts (`Specialize.ps1`, `DefaultUser.ps1`, etc.) are pre-extracted directly into the image during build time with robust `try/catch` error shielding, preventing specialize pass aborts.
  - **Bootable WIM Exports**: Added `/Bootable` flag to all `boot.wim` exports to prevent `0xc1510115` errors across all UEFI/BIOS firmware.
- **💿 Robust ISO Generation & Boot Sector Auto-Recovery**:
  - **Auto-Discovery & Fallback**: Searches for `etfsboot.com` and `efisys.bin` / `efisys_noprompt.bin` across candidate paths, automatically copying from source installation media if missing.
  - **Dynamic Bootdata**: Seamlessly builds Dual-Boot (BIOS + UEFI), UEFI-only, or BIOS-only boot parameters based on available bootloaders.
  - **Robocopy Mirroring**: Uses `robocopy` with `Copy-Item` fallback to ensure 100% of directory structures and boot files are preserved from read-only ISO media.
  - **Build Integrity & Safe Cleanup**: Validates output ISO existence and size (> 1 MB), captures `oscdimg` exit codes, displays SHA256 checksums, and preserves the working directory upon error for troubleshooting.
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
- **⚡ Radical RAM Optimization (Idle Memory Baseline ~1.0 GB – 1.3 GB)**:
  - **SvcHost Grouping**: Sets `SvcHostSplitThresholdInKB` to 64 GB, consolidating 70–90 separate `svchost.exe` instances into 12–15 shared processes, instantly freeing 500 MB – 800 MB of RAM.
  - **Kernel Memory Manager & Page Combining**: Enables `PageCombining` (NT kernel COW memory deduplication) via MMAgent and sets paged pool trim threshold (`PoolUsageMaximum = 60`) while prioritizing application working sets over file system cache (`LargeSystemCache = 0`).
  - **DWM & Visual Effects Lightweighting**: Disables window transparency (Acrylic/Mica) and animations while preserving ClearType font smoothing, reducing `dwm.exe` render target buffers.
  - **Service Pruning & Demand-Start**: Disables memory-heavy background services (`SysMain`, `WSearch`, `FontCache`, `DoSvc`, `DPS`, `WdiServiceHost`, `DusmSvc`) and configures non-essential daemons (`LanmanServer`, `ShellHWDetection`, `stisvc`) to demand-start.
  - **Automated Post-Boot Working Set Trimming**: Automatically invokes Win32 `EmptyWorkingSet` and garbage collection at the end of `FirstLogon.ps1` to reclaim one-time setup heap allocations.
- **🛠️ Robust DISM & ISO Generation**:
  - Automatically repairs orphaned DISM mount points on startup (`dism /Cleanup-Wim`).
  - Handles single-index and dual-index `boot.wim` structures seamlessly.
  - Generates ISO with proper volume label (`-l"nano11"`) and outputs SHA256 verification hash.
- **📄 MIT License Included (Issue #14)**:
  - Fully compliant open-source license.

---

## **☢️ BEFORE YOU BEGIN**

This is an **extreme debloat script** designed for rapid testing, lightweight virtual machines, and development environments.
By default, aggressive trimming removes the Windows Component Store (WinSxS) and non-essential background services to achieve the lowest possible footprint.

The resulting minimal OS is **not serviceable via cumulative updates** when WinSxS is stripped. If you require long-term servicing, enable the options to retain updates and Defender.

---

## **What can be removed?**

- **Bloatware & UWP Apps:** Clipchamp, News, Weather, Xbox, Solitaire, Copilot, DevHome, Teams, OneDrive, etc.
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
