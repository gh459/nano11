#Requires -Version 5.1
<#
.SYNOPSIS
    Pester test suite for nano11 project.
    Validates script syntax, XML integrity, profile configs, offline registry safety, and report generation.
#>

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$builderScript = Join-Path -Path $repoRoot -ChildPath "nano11builder.ps1"
$unattendXml = Join-Path -Path $repoRoot -ChildPath "autounattend.xml"
$profilesDir = Join-Path -Path $repoRoot -ChildPath "profiles"
$toolsDir = Join-Path -Path $repoRoot -ChildPath "tools"

Describe "nano11 Core Architecture & Integrity Suite" {

    Context "Encoding & Localization Integrity" {
        It "nano11builder.ps1 should be UTF-8 with BOM for PowerShell 5.1 parser compatibility" {
            $bytes = [System.IO.File]::ReadAllBytes($builderScript)
            ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should Be $true
        }

        It "nano11-GUI.bat should exist, be UTF-8 without BOM, and contain chcp 65001" {
            $guiBat = Join-Path -Path $repoRoot -ChildPath "nano11-GUI.bat"
            Test-Path -LiteralPath $guiBat | Should Be $true
            $bytes = [System.IO.File]::ReadAllBytes($guiBat)
            # Must NOT have UTF-8 BOM (cmd.exe parser failure)
            ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should Be $false
            $batText = [System.IO.File]::ReadAllText($guiBat, [System.Text.Encoding]::UTF8)
            ($batText -match 'chcp 65001') | Should Be $true
            ($batText -match 'nano11builder\.ps1') | Should Be $true
            ($batText -match 'BUILDER') | Should Be $true
        }

        It "Show-Nano11GUI should contain localized Japanese strings" {
            $scriptContent = [System.IO.File]::ReadAllText($builderScript, [System.Text.Encoding]::UTF8)
            ($scriptContent -match 'nano11 ビルド開始') | Should Be $true
            ($scriptContent -match 'Windows 11 メディア & 作業フォルダー') | Should Be $true
            ($scriptContent -match '構成プロファイル & プリセット') | Should Be $true
            ($scriptContent -match 'Windows Defender とセキュリティUIの完全削除') | Should Be $true
        }
    }

    Context "Script Syntax & Static Analysis" {
        It "nano11builder.ps1 should pass AST parsing with 0 syntax errors" {
            $parseErrors = $null
            [System.Management.Automation.Language.Parser]::ParseFile($builderScript, [ref]$null, [ref]$parseErrors)
            $parseErrors.Count | Should Be 0
        }

        It "nano11builder.ps1 should never create illegal zSYSTEM\CurrentControlSet in offline operations" {
            $scriptContent = Get-Content -LiteralPath $builderScript -Raw
            $lines = $scriptContent -split "`r?`n"
            $badLines = @()
            foreach ($line in $lines) {
                if ($line -like "*zSYSTEM\CurrentControlSet*" -and $line -notlike "*reg.exe query*" -and $line -notlike "*reg.exe delete*" -and $line -notlike "*#*") {
                    $badLines += $line.Trim()
                }
            }
            $badLines.Count | Should Be 0
        }

        It "nano11builder.ps1 should define Apply-ProfileSettings, Enter-Phase, and Exit-Phase" {
            $scriptContent = Get-Content -LiteralPath $builderScript -Raw
            ($scriptContent -match 'function Apply-ProfileSettings') | Should Be $true
            ($scriptContent -match 'function Enter-Phase') | Should Be $true
            ($scriptContent -match 'function Exit-Phase') | Should Be $true
        }

        It "nano11builder.ps1 should expose parameterized ComputerName, UserName, InjectDrivers, KeepBasicApps, and KeepSearchIndex" {
            $scriptContent = Get-Content -LiteralPath $builderScript -Raw
            ($scriptContent -match '\[string\]\$ComputerName\s*=\s*''\*''') | Should Be $true
            ($scriptContent -match '\[string\]\$UserName\s*=\s*''User''') | Should Be $true
            ($scriptContent -match '\[string\]\$InjectDrivers') | Should Be $true
            ($scriptContent -match '\[switch\]\$KeepBasicApps') | Should Be $true
            ($scriptContent -match '\[switch\]\$KeepSearchIndex') | Should Be $true
        }
    }

    Context "Unattend XML & Zero-Click Setup Configuration" {
        It "autounattend.xml should exist and be well-formed XML" {
            Test-Path -LiteralPath $unattendXml | Should Be $true
            { [xml](Get-Content -LiteralPath $unattendXml -Raw -Encoding utf8) } | Should Not Throw
        }

        It "autounattend.xml should contain Zero-Click setup keys in specialize pass" {
            $xmlContent = Get-Content -LiteralPath $unattendXml -Raw -Encoding utf8
            ($xmlContent -match 'ChildCompletion' -and $xmlContent -match 'setup\.exe' -and $xmlContent -match 'SetupType') | Should Be $true
        }

        It "autounattend.xml should include Specialize.ps1, DefaultUser.ps1, UserOnce.ps1, and FirstLogon.ps1" {
            $xmlContent = Get-Content -LiteralPath $unattendXml -Raw -Encoding utf8
            ($xmlContent -match 'Specialize\.ps1') | Should Be $true
            ($xmlContent -match 'DefaultUser\.ps1') | Should Be $true
            ($xmlContent -match 'UserOnce\.ps1') | Should Be $true
            ($xmlContent -match 'FirstLogon\.ps1') | Should Be $true
        }
    }

    Context "Profile Presets Validation" {
        $expectedProfiles = @(
            "extreme-gaming.json",
            "balanced-pro.json",
            "fat32-splitwim.json",
            "handheld-gaming.json",
            "vm-developer.json",
            "audio-daw.json"
        )

        foreach ($pName in $expectedProfiles) {
            It "Profile $pName should exist and parse as valid JSON" {
                $pPath = Join-Path -Path $profilesDir -ChildPath $pName
                Test-Path -LiteralPath $pPath | Should Be $true
                $json = Get-Content -LiteralPath $pPath -Raw -Encoding utf8 | ConvertFrom-Json
                $json | Should Not Be $null
                $json.ProfileName | Should Not BeNullOrEmpty
            }
        }
    }

    Context "Optimization Toolkit Removal & Deployment Tooling" {
        It "RevisionTool-Setup.exe and Optimizer.exe should NOT be present in tools cache" {
            $revPath = Join-Path -Path $toolsDir -ChildPath "RevisionTool-Setup.exe"
            $optPath = Join-Path -Path $toolsDir -ChildPath "Optimizer.exe"
            Test-Path -LiteralPath $revPath | Should Be $false
            Test-Path -LiteralPath $optPath | Should Be $false
        }

        It "oscdimg.exe should be present and valid" {
            $oscdPath = Join-Path -Path $repoRoot -ChildPath "oscdimg.exe"
            Test-Path -LiteralPath $oscdPath | Should Be $true
        }
    }

    Context "Visual HTML Report Generation" {
        It "Export-Nano11HtmlReport should produce a complete, non-empty HTML document" {
            # Dot-source function from builder
            $scriptContent = Get-Content -LiteralPath $builderScript -Raw
            $funcMatch = [regex]::Match($scriptContent, '(?s)function Export-Nano11HtmlReport \{.*?\n\}')
            $funcMatch.Success | Should Be $true
            Invoke-Expression $funcMatch.Value

            $tempReport = Join-Path -Path $env:TEMP -ChildPath "nano11_test_report_$([System.IO.Path]::GetRandomFileName()).html"
            try {
                Export-Nano11HtmlReport -OutputPath $tempReport -BuildInfo @{
                    Title             = "Unit Test Build Report"
                    Profile           = "extreme"
                    Architecture      = "amd64"
                    SourceDrive       = "E:"
                    OutputIso         = "nano11.iso"
                    OriginalSizeBytes = 6871947673
                    FinalSizeBytes    = 3435973836
                }
                Test-Path -LiteralPath $tempReport | Should Be $true
                $content = Get-Content -LiteralPath $tempReport -Raw -Encoding utf8
                $content | Should Match '<!DOCTYPE html>'
                $content | Should Match 'nano11'
                $content | Should Match 'Zero-Click Automated Setup'
            } finally {
                if (Test-Path -LiteralPath $tempReport) {
                    Remove-Item -LiteralPath $tempReport -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    Context "Post-Setup Automation & Verification Architecture" {
        It "tools/winget-packages.json should exist, parse as valid JSON, and define Sources and Packages" {
            $wingetJson = Join-Path -Path $toolsDir -ChildPath "winget-packages.json"
            Test-Path -LiteralPath $wingetJson | Should Be $true
            $obj = Get-Content -LiteralPath $wingetJson -Raw -Encoding utf8 | ConvertFrom-Json
            $obj.Sources | Should Not Be $null
            $obj.Sources[0].Packages.Count | Should BeGreaterThan 0
        }

        It "tools/post-build.ps1 should exist and declare IsoPath, IsoHash, Profile, and LogDir parameters" {
            $postBuild = Join-Path -Path $toolsDir -ChildPath "post-build.ps1"
            Test-Path -LiteralPath $postBuild | Should Be $true
            $content = Get-Content -LiteralPath $postBuild -Raw -Encoding utf8
            ($content -match '\[string\]\$IsoPath') | Should Be $true
            ($content -match '\[string\]\$IsoHash') | Should Be $true
            ($content -match '\[string\]\$Profile') | Should Be $true
            ($content -match '\[string\]\$LogDir') | Should Be $true
        }

        It "autounattend.xml should contain winget import and journal CSV logging" {
            $xmlContent = Get-Content -LiteralPath $unattendXml -Raw -Encoding utf8
            ($xmlContent -match 'winget\.exe import') | Should Be $true
            ($xmlContent -match 'firstlogon-registry-applied\.csv') | Should Be $true
        }

        It "autounattend.xml should contain two-stage verification marker check and MSI target class filtering" {
            $xmlContent = Get-Content -LiteralPath $unattendXml -Raw -Encoding utf8
            ($xmlContent -match 'setupcomplete\.stamp') | Should Be $true
            ($xmlContent -match 'firstlogon\.stamp') | Should Be $true
            ($xmlContent -match '4d36e968-e325-11ce-bfc1-08002be10318') | Should Be $true
        }
    }

    Context "Built-In Self Test Diagnostics" {
        It "Executing nano11builder.ps1 with -TestSelf should exit with code 0" {
            $proc = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$builderScript`" -TestSelf" -Wait -PassThru -NoNewWindow
            $proc.ExitCode | Should Be 0
        }
    }
}
