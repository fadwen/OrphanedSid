#Requires -Version 5.1

BeforeAll {
    $ScriptPath = $PSScriptRoot

    $ModulePath = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptPath)))

    . "$ModulePath\Classes\MemoryManager.ps1"

    . "$ModulePath\Private\System\Get-MemoryStatistics.ps1"

    function New-Usage {
        param([double]$WorkingSetMB, [int]$Gen2Collections = 0)
        [PSCustomObject]@{ WorkingSetMB = $WorkingSetMB; Gen2Collections = $Gen2Collections }
    }
}

Describe "Get-CurrentMemoryUsage" -Tag 'Unit' {
    Context "Memory Statistics Collection" {
        It "Should report the process memory in MB, rounded to two places, for the current process" {
            Mock Get-Process {
                [PSCustomObject]@{
                    WorkingSet64 = 512MB + 5KB
                    PrivateMemorySize64 = 256MB
                    VirtualMemorySize64 = 2GB
                }
            }

            $result = Get-CurrentMemoryUsage

            $result.PSObject.TypeNames[0] | Should -Be 'MemoryUsageStatistics'
            $result.ProcessId | Should -Be $PID
            $result.WorkingSetMB | Should -Be 512
            $result.PrivateMemoryMB | Should -Be 256
            $result.VirtualMemoryMB | Should -Be 2048
            Should -Invoke Get-Process -Times 1 -Exactly -ParameterFilter { $Id -eq $PID }
        }

        It "Should include the GC totals and collection counts" {
            $result = Get-CurrentMemoryUsage

            $result.GCTotalMemoryMB | Should -BeGreaterThan 0
            $result.Gen0Collections | Should -BeOfType [int]
            $result.Gen0Collections | Should -BeGreaterOrEqual $result.Gen1Collections
            $result.Gen1Collections | Should -BeGreaterOrEqual $result.Gen2Collections
            $result.Timestamp | Should -BeOfType [DateTime]
        }

        It "Should warn and return nothing when the process cannot be read" {
            Mock Get-Process { throw 'access denied' }
            Mock Write-Warning { }

            $result = Get-CurrentMemoryUsage

            $result | Should -BeNullOrEmpty
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -eq 'Failed to retrieve memory usage: access denied' }
        }
    }
}

Describe "Get-MemoryUsageReport" -Tag 'Unit' {
    BeforeEach {
        $script:manager = [MemoryManager]::new(1000, 30, 'report-id')
        Mock Get-CurrentMemoryUsage { New-Usage -WorkingSetMB 700 }
    }

    Context "Parameter Validation" {
        It "Should reject a null MemoryManager" {
            { Get-MemoryUsageReport -MemoryManager $null } | Should -Throw -ExpectedMessage '*MemoryManager*'
        }
    }

    Context "Report Generation" {
        It "Should carry the manager's settings, correlation ID, current usage and peak" {
            $script:manager.PeakMemoryUsage = 640

            $result = Get-MemoryUsageReport -MemoryManager $script:manager

            $result.PSObject.TypeNames[0] | Should -Be 'MemoryUsageReport'
            $result.CorrelationId | Should -Be 'report-id'
            $result.Configuration.MaxMemoryThresholdMB | Should -Be 1000
            $result.Configuration.CheckInterval | Should -Be 30
            $result.CurrentUsage.WorkingSetMB | Should -Be 700
            $result.PeakUsageMB | Should -Be 640
            $result.GeneratedAt | Should -BeOfType [DateTime]
            $result.PSObject.Properties.Name | Should -Not -Contain 'Recommendations'
        }

        It "Should compute ThresholdUtilization as working set over threshold, as a percentage to one place" {
            Mock Get-CurrentMemoryUsage { New-Usage -WorkingSetMB 333.33 }

            $result = Get-MemoryUsageReport -MemoryManager $script:manager

            $result.ThresholdUtilization | Should -Be 33.3
        }

        It "Should rate <WorkingSetMB> MB of a 1000 MB threshold as <Expected>" -ForEach @(
            @{ WorkingSetMB = 799; Expected = 'Excellent' }
            @{ WorkingSetMB = 800; Expected = 'Good' }
            @{ WorkingSetMB = 899; Expected = 'Good' }
            @{ WorkingSetMB = 900; Expected = 'Acceptable' }
            @{ WorkingSetMB = 999; Expected = 'Acceptable' }
            @{ WorkingSetMB = 1000; Expected = 'Concerning' }
        ) {
            $ws = $WorkingSetMB
            Mock Get-CurrentMemoryUsage { New-Usage -WorkingSetMB $ws }

            (Get-MemoryUsageReport -MemoryManager $script:manager).PerformanceStatus | Should -Be $Expected
        }
    }

    Context "Recommendations" {
        It "Should report usage as optimal when no rule fires" {
            $result = Get-MemoryUsageReport -MemoryManager $script:manager -IncludeRecommendations

            $result.Recommendations | Should -Be @('Memory usage is within optimal parameters')
        }

        It "Should recommend a threshold 1.5 times larger above 90% utilization" {
            Mock Get-CurrentMemoryUsage { New-Usage -WorkingSetMB 950 }

            $result = Get-MemoryUsageReport -MemoryManager $script:manager -IncludeRecommendations

            $result.Recommendations | Should -Be @('Consider increasing memory threshold to 1500 MB')
        }

        It "Should flag more than 10 Gen2 collections" {
            Mock Get-CurrentMemoryUsage { New-Usage -WorkingSetMB 100 -Gen2Collections 11 }

            $result = Get-MemoryUsageReport -MemoryManager $script:manager -IncludeRecommendations

            $result.Recommendations | Should -Be @('High Gen2 collections detected - review object lifecycle management')
        }

        It "Should flag a peak above 120% of the threshold" {
            $script:manager.PeakMemoryUsage = 1201

            $result = Get-MemoryUsageReport -MemoryManager $script:manager -IncludeRecommendations

            $result.Recommendations | Should -Be @('Peak usage exceeded threshold - consider more frequent memory checks')
        }

        It "Should list every rule that fires, without the optimal note" {
            Mock Get-CurrentMemoryUsage { New-Usage -WorkingSetMB 950 -Gen2Collections 11 }
            $script:manager.PeakMemoryUsage = 1300

            $result = Get-MemoryUsageReport -MemoryManager $script:manager -IncludeRecommendations

            @($result.Recommendations).Count | Should -Be 3
            $result.Recommendations | Should -Not -Contain 'Memory usage is within optimal parameters'
        }
    }

    Context "Error Handling" {
        It "Should stop with a message naming the failure" {
            Mock Get-CurrentMemoryUsage { throw 'counter unavailable' }

            { Get-MemoryUsageReport -MemoryManager $script:manager } |
                Should -Throw -ExpectedMessage 'Failed to generate memory usage report: counter unavailable'
        }
    }
}
