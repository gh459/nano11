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

    Context "Optimization Toolkit Cache" {
        It "RevisionTool-Setup.exe should be present in tools cache" {
            $revPath = Join-Path -Path $toolsDir -ChildPath "RevisionTool-Setup.exe"
            Test-Path -LiteralPath $revPath | Should Be $true
        }

        It "Optimizer.exe should be present in tools cache" {
            $optPath = Join-Path -Path $toolsDir -ChildPath "Optimizer.exe"
            Test-Path -LiteralPath $optPath | Should Be $true
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

    Context "Built-In Self Test Diagnostics" {
        It "Executing nano11builder.ps1 with -TestSelf should exit with code 0" {
            $proc = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$builderScript`" -TestSelf" -Wait -PassThru -NoNewWindow
            $proc.ExitCode | Should Be 0
        }
    }
}
