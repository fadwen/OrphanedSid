#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
#Requires -Version 5.1

<#
.SYNOPSIS
    Unit tests for the parts of Tools/Generate-OrphanedSIDs.ps1 that can run without a domain.

.DESCRIPTION
    The script fills a lab domain when it is run, so it is never dot-sourced here. It is parsed,
    and the one function that needs no directory, New-TestPassword, is defined from its own text.
    The other cases read the syntax tree.
#>

BeforeAll {
    $toolPath = (Resolve-Path -LiteralPath "$PSScriptRoot\..\..\..\Tools\Generate-OrphanedSIDs.ps1").Path
    $tokens = $null
    $parseErrors = $null
    $script:ToolAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $toolPath, [ref]$tokens, [ref]$parseErrors)
    $script:ParseErrors = @($parseErrors)

    $definition = $script:ToolAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'New-TestPassword'
        }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))

    function ConvertTo-PlainText {
        param([System.Security.SecureString]$SecureString)
        [System.Net.NetworkCredential]::new('', $SecureString).Password
    }
}

Describe 'Generate-OrphanedSIDs.ps1' -Tag 'Unit', 'Tools' {

    Context 'The script as text' {
        It 'Parses without errors' {
            $script:ParseErrors.Count | Should-Be 0
        }

        It 'Runs no command through Invoke-Expression' {
            $calls = @($script:ToolAst.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.CommandAst] -and
                        $node.GetCommandName() -in 'Invoke-Expression', 'iex'
                    }, $true))

            $calls.Count | Should-Be 0 -Because "line(s) $($calls.Extent.StartLineNumber -join ', ')"
        }

        It 'Makes no secure string from plain text' {
            $calls = @($script:ToolAst.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.CommandAst] -and
                        $node.GetCommandName() -eq 'ConvertTo-SecureString'
                    }, $true))

            $calls.Count | Should-Be 0 -Because "line(s) $($calls.Extent.StartLineNumber -join ', ')"
        }

        It 'Calls dsacls with its arguments as a list, both times' {
            $calls = @($script:ToolAst.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.CommandAst] -and
                        $node.GetCommandName() -eq 'dsacls.exe'
                    }, $true))

            $calls.Count | Should-Be 2
            $calls | Should-All { $_.Extent.Text -eq '& dsacls.exe @dsaclsArguments' }
        }
    }

    Context 'New-TestPassword' {
        It 'Returns a read-only secure string of 28 characters' {
            $password = New-TestPassword

            $password | Should-HaveType ([System.Security.SecureString])
            $password.Length | Should-Be 28
            $password.IsReadOnly() | Should-BeTrue
        }

        It 'Holds an upper-case letter, a lower-case letter, a digit and a symbol' {
            $text = ConvertTo-PlainText -SecureString (New-TestPassword)

            $text | Should-MatchString '[A-Z]' -CaseSensitive
            $text | Should-MatchString '[a-z]' -CaseSensitive
            $text | Should-MatchString '[0-9]'
            $text | Should-MatchString '[!#%+\-_=]'
            $text | Should-MatchString '^[A-Za-z0-9!#%+\-_=]{28}$' -CaseSensitive
        }

        It 'Returns another password each time' {
            $passwords = @(1..20 | ForEach-Object { ConvertTo-PlainText -SecureString (New-TestPassword) })

            @($passwords | Select-Object -Unique).Count | Should-Be 20
        }
    }
}
