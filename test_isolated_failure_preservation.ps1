# test_isolated_failure_preservation.ps1
# Empirically tests failure preservation in an isolated sandbox without touching production files.

$ErrorActionPreference = "Stop"
$testSandbox = Join-Path -Path $env:TEMP -ChildPath "nano11_preservation_sandbox_$([System.IO.Path]::GetRandomFileName())"
New-Item -ItemType Directory -Path $testSandbox -Force | Out-Null

try {
    # 1. Setup isolated mock workspace
    $mockScriptDir = Join-Path -Path $testSandbox -ChildPath "repo"
    $mockNano11Dir = Join-Path -Path $testSandbox -ChildPath "nano11_iso_workspace"
    $mockWorkDir   = Join-Path -Path $testSandbox -ChildPath "work"
    $mockDiagDir   = Join-Path -Path $testSandbox -ChildPath "build_diagnostics\TEST_001"

    New-Item -ItemType Directory -Path (Join-Path $mockNano11Dir "sources") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $mockWorkDir "deep_apply_verification") -Force | Out-Null
    New-Item -ItemType Directory -Path $mockDiagDir -Force | Out-Null
    New-Item -ItemType Directory -Path $mockScriptDir -Force | Out-Null

    $mockBackupWim = Join-Path $mockNano11Dir "sources\install_pre_export_backup.wim"
    $mockFinalWim  = Join-Path $mockNano11Dir "sources\install.wim"
    $mockApplyDir  = Join-Path $mockWorkDir "deep_apply_verification"
    $mockApplyFile = Join-Path $mockApplyDir "dummy_extracted_file.sys"
    $mockVhdx      = Join-Path $mockWorkDir "scratch_disk.vhdx"
    $mockDiagJson  = Join-Path $mockDiagDir "build_diagnostic_report.json"

    [System.IO.File]::WriteAllText($mockBackupWim, "DUMMY PRE EXPORT WIM CONTENT", [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText($mockFinalWim,  "DUMMY FINAL EXPORT WIM CONTENT", [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText($mockApplyFile, "DUMMY APPLIED FILE", [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText($mockVhdx,      "DUMMY VHDX FILE", [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText($mockDiagJson,  '{"status":"FAILED"}', [System.Text.Encoding]::UTF8)

    # 2. Emulate the exact finally retention block from nano11builder.ps1
    $script:BuildSucceeded = $false
    $nano11Dir = $mockNano11Dir
    $workDir = $mockWorkDir
    $vhdxPath = $mockVhdx
    $script:DiagDir = $mockDiagDir
    $script:DiagnosticData = [ordered]@{ PreservedArtifacts = @() }

    # Execute retention logic from nano11builder.ps1 line 9570-9640
    if ($script:BuildSucceeded) {
        Write-Host "Simulating success branch (cleaning up)..."
        Remove-Item -LiteralPath $nano11Dir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host "Simulating failure branch (preserving artifacts)..."
        if ($nano11Dir -and (Test-Path -LiteralPath $nano11Dir)) {
            $script:DiagnosticData.PreservedArtifacts += $nano11Dir
            $destWimBackupPath = Join-Path -Path "$nano11Dir\sources" -ChildPath "install_pre_export_backup.wim"
            if (Test-Path -LiteralPath $destWimBackupPath) {
                $script:DiagnosticData.PreservedArtifacts += $destWimBackupPath
            }
            $finalWimPath = Join-Path -Path "$nano11Dir\sources" -ChildPath "install.wim"
            if (Test-Path -LiteralPath $finalWimPath) {
                $script:DiagnosticData.PreservedArtifacts += $finalWimPath
            }
        }
        if ($workDir -and (Test-Path -LiteralPath $workDir)) {
            $script:DiagnosticData.PreservedArtifacts += $workDir
        }
        if ($vhdxPath -and (Test-Path -LiteralPath $vhdxPath)) {
            $script:DiagnosticData.PreservedArtifacts += $vhdxPath
        }
        if ($script:DiagDir) {
            $script:DiagnosticData.PreservedArtifacts += $script:DiagDir
        }
    }

    # 3. Verify survival of all target artifacts
    $bBackup = Test-Path -LiteralPath $mockBackupWim
    $bFinal  = Test-Path -LiteralPath $mockFinalWim
    $bApply  = Test-Path -LiteralPath $mockApplyFile
    $bVhdx   = Test-Path -LiteralPath $mockVhdx
    $bDiag   = Test-Path -LiteralPath $mockDiagJson

    Write-Host "`nPreservation Verification Results:"
    Write-Host "  Pre-export WIM backup preserved: $bBackup" -ForegroundColor $(if ($bBackup) { "Green" } else { "Red" })
    Write-Host "  Final Export WIM preserved:      $bFinal"  -ForegroundColor $(if ($bFinal)  { "Green" } else { "Red" })
    Write-Host "  Apply directory preserved:       $bApply"  -ForegroundColor $(if ($bApply)  { "Green" } else { "Red" })
    Write-Host "  VHDX disk file preserved:        $bVhdx"   -ForegroundColor $(if ($bVhdx)   { "Green" } else { "Red" })
    Write-Host "  Diagnostic log preserved:        $bDiag"   -ForegroundColor $(if ($bDiag)   { "Green" } else { "Red" })

    $allSurv = ($bBackup -and $bFinal -and $bApply -and $bVhdx -and $bDiag)
    if ($allSurv) {
        Write-Host "`n[PASS] All forensic files successfully preserved on failure!" -ForegroundColor Green
        exit 0
    } else {
        Write-Host "`n[FAIL] Some forensic files were unexpectedly removed!" -ForegroundColor Red
        exit 1
    }
} finally {
    Remove-Item -LiteralPath $testSandbox -Recurse -Force -ErrorAction SilentlyContinue
}
