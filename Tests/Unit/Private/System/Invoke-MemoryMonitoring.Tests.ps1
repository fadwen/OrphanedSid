#Requires -Version 5.1

BeforeAll {
    # Pester can only mock a command that exists. The real Write-StructuredLog lives in another file;
    # this placeholder is what the Mock below replaces when the file runs on its own.
    if (-not (Get-Command Write-StructuredLog -ErrorAction SilentlyContinue)) {
        function Write-StructuredLog { param($Message, $Level, $Component, $CorrelationId, $LogPath, $Data) }
    }

    . "$PSScriptRoot\..\..\..\..\Classes\MemoryManager.ps1"

    . "$PSScriptRoot\..\..\..\..\Private\System\Invoke-MemoryMonitoring.ps1"

    . "$PSScriptRoot\..\..\..\..\Private\System\Get-MemoryStatistics.ps1"
}

Describe "Invoke-MemoryCheck" -Tag 'Unit' {
    BeforeEach {
        $script:mockMemoryManager = [MemoryManager]::new(1024, 25, 'test-correlation-id')

        # Pester cannot mock a .NET static method, so the function reads [System.GC] through
        # these wrappers
        Mock Get-SystemGCTotalMemory { return 500MB }
        Mock Get-SystemGCCollectionCount { return 10 + $Generation }
        Mock Write-StructuredLog { }
        Mock Write-Verbose { }
    }

    Context "Parameter Validation" {
        It "Should require MemoryManager parameter" {
            $command = Get-Command Invoke-MemoryCheck
            $attribute = $command.Parameters['MemoryManager'].Attributes | Where-Object { $_ -is [Parameter] }
            $attribute.Mandatory | Should -Be $true
        }

        It "Should use the CorrelationId it is given" {
            $result = Invoke-MemoryCheck -MemoryManager $script:mockMemoryManager -CorrelationId 'test-id'

            $result.CorrelationId | Should -Be 'test-id'
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter { $CorrelationId -eq 'test-id' }
        }

        It "Should use the MemoryManager's CorrelationId when none is given" {
            $result = Invoke-MemoryCheck -MemoryManager $script:mockMemoryManager
            $result.CorrelationId | Should -Be 'test-correlation-id'
        }

        It "Should use the MemoryManager's CorrelationId when a blank one is given" {
            $result = Invoke-MemoryCheck -MemoryManager $script:mockMemoryManager -CorrelationId '  '
            $result.CorrelationId | Should -Be 'test-correlation-id'
        }

        It "Should reject an object that is not a MemoryManager" {
            $invalidObject = [PSCustomObject]@{ Name = 'Invalid' }
            { Invoke-MemoryCheck -MemoryManager $invalidObject } | Should -Throw -ExpectedMessage '*MemoryManager*'
        }

        It "Should reject a null MemoryManager" {
            { Invoke-MemoryCheck -MemoryManager $null } | Should -Throw -ExpectedMessage '*MemoryManager*'
        }

        It "Should accept the MemoryManager from the pipeline" {
            $result = $script:mockMemoryManager | Invoke-MemoryCheck

            $result.MaxMemoryMB | Should -Be 1024
        }
    }

    Context "Memory Threshold Checking" {
        It "Should report <MB> MB against a 1024 MB threshold as exceeded: <Exceeded>" -ForEach @(
            @{ MB = 200; Exceeded = $false }
            @{ MB = 1024; Exceeded = $false }
            @{ MB = 1025; Exceeded = $true }
            @{ MB = 5120; Exceeded = $true }
        ) {
            $bytes = $MB * 1MB
            Mock Get-SystemGCTotalMemory { $bytes }

            $result = Invoke-MemoryCheck -MemoryManager $script:mockMemoryManager

            $result.CurrentMemoryMB | Should -Be $MB
            $result.ThresholdExceeded | Should -Be $Exceeded
        }

        It "Should calculate memory usage percentage" {
            Mock Get-SystemGCTotalMemory { return 512MB }  # 50% of 1024 MB

            $result = Invoke-MemoryCheck -MemoryManager $script:mockMemoryManager

            $result.MemoryUsagePercent | Should -Be 50
            $result.MemoryToThresholdRatio | Should -Be 0.5
        }

        It "Should report usage above 100% when the threshold is far exceeded" {
            Mock Get-SystemGCTotalMemory { return 5120MB }

            $result = Invoke-MemoryCheck -MemoryManager $script:mockMemoryManager

            $result.MemoryUsagePercent | Should -Be 500
        }
    }

    Context "Memory Status Classification" {
        It "Should classify <MB> MB of 1024 MB as <Status>" -ForEach @(
            @{ MB = 200; Status = 'Normal' }
            @{ MB = 768; Status = 'Normal' }     # exactly 75%
            @{ MB = 800; Status = 'High' }       # 78.1%
            @{ MB = 922; Status = 'High' }       # 90.04% rounds to 90.0, which is not above 90
            @{ MB = 923; Status = 'Critical' }   # 90.1%
            @{ MB = 1500; Status = 'Critical' }
        ) {
            $bytes = $MB * 1MB
            Mock Get-SystemGCTotalMemory { $bytes }

            (Invoke-MemoryCheck -MemoryManager $script:mockMemoryManager).MemoryStatus | Should -Be $Status
        }

        It "Should recommend nothing at Normal usage" {
            $result = Invoke-MemoryCheck -MemoryManager $script:mockMemoryManager

            @($result.Recommendations).Count | Should -Be 0
        }

        It "Should recommend garbage collection at High usage" {
            Mock Get-SystemGCTotalMemory { return 800MB }

            $result = Invoke-MemoryCheck -MemoryManager $script:mockMemoryManager

            $result.Recommendations | Should -Be @('Consider running garbage collection')
        }

        It "Should recommend stopping, LOH compaction and a threshold review at Critical usage over the threshold" {
            Mock Get-SystemGCTotalMemory { return 1500MB }

            $result = Invoke-MemoryCheck -MemoryManager $script:mockMemoryManager

            $result.Recommendations | Should -Be @(
                'Immediate action required: Stop processing and run garbage collection'
                'Consider LOH compaction for large object cleanup'
                'Consider adjusting memory threshold settings'
            )
        }
    }

    Context "Check interval" {
        It "Should count one operation towards the interval without -Force" {
            Invoke-MemoryCheck -MemoryManager $script:mockMemoryManager | Out-Null

            $script:mockMemoryManager.CheckCounter | Should -Be 1
        }

        It "Should force a check on this call with -Force, which resets the counter" {
            $script:mockMemoryManager.CheckCounter = 5

            Invoke-MemoryCheck -MemoryManager $script:mockMemoryManager -Force | Out-Null

            # -Force sets the counter to the interval; CheckMemoryUsage then checks and resets it to 0
            $script:mockMemoryManager.CheckCounter | Should -Be 0
            $script:mockMemoryManager.PeakMemoryUsage | Should -BeGreaterThan 0
        }
    }

    Context "Result Properties" {
        It "Should report the threshold, GC totals and collection counts per generation" {
            $result = Invoke-MemoryCheck -MemoryManager $script:mockMemoryManager

            $result.MaxMemoryMB | Should -Be 1024
            $result.SystemMemoryTotal | Should -Be 500MB
            $result.Gen0Collections | Should -Be 10
            $result.Gen1Collections | Should -Be 11
            $result.Gen2Collections | Should -Be 12
            $result.WhatIfMode | Should -Be $false
        }

        It "Should set monitoring time to current time" {
            $beforeTime = Get-Date
            $result = Invoke-MemoryCheck -MemoryManager $script:mockMemoryManager
            $afterTime = Get-Date

            $result.MonitoringTime | Should -BeGreaterOrEqual $beforeTime
            $result.MonitoringTime | Should -BeLessOrEqual $afterTime
        }

        It "Should log the check at Debug level" {
            Invoke-MemoryCheck -MemoryManager $script:mockMemoryManager | Out-Null

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Message -eq 'Performing memory check...' -and $Level -eq 'Debug' -and
                $Component -eq 'MemoryManagement' -and $CorrelationId -eq 'test-correlation-id'
            }
        }
    }

    Context "Error Handling" {
        It "Should log a Warning and rethrow when the memory reading fails" {
            Mock Get-SystemGCTotalMemory { throw "Insufficient memory" }

            { Invoke-MemoryCheck -MemoryManager $script:mockMemoryManager -CorrelationId 'err-id' } |
                Should -Throw -ExpectedMessage 'Insufficient memory'

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Warning' -and $Message -eq 'Memory check operation failed: Insufficient memory' -and
                $CorrelationId -eq 'err-id'
            }
        }
    }

    Context "WhatIf Support" {
        It "Should still measure under -WhatIf but log only a verbose note" {
            $result = Invoke-MemoryCheck -MemoryManager $script:mockMemoryManager -WhatIf

            $result.CurrentMemoryMB | Should -Be 500
            $result.WhatIfMode | Should -Be $true
            $script:mockMemoryManager.CheckCounter | Should -Be 1
            Should -Invoke Write-StructuredLog -Times 0 -Exactly
            Should -Invoke Write-Verbose -Times 1 -Exactly -ParameterFilter {
                $Message -eq 'WhatIf: Would check memory usage and cleanup if needed'
            }
        }
    }
}

Describe "Test-MemoryThreshold" -Tag 'Unit' {
    BeforeEach {
        Mock Get-CurrentMemoryUsage { [PSCustomObject]@{ WorkingSetMB = 500 } }
    }

    Context "Parameter Validation" {
        It "Should reject ThresholdMB <Value>, outside 128-32768" -ForEach @(
            @{ Value = 127 }
            @{ Value = 32769 }
        ) {
            { Test-MemoryThreshold -ThresholdMB $Value } | Should -Throw -ExpectedMessage '*ThresholdMB*'
        }

        It "Should reject an unknown ThresholdType" {
            { Test-MemoryThreshold -ThresholdMB 1024 -ThresholdType 'Severe' } | Should -Throw -ExpectedMessage '*ThresholdType*'
        }
    }

    Context "Basic Threshold Testing" {
        It "Should report usage under the threshold as Low with no action" {
            $result = Test-MemoryThreshold -ThresholdMB 1000

            $result.PSObject.TypeNames[0] | Should -Be 'MemoryThresholdResult'
            $result.ThresholdExceeded | Should -Be $false
            $result.CurrentMemoryMB | Should -Be 500
            $result.ThresholdMB | Should -Be 1000
            $result.ThresholdType | Should -Be 'Warning'
            $result.UtilizationPercent | Should -Be 50
            $result.Severity | Should -Be 'Low'
            $result.RecommendedAction | Should -Be 'No action required'
        }

        It "Should not treat usage equal to the threshold as exceeded" {
            Mock Get-CurrentMemoryUsage { [PSCustomObject]@{ WorkingSetMB = 1024 } }

            (Test-MemoryThreshold -ThresholdMB 1024).ThresholdExceeded | Should -Be $false
        }

        It "Should rate an exceeded <ThresholdType> threshold as <Severity>: <Action>" -ForEach @(
            @{ ThresholdType = 'Warning'; Severity = 'Medium'; Action = 'Monitor and consider cleanup' }
            @{ ThresholdType = 'Critical'; Severity = 'High'; Action = 'Immediate garbage collection recommended' }
            @{ ThresholdType = 'Emergency'; Severity = 'Critical'; Action = 'Cleanup required immediately' }
        ) {
            Mock Get-CurrentMemoryUsage { [PSCustomObject]@{ WorkingSetMB = 2048 } }

            $result = Test-MemoryThreshold -ThresholdMB 1024 -ThresholdType $ThresholdType

            $result.ThresholdExceeded | Should -Be $true
            $result.UtilizationPercent | Should -Be 200
            $result.Severity | Should -Be $Severity
            $result.RecommendedAction | Should -Be $Action
        }
    }

    Context "Error Handling" {
        It "Should stop with a message naming the failure" {
            Mock Get-CurrentMemoryUsage { throw 'counter unavailable' }

            { Test-MemoryThreshold -ThresholdMB 1024 } | Should -Throw -ExpectedMessage 'Memory threshold test failed: counter unavailable'
        }
    }
}
