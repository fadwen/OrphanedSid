#Requires -Version 5.1

<#
.SYNOPSIS
    Pester tests for the Invoke-GarbageCollection private function

.DESCRIPTION
    Runs Invoke-GarbageCollection with its [System.GC] wrappers (Invoke-GCCollect,
    Invoke-GCWaitForPendingFinalizers, Get-GCTotalMemory) mocked, so the collection strategy, the
    memory figures it reports, -WhatIf and its error handling can be asserted exactly.
    Invoke-Cleanup, from the same file, is covered by Invoke-Cleanup.Tests.ps1.

.NOTES
    PowerShell Version: 5.1+

    Author: Jeffrey Stuhr
#>

BeforeAll {
    # The constants Invoke-Cleanup reads are defined once, in Initialize-MemoryManager.ps1
    . "$PSScriptRoot\..\..\..\..\Private\System\Initialize-MemoryManager.ps1"
    . "$PSScriptRoot\..\..\..\..\Private\System\Invoke-GarbageCollection.ps1"

    function Write-StructuredLog { param($Message, $Level, $Component, $CorrelationId) }
}

Describe "Invoke-GarbageCollection" -Tag 'Unit' {

    BeforeEach {
        Mock Write-StructuredLog { }
        Mock Write-Verbose { }
        Mock Invoke-GCCollect { }
        Mock Invoke-GCWaitForPendingFinalizers { }
        # 1000 MB before the collection, 800 MB after the forced full measurement
        Mock Get-GCTotalMemory { if ($ForceFullCollection) { 800MB } else { 1000MB } }
    }

    Context "Parameter Validation" {
        It "Should reject Generation <Value>, outside -1 to 2" -ForEach @(
            @{ Value = -2 }
            @{ Value = 3 }
        ) {
            { Invoke-GarbageCollection -Generation $Value } | Should -Throw -ExpectedMessage '*Generation*'
            Should -Invoke Invoke-GCCollect -Times 0 -Exactly
        }

        It "Should replace a blank CorrelationId with a GUID" {
            $result = Invoke-GarbageCollection -CorrelationId '   '

            $result.CorrelationId | Should -Match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
        }
    }

    Context "Collection strategy" {
        It "Should collect, wait for finalizers and collect again by default" {
            $result = Invoke-GarbageCollection

            Should -Invoke Invoke-GCCollect -Times 2 -Exactly -ParameterFilter { -not $PSBoundParameters.ContainsKey('Generation') }
            Should -Invoke Invoke-GCWaitForPendingFinalizers -Times 1 -Exactly
            $result.GenerationsCollected | Should -Be @(0, 1, 2)
        }

        It "Should collect only generation <Generation> when one is named" -ForEach @(
            @{ Generation = 0 }
            @{ Generation = 1 }
            @{ Generation = 2 }
        ) {
            $requested = $Generation

            $result = Invoke-GarbageCollection -Generation $requested

            Should -Invoke Invoke-GCCollect -Times 1 -Exactly
            Should -Invoke Invoke-GCCollect -Times 1 -Exactly -ParameterFilter { $Generation -eq $requested }
            Should -Invoke Invoke-GCWaitForPendingFinalizers -Times 0 -Exactly
            $result.GenerationsCollected | Should -Be @($requested)
        }
    }

    Context "Result" {
        It "Should report memory before, after and freed in MB, with the correlation ID" {
            $result = Invoke-GarbageCollection -CorrelationId 'gc-1'

            $result | Should -BeOfType [PSCustomObject]
            $result.Success | Should -Be $true
            $result.MemoryBefore | Should -Be 1000
            $result.MemoryAfter | Should -Be 800
            $result.MemoryFreed | Should -Be 200
            $result.CorrelationId | Should -Be 'gc-1'
            $result.WhatIfMode | Should -Be $false
            $result.CollectionTime | Should -BeOfType [TimeSpan]
            Should -Invoke Get-GCTotalMemory -Times 1 -Exactly -ParameterFilter { $ForceFullCollection -eq $true }
        }

        It "Should log the start and the amount freed" {
            Invoke-GarbageCollection -CorrelationId 'gc-2'

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Message -eq 'Starting garbage collection...' -and $Level -eq 'Information' -and
                $Component -eq 'GarbageCollection' -and $CorrelationId -eq 'gc-2'
            }
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Message -eq 'Garbage collection completed. Freed: 200 MB' -and $CorrelationId -eq 'gc-2'
            }
        }
    }

    Context "Memory pressure" {
        It "Should warn when more than 1000 MB is in use" {
            Mock Get-GCTotalMemory { if ($ForceFullCollection) { 800MB } else { 1001MB } }

            Invoke-GarbageCollection | Out-Null

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Warning' -and $Message -eq 'High memory pressure detected: 1001 MB'
            }
        }

        It "Should not warn at exactly 1000 MB" {
            Invoke-GarbageCollection | Out-Null

            Should -Invoke Write-StructuredLog -Times 0 -Exactly -ParameterFilter { $Level -eq 'Warning' }
        }
    }

    Context "Large Object Heap" {
        AfterEach {
            [System.Runtime.GCSettings]::LargeObjectHeapCompactionMode = [System.Runtime.GCLargeObjectHeapCompactionMode]::Default
        }

        It "Should report and log LOH compaction when asked" {
            $result = Invoke-GarbageCollection -CompactLOH
            [System.Runtime.GCSettings]::LargeObjectHeapCompactionMode = [System.Runtime.GCLargeObjectHeapCompactionMode]::Default

            $result.LOHCompacted | Should -Be $true
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter { $Message -eq 'LOH compaction enabled' }
        }

        It "Should not report LOH compaction by default" {
            (Invoke-GarbageCollection).LOHCompacted | Should -Be $false
            Should -Invoke Write-StructuredLog -Times 0 -Exactly -ParameterFilter { $Message -eq 'LOH compaction enabled' }
        }

        It "Should request a one-time LOH compaction before collecting" {
            # Invoke-GCCollect is mocked, so no collection consumes the request before it is read
            try {
                Invoke-GarbageCollection -CompactLOH | Out-Null

                [System.Runtime.GCSettings]::LargeObjectHeapCompactionMode | Should -Be ([System.Runtime.GCLargeObjectHeapCompactionMode]::CompactOnce)
            }
            finally {
                [System.Runtime.GCSettings]::LargeObjectHeapCompactionMode = [System.Runtime.GCLargeObjectHeapCompactionMode]::Default
            }
        }

        It "Should not request LOH compaction for a generation 0 or 1 collection, and say why" {
            [System.Runtime.GCSettings]::LargeObjectHeapCompactionMode = [System.Runtime.GCLargeObjectHeapCompactionMode]::Default

            $result = Invoke-GarbageCollection -CompactLOH -Generation 1

            $result.LOHCompacted | Should -Be $false
            [System.Runtime.GCSettings]::LargeObjectHeapCompactionMode | Should -Be ([System.Runtime.GCLargeObjectHeapCompactionMode]::Default)
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Message -eq 'LOH compaction skipped: it needs a generation 2 collection, not generation 1'
            }
        }

        It "Should not report LOH compaction under -WhatIf" {
            (Invoke-GarbageCollection -CompactLOH -WhatIf).LOHCompacted | Should -Be $false
        }
    }

    Context "WhatIf" {
        It "Should not collect under -WhatIf and report memory unchanged" {
            $result = Invoke-GarbageCollection -WhatIf

            Should -Invoke Invoke-GCCollect -Times 0 -Exactly
            Should -Invoke Invoke-GCWaitForPendingFinalizers -Times 0 -Exactly
            $result.WhatIfMode | Should -Be $true
            $result.MemoryBefore | Should -Be 1000
            $result.MemoryAfter | Should -Be 1000
            $result.MemoryFreed | Should -Be 0
            Should -Invoke Write-Verbose -Times 1 -Exactly -ParameterFilter { $Message -eq 'WhatIf: Would perform garbage collection' }
            Should -Invoke Write-StructuredLog -Times 0 -Exactly
        }
    }

    Context "Error Handling" {
        It "Should log the failure at Error level and rethrow when collection fails" {
            Mock Invoke-GCCollect { throw 'Test collection error' }

            { Invoke-GarbageCollection -CorrelationId 'error-test-id' } | Should -Throw -ExpectedMessage 'Test collection error'

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Error' -and $Message -eq 'Garbage collection failed: Test collection error' -and
                $CorrelationId -eq 'error-test-id'
            }
        }

        It "Should stop when the memory measurement fails" {
            Mock Get-GCTotalMemory { throw 'Memory measurement failed' }

            { Invoke-GarbageCollection } | Should -Throw -ExpectedMessage '*Memory measurement failed*'
            Should -Invoke Invoke-GCCollect -Times 0 -Exactly
        }
    }
}
