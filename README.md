# **nano11 🔬**

A PowerShell script to build a heavily trimmed-down, lightning-fast Windows 11 image.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Architecture: x64 | ARM64](https://img.shields.io/badge/Architecture-x64%20%7C%20ARM64-blue.svg)](#)
[![OS: Windows 11 23H2 / 24H2 / LTSC](https://img.shields.io/badge/Windows%2011-23H2%20%7C%2024H2%20%7C%20LTSC-brightgreen.svg)](#)

---

## **Introduction**

Introducing **nano11 builder**, a powerful PowerShell script that creates an ultra-minimal Windows 11 image!

The goal of nano11 is to automate the creation of a streamlined Windows 11 image. The script uses native DISM capabilities and the official `oscdimg.exe` (downloaded automatically) to create a bootable ISO with no third-party binary dependencies. An included unattended answer file bypasses Microsoft Account requirements during setup, enables automatic local administrator logon, and configures a clean, bloatware-free desktop.

---

## **✨ Features & Improvements in this Fork**

- **🌐 Universal Language Independence (PR #6 by Tinnitus97)**:
  - Works on any host operating system language/locale without permission or translation errors.
  - Replaces localized tools (`takeown`/`icacls`) with native .NET Access Control Lists (`Set-Acl` via Well-Known Administrator SID `S-1-5-32-544`).
- **🛡️ Customization Options (Issues #9, #10, #12, #13)**:
  - **Keep Asian IMEs**: Choose whether to retain Japanese, Chinese (Simplified/Traditional), and Korean input methods.
  - **Windows Defender Toggle**: Option to keep Windows Defender active or remove it completely.
  - **Fonts & Drivers**: Option to preserve international font collections and essential hardware drivers.
  - **Windows Update**: Option to keep Windows Update enabled or disabled.
- **⚡ Unattended Setup Fixed (Issue #21)**:
  - Automatically injects `autounattend.xml` directly into the **ISO root directory**, ensuring Windows Setup detects and executes unattended setup out-of-the-box.
- **📱 ARM64 & UEFI Support (Issues #2, #8, #20)**:
  - Dynamic architecture detection (`amd64` / `arm64`).
  - Automatically adjusts `autounattend.xml` processor architecture and generates UEFI-compliant boot records for ARM64.
- **🛠️ Installation Failure Fixes (Issues #4, #11, #17, #28)**:
  - Prevents "Windows 11 installation has failed" errors on Windows 11 24H2 and IoT Enterprise LTSC 2024 by properly preserving essential Servicing Stack and Windows Foundation components.
  - Fixes WinSxS permission issues using the safe robocopy mirror technique.
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

---

## **Instructions**

### **1. Prerequisites**
1. Download a Windows 11 ISO from the official Microsoft website (supports 23H2, 24H2, and IoT Enterprise LTSC).
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
# Keep Asian IMEs, Defender, and international fonts:
.\nano11builder.ps1 -NonInteractive -KeepIME -KeepDefender -KeepFonts

# Full aggressive debloat without prompts:
.\nano11builder.ps1 -NonInteractive
```

### **Available Parameters:**
| Parameter | Description |
| :--- | :--- |
| `-NonInteractive` | Runs without interactive confirmation prompts |
| `-KeepIME` | Retains Asian language input methods (Japanese, Chinese, Korean) |
| `-KeepDefender` | Retains Windows Defender and related services |
| `-KeepFonts` | Retains international and Asian font families |
| `-KeepDrivers` | Retains printer, scanner, and legacy drivers in DriverStore |
| `-KeepWindowsUpdate` | Retains Windows Update services and registry endpoints |

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
