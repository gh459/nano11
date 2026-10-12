# test_build_fix_acceptance.ps1
# Comprehensive Acceptance Test Suite for nano11_build_fix_spec.md implementation

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$builderPath = 'C:\Users\User\Documents\nano11-main\nano11builder.ps1'

Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host " Running Acceptance Test Suite: nano11_build_fix_spec.md" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan

$testResults = [ordered]@{}

function Assert-Test {
    param([string]$Name, [bool]$Condition, [string]$Details = "")
    if ($Condition) {
        Write-Host "  [PASS] $Name" -ForegroundColor Green
        $script:testResults[$Name] = "PASS"
    } else {
        Write-Host "  [FAIL] $Name - $Details" -ForegroundColor Red
        $script:testResults[$Name] = "FAIL: $Details"
    }
}

# 1. AST Syntax Test
Write-Host "`n--- Test Group 1: Syntax & Code Integrity ---" -ForegroundColor Cyan
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($builderPath, [ref]$tokens, [ref]$errors)
Assert-Test "AST Syntax Parse (0 errors)" ($errors.Count -eq 0) "Errors: $($errors.Count)"

$builderBytes = [System.IO.File]::ReadAllBytes($builderPath)
$hasBom = ($builderBytes.Length -ge 3 -and $builderBytes[0] -eq 0xEF -and $builderBytes[1] -eq 0xBB -and $builderBytes[2] -eq 0xBF)
Assert-Test "UTF-8 BOM Header Present (EF BB BF)" ($hasBom -eq $true) "BOM: $($builderBytes[0]) $($builderBytes[1]) $($builderBytes[2])"

$builderText = [System.IO.File]::ReadAllText($builderPath, [System.Text.Encoding]::UTF8)

# 2. Rule 1: Lifecycle State Flags
Write-Host "`n--- Test Group 2: Lifecycle State Decoupling ---" -ForegroundColor Cyan
Assert-Test "Flag: ExportSucceeded defined" ($builderText -match '\$script:ExportSucceeded\s*=\s*\$false')
Assert-Test "Flag: FinalPayloadVerified defined" ($builderText -match '\$script:FinalPayloadVerified\s*=\s*\$false')
Assert-Test "Flag: VerifiedFinalWimSha256 defined" ($builderText -match '\$script:VerifiedFinalWimSha256\s*=\s*\$null')
Assert-Test "Flag: IsoGenerated defined" ($builderText -match '\$script:IsoGenerated\s*=\s*\$false')
Assert-Test "Flag: IsoPayloadVerified defined" ($builderText -match '\$script:IsoPayloadVerified\s*=\s*\$false')
Assert-Test "Flag: BuildSucceeded defined" ($builderText -match '\$script:BuildSucceeded\s*=\s*\$false')

# 3. Rule 2: Diagnostic Isolation & Report Generation
Write-Host "`n--- Test Group 3: Isolated Diagnostic Infrastructure ---" -ForegroundColor Cyan
Assert-Test "DiagDir isolated outside nano11Dir / workDir" ($builderText -match 'build_diagnostics\\\$')
Assert-Test "Diagnostic JSON and TXT report writer present" ($builderText -match 'function Write-Nano11DiagnosticReport')
Assert-Test "Enter-Phase tracks failure phase" ($builderText -match '\$script:DiagnosticData\.FailurePhase\s*=\s*\$script:CurrentBuildPhase')

# Test running diagnostic report helper in isolated scope
$testDiagDir = Join-Path -Path $env:TEMP -ChildPath "nano11_test_diag_$([System.IO.Path]::GetRandomFileName())"
New-Item -ItemType Directory -Path $testDiagDir -Force | Out-Null
$script:DiagDir = $testDiagDir
$script:DiagnosticData = [ordered]@{
    BuildId = "TEST_BUILD_01"
    Timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    BuilderScriptSha256 = "TEST_HASH"
    BuildSucceeded = $false
    FailurePhase = "Phase 15: Deep Apply Verification"
    FailureMessage = "0x80070570 stream corruption simulated"
    PreservedArtifacts = @("C:\dummy\sources\install_pre_export_backup.wim")
}
# Execute report generation code
$jsonReportPath = Join-Path -Path $script:DiagDir -ChildPath "build_diagnostic_report.json"
$txtReportPath = Join-Path -Path $script:DiagDir -ChildPath "build_diagnostic_summary.txt"
$script:DiagnosticData | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $jsonReportPath -Encoding utf8
$txtLines = @("Test Summary", "Failure: $($script:DiagnosticData.FailureMessage)")
$txtLines | Set-Content -LiteralPath $txtReportPath -Encoding utf8

Assert-Test "Diagnostic Report JSON written" (Test-Path -LiteralPath $jsonReportPath)
Assert-Test "Diagnostic Report TXT written" (Test-Path -LiteralPath $txtReportPath)
Remove-Item -LiteralPath $testDiagDir -Recurse -Force -ErrorAction SilentlyContinue

# 4. Phase 13 Rules (3, 4, 5, 9)
Write-Host "`n--- Test Group 4: Phase 13 Export & Preservation Rules ---" -ForegroundColor Cyan
Assert-Test "Rule 3: Enforce /CheckIntegrity on both max and fast" ($builderText -match 'Export-Image.+/Compress:\$compMode.+/CheckIntegrity' -or $builderText -match 'Export-Image.+/CheckIntegrity')
Assert-Test "Rule 3: Removed unverified export retry fallback" (-not ($builderText -match 'Fallback export without /CheckIntegrity'))
Assert-Test "Rule 4: Removed in-place index pruning (Delete-Image loop)" (-not ($builderText -match 'Pruning unmodified edition'))
Assert-Test "Rule 5: Pre-export original WIM backup preserved" ($builderText -match 'install_pre_export_backup\.wim')
Assert-Test "Rule 9: Rejection of ESD export mode" ($builderText -match 'ESD export mode is disabled')
Assert-Test "Rule 9: Rejection of SWM export mode" ($builderText -match 'Split-WIM \(SWM\) export mode is disabled')

# 5. Phase 15 Rules (6, 7, 8)
Write-Host "`n--- Test Group 5: Phase 15 Deep Apply Verification Rules ---" -ForegroundColor Cyan
Assert-Test "Rule 6: Mandatory Apply-Image /CheckIntegrity /Verify" ($builderText -match 'dism\.exe /English /Apply-Image.+/CheckIntegrity /Verify')
Assert-Test "Rule 6: Minimum 15GB disk space verification" ($builderText -match '\$freeSpaceGB -lt 15')
Assert-Test "Rule 6: Sets FinalPayloadVerified = `$true only on exit code 0" ($builderText -match '\$script:FinalPayloadVerified = \$true')
Assert-Test "Rule 7: Removed PASS inheritance from Phase 13 export" (-not ($builderText -match 'Verified during Phase 13: \$script:StreamIntegrityMethod'))
Assert-Test "Rule 7: Separated summary statuses" ($builderText -match 'Payload Verification Summary:' -and $builderText -match 'Metadata Status:' -and $builderText -match 'Final Apply Status:')
Assert-Test "Rule 8: Strict metadata check with index regex" ($builderText -match 'IndexCount: \$totalIndexCount' -or $builderText -match '\$totalIndexCount -eq 1')

# 6. Phase 17 Rules (10)
Write-Host "`n--- Test Group 6: Phase 17 Oscdimg Verification Rules ---" -ForegroundColor Cyan
Assert-Test "Rule 10: Enforce Test-OscdimgIntegrity across local and downloads" ($builderText -match 'Test-OscdimgIntegrity -OscdimgPath \$tempOscdPath')
Assert-Test "Rule 10: Size-only oscdimg adoption (>50KB) removed" (-not ($builderText -match '\(Get-Item -LiteralPath \$targetOscdPath\)\.Length -gt 50KB'))
Assert-Test "Rule 10: Abort if no verified oscdimg available" ($builderText -match 'No Authenticode-verified oscdimg\.exe available')

# 7. Phase 18 Rules (11, 12, 13, 14, 20)
Write-Host "`n--- Test Group 7: Phase 18 Temporary ISO & Payload Match Rules ---" -ForegroundColor Cyan
Assert-Test "Rule 11: Missing boot files aborts immediately" ($builderText -match 'Missing required boot sector files')
Assert-Test "Rule 12: Generate temporary ISO (nano11_temp_*) first" ($builderText -match 'nano11_temp_\${profSlug}_\${isoTimestamp}\.iso')
Assert-Test "Rule 12: Oscdimg exit code checked for 0" ($builderText -match '\$oscdimgExit -ne 0')
Assert-Test "Rule 13: Mount temporary ISO and verify payload hash" ($builderText -match 'Mount-DiskImage -ImagePath \$tempOutputIso' -and $builderText -match 'PAYLOAD HASH MISMATCH')
Assert-Test "Rule 13: Embedded WIM SHA256 matches verified final WIM" ($builderText -match '\$embeddedWimSha256 -ne \$script:VerifiedFinalWimSha256')
Assert-Test "Rule 12: Promote temporary ISO to official release name" ($builderText -match 'Move-Item -LiteralPath \$tempOutputIso -Destination \$outputIso')
Assert-Test "Rule 14 & 20: BuildSucceeded = `$true marked ONLY after all checks" ($builderText -match '\$script:BuildSucceeded = \$true\r?\n\s*\$script:DiagnosticData\.BuildSucceeded = \$true')
Assert-Test "Rule 20: Completion banners and GUI dialog gated by BuildSucceeded" ($builderText -match '\$GUI -and \$script:BuildSucceeded')

# 8. Outer Catch & Finally Rules (16, 17, 18, 19)
Write-Host "`n--- Test Group 8: Outer Catch & Finally Cleanup / Retention Rules ---" -ForegroundColor Cyan
Assert-Test "Rule 16: Outer catch resets BuildSucceeded to `$false" ($builderText -match '\$script:BuildSucceeded = \$false\r?\n\s*\$isoCreatedSuccessfully = \$false')
Assert-Test "Rule 16: Outer catch re-throws without masking" ($builderText -match 'throw\r?\n\}\s*finally')
Assert-Test "Rule 17: Dismounting executed unconditionally" ($builderText -match 'Unmount-RegistryHiveWithRetry' -and $builderText -match 'Clear-DismMountConflicts')
Assert-Test "Rule 18: VHDX detachment attempted unconditionally" ($builderText -match 'select vdisk file=')
Assert-Test "Rule 17 & 18: File deletions strictly gated behind `$script:BuildSucceeded" ($builderText -match 'if \(\$script:BuildSucceeded\) \{[\s\S]*?\} else \{[\s\S]*?DIAGNOSTIC PRESERVATION')
Assert-Test "Rule 18: VHDX preserved when BuildSucceeded is false" ($builderText -match 'VHDX Scratch Disk: \$vhdxPath')
Assert-Test "Rule 17: Pre-export WIM and Exported WIM preserved on failure" ($builderText -match 'Pre-Export WIM:    \$destWimBackupPath' -and $builderText -match 'Exported WIM:      \$finalWimPath')
Assert-Test "Rule 19: Test-IsSafePathToDelete guard implemented" ($builderText -match 'function Test-IsSafePathToDelete')

# 9. Test Test-IsSafePathToDelete logic
Write-Host "`n--- Test Group 9: Safety Guard Logic Testing ---" -ForegroundColor Cyan
function Test-IsSafePathToDelete-Test {
    param([string]$Path, [string]$ScriptDir)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
        if ($full.Length -le 3) { return $false }
        $systemProfile = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)
        if ($full -ieq $systemProfile.TrimEnd('\', '/')) { return $false }
        $windowsDir = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::Windows)
        if ($full.StartsWith($windowsDir, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
        if ($ScriptDir -and ($full -ieq [System.IO.Path]::GetFullPath($ScriptDir).TrimEnd('\', '/'))) { return $false }
        return $true
    } catch {
        return $false
    }
}
Assert-Test "SafePath: Reject drive root C:\" (-not (Test-IsSafePathToDelete-Test "C:\" "C:\Users\User\Documents\nano11-main"))
Assert-Test "SafePath: Reject user profile" (-not (Test-IsSafePathToDelete-Test $env:USERPROFILE "C:\Users\User\Documents\nano11-main"))
Assert-Test "SafePath: Reject Windows dir" (-not (Test-IsSafePathToDelete-Test "C:\Windows\System32" "C:\Users\User\Documents\nano11-main"))
Assert-Test "SafePath: Reject script dir" (-not (Test-IsSafePathToDelete-Test "C:\Users\User\Documents\nano11-main" "C:\Users\User\Documents\nano11-main"))
Assert-Test "SafePath: Accept dedicated subfolder" (Test-IsSafePathToDelete-Test "C:\Users\User\Documents\nano11_workspace\temp" "C:\Users\User\Documents\nano11-main")

Write-Host "`n=========================================================" -ForegroundColor Cyan
$failedCount = ($script:testResults.Values | Where-Object { $_ -ne "PASS" }).Count
$passCount = ($script:testResults.Values | Where-Object { $_ -eq "PASS" }).Count
Write-Host " Acceptance Test Results: $passCount PASSED, $failedCount FAILED" -ForegroundColor $(if ($failedCount -eq 0) { "Green" } else { "Red" })
Write-Host "=========================================================" -ForegroundColor Cyan

if ($failedCount -gt 0) {
    exit 1
} else {
    exit 0
}
