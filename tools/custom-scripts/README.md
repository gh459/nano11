# Custom Post-Install Scripts Hook (`tools/custom-scripts`)

nano11 supports executing custom user scripts automatically after Windows installation completes.

## How to Use
Place any custom automation scripts or registry files inside this directory (`tools/custom-scripts/`):
- `.ps1` (PowerShell scripts)
- `.bat` / `.cmd` (Batch scripts)
- `.reg` (Registry import files)

## How It Works
1. When `nano11builder.ps1` builds the Windows 11 image, it automatically copies all files in this directory into the offline image under:
   `C:\Windows\Setup\Scripts\Custom\`
2. During the first user login (`FirstLogon.ps1`), all scripts in this directory are executed sequentially in alphabetical order with administrator privileges.
3. This `README.md` file is automatically ignored during the build process.

## Examples
- `01-install-tools.ps1`: Run `winget install ...` or custom PowerShell automation.
- `02-apply-network-settings.cmd`: Run custom IP or route configurations.
- `03-custom-branding.reg`: Import custom corporate or personal registry policies.
