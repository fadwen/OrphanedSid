#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
#Requires -Version 5.1

<#
.SYNOPSIS
    Contract tests for the workflow files under .github/workflows.

.DESCRIPTION
    Reads the workflow files as text. GitHub replaces an expression, ${{ ... }}, before the shell
    reads the script of a step, so a value that is written into a script that way is script text.
    The name of a tag or of a branch may hold a quote and a semicolon, and whoever can push one
    chooses it. A step takes such a value from an environment variable instead (#167).

    The files are not parsed as YAML: no YAML parser ships with Windows PowerShell 5.1. A run
    script is the text of a `run:` key, on its own line or in the block that follows `run: |`,
    and the block ends at the first line that is not indented more deeply than the key.
#>

BeforeDiscovery {
    $repositoryRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    $workflowFolder = Join-Path -Path (Join-Path -Path $repositoryRoot -ChildPath '.github') -ChildPath 'workflows'
    $workflows = @(
        Get-ChildItem -LiteralPath $workflowFolder -File |
            Where-Object { $_.Extension -in '.yml', '.yaml' } |
            ForEach-Object { @{ Name = $_.Name; FullName = $_.FullName } }
    )
}

BeforeAll {
    function Get-ExpressionInRunScript {
        <#
        .SYNOPSIS
        Lists the lines of the run scripts in workflow text that hold a GitHub expression.
        #>
        [CmdletBinding()]
        [OutputType([string])]
        param(
            [Parameter(Mandatory)]
            [AllowEmptyString()]
            [string[]]$Line
        )

        # The indentation of the run key whose block is being read, or -1 outside a block
        $blockIndent = -1
        for ($index = 0; $index -lt $Line.Count; $index++) {
            $text = $Line[$index]
            if ($text.Trim().Length -eq 0) {
                continue
            }

            $indent = $text.Length - $text.TrimStart().Length
            if ($blockIndent -ge 0 -and $indent -le $blockIndent) {
                $blockIndent = -1
            }

            if ($blockIndent -ge 0) {
                if ($text.Contains('${{')) {
                    'line {0}: {1}' -f ($index + 1), $text.Trim()
                }
                continue
            }

            if ($text -match '^\s*(-\s+)?run:\s*[|>][+-]?\d*\s*$') {
                $blockIndent = $indent
            } elseif ($text -match '^\s*(-\s+)?run:\s*\S' -and $text.Contains('${{')) {
                'line {0}: {1}' -f ($index + 1), $text.Trim()
            }
        }
    }
}

Describe 'Workflow files' -Tag 'Unit', 'Contract' {

    Context 'The helper that reads a run script' {
        It 'Finds an expression in a run block and in a run line, and none outside a script' {
            $sample = @(
                'jobs:'
                '  build:'
                '    if: ${{ github.event_name == ''push'' }}'
                '    steps:'
                '      - name: In a block'
                '        env:'
                '          SAFE: ${{ github.ref_name }}'
                '        run: |'
                '          $tag = ''${{ github.ref_name }}'''
                ''
                '          Write-Host $env:SAFE'
                '      - run: echo ${{ github.ref }}'
                '      - name: After a block'
                '        with:'
                '          value: ${{ inputs.dryRun }}'
            )

            $found = @(Get-ExpressionInRunScript -Line $sample)

            $found | Should-BeCollection -Count 2
            $found[0] | Should-BeString 'line 9: $tag = ''${{ github.ref_name }}''' -CaseSensitive
            $found[1] | Should-BeString 'line 12: - run: echo ${{ github.ref }}' -CaseSensitive
        }
    }

    Context 'Run scripts' {
        It 'Writes no expression into a run script of <Name> (#167)' -ForEach $workflows {
            $lines = [System.IO.File]::ReadAllLines($FullName)

            $found = @(Get-ExpressionInRunScript -Line $lines)

            $reason = "an expression in a run script is script text; found $($found -join '; ')"
            $found.Count | Should-Be 0 -Because $reason
        }
    }
}
