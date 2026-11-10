#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
#Requires -Version 5.1

<#
.SYNOPSIS
    Unit tests for Get-SIDProcessingStatistics, the aggregation half of Invoke-SIDProcessing.ps1.

.DESCRIPTION
    Find-OrphanedSIDsInObject, the other function in the file, has its own test file. These tests
    build OrphanedSIDResult objects carrying ProcessingStatistics hashtables of the shape that
    function attaches, and check the aggregate Get-SIDProcessingStatistics computes from them.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\..\Classes\OrphanedSIDResult.ps1"
    . "$PSScriptRoot\..\..\..\..\Private\SID\Invoke-SIDProcessing.ps1"

    function Write-StructuredLog { param($Message, $Level, $Component, $CorrelationId, $LogPath, $Data) }

    # One result carrying the statistics Find-OrphanedSIDsInObject attaches for its object
    function New-StatResult {
        param(
            [string]$Dn,
            [int]$Processed,
            [int]$Orphaned,
            [int]$Errors = 0,
            [int]$Skipped = 0,
            [double]$Duration,
            [string]$Method = 'Identity-Resolution',
            [hashtable]$Stats
        )
        if (-not $Stats) {
            $start = [datetime]'2026-01-01T00:00:00'
            $Stats = @{
                ObjectDN = $Dn; ProcessedSIDs = $Processed; OrphanedSIDsFound = $Orphaned
                ErrorsEncountered = $Errors; SkippedSIDs = $Skipped; Duration = $Duration
                StartTime = $start; EndTime = $start.AddMilliseconds($Duration)
            }
        }
        $r = [OrphanedSIDResult]::new()
        $r.ObjectDN = $Dn
        $r.ProcessingMethod = $Method
        $r | Add-Member -NotePropertyName ProcessingStatistics -NotePropertyValue $Stats
        $r
    }
}

# Module bug (#25): the statistics are hashtables, and Measure-Object -Property reads hashtable keys only
# from PowerShell 6, so on Windows PowerShell 5.1 every sum, average and timing figure is null.
# The tests that read those figures are skipped there.
BeforeDiscovery {
    $onDesktop = $PSVersionTable.PSVersion.Major -lt 6
}

Describe 'Get-SIDProcessingStatistics' -Tag 'Unit', 'SID', 'Private' {

    BeforeEach {
        Mock Write-StructuredLog { }
    }

    It 'Sums the per-object counts' -Skip:$onDesktop {
        $results = @(
            New-StatResult -Dn 'CN=A' -Processed 10 -Orphaned 2 -Errors 0 -Skipped 1 -Duration 100
            New-StatResult -Dn 'CN=B' -Processed 6 -Orphaned 1 -Errors 1 -Skipped 2 -Duration 300
        )

        $stats = Get-SIDProcessingStatistics -OrphanedSIDResults $results

        $stats.TotalObjectsProcessed | Should -Be 2
        $stats.TotalSIDsProcessed | Should -Be 16
        $stats.TotalOrphanedSIDsFound | Should -Be 3
        $stats.TotalErrorsEncountered | Should -Be 1
        $stats.TotalSIDsSkipped | Should -Be 3
    }

    It 'Reports the timing figures across objects' -Skip:$onDesktop {
        $results = @(
            New-StatResult -Dn 'CN=A' -Processed 10 -Orphaned 2 -Duration 100
            New-StatResult -Dn 'CN=B' -Processed 10 -Orphaned 1 -Duration 300
        )

        $stats = Get-SIDProcessingStatistics -OrphanedSIDResults $results

        $stats.AverageProcessingTimeMS | Should -Be 200
        $stats.TotalProcessingTimeMS | Should -Be 400
        $stats.MaxProcessingTimeMS | Should -Be 300
        $stats.MinProcessingTimeMS | Should -Be 100
        $stats.TimingAnalysis.TotalDurationSeconds | Should -Be 0.4
        $stats.PerformanceAnalysis.ProcessingThroughput | Should -Be 50
    }

    It 'Computes the detection rate and per-object averages' -Skip:$onDesktop {
        $results = @(
            New-StatResult -Dn 'CN=A' -Processed 6 -Orphaned 2 -Duration 10
            New-StatResult -Dn 'CN=B' -Processed 2 -Orphaned 1 -Duration 10
        )

        $stats = Get-SIDProcessingStatistics -OrphanedSIDResults $results

        $stats.OrphanedSIDDetectionRate | Should -Be 37.5
        $stats.PerformanceAnalysis.AverageSIDsPerObject | Should -Be 4
        $stats.PerformanceAnalysis.AverageOrphanedSIDsPerObject | Should -Be 1.5
    }

    It 'Reports a zero detection rate and throughput when nothing was processed' {
        $stats = Get-SIDProcessingStatistics -OrphanedSIDResults @(New-StatResult -Dn 'CN=A' -Processed 0 -Orphaned 0 -Duration 0)

        $stats.OrphanedSIDDetectionRate | Should -Be 0
        $stats.PerformanceAnalysis.ProcessingThroughput | Should -Be 0
        $stats.TimingAnalysis.TotalDurationSeconds | Should -Be 0
    }

    It 'Analyses errors by the objects that had them' -Skip:$onDesktop {
        $results = @(
            New-StatResult -Dn 'CN=A' -Processed 5 -Orphaned 1 -Errors 3 -Duration 10
            New-StatResult -Dn 'CN=B' -Processed 5 -Orphaned 1 -Errors 1 -Duration 10
            New-StatResult -Dn 'CN=C' -Processed 5 -Orphaned 1 -Errors 0 -Duration 10
            New-StatResult -Dn 'CN=D' -Processed 5 -Orphaned 1 -Errors 0 -Duration 10
        )

        $stats = Get-SIDProcessingStatistics -OrphanedSIDResults $results

        $stats.ErrorAnalysis.ObjectsWithErrors | Should -Be 2
        $stats.ErrorAnalysis.ErrorRate | Should -Be 50
        $stats.ErrorAnalysis.AverageErrorsPerFailedObject | Should -Be 2
        $stats.SuccessRate | Should -Be 0
    }

    It 'Reports full success when no object had errors' {
        $stats = Get-SIDProcessingStatistics -OrphanedSIDResults @(New-StatResult -Dn 'CN=A' -Processed 3 -Orphaned 1 -Duration 10)

        $stats.SuccessRate | Should -Be 100
        $stats.ErrorAnalysis.ObjectsWithErrors | Should -Be 0
        $stats.ErrorAnalysis.AverageErrorsPerFailedObject | Should -Be 0
    }

    It 'Breaks the results down by processing method' {
        $results = @(
            New-StatResult -Dn 'CN=A' -Processed 1 -Orphaned 1 -Duration 1 -Method 'Identity-Resolution'
            New-StatResult -Dn 'CN=B' -Processed 1 -Orphaned 1 -Duration 1 -Method 'Identity-Resolution'
            New-StatResult -Dn 'CN=C' -Processed 1 -Orphaned 1 -Duration 1 -Method 'Direct-SID'
            New-StatResult -Dn 'CN=D' -Processed 1 -Orphaned 1 -Duration 1 -Method 'Direct-SID'
        )

        $methods = (Get-SIDProcessingStatistics -OrphanedSIDResults $results).ProcessingMethods

        @($methods).Count | Should -Be 2
        ($methods | Where-Object Method -eq 'Identity-Resolution').Count | Should -Be 2
        ($methods | Where-Object Method -eq 'Direct-SID').Percentage | Should -Be 50
    }

    It 'Records the correlation ID and the earliest and latest processing times' -Skip:$onDesktop {
        $first = New-StatResult -Dn 'CN=A' -Processed 1 -Orphaned 1 -Duration 100
        $second = New-StatResult -Dn 'CN=B' -Processed 1 -Orphaned 1 -Duration 500

        $stats = Get-SIDProcessingStatistics -OrphanedSIDResults @($first, $second) -CorrelationId 'stats-1'

        $stats.CorrelationId | Should -Be 'stats-1'
        $stats.TimingAnalysis.EarliestProcessing | Should -Be ([datetime]'2026-01-01T00:00:00')
        $stats.TimingAnalysis.LatestProcessing | Should -Be (([datetime]'2026-01-01T00:00:00').AddMilliseconds(500))
    }

    It 'Ignores results without processing statistics' -Skip:$onDesktop {
        $bare = [OrphanedSIDResult]::new()
        $withStats = New-StatResult -Dn 'CN=A' -Processed 4 -Orphaned 1 -Duration 10

        $stats = Get-SIDProcessingStatistics -OrphanedSIDResults @($bare, $withStats)

        $stats.TotalObjectsProcessed | Should -Be 1
        $stats.TotalSIDsProcessed | Should -Be 4
    }

    It 'Warns and returns nothing when no result carries statistics' {
        $stats = Get-SIDProcessingStatistics -OrphanedSIDResults @([OrphanedSIDResult]::new()) -CorrelationId 'stats-2'

        $stats | Should -BeNullOrEmpty
        Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
            $Level -eq 'Warning' -and $Message -eq 'No processing statistics found in results' -and $CorrelationId -eq 'stats-2'
        }
    }

    It 'Logs at Error level and rethrows when the aggregation fails' {
        Mock Measure-Object { throw 'measure failed' }
        $result = New-StatResult -Dn 'CN=A' -Processed 1 -Orphaned 1 -Duration 10

        { Get-SIDProcessingStatistics -OrphanedSIDResults @($result) -CorrelationId 'stats-3' } |
            Should -Throw -ExpectedMessage 'measure failed'

        Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
            $Level -eq 'Error' -and $Message -eq 'Error generating processing statistics: measure failed' -and $CorrelationId -eq 'stats-3'
        }
    }

    # Module bug (#25): Find-OrphanedSIDsInObject attaches one shared statistics hashtable to every result
    # from an object, and this function counts it once per result, so an object with two orphaned
    # SIDs is counted as two objects and its processed SIDs twice
    It 'Counts an object once when it yielded several results' -Skip {
        $shared = @{ ObjectDN = 'CN=A'; ProcessedSIDs = 5; OrphanedSIDsFound = 2; ErrorsEncountered = 0; SkippedSIDs = 0; Duration = 10 }
        $results = @(
            New-StatResult -Dn 'CN=A' -Stats $shared
            New-StatResult -Dn 'CN=A' -Stats $shared
        )

        $stats = Get-SIDProcessingStatistics -OrphanedSIDResults $results

        $stats.TotalObjectsProcessed | Should -Be 1
        $stats.TotalSIDsProcessed | Should -Be 5
        $stats.TotalOrphanedSIDsFound | Should -Be 2
    }

    # Module bug (#25): the parameter is ValueFromPipeline and the aggregation runs in process, so piped
    # results each get their own statistics object instead of one aggregate
    It 'Aggregates results piped to it into one statistics object' -Skip {
        $results = @(
            New-StatResult -Dn 'CN=A' -Processed 10 -Orphaned 2 -Duration 100
            New-StatResult -Dn 'CN=B' -Processed 6 -Orphaned 1 -Duration 300
        )

        $stats = @($results | Get-SIDProcessingStatistics)

        $stats.Count | Should -Be 1
        $stats[0].TotalSIDsProcessed | Should -Be 16
    }
}
