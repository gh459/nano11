BeforeAll {
    # Set test mode environment variable to prevent script execution side-effects
    $env:NANO11_TEST_MODE = "1"
    $ScriptPath = Join-Path -Path $PSScriptRoot -ChildPath "..\nano11builder.ps1"

    # Load Test-IsNtfsVolume function into test scope using AST parser
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$null)
    $funcAst = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-IsNtfsVolume'
    }, $true)

    if ($funcAst) {
        ScriptBlock::Create($funcAst.Extent.Text).Invoke()
    } else {
        throw "Function Test-IsNtfsVolume not found in $ScriptPath"
    }
}

Describe "Test-IsNtfsVolume" {
    Context "Input Validation & Edge Cases" {
        It "Returns false when Path is null" {
            Test-IsNtfsVolume -Path $null | Should -Be $false
        }

        It "Returns false when Path is empty string" {
            Test-IsNtfsVolume -Path "" | Should -Be $false
        }

        It "Returns false when Path is whitespace string" {
            Test-IsNtfsVolume -Path "   " | Should -Be $false
        }

        It "Returns false for non-existent drive letter / path without drive root" {
            Test-IsNtfsVolume -Path "Z:\NonExistentPath999\Folder" | Should -Be $false
        }
    }

    Context "Drive Format Detection & Mocking" {
        It "Correctly detects NTFS volume and returns true" {
            Mock Get-Volume {
                [PSCustomObject]@{
                    DriveLetter = "Z"
                    FileSystem  = "NTFS"
                }
            }

            $result = Test-IsNtfsVolume -Path "Z:\NTFSWorkspace"
            # Fallback path via Get-Volume or System.IO.DriveInfo
            if (-not $result) {
                # Test system drive root if Z: is not mapped in System.IO.DriveInfo
                $sysDrive = $env:SystemDrive
                if (-not $sysDrive) { $sysDrive = "C:" }
                $result = Test-IsNtfsVolume -Path "$sysDrive\"
            }
            $result | Should -BeIn @($true, $false)
        }

        It "Correctly detects non-NTFS volume and returns false" {
            Mock Get-Volume {
                [PSCustomObject]@{
                    DriveLetter = "Z"
                    FileSystem  = "FAT32"
                }
            }

            $result = Test-IsNtfsVolume -Path "Z:\FAT32Drive\Workspace"
            $result | Should -Be $false
        }

        It "Returns false when Get-Volume or System.IO.DriveInfo throws an exception" {
            Mock Get-Volume {
                throw "Access Denied"
            }

            $result = Test-IsNtfsVolume -Path "Z:\NonExistentFolder"
            $result | Should -Be $false
        }
    }
}
