# **nano11 🔬**

A PowerShell script to build a heavily trimmed-down, lightning-fast Windows 11 image.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Architecture: x64 | ARM64](https://img.shields.io/badge/Architecture-x64%20%7C%20ARM64-blue.svg)](#)
[![OS: Windows 11 23H2 / 24H2 / LTSC / Canary](https://img.shields.io/badge/Windows%2011-23H2%20%7C%2024H2%20%7C%20LTSC%20%7C%20Canary-brightgreen.svg)](#)

---

## **Introduction**

Introducing **nano11 builder**, a powerful PowerShell script that creates an ultra-minimal Windows 11 image!

The goal of nano11 is to automate the creation of a streamlined Windows 11 image. The script uses native DISM capabilities and the official `oscdimg.exe` (downloaded automatically) to create a bootable ISO with no third-party binary dependencies. An included unattended answer file bypasses Microsoft Account requirements during setup, enables automatic local administrator logon, and configures a clean, bloatware-free desktop.

---

## **✨ Features & Improvements in this Fork**

- **🌐 Universal Language Independence (PR #6 by Tinnitus97)**:
  - Works on any host operating system language/locale without permission or translation errors.
  - Replaces localized tools (`takeown`/`icacls`) with native .NET Access Control Lists (`Set-Acl` via Well-Known Administrator SID `S-1-5-32-544`).
- **🛡️ Customization Options (Issues #1, #9, #10, #12, #13)**:
  - **Keep Asian IMEs**: Choose whether to retain Japanese, Chinese (Simplified/Traditional), and Korean input methods (Default: Keep).
  - **Windows Defender Toggle**: Option to keep Windows Defender active or remove it completely.
  - **Fonts & Drivers**: Option to preserve international font collections and essential hardware drivers.
  - **Windows Update**: Option to keep Windows Update enabled or disabled.
  - **Bluetooth & Audio**: Preserves Bluetooth audio transport and peripheral services by default so wireless headphones and controllers function properly.
- **💾 Custom Working Directory Support (Issues #27, #23)**:
  - Use `-WorkDir <Path>` to specify another partition (e.g. `D:\Build`) for extracting and building images, completely preventing DISM crashes (`0xc1510115`) caused by low C: drive SSD space.
  - Automatically selects an alternate drive with ample free space if C: has less than 25 GB.
- **⚡ Unattended Setup Fixed (Issue #21)**:
  - Automatically injects `autounattend.xml` directly into the **ISO root directory**, ensuring Windows Setup detects and executes unattended setup out-of-the-box.
  - **Self-Healing**: If `autounattend.xml` is missing locally (e.g. script downloaded standalone), it will automatically download it from GitHub.
- **📱 ARM64 & UEFI Support (Issues #2, #8, #20)**:
  - Dynamic architecture detection (`amd64` / `arm64`).
  - Automatically adjusts `autounattend.xml` processor architecture and generates UEFI-compliant boot records for ARM64.
- **🚀 Canary 28020+ & Legacy Hardware Setup Bypass (Issue #29)**:
  - Automatically neutralizes `sources\appraiserres.dll` alongside offline registry `LabConfig` tweaks, allowing installation on unsupported CPUs, TPM 1.2/none, and older motherboards (e.g. Intel 6-series H67, 2nd-7th gen Core).
- **🛠️ Installation Failure Fixes (Issues #4, #11, #17, #28)**:
  - Prevents "Windows 11 installation has failed" errors on Windows 11 24H2 and IoT Enterprise LTSC 2024 by properly preserving essential Servicing Stack and Windows Foundation components.
  - Fixes WinSxS permission issues using the safe robocopy mirror technique.
  - Automatically repairs orphaned DISM mount points on startup (`dism /Cleanup-Wim`).
- **📦 Support for `install.esd`**:
  - Automatically detects `install.esd` in media and exports it to `install.wim` on-the-fly.
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
# Recommended balanced build: Keep Asian IMEs, Defender, international fonts, and Bluetooth:
.\nano11builder.ps1 -NonInteractive -KeepIME -KeepDefender -KeepFonts -KeepBluetooth

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

When finished, your bootable ISO will be generated in the script directory as `nano11.iso`!

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
