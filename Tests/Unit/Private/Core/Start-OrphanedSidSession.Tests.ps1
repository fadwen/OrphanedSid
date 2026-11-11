#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
#Requires -Version 5.1

<#
.SYNOPSIS
    Unit tests for Start-OrphanedSidSession, which every public command calls first.

.DESCRIPTION
    Tests the real function with Initialize-ScriptExecution mocked. Covers the RSAT check, the default
    log path under the current directory, the log level taken from -Verbose and -Debug, the per-run
    state reset and the state the function leaves in module scope.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\..\Private\Core\Start-OrphanedSidSession.ps1"

    function Write-StructuredLog { param($Message, $Level, $Component, $CorrelationId, $LogPath, $Data) }
    function Initialize-ScriptExecution { param($ConfigPath, $LogPath, $MaxMemoryUsageMB, $CorrelationId, $LogLevel, [switch]$UseConfigLogLevel, [switch]$SuppressConsoleOutput) }
}

Describe 'Start-OrphanedSidSession' -Tag 'Unit', 'Core', 'Private' {

    BeforeEach {
        Mock Write-StructuredLog { }
        Mock Initialize-ScriptExecution {
            @{
                Config        = [PSCustomObject]@{ BatchSize = 50 }
                MemoryManager = [PSCustomObject]@{ Name = 'manager' }
                Statistics    = [PSCustomObject]@{ Name = 'stats' }
                LogPath       = $LogPath
                CorrelationId = $CorrelationId
            }
        }
        $script:StreamingResults = 'stale'
        $script:RemovalResults = @('stale')
        $script:CurrentDomainSID = 'S-1-5-21-stale'
        $script:priorLocation = Get-Location
        Set-Location $TestDrive
    }

    AfterEach {
        Set-Location $script:priorLocation
    }

    Context 'Parameter validation' {
        It 'Requires a command name' {
            { Start-OrphanedSidSession -CommandName '' } | Should -Throw -ExpectedMessage '*CommandName*'
        }

        It 'Rejects a memory limit outside 100-16384' {
            { Start-OrphanedSidSession -CommandName 'Find-OrphanedSid' -MaxMemoryUsageMB 50 } | Should -Throw -ExpectedMessage '*MaxMemoryUsageMB*'
        }

        It 'Rejects an unknown log level' {
            { Start-OrphanedSidSession -CommandName 'Find-OrphanedSid' -LogLevel 'Chatty' } | Should -Throw -ExpectedMessage '*LogLevel*'
        }
    }

    Context 'Active Directory requirement' {
        It 'Stops with installation guidance when the ActiveDirectory module is not installed' {
            Mock Get-Module { $null }

            { Start-OrphanedSidSession -CommandName 'Find-OrphanedSid' -RequireActiveDirectory } |
                Should -Throw -ExpectedMessage '*ActiveDirectory PowerShell module is not available*Rsat.ActiveDirectory*'
            Should -Invoke Initialize-ScriptExecution -Times 0 -Exactly
        }

        It 'Imports the module when it is installed but not loaded' {
            Mock Get-Module { if ($ListAvailable) { [PSCustomObject]@{ Name = 'ActiveDirectory' } } else { $null } }
            Mock Import-Module { }

            Start-OrphanedSidSession -CommandName 'Find-OrphanedSid' -RequireActiveDirectory | Out-Null

            Should -Invoke Import-Module -Times 1 -Exactly -ParameterFilter { $Name -eq 'ActiveDirectory' }
        }

        It 'Does not import the module again when it is already loaded' {
            Mock Get-Module { [PSCustomObject]@{ Name = 'ActiveDirectory' } }
            Mock Import-Module { }

            Start-OrphanedSidSession -CommandName 'Find-OrphanedSid' -RequireActiveDirectory | Out-Null

            Should -Invoke Import-Module -Times 0 -Exactly
        }

        It 'Does not look for the module unless asked' {
            Mock Get-Module { throw 'should not be called' }

            Start-OrphanedSidSession -CommandName 'Find-OrphanedSid' | Out-Null

            Should -Invoke Get-Module -Times 0 -Exactly
            Should -Invoke Initialize-ScriptExecution -Times 1 -Exactly
        }
    }

    Context 'Log path and level' {
        It 'Defaults the log to .\Logs\<Command>_<timestamp>.log under the current directory: <Case>' -ForEach @(
            @{ Case = 'no -LogPath'; Given = $null }
            @{ Case = 'a -LogPath of only spaces'; Given = '   ' }
        ) {
            $parameters = @{ CommandName = 'Remove-OrphanedSid' }
            if ($null -ne $Given) { $parameters.LogPath = $Given }
            Start-OrphanedSidSession @parameters | Out-Null

            $expectedFolder = Join-Path (Get-Location).Path 'Logs'
            Should -Invoke Initialize-ScriptExecution -Times 1 -Exactly -ParameterFilter {
                $LogPath -like "$expectedFolder\Remove-OrphanedSid_????????_??????.log"
            }
        }

        It 'Uses the log path it is given' {
            Start-OrphanedSidSession -CommandName 'Find-OrphanedSid' -LogPath 'C:\Logs\run.log' | Out-Null

            Should -Invoke Initialize-ScriptExecution -Times 1 -Exactly -ParameterFilter { $LogPath -eq 'C:\Logs\run.log' }
        }

        It 'Raises the log level to Verbose when -Verbose is in effect and no level was given' {
            $VerbosePreference = 'Continue'

            Start-OrphanedSidSession -CommandName 'Find-OrphanedSid' | Out-Null

            Should -Invoke Initialize-ScriptExecution -Times 1 -Exactly -ParameterFilter { $LogLevel -eq 'Verbose' }
            $script:LogLevel | Should -Be 'Verbose'
        }

        It 'Raises the log level to Debug when -Debug is in effect and no level was given' {
            $DebugPreference = 'Continue'

            Start-OrphanedSidSession -CommandName 'Find-OrphanedSid' | Out-Null

            Should -Invoke Initialize-ScriptExecution -Times 1 -Exactly -ParameterFilter { $LogLevel -eq 'Debug' }
        }

        It 'Keeps an explicitly bound log level even under -Verbose' {
            $VerbosePreference = 'Continue'

            Start-OrphanedSidSession -CommandName 'Find-OrphanedSid' -LogLevel 'Warning' -LogLevelBound $true | Out-Null

            Should -Invoke Initialize-ScriptExecution -Times 1 -Exactly -ParameterFilter { $LogLevel -eq 'Warning' }
        }

        It "Lets the configuration file's LogLevel apply only when the command line chose no level (#43): <Case>" -ForEach @(
            @{ Case = 'nothing chosen'; Bound = $false; Verbose = $false; Debug = $false; Expected = $true }
            @{ Case = '-LogLevel bound'; Bound = $true; Verbose = $false; Debug = $false; Expected = $false }
            @{ Case = '-Verbose'; Bound = $false; Verbose = $true; Debug = $false; Expected = $false }
            @{ Case = '-Debug'; Bound = $false; Verbose = $false; Debug = $true; Expected = $false }
        ) {
            if ($Verbose) { $VerbosePreference = 'Continue' }
            if ($Debug) { $DebugPreference = 'Continue' }

            Start-OrphanedSidSession -CommandName 'Find-OrphanedSid' -LogLevelBound $Bound | Out-Null

            Should -Invoke Initialize-ScriptExecution -Times 1 -Exactly -ParameterFilter { [bool]$UseConfigLogLevel -eq $Expected }
        }
    }

    Context 'Module state' {
        It 'Resets the per-run state before initializing and records the results after' {
            $result = Start-OrphanedSidSession -CommandName 'Find-OrphanedSid' -CorrelationId 'start-1' -SuppressConsoleOutput -ConfigPath 'C:\cfg.json' -MaxMemoryUsageMB 2048

            $script:StreamingResults | Should -BeNullOrEmpty
            $script:RemovalResults | Should -BeNullOrEmpty
            $script:CurrentDomainSID | Should -BeNullOrEmpty
            $script:CorrelationId | Should -Be 'start-1'
            $script:SuppressConsoleOutput | Should -BeTrue
            $script:Config.BatchSize | Should -Be 50
            $script:MemoryManager.Name | Should -Be 'manager'
            $script:Statistics.Name | Should -Be 'stats'
            $script:LogPath | Should -Be $result.LogPath
            $result.CorrelationId | Should -Be 'start-1'
            Should -Invoke Initialize-ScriptExecution -Times 1 -Exactly -ParameterFilter {
                $ConfigPath -eq 'C:\cfg.json' -and $MaxMemoryUsageMB -eq 2048 -and $CorrelationId -eq 'start-1' -and $SuppressConsoleOutput
            }
        }

        It 'Logs the command start with the correlation ID' {
            Start-OrphanedSidSession -CommandName 'Restore-OrphanedSidBackup' -CorrelationId 'start-2' | Out-Null

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Message -eq 'Restore-OrphanedSidBackup starting (CorrelationId: start-2)' -and $Level -eq 'Information' -and $Component -eq 'Main'
            }
        }
    }
}
