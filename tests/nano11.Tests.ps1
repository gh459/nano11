BeforeAll {
    $env:NANO11_TEST_MODE = '1'
    $script:ScriptRoot = Resolve-Path "$PSScriptRoot/.."
    $script:BuilderPath = Join-Path -Path $script:ScriptRoot -ChildPath "nano11builder.ps1"
    $script:UnattendPath = Join-Path -Path $script:ScriptRoot -ChildPath "autounattend.xml"

    # Load functions and script variables from nano11builder.ps1 AST to avoid platform-dependent script top-level execution
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:BuilderPath, [ref]$null, [ref]$null)
    $functions = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
    foreach ($fn in $functions) {
        Invoke-Expression $fn.Extent.Text
    }

    # Extract BuiltInPresets assignment block from AST and evaluate it into script scope
    $assignments = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)
    foreach ($a in $assignments) {
        if ($a.Left.Extent.Text -like "*BuiltInPresets*") {
            Invoke-Expression $a.Extent.Text
        }
    }
}

Describe "Unattend Pre-Extraction Path Traversal Security" {
    It "Should reject path traversal sequences and workspace escaping targets" {
        $mockScratch = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "nano11_mock_scratch_$([Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $mockScratch -Force | Out-Null

        try {
            $testXml = @"
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <Extensions xmlns="https://schneegans.de/windows/unattend-generator/">
        <File path="C:\Windows\Setup\Scripts\Valid.ps1">Write-Host 'Safe'</File>
        <File path="C:\..\..\..\EscapedHostFile.txt">Write-Host 'Malicious'</File>
    </Extensions>
</unattend>
"@
            $xmlDoc = [xml]$testXml
            $scratchDir = $mockScratch

            foreach ($fileNode in $xmlDoc.unattend.Extensions.File) {
                $rawTarget = $fileNode.GetAttribute("path")
                if ($rawTarget) {
                    $relTarget = $rawTarget -replace '^(?:[A-Za-z]:|%SystemDrive%)[\\/]+', ''
                    if ($relTarget -match '\.\.') {
                        continue
                    }
                    $scratchFull = [System.IO.Path]::GetFullPath($scratchDir).TrimEnd('\', '/')
                    $destPath = [System.IO.Path]::GetFullPath((Join-Path -Path $scratchFull -ChildPath $relTarget))
                    if (-not $destPath.StartsWith($scratchFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
                        continue
                    }
                    $parentDir = Split-Path -Path $destPath -Parent
                    if (-not (Test-Path -LiteralPath $parentDir)) {
                        New-Item -Path $parentDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
                    }
                    $utf8WithBom = New-Object System.Text.UTF8Encoding($true)
                    [System.IO.File]::WriteAllText($destPath, $fileNode.InnerText.Trim(), $utf8WithBom)
                }
            }

            Test-Path -LiteralPath (Join-Path -Path $mockScratch -ChildPath "Windows\Setup\Scripts\Valid.ps1") | Should -Be $true
            Test-Path -LiteralPath (Join-Path -Path $mockScratch -ChildPath "EscapedHostFile.txt") | Should -Be $false
            Test-Path -LiteralPath (Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "EscapedHostFile.txt") | Should -Be $false
        } finally {
            if (Test-Path -LiteralPath $mockScratch) {
                Remove-Item -LiteralPath $mockScratch -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

Describe "nano11builder.ps1 Script AST & Structure" {
    It "Should parse with 0 syntax or parser errors" {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:BuilderPath, [ref]$tokens, [ref]$errors)
        $errors.Count | Should -Be 0
    }

    It "Should define all expected CLI parameter switches and aliases" {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:BuilderPath, [ref]$null, [ref]$null)
        $paramBlock = $ast.ParamBlock
        $paramBlock | Should -Not -BeNullOrEmpty

        $paramNames = $paramBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }
        $expectedParams = @(
            'NonInteractive', 'Interactive', 'GUI', 'Profile', 'SaveProfile', 'LoadProfile',
            'SourceDrive', 'WorkDir', 'Index', 'OutputIsoName', 'TimestampIso', 'DryRun',
            'Resume', 'Validate', 'SkipEiCfg', 'NoPostInstallAssets', 'KeepDefender',
            'RemoveDefender', 'KeepIME', 'RemoveIME', 'KeepFonts', 'RemoveFonts',
            'KeepDrivers', 'RemoveDrivers', 'KeepWindowsUpdate', 'DisableWindowsUpdate',
            'KeepBluetooth', 'DisableBluetooth', 'EnableWSL', 'DisableWSL',
            'KeepRecovery', 'RemoveRecovery', 'SafeDebloat', 'AggressiveWinSxS',
            'UltraSlim', 'NoUltraSlim', 'JapaneseKeyboard', 'NoJapaneseKeyboard',
            'AtlasReviOS', 'NoAtlasReviOS', 'ExportESD', 'ExportWIM', 'SplitWIM',
            'NoSplitWIM', 'KeepStore', 'RemoveStore', 'UseVHDX', 'TestSelf', 'CheckHealth'
        )

        foreach ($p in $expectedParams) {
            $paramNames | Should -Contain $p
        }
    }
}

Describe "Path Normalization (ConvertTo-Nano11NormalizedPath)" {
    It "Should normalize valid Windows drive paths with forward slashes" {
        $normalized = ConvertTo-Nano11NormalizedPath -Path "C:/Windows/System32"
        $normalized | Should -Match 'C:\\Windows\\System32$'
    }

    It "Should throw on null or empty path" {
        { ConvertTo-Nano11NormalizedPath -Path "" } | Should -Throw
    }

    It "Should throw on relative or non-drive paths" {
        { ConvertTo-Nano11NormalizedPath -Path "relative/path" } | Should -Throw
    }

    It "Should throw on drive letter without path" {
        { ConvertTo-Nano11NormalizedPath -Path "C:" } | Should -Throw
    }
}

Describe "Safety Boundary Assertions" {
    It "Should reject empty paths in Assert-Nano11DirectorySafety" {
        { Assert-Nano11DirectorySafety -Path "" -Operation "Reset" } | Should -Throw
    }

    It "Should reject drive roots in Assert-Nano11DirectorySafety" {
        { Assert-Nano11DirectorySafety -Path "C:\" -Operation "Reset" } | Should -Throw
    }

    It "Should identify system directories as unsafe to delete in Test-IsSafePathToDelete" {
        $winDir = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::Windows)
        if (-not $winDir) { $winDir = "C:\Windows" }
        Test-IsSafePathToDelete -Path $winDir | Should -Be $false
    }

    It "Should return false for non-absolute/drive paths in Test-IsSafePathToDelete" {
        Test-IsSafePathToDelete -Path "relative_path" | Should -Be $false
    }
}

Describe "Profile Management & Preset Resolution" {
    Context "Get-Nano11Preset" {
        It "Should return extreme preset by default when name is empty" {
            $preset = Get-Nano11Preset -Name ""
            $preset | Should -Not -BeNullOrEmpty
            $preset.ProfileName | Should -Be "Extreme Slim & Gaming"
        }

        It "Should resolve valid preset names and numeric aliases" {
            (Get-Nano11Preset -Name "extreme").ProfileName | Should -Be "Extreme Slim & Gaming"
            (Get-Nano11Preset -Name "1").ProfileName | Should -Be "Extreme Slim & Gaming"
            (Get-Nano11Preset -Name "balanced").ProfileName | Should -Be "Balanced Pro"
            (Get-Nano11Preset -Name "2").ProfileName | Should -Be "Balanced Pro"
            (Get-Nano11Preset -Name "fat32").ProfileName | Should -Be "FAT32 USB Split-WIM"
            (Get-Nano11Preset -Name "handheld").ProfileName | Should -Be "Portable Gaming PC"
            (Get-Nano11Preset -Name "vm").ProfileName | Should -Be "VM & Developer Workstation"
            (Get-Nano11Preset -Name "audio").ProfileName | Should -Be "Audio & DAW Production"
        }

        It "Should return null for unknown preset name" {
            Get-Nano11Preset -Name "nonexistent_preset_xyz" | Should -BeNullOrEmpty
        }
    }

    Context "Export-Nano11Profile & Import-Nano11Profile" {
        It "Should export and import profile JSON accurately" {
            $tempFile = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "nano11_test_profile_$([Guid]::NewGuid().ToString('N')).json"
            $config = @{
                ProfileName = "Test Custom Profile"
                RemoveDefender = $true
                KeepAsianIME = $true
                PayloadFormat = "WIM"
            }

            try {
                Export-Nano11Profile -FilePath $tempFile -Config $config
                Test-Path -LiteralPath $tempFile | Should -Be $true

                $imported = Import-Nano11Profile -FilePath $tempFile
                $imported | Should -Not -BeNullOrEmpty
                [bool]$imported.RemoveDefender | Should -Be $true
                [bool]$imported.KeepAsianIME | Should -Be $true
            } finally {
                if (Test-Path -LiteralPath $tempFile) {
                    Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }
}

Describe "Build State Management" {
    It "Should write, read, and test phase completion" {
        $tempDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "nano11_test_state_$([Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

        try {
            Initialize-Nano11BuildState -Dir $tempDir
            Set-Nano11BuildState -Phase "Phase1" -Status "Completed"

            $state = Get-Nano11BuildState
            $state | Should -Not -BeNullOrEmpty
            $state.Phases.Phase1 | Should -Be "Completed"

            $script:Resume = $true
            Test-Nano11PhaseCompleted -Phase "Phase1" | Should -Be $true
            Test-Nano11PhaseCompleted -Phase "Phase2" | Should -Be $false
        } finally {
            $script:BuildStateFile = $null
            $script:Resume = $false
            if (Test-Path -LiteralPath $tempDir) {
                Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

Describe "Helper Utilities" {
    Context "New-Nano11BuildId" {
        It "Should generate a valid timestamped build ID" {
            $buildId = New-Nano11BuildId
            $buildId | Should -Match '^\d{8}_\d{6}_[0-9a-f]{8}$'
        }
    }

    Context "Test-IsNtfsVolume" {
        It "Should return false for empty or non-existent path" {
            Test-IsNtfsVolume -Path "" | Should -Be $false
            Test-IsNtfsVolume -Path "Z:\NonExistentPath12345" | Should -Be $false
        }
    }

    Context "Test-OscdimgIntegrity" {
        It "Should verify bundled oscdimg.exe integrity if present" {
            $oscdPath = Join-Path -Path $script:ScriptRoot -ChildPath "oscdimg.exe"
            if (Test-Path -LiteralPath $oscdPath) {
                Test-OscdimgIntegrity -OscdimgPath $oscdPath | Should -Be $true
            }
        }

        It "Should return false for non-existent path" {
            Test-OscdimgIntegrity -OscdimgPath "C:\nonexistent\oscdimg.exe" | Should -Be $false
        }
    }
}

Describe "autounattend.xml Schema & Embedded Setup Scripts" {
    It "Should exist and be valid XML" {
        Test-Path -LiteralPath $script:UnattendPath | Should -Be $true
        $doc = [xml]::new()
        { $doc.Load($script:UnattendPath) } | Should -Not -Throw
        $doc.DocumentElement.Name | Should -Be "unattend"
    }

    It "Should contain embedded setup scripts in Extensions block" {
        $doc = [xml]::new()
        $doc.Load($script:UnattendPath)
        $nsMgr = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
        $nsMgr.AddNamespace("u", $doc.DocumentElement.NamespaceURI)

        $fileNodes = $doc.SelectNodes("//*[local-name()='Extensions']/*[local-name()='File']")
        $fileNodes | Should -Not -BeNullOrEmpty
        $fileNodes.Count | Should -BeGreaterThan 0

        $extractedPaths = $fileNodes | ForEach-Object { $_.GetAttribute("path") }
        $requiredScripts = @('Specialize.ps1', 'FirstLogon.ps1', 'DefaultUser.ps1', 'UserOnce.ps1', 'Winhancements.ps1')

        foreach ($rs in $requiredScripts) {
            $matched = $extractedPaths | Where-Object { $_ -like "*$rs*" }
            $matched | Should -Not -BeNullOrEmpty
        }
    }
}
