#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
#Requires -Version 5.1

<#
.SYNOPSIS
    Unit tests for the Export-DiagnosticData function

.DESCRIPTION
    Tests Export-DiagnosticData parameter validation, the diagnostic package it writes under
    TestDrive, and its error handling. Only its logging and log-summary collaborators are mocked.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot "..\..\..\..\Private\Reporting\Export-DiagnosticData.ps1")

    # Placeholders for functions defined in other files: Pester can only mock a command that exists
    function Get-LogFileSummary { param() }
    function Write-StructuredLogEntry { param($Message, $Level, $Component, $CorrelationId, $LogPath, [hashtable]$Details) }
}

Describe "Export-DiagnosticData" -Tag "Unit", "Private", "Reporting" {

    BeforeEach {
        Mock Get-LogFileSummary { [PSCustomObject]@{ TotalLines = 42; ErrorCount = 3 } }
        Mock Write-StructuredLogEntry { }
        Mock Write-Error { }
        # A real PathInfo carries its provider and drive, which take minutes to serialize at depth 10
        Mock Get-Location { 'C:\Diagnostics\Location' }
        $script:LogPath = $null
        $script:OutputRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString())
    }

    Context "Parameter Validation" {
        It "Should reject a null OutputPath" {
            { Export-DiagnosticData -OutputPath $null } | Should -Throw
        }

        It "Should reject an OutputPath that is not a valid path" {
            { Export-DiagnosticData -OutputPath 'C:\bad|path' } | Should -Throw -ExpectedMessage '*OutputPath must be a valid directory path*'
        }
    }

    Context "Diagnostic package" {
        It "Should create the output directory when it does not exist" {
            Test-Path $script:OutputRoot | Should -BeFalse

            Export-DiagnosticData -OutputPath $script:OutputRoot

            Test-Path $script:OutputRoot -PathType Container | Should -BeTrue
        }

        It "Should return a timestamped package directory under the output path" {
            $result = Export-DiagnosticData -OutputPath $script:OutputRoot

            Split-Path $result -Parent | Should -Be $script:OutputRoot
            Split-Path $result -Leaf | Should -Match '^Diagnostic-\d{8}-\d{6}$'
            Test-Path $result -PathType Container | Should -BeTrue
        }

        It "Should write the diagnostic, session, module and summary files" {
            $result = Export-DiagnosticData -OutputPath $script:OutputRoot

            @((Get-ChildItem $result -File).Name | Sort-Object) |
                Should -Be @('diagnostic-data.json', 'loaded-modules.json', 'package-summary.json', 'powershell-info.json')
        }

        It "Should record the correlation ID, process and log summary in diagnostic-data.json" {
            $result = Export-DiagnosticData -OutputPath $script:OutputRoot -CorrelationId 'diag-123'

            $data = Get-Content (Join-Path $result 'diagnostic-data.json') -Raw | ConvertFrom-Json
            $data.CorrelationId | Should -Be 'diag-123'
            $data.SystemInfo.ProcessId | Should -Be $PID
            $data.SystemInfo.MachineName | Should -Be $env:COMPUTERNAME
            $data.MemoryUsage.WorkingSetMB | Should -BeGreaterThan 0
            $data.LogInfo.TotalLines | Should -Be 42
            $data.PowerShellConfiguration.CurrentLocation | Should -Be 'C:\Diagnostics\Location'
        }

        It "Should list the loaded modules in loaded-modules.json" {
            $result = Export-DiagnosticData -OutputPath $script:OutputRoot

            $modules = Get-Content (Join-Path $result 'loaded-modules.json') -Raw | ConvertFrom-Json
            $modules.Name | Should -Contain 'Pester'
        }

        It "Should copy the current log file into the package" {
            $script:LogPath = Join-Path $TestDrive 'current.log'
            Set-Content -Path $script:LogPath -Value 'log line one'

            $result = Export-DiagnosticData -OutputPath $script:OutputRoot

            Get-Content (Join-Path $result 'current-log.log') | Should -Be 'log line one'
        }

        It "Should list every file and the correlation ID in package-summary.json" {
            $result = Export-DiagnosticData -OutputPath $script:OutputRoot -CorrelationId 'diag-456'

            $summary = Get-Content (Join-Path $result 'package-summary.json') -Raw | ConvertFrom-Json
            $summary.CorrelationId | Should -Be 'diag-456'
            $summary.PackagePath | Should -Be $result
            @($summary.FilesIncluded | Sort-Object) | Should -Be @('diagnostic-data.json', 'loaded-modules.json', 'powershell-info.json')
        }

        It "Should log the export with its path and file count" {
            $result = Export-DiagnosticData -OutputPath $script:OutputRoot -CorrelationId 'diag-789'

            Should -Invoke Write-StructuredLogEntry -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Information' -and
                $Component -eq 'Diagnostics' -and
                $CorrelationId -eq 'diag-789' -and
                $Details.ExportPath -eq $result -and
                $Details.FilesExported -eq 3
            }
        }

        It "Should record the failure in LogInfo when the log summary throws" {
            Mock Get-LogFileSummary { throw 'summary unavailable' }

            $result = Export-DiagnosticData -OutputPath $script:OutputRoot

            $data = Get-Content (Join-Path $result 'diagnostic-data.json') -Raw | ConvertFrom-Json
            $data.LogInfo.Error | Should -Be 'Log summary unavailable: summary unavailable'
        }

        It "Should create nothing under -WhatIf" {
            New-Item -Path $script:OutputRoot -ItemType Directory | Out-Null

            $result = Export-DiagnosticData -OutputPath $script:OutputRoot -WhatIf

            $result | Should -BeNullOrEmpty
            @(Get-ChildItem $script:OutputRoot).Count | Should -Be 0
        }
    }

    Context "Error Handling" {
        It "Should rethrow when the output directory cannot be created" {
            Mock New-Item { throw "Access denied" } -ParameterFilter { $Path -eq $script:OutputRoot }

            { Export-DiagnosticData -OutputPath $script:OutputRoot } | Should -Throw -ExpectedMessage '*Access denied*'
        }

        It "Should log the failure and rethrow when a package file cannot be written" {
            Mock Out-File { throw "Disk full" }

            { Export-DiagnosticData -OutputPath $script:OutputRoot -CorrelationId 'diag-err' } | Should -Throw -ExpectedMessage '*Disk full*'

            Should -Invoke Write-StructuredLogEntry -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Error' -and $Details.ErrorMessage -eq 'Disk full' -and $CorrelationId -eq 'diag-err'
            }
            Should -Invoke Write-Error -Times 1 -Exactly -ParameterFilter { $Message -eq 'Diagnostic export failed: Disk full' }
        }
    }
}
