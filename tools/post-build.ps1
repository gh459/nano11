#Requires -Version 5.1
<#
.SYNOPSIS
    Post-Build Hook for nano11 Builder.
    Executed automatically on the host system after bootable ISO generation and validation.
.PARAMETER IsoPath
    Full path to the generated nano11 ISO.
.PARAMETER IsoHash
    SHA256 checksum of the generated ISO.
.PARAMETER Profile
    Name of the configuration profile applied during build.
.PARAMETER LogDir
    Directory containing build logs and reports.
#>
param(
    [string]$IsoPath,
    [string]$IsoHash,
    [string]$Profile,
    [string]$LogDir
)

Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "       nano11 Post-Build Lifecycle Hook Triggered        " -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "  - Output ISO : $IsoPath"
Write-Host "  - SHA256     : $IsoHash"
Write-Host "  - Profile    : $Profile"
Write-Host "  - Logs       : $LogDir"

# Optional User Automation Examples:
# 1. Copy ISO to a local network share / NAS:
#    Copy-Item -LiteralPath $IsoPath -Destination "\\NAS\ISOs\nano11.iso" -Force
# 2. Write ISO metadata / checksum to build archive:
#    "$IsoPath`t$IsoHash`t$Profile`t$([DateTime]::UtcNow.ToString('o'))" | Out-File (Join-Path $LogDir "build-checksums.txt") -Append

Write-Host "Post-build hook completed successfully." -ForegroundColor Green
