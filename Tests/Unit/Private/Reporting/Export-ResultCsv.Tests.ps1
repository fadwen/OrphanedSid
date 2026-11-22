#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
#Requires -Version 5.1

<#
.SYNOPSIS
    Unit tests for Export-ResultCsv, which writes result objects to a CSV file whose first line
    is the header.

.DESCRIPTION
    Tests the real function. The cases that read the file write it to the test drive with the
    real Export-Csv. Export-Csv is mocked only in the case that asserts which parameters it is
    given, because the effect of -NoTypeInformation differs by edition: Windows PowerShell 5.1
    writes a #TYPE line without it, and PowerShell 7.7 writes a warning with it.
#>

BeforeAll {
    # As OrphanedSid.psm1 does: in the module the code under test runs under strict mode
    Set-StrictMode -Version Latest

    . "$PSScriptRoot\..\..\..\..\Private\Reporting\Export-ResultCsv.ps1"

    $script:onWindowsPowerShell = $PSVersionTable.PSVersion -lt [version]'6.0'
}

Describe 'Export-ResultCsv' -Tag 'Unit', 'Reporting', 'Private' {

    BeforeEach {
        $script:csv = Join-Path -Path $TestDrive -ChildPath "results-$([guid]::NewGuid().ToString('N')).csv"
        $script:rows = @(
            [PSCustomObject]@{ ObjectDN = 'CN=Alice,OU=Sales,DC=contoso,DC=com'; Success = $true; Note = 'first' }
            [PSCustomObject]@{
                ObjectDN = 'CN=Doe\, Jane,OU=Sales,DC=contoso,DC=com'
                Success = $false
                Note = 'a "quoted" word'
            }
        )
    }

    Context 'Parameter Validation' {
        It 'Declares <ParameterName> as a mandatory parameter' -ForEach @(
            @{ ParameterName = 'InputObject'; ParameterType = [object[]] }
            @{ ParameterName = 'LiteralPath'; ParameterType = [string] }
        ) {
            Get-Command -Name Export-ResultCsv |
                Should-HaveParameter -ParameterName $ParameterName -Type $ParameterType -Mandatory
        }
    }

    Context 'Core Functionality' {
        It 'Writes the header as the first line of the file' {
            Export-ResultCsv -InputObject $script:rows -LiteralPath $script:csv -ErrorAction Stop

            $lines = @(Get-Content -LiteralPath $script:csv)
            $lines | Should-BeCollection -Count 3
            $lines[0] | Should-BeString '"ObjectDN","Success","Note"' -CaseSensitive
        }

        It 'Writes one row for each object, with values that read back as they were' {
            Export-ResultCsv -InputObject $script:rows -LiteralPath $script:csv -ErrorAction Stop

            $readBack = @(Import-Csv -LiteralPath $script:csv)
            $readBack | Should-BeCollection -Count 2
            $readBack[0].ObjectDN | Should-BeString 'CN=Alice,OU=Sales,DC=contoso,DC=com' -CaseSensitive
            $readBack[1].ObjectDN | Should-BeString 'CN=Doe\, Jane,OU=Sales,DC=contoso,DC=com' -CaseSensitive
            $readBack[1].Success | Should-BeString 'False'
            $readBack[1].Note | Should-BeString 'a "quoted" word' -CaseSensitive
        }

        It 'Writes a file for a single object' {
            Export-ResultCsv -InputObject $script:rows[0] -LiteralPath $script:csv -ErrorAction Stop

            @(Import-Csv -LiteralPath $script:csv) | Should-BeCollection -Count 1
        }

        It 'Replaces a file that is already there' {
            Set-Content -LiteralPath $script:csv -Value 'earlier content' -Encoding ascii

            Export-ResultCsv -InputObject $script:rows -LiteralPath $script:csv -ErrorAction Stop

            @(Get-Content -LiteralPath $script:csv)[0] |
                Should-BeString '"ObjectDN","Success","Note"' -CaseSensitive
        }

        It 'Writes to a path that holds square brackets' {
            $folder = Join-Path -Path $TestDrive -ChildPath "Reports [$([guid]::NewGuid().ToString('N'))]"
            $null = New-Item -Path $folder -ItemType Directory
            $bracketed = Join-Path -Path $folder -ChildPath 'out [1].csv'

            Export-ResultCsv -InputObject $script:rows -LiteralPath $bracketed -ErrorAction Stop

            Test-Path -LiteralPath $bracketed -PathType Leaf | Should-BeTrue
            @(Import-Csv -LiteralPath $bracketed) | Should-BeCollection -Count 2
        }

        It 'Writes no warning' {
            # On PowerShell 7.7, Export-Csv writes one for each call that passes -NoTypeInformation
            $warnings = @(
                Export-ResultCsv -InputObject $script:rows -LiteralPath $script:csv -ErrorAction Stop 3>&1
            )

            $warnings.Count | Should-Be 0 -Because "the call wrote: $($warnings -join '; ')"
        }

        It 'Writes nothing to the pipeline' {
            $output = @(Export-ResultCsv -InputObject $script:rows -LiteralPath $script:csv -ErrorAction Stop)

            $output.Count | Should-Be 0
        }

        It 'Passes -NoTypeInformation to Export-Csv on Windows PowerShell and on no other edition' {
            Mock -CommandName Export-Csv -MockWith { }

            Export-ResultCsv -InputObject $script:rows -LiteralPath $script:csv -ErrorAction Stop

            # A mock in a pipeline is counted once for each object that reaches it: two rows here
            Should-Invoke -CommandName Export-Csv -Times 2 -Exactly -ParameterFilter {
                $LiteralPath -eq $script:csv -and
                $PesterBoundParameters.ContainsKey('NoTypeInformation') -eq $script:onWindowsPowerShell
            }
            Should-Invoke -CommandName Export-Csv -Times 0 -Exactly -ParameterFilter {
                $PesterBoundParameters.ContainsKey('NoTypeInformation') -ne $script:onWindowsPowerShell
            }
        }

        It 'Writes nothing under -WhatIf' {
            Export-ResultCsv -InputObject $script:rows -LiteralPath $script:csv -WhatIf -ErrorAction Stop

            Test-Path -LiteralPath $script:csv | Should-BeFalse
        }
    }

    Context 'The callers of Export-Csv' {
        It 'Is one of the two places in Classes, Private and Public that call Export-Csv' {
            # A call elsewhere would have to decide about -NoTypeInformation again. The second
            # place is the method of StreamingResultsManager: a method of a class calls no
            # function of the module, so it makes the decision itself, and its own test holds it.
            $moduleRoot = (Resolve-Path -LiteralPath "$PSScriptRoot\..\..\..\..").Path
            $calls = foreach ($folder in 'Classes', 'Private', 'Public') {
                $folderPath = Join-Path -Path $moduleRoot -ChildPath $folder
                foreach ($file in Get-ChildItem -LiteralPath $folderPath -Filter '*.ps1' -File -Recurse) {
                    $tokens = $null
                    $parseErrors = $null
                    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                        $file.FullName, [ref]$tokens, [ref]$parseErrors)
                    $found = $ast.FindAll({
                            param($node)
                            $node -is [System.Management.Automation.Language.CommandAst] -and
                            $node.GetCommandName() -eq 'Export-Csv'
                        }, $true)
                    foreach ($call in $found) {
                        '{0}:{1}' -f $file.Name, $call.Extent.StartLineNumber
                    }
                }
            }
            $callers = @($calls | ForEach-Object { ($_ -split ':')[0] } | Sort-Object)

            $callers | Should-BeCollection -Count 2
            $callers[0] | Should-BeString 'Export-ResultCsv.ps1'
            $callers[1] | Should-BeString 'StreamingResultsManager.ps1'
        }
    }

    Context 'Error Handling' {
        It 'Ends with the error of the file system for a folder that does not exist' {
            $missing = Join-Path -Path $TestDrive -ChildPath "no-such-folder-$([guid]::NewGuid().ToString('N'))"
            $target = Join-Path -Path $missing -ChildPath 'out.csv'

            { Export-ResultCsv -InputObject $script:rows -LiteralPath $target } |
                Should-Throw -ExceptionType ([System.IO.DirectoryNotFoundException])

            Test-Path -LiteralPath $missing | Should-BeFalse
        }

        It 'Ends with the error of the file system for a file that is read-only, and leaves the file' {
            Set-Content -LiteralPath $script:csv -Value 'earlier content' -Encoding ascii
            (Get-Item -LiteralPath $script:csv).IsReadOnly = $true

            try {
                { Export-ResultCsv -InputObject $script:rows -LiteralPath $script:csv } |
                    Should-Throw -ExceptionType ([System.UnauthorizedAccessException])
            } finally {
                (Get-Item -LiteralPath $script:csv).IsReadOnly = $false
            }

            Get-Content -LiteralPath $script:csv -Raw | Should-BeString 'earlier content' -TrimWhitespace
        }

        It 'Raises the error also when the caller asks to continue silently' {
            $target = Join-Path -Path (Join-Path -Path $TestDrive -ChildPath 'absent') -ChildPath 'out.csv'

            { Export-ResultCsv -InputObject $script:rows -LiteralPath $target -ErrorAction SilentlyContinue } |
                Should-Throw -ExceptionType ([System.IO.DirectoryNotFoundException])
        }
    }
}
