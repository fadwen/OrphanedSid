#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
#Requires -Version 5.1

<#
.SYNOPSIS
    Unit tests for Stop-OrphanedSidSession, which every public command calls in its finally block.

.DESCRIPTION
    Tests the real function with Invoke-ResourceCleanup mocked and doubles for the streaming results
    manager and the memory manager. Covers the temp-file preservation flag, the fallback disposal when
    cleanup throws, and the state the function clears.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\..\Private\Core\Stop-OrphanedSidSession.ps1"

    function Write-StructuredLog { param($Message, $Level, $Component, $CorrelationId, $LogPath, $Data) }
    function Invoke-ResourceCleanup { param($MemoryManager, $AdditionalResources, $CorrelationId, [switch]$WhatIf) }

    function New-Disposable {
        $o = [PSCustomObject]@{ Disposed = $false; PreserveFiles = $false; TempDirectory = 'C:\Temp\run' }
        $o | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.Disposed = $true }
        return $o
    }
}

Describe 'Stop-OrphanedSidSession' -Tag 'Unit', 'Core', 'Private' {

    BeforeEach {
        Mock Write-StructuredLog { }
        Mock Invoke-ResourceCleanup { }
        $script:CorrelationId = 'session-1'
        $script:StreamingResults = New-Disposable
        $script:MemoryManager = New-Disposable
        $script:Statistics = [PSCustomObject]@{ Name = 'stats' }
        $script:RemovalResults = @('r1', 'r2')
    }

    Context 'Cleanup' {
        It 'Hands the memory manager and the streaming manager to the cleanup with WhatIf pinned off' {
            $manager = $script:MemoryManager
            $streaming = $script:StreamingResults

            Stop-OrphanedSidSession

            Should -Invoke Invoke-ResourceCleanup -Times 1 -Exactly -ParameterFilter {
                $MemoryManager -eq $manager -and @($AdditionalResources)[0] -eq $streaming -and
                $CorrelationId -eq 'session-1' -and $WhatIf -eq $false
            }
        }

        It 'Passes no extra resources when no streaming manager exists' {
            $script:StreamingResults = $null

            Stop-OrphanedSidSession

            Should -Invoke Invoke-ResourceCleanup -Times 1 -Exactly -ParameterFilter { @($AdditionalResources).Count -eq 0 }
        }

        It 'Uses the module correlation ID unless one is given' {
            Stop-OrphanedSidSession -CorrelationId 'override'

            Should -Invoke Invoke-ResourceCleanup -Times 1 -Exactly -ParameterFilter { $CorrelationId -eq 'override' }
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter { $Message -eq 'All resources cleaned up' -and $CorrelationId -eq 'override' }
        }
    }

    Context 'Temporary files' {
        It 'Marks the streaming manager to keep its files when asked, and says where they are' {
            $streaming = $script:StreamingResults

            Stop-OrphanedSidSession -PreserveTempFiles

            $streaming.PreserveFiles | Should -BeTrue
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter { $Message -eq 'Temporary result files preserved in: C:\Temp\run' }
        }

        It 'Leaves the files to disposal by default' {
            $streaming = $script:StreamingResults

            Stop-OrphanedSidSession

            $streaming.PreserveFiles | Should -BeFalse
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter { $Message -like 'Temporary result files will be cleaned up*' }
        }
    }

    Context 'SID classification cache (#111)' {
        It 'Drops the cache, so detection outside a run checks every rule' {
            $script:SIDClassificationCache = @{ 'S-1-5-21-1-2-3-500' = $true }

            Stop-OrphanedSidSession

            $script:SIDClassificationCache | Should -BeNullOrEmpty
        }
    }

    Context 'When cleanup throws' {
        It 'Warns, disposes both managers itself, and still clears the state' {
            Mock Invoke-ResourceCleanup { throw 'cleanup exploded' }
            Mock Write-Warning { }
            $manager = $script:MemoryManager
            $streaming = $script:StreamingResults

            Stop-OrphanedSidSession

            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like '*cleanup exploded*' }
            $manager.Disposed | Should -BeTrue
            $streaming.Disposed | Should -BeTrue
            $script:MemoryManager | Should -BeNullOrEmpty
            $script:StreamingResults | Should -BeNullOrEmpty
        }

        It 'Does not dispose a manager that is already disposed' {
            Mock Invoke-ResourceCleanup { throw 'cleanup exploded' }
            Mock Write-Warning { }
            $script:MemoryManager.Disposed = $true
            $script:MemoryManager | Add-Member -MemberType ScriptMethod -Name Dispose -Value { throw 'disposed twice' } -Force

            $streaming = $script:StreamingResults

            Stop-OrphanedSidSession

            # A second warning would mean the throwing Dispose ran
            Should -Invoke Write-Warning -Times 1 -Exactly
            $streaming.Disposed | Should -BeTrue
        }

        It 'Warns a second time when the fallback disposal fails too' {
            Mock Invoke-ResourceCleanup { throw 'cleanup exploded' }
            Mock Write-Warning { }
            $script:StreamingResults | Add-Member -MemberType ScriptMethod -Name Dispose -Value { throw 'dispose exploded' } -Force

            Stop-OrphanedSidSession

            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like 'Fallback cleanup failed:*dispose exploded*' }
        }
    }

    Context 'State afterwards' {
        It 'Clears every per-run module variable' {
            Stop-OrphanedSidSession

            $script:StreamingResults | Should -BeNullOrEmpty
            $script:MemoryManager | Should -BeNullOrEmpty
            $script:Statistics | Should -BeNullOrEmpty
            @($script:RemovalResults).Count | Should -Be 0
        }
    }
}
