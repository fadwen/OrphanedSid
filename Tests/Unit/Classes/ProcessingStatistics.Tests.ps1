#Requires -Version 5.1

BeforeAll {
    . $PSScriptRoot\..\..\..\Classes\ProcessingStatistics.ps1
}

Describe "ProcessingStatistics Class Tests" -Tag "Unit", "Classes", "ProcessingStatistics" {
    Context "Constructor Tests" {
        It "Should set StartTime to the time of construction" {
            $beforeCreate = Get-Date
            $stats = [ProcessingStatistics]::new()
            $afterCreate = Get-Date

            $stats.StartTime | Should -BeGreaterOrEqual $beforeCreate
            $stats.StartTime | Should -BeLessOrEqual $afterCreate
        }

        It "Should initialize counters to zero" {
            $stats = [ProcessingStatistics]::new()

            $stats.TotalObjects | Should -Be 0
            $stats.ProcessedObjects | Should -Be 0
            $stats.OrphanedSIDsFound | Should -Be 0
            $stats.UnverifiedSIDsFound | Should -Be 0
            $stats.ProcessingErrors | Should -Be 0
            $stats.CriticalErrors | Should -Be 0
            $stats.ObjectsPerSecond | Should -Be 0
            $stats.PeakMemoryUsageMB | Should -Be 0
        }

        It "Should leave EndTime and Duration unset until Complete is called" {
            $stats = [ProcessingStatistics]::new()

            $stats.EndTime | Should -Be ([DateTime]::MinValue)
            $stats.Duration | Should -Be ([TimeSpan]::Zero)
        }
    }

    Context "Property Tests" {
        It "Should declare the property types consumers rely on" {
            $stats = [ProcessingStatistics]::new()

            $stats.TotalObjects | Should -BeOfType [int]
            $stats.ProcessedObjects | Should -BeOfType [int]
            $stats.OrphanedSIDsFound | Should -BeOfType [int]
            $stats.UnverifiedSIDsFound | Should -BeOfType [int]
            $stats.ProcessingErrors | Should -BeOfType [int]
            $stats.CriticalErrors | Should -BeOfType [int]
            $stats.StartTime | Should -BeOfType [DateTime]
            $stats.EndTime | Should -BeOfType [DateTime]
            $stats.Duration | Should -BeOfType [TimeSpan]
            $stats.ObjectsPerSecond | Should -BeOfType [double]
            $stats.PeakMemoryUsageMB | Should -BeOfType [long]
        }
    }

    Context "Complete Method Tests" {
        BeforeEach {
            $script:testStats = [ProcessingStatistics]::new()
            $script:testStats.ProcessedObjects = 100
        }

        It "Should set EndTime to the time Complete is called" {
            $beforeComplete = Get-Date
            $script:testStats.Complete()
            $afterComplete = Get-Date

            $script:testStats.EndTime | Should -BeGreaterOrEqual $beforeComplete
            $script:testStats.EndTime | Should -BeLessOrEqual $afterComplete
        }

        It "Should set Duration to EndTime minus StartTime" {
            $script:testStats.StartTime = (Get-Date).AddMinutes(-5)

            $script:testStats.Complete()

            $script:testStats.Duration | Should -Be ($script:testStats.EndTime - $script:testStats.StartTime)
            $script:testStats.Duration.TotalMinutes | Should -BeGreaterOrEqual 5
        }

        It "Should calculate ObjectsPerSecond as processed objects over seconds, rounded to two places" {
            # A start 100 seconds back makes the rate about 10 per second
            $script:testStats.ProcessedObjects = 1000
            $script:testStats.StartTime = (Get-Date).AddSeconds(-100)

            $script:testStats.Complete()

            $expected = [Math]::Round(1000 / $script:testStats.Duration.TotalSeconds, 2)
            $script:testStats.ObjectsPerSecond | Should -Be $expected
            $script:testStats.ObjectsPerSecond | Should -BeGreaterThan 9.9
            $script:testStats.ObjectsPerSecond | Should -BeLessOrEqual 10
        }

        It "Should leave ObjectsPerSecond unchanged when Duration is not positive" {
            # A StartTime after EndTime gives a negative Duration, which must not produce a rate
            $script:testStats.StartTime = (Get-Date).AddHours(1)
            $script:testStats.ObjectsPerSecond = 0

            $script:testStats.Complete()

            $script:testStats.Duration.TotalSeconds | Should -BeLessThan 0
            $script:testStats.ObjectsPerSecond | Should -Be 0
        }

        It "Should report zero ObjectsPerSecond when nothing was processed" {
            $script:testStats.ProcessedObjects = 0
            $script:testStats.StartTime = (Get-Date).AddSeconds(-10)

            $script:testStats.Complete()

            $script:testStats.ObjectsPerSecond | Should -Be 0
        }

        It "Should recalculate EndTime and Duration on subsequent calls" {
            $script:testStats.Complete()
            $firstEndTime = $script:testStats.EndTime

            Start-Sleep -Milliseconds 50
            $script:testStats.Complete()

            $script:testStats.EndTime | Should -BeGreaterThan $firstEndTime
            $script:testStats.Duration | Should -Be ($script:testStats.EndTime - $script:testStats.StartTime)
        }

        It "Should not change the counters" {
            $script:testStats.TotalObjects = 100
            $script:testStats.ProcessedObjects = 95
            $script:testStats.OrphanedSIDsFound = 10
            $script:testStats.UnverifiedSIDsFound = 3

            $script:testStats.Complete()

            $script:testStats.TotalObjects | Should -Be 100
            $script:testStats.ProcessedObjects | Should -Be 95
            $script:testStats.OrphanedSIDsFound | Should -Be 10
            $script:testStats.UnverifiedSIDsFound | Should -Be 3
        }
    }
}
