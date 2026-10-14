BeforeAll {
    $builderPath = Join-Path $PSScriptRoot "../nano11builder.ps1"
    $scriptContent = Get-Content -LiteralPath $builderPath -Raw
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($scriptContent, [ref]$null, [ref]$null)
    $funcAst = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq "ConvertTo-Nano11NormalizedPath" }, $true)[0]
    Invoke-Expression $funcAst.Extent.Text
}

Describe "ConvertTo-Nano11NormalizedPath" {
    Context "Happy Paths" {
        It "Normalizes forward slashes to backslashes and trims trailing slashes" {
            $normalized = ConvertTo-Nano11NormalizedPath -Path "C:/Windows/System32/"
            $normalized | Should -BeLike "*C:\Windows\System32"
        }

        It "Normalizes standard absolute path with trailing backslash" {
            $normalized = ConvertTo-Nano11NormalizedPath -Path "D:\BuildWorkspace\scratchdir\"
            $normalized | Should -BeLike "*D:\BuildWorkspace\scratchdir"
        }
    }

    Context "Error Paths" {
        It "Throws error when path is whitespace" {
            { ConvertTo-Nano11NormalizedPath -Path "   " } | Should -Throw "*cannot be null or empty*"
        }

        It "Throws error when path is relative or does not start with a drive letter" {
            { ConvertTo-Nano11NormalizedPath -Path "relative\path" } | Should -Throw "Path must be an absolute local drive path starting with a drive letter: 'relative\path'"
            { ConvertTo-Nano11NormalizedPath -Path "\NoDriveLetter\path" } | Should -Throw "Path must be an absolute local drive path starting with a drive letter: '\NoDriveLetter\path'"
            { ConvertTo-Nano11NormalizedPath -Path "1:\invalid\drive" } | Should -Throw "Path must be an absolute local drive path starting with a drive letter: '1:\invalid\drive'"
        }

        It "Throws error when path is a drive root" -Skip:(-not $IsWindows) {
            { ConvertTo-Nano11NormalizedPath -Path "C:\" } | Should -Throw "Drive root path is not allowed as a managed path: 'C:\'"
            { ConvertTo-Nano11NormalizedPath -Path "D:/" } | Should -Throw "Drive root path is not allowed as a managed path: 'D:/'"
        }

        It "Throws error in catch block when GetFullPath fails due to invalid characters" {
            $nullChar = [char]0
            $invalidPath = "C:\Folder\${nullChar}Invalid"
            { ConvertTo-Nano11NormalizedPath -Path $invalidPath } | Should -Throw "Failed to get full path for *"
        }
    }
}
