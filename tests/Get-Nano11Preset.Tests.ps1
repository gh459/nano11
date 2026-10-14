BeforeAll {
    $scriptPath = Join-Path $PSScriptRoot "../nano11builder.ps1"
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)

    # Use AST node lookup to cleanly locate script-scoped preset definitions and function definition
    $variablesToLoad = @('PowerPresets', 'TweakGroups', 'BuiltInPresets')
    foreach ($varName in $variablesToLoad) {
        $targetName = '$script:' + $varName
        $assignNode = $ast.Find({
            $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $args[0].Left.Extent.Text -eq $targetName
        }, $true)

        if ($assignNode) {
            Invoke-Expression $assignNode.Extent.Text
        }
    }

    $funcNode = $ast.Find({
        $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $args[0].Name -eq 'Get-Nano11Preset'
    }, $true)

    if ($funcNode) {
        Invoke-Expression $funcNode.Extent.Text
    }
}

Describe 'Get-Nano11Preset' {
    Context 'Default and Empty Parameters' {
        It 'Returns extreme preset when no parameter is passed' {
            $preset = Get-Nano11Preset
            $preset.ProfileName | Should -Be 'Extreme Slim & Gaming'
        }

        It 'Returns extreme preset when empty string is passed' {
            $preset = Get-Nano11Preset -Name ''
            $preset.ProfileName | Should -Be 'Extreme Slim & Gaming'
        }

        It 'Returns extreme preset when $null is passed' {
            $preset = Get-Nano11Preset -Name $null
            $preset.ProfileName | Should -Be 'Extreme Slim & Gaming'
        }
    }

    Context 'Canonical Preset Names' {
        It 'Returns expected preset for <Name>' -TestCases @(
            @{ Name = 'extreme';  ExpectedProfile = 'Extreme Slim & Gaming' }
            @{ Name = 'balanced'; ExpectedProfile = 'Balanced Pro' }
            @{ Name = 'fat32';    ExpectedProfile = 'FAT32 USB Split-WIM' }
            @{ Name = 'handheld'; ExpectedProfile = 'Portable Gaming PC' }
            @{ Name = 'vm';       ExpectedProfile = 'VM & Developer Workstation' }
            @{ Name = 'audio';    ExpectedProfile = 'Audio & DAW Production' }
        ) {
            param($Name, $ExpectedProfile)
            $preset = Get-Nano11Preset -Name $Name
            $preset | Should -Not -BeNullOrEmpty
            $preset.ProfileName | Should -Be $ExpectedProfile
        }
    }

    Context 'Numeric Shortcuts and Text Aliases' {
        It 'Resolves numeric shortcuts <Name> to <ExpectedKey>' -TestCases @(
            @{ Name = '1'; ExpectedKey = 'extreme' }
            @{ Name = '2'; ExpectedKey = 'balanced' }
            @{ Name = '3'; ExpectedKey = 'fat32' }
            @{ Name = '4'; ExpectedKey = 'handheld' }
            @{ Name = '5'; ExpectedKey = 'vm' }
            @{ Name = '6'; ExpectedKey = 'audio' }
        ) {
            param($Name, $ExpectedKey)
            $preset = Get-Nano11Preset -Name $Name
            $preset | Should -Be $script:BuiltInPresets[$ExpectedKey]
        }

        It 'Resolves text alias <Alias> to <ExpectedKey>' -TestCases @(
            @{ Alias = 'gaming';    ExpectedKey = 'extreme' }
            @{ Alias = 'slim';      ExpectedKey = 'extreme' }
            @{ Alias = 'safe';      ExpectedKey = 'balanced' }
            @{ Alias = 'pro';       ExpectedKey = 'balanced' }
            @{ Alias = 'split';     ExpectedKey = 'fat32' }
            @{ Alias = 'splitwim';  ExpectedKey = 'fat32' }
            @{ Alias = 'ally';      ExpectedKey = 'handheld' }
            @{ Alias = 'deck';      ExpectedKey = 'handheld' }
            @{ Alias = 'legion';    ExpectedKey = 'handheld' }
            @{ Alias = 'dev';       ExpectedKey = 'vm' }
            @{ Alias = 'developer'; ExpectedKey = 'vm' }
            @{ Alias = 'daw';       ExpectedKey = 'audio' }
            @{ Alias = 'dtm';       ExpectedKey = 'audio' }
        ) {
            param($Alias, $ExpectedKey)
            $preset = Get-Nano11Preset -Name $Alias
            $preset | Should -Be $script:BuiltInPresets[$ExpectedKey]
        }
    }

    Context 'Case-Insensitivity and Whitespace Handling' {
        It 'Trims whitespace and handles uppercase input <InputName>' -TestCases @(
            @{ InputName = '  ExTrEmE  '; ExpectedKey = 'extreme' }
            @{ InputName = ' GAMING ';     ExpectedKey = 'extreme' }
            @{ InputName = '  2  ';        ExpectedKey = 'balanced' }
            @{ InputName = " `tAUDIO`n "; ExpectedKey = 'audio' }
        ) {
            param($InputName, $ExpectedKey)
            $preset = Get-Nano11Preset -Name $InputName
            $preset | Should -Be $script:BuiltInPresets[$ExpectedKey]
        }
    }

    Context 'Invalid and Unknown Presets' {
        It 'Returns null for unknown preset names' -TestCases @(
            @{ InvalidName = 'nonexistent' }
            @{ InvalidName = '99' }
            @{ InvalidName = 'unknown_preset' }
        ) {
            param($InvalidName)
            $preset = Get-Nano11Preset -Name $InvalidName
            $preset | Should -BeNullOrEmpty
        }
    }

    Context 'Preset Structure Integrity' {
        It 'Returns a preset dictionary containing all mandatory configuration keys' {
            $preset = Get-Nano11Preset -Name 'extreme'
            $preset.Contains('ProfileName') | Should -Be $true
            $preset.Contains('Description') | Should -Be $true
            $preset.Contains('RemoveDefender') | Should -Be $true
            $preset.Contains('PowerPreset') | Should -Be $true
            $preset.Contains('TweakGroups') | Should -Be $true
            $preset.Contains('PayloadFormat') | Should -Be $true
        }
    }
}
