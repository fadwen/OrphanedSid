#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
#Requires -Version 5.1

<#
.SYNOPSIS
    Unit tests for Invoke-Cleanup, the memory cleanup the memory manager triggers.

.DESCRIPTION
    Invoke-GarbageCollection.Tests.ps1 covers the sibling functions in the same file; this one runs
    Invoke-Cleanup itself with Get-CurrentMemoryUsage mocked so the before and after figures are
    known. The garbage collector really runs; it is fast and harmless.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\..\Private\System\Invoke-GarbageCollection.ps1"

    function Write-StructuredLog { param($Message, $Level, $Component, $CorrelationId, $LogPath, $Data) }
    function Get-CurrentMemoryUsage { }
}

Describe 'Invoke-Cleanup' -Tag 'Unit', 'System', 'Private' {

    BeforeEach {
        Mock Write-StructuredLog { }
        $script:readings = [System.Collections.Generic.Queue[double]]::new()
        $script:readings.Enqueue(300.5); $script:readings.Enqueue(250.25)
        Mock Get-CurrentMemoryUsage { [PSCustomObject]@{ WorkingSetMB = $script:readings.Dequeue() } }
    }

    It 'Reports the memory before, after and freed, with three collection cycles' {
        $result = Invoke-Cleanup -CorrelationId 'gc-1'

        $result.PSTypeNames | Should -Contain 'MemoryCleanupResult'
        $result.MemoryBeforeMB | Should -Be 300.5
        $result.MemoryAfterMB | Should -Be 250.25
        $result.MemoryFreedMB | Should -Be 50.25
        $result.Success | Should -BeTrue
        $result.GCCycles | Should -Be 3
        $result.LOHCompactionUsed | Should -BeFalse
        $result.WhatIfMode | Should -BeFalse
        $result.CorrelationId | Should -Be 'gc-1'
        Should -Invoke Get-CurrentMemoryUsage -Times 2 -Exactly
        Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter { $Message -eq 'Starting memory cleanup operation...' -and $Component -eq 'MemoryManagement' }
        Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter { $Message -eq 'Memory after cleanup: 250.25 MB (Freed: 50.25 MB)' -and $Level -eq 'Information' }
    }

    It 'Reports no success when nothing was freed' {
        $script:readings.Clear(); $script:readings.Enqueue(200); $script:readings.Enqueue(210)

        $result = Invoke-Cleanup

        $result.MemoryFreedMB | Should -Be -10
        $result.Success | Should -BeFalse
    }

    It 'Compacts the large object heap when asked and says so' {
        $result = Invoke-Cleanup -IncludeLOHCompaction

        $result.LOHCompactionUsed | Should -BeTrue
        Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter { $Message -eq 'Large Object Heap compaction enabled' }
    }

    It 'Generates a correlation ID when given a blank one' {
        $result = Invoke-Cleanup -CorrelationId '   '

        [guid]::TryParse($result.CorrelationId, [ref][guid]::Empty) | Should -BeTrue
    }

    It 'Under -WhatIf still measures and collects but logs only the simulation' {
        $result = Invoke-Cleanup -WhatIf

        $result.WhatIfMode | Should -BeTrue
        $result.MemoryBeforeMB | Should -Be 300.5
        Should -Invoke Get-CurrentMemoryUsage -Times 2 -Exactly
        Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter { $Message -eq 'WhatIf simulation: memory cleanup would be performed' }
        Should -Invoke Write-StructuredLog -Times 0 -Exactly -ParameterFilter { $Message -eq 'Starting memory cleanup operation...' }
    }

    It 'Logs at Error level and stops when the memory reading fails' {
        Mock Get-CurrentMemoryUsage { throw 'counter unavailable' }

        { Invoke-Cleanup -CorrelationId 'gc-2' } | Should -Throw -ExpectedMessage '*counter unavailable*'
        Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'Error' -and $Message -eq 'Cleanup failed: counter unavailable' -and $CorrelationId -eq 'gc-2' }
    }
}
