# Pester test suite for nano11builder functions

BeforeAll {
    $scriptPath = Join-Path -Path $PSScriptRoot -ChildPath '../nano11builder.ps1'
    if (Test-Path -LiteralPath $scriptPath) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $scriptPath).Path, [ref]$null, [ref]$null)
        $funcAst = $ast.Find({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'New-Nano11BuildId' }, $true)
        if ($funcAst) {
            Invoke-Expression $funcAst.Extent.Text
        } else {
            throw "Function New-Nano11BuildId not found in $scriptPath"
        }
    } else {
        throw "Script not found at $scriptPath"
    }
}

Describe 'New-Nano11BuildId' {
    Context 'Happy path - Default Parameter' {
        It 'generates a build ID with current date and valid format' {
            $id = New-Nano11BuildId
            $id | Should -Not -BeNullOrEmpty
            # Expected pattern: yyyyMMdd_HHmmss_[0-9a-fA-F]{8}
            $id | Should -Match '^\d{8}_\d{6}_[0-9a-fA-F]{8}$'
        }

        It 'uses the current UTC/local time when no timestamp is passed' {
            $before = Get-Date
            $id = New-Nano11BuildId
            $after = Get-Date

            $timePart = $id.Split('_')[0..1] -join '_'
            $dateParsed = [datetime]::ParseExact($timePart, 'yyyyMMdd_HHmmss', $null)

            ($dateParsed -ge $before.AddSeconds(-1)) | Should -Be $true
            ($dateParsed -le $after.AddSeconds(1)) | Should -Be $true
        }
    }

    Context 'Custom Timestamp Values' {
        It 'formats a specified DateTime correctly with zero-padding' {
            $customDate = [datetime]::new(2025, 3, 5, 9, 7, 4)
            $id = New-Nano11BuildId -Timestamp $customDate
            $id | Should -Match '^20250305_090704_[0-9a-fA-F]{8}$'
        }

        It 'handles leap year dates correctly' {
            $leapDate = [datetime]::new(2024, 2, 29, 23, 59, 58)
            $id = New-Nano11BuildId -Timestamp $leapDate
            $id | Should -Match '^20240229_235958_[0-9a-fA-F]{8}$'
        }
    }

    Context 'Boundary and Edge Cases' {
        It 'handles MinValue date (0001-01-01 00:00:00)' {
            $minDate = [datetime]::MinValue
            $id = New-Nano11BuildId -Timestamp $minDate
            $id | Should -Match '^00010101_000000_[0-9a-fA-F]{8}$'
        }

        It 'handles MaxValue date (9999-12-31 23:59:59)' {
            $maxDate = [datetime]::MaxValue
            $id = New-Nano11BuildId -Timestamp $maxDate
            $id | Should -Match '^99991231_235959_[0-9a-fA-F]{8}$'
        }
    }

    Context 'GUID Fragment Uniqueness & Format' {
        It 'generates unique GUID fragments for identical timestamps' {
            $fixedDate = [datetime]::new(2025, 1, 1, 12, 0, 0)
            $id1 = New-Nano11BuildId -Timestamp $fixedDate
            $id2 = New-Nano11BuildId -Timestamp $fixedDate

            $id1 | Should -Not -Be $id2

            $guidPart1 = $id1.Split('_')[2]
            $guidPart2 = $id2.Split('_')[2]

            $guidPart1.Length | Should -Be 8
            $guidPart2.Length | Should -Be 8

            $guidPart1 | Should -Not -Be $guidPart2
        }
    }
}
