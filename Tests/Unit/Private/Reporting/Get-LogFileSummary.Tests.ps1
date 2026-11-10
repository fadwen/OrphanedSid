#Requires -Version 5.1

# Unit tests for Get-LogFileSummary.ps1 and the functions it defines. Every test writes a real log
# file under TestDrive and points the logging state at it, so Get-LogFileHealth and
# Get-LogFileStatistics run through the real Get-LogFileSummary and Get-LogContentAnalysis.
BeforeAll {
    $ModuleRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))

    . "$ModuleRoot\Private\Logging\Initialize-LoggingSystem.ps1"

    . "$ModuleRoot\Private\Reporting\Get-LogFileSummary.ps1"

    # Writes the lines to a log file under TestDrive and makes it the active log
    function Set-TestLog {
        param([string[]]$Lines = @())
        $script:TestLogPath = Join-Path $TestDrive "$([guid]::NewGuid()).log"
        if ($Lines.Count -gt 0) {
            Set-Content -Path $script:TestLogPath -Value $Lines
        } else {
            New-Item -Path $script:TestLogPath -ItemType File | Out-Null
        }
        $script:TestLogPath
    }

    # Builds log lines: the counts given for each level, in the format Write-StructuredLogEntry writes
    function New-TestLogLines {
        param([int]$Information = 0, [int]$Warning = 0, [int]$ErrorLines = 0, [int]$Critical = 0)
        $id = '12345678-1234-1234-1234-123456789abc'
        foreach ($i in 1..$Information) { if ($Information) { "[2026-01-15T08:00:00.000] [Information] [General] [$id] info $i" } }
        foreach ($i in 1..$Warning) { if ($Warning) { "[2026-01-15T08:00:00.000] [Warning] [General] [$id] warning $i" } }
        foreach ($i in 1..$ErrorLines) { if ($ErrorLines) { "[2026-01-15T08:00:00.000] [Error] [General] [$id] error $i" } }
        foreach ($i in 1..$Critical) { if ($Critical) { "[2026-01-15T08:00:00.000] [Critical] [General] [$id] critical $i" } }
    }

    # Presents the active log file to Get-LogFileSummary with a chosen size and timestamps. The
    # content is still read from the real file.
    function Set-TestLogMetadata {
        param([long]$Length, [datetime]$CreationTime = (Get-Date).AddDays(-7), [datetime]$LastWriteTime = (Get-Date).AddMinutes(-5))
        $script:TestLogItem = [PSCustomObject]@{
            Length = $Length
            CreationTime = $CreationTime
            LastWriteTime = $LastWriteTime
            LastAccessTime = Get-Date
        }
        Mock Get-Item { $script:TestLogItem } -ParameterFilter { $Path -eq $script:TestLogPath }
    }
}

Describe "Get-LogFileSummary" -Tag "Unit", "Private", "Reporting" {

    BeforeEach {
        Mock Get-LoggingSystemState {
            [PSCustomObject]@{ LogPath = $script:TestLogPath; CorrelationId = 'corr-123'; LogLevel = 'Warning' }
        }
        Mock Write-Warning { }
    }

    Context "Basic Functionality" {
        It "Should summarize the active log file" {
            $path = Set-TestLog -Lines (New-TestLogLines -Information 3 -Warning 2 -ErrorLines 1)

            $result = Get-LogFileSummary

            $result.PSObject.TypeNames[0] | Should -Be 'LogFileSummary'
            $result.LogPath | Should -Be $path
            $result.LineCount | Should -Be 6
            $result.InformationCount | Should -Be 3
            $result.WarningCount | Should -Be 2
            $result.ErrorCount | Should -Be 1
            $result.CriticalCount | Should -Be 0
        }

        It "Should report the file size in bytes and megabytes" {
            $path = Set-TestLog -Lines (New-TestLogLines -Information 2)

            $result = Get-LogFileSummary

            $result.SizeBytes | Should -Be (Get-Item $path).Length
            $result.SizeMB | Should -Be ([Math]::Round((Get-Item $path).Length / 1MB, 2))
        }

        It "Should report a large file size in megabytes" {
            Set-TestLog -Lines (New-TestLogLines -Information 1) | Out-Null
            Set-TestLogMetadata -Length 1048576

            (Get-LogFileSummary).SizeMB | Should -Be 1
        }

        It "Should include the file timestamps" {
            $path = Set-TestLog -Lines (New-TestLogLines -Information 1)
            $item = Get-Item $path

            $result = Get-LogFileSummary

            $result.CreatedTime | Should -Be $item.CreationTime
            $result.LastWriteTime | Should -Be $item.LastWriteTime
        }

        It "Should carry the logging state's correlation ID and log level" {
            Set-TestLog -Lines (New-TestLogLines -Information 1) | Out-Null

            $result = Get-LogFileSummary

            $result.CorrelationId | Should -Be 'corr-123'
            $result.LogLevel | Should -Be 'Warning'
        }

        It "Should stamp the analysis time" {
            Set-TestLog -Lines (New-TestLogLines -Information 1) | Out-Null
            $before = Get-Date

            $result = Get-LogFileSummary

            $result.AnalysisTimestamp | Should -BeOfType [DateTime]
            $result.AnalysisTimestamp | Should -BeGreaterOrEqual $before
        }
    }

    Context "Health flag" {
        It "Should report healthy when the log has no errors or critical entries" {
            Set-TestLog -Lines (New-TestLogLines -Information 5 -Warning 2) | Out-Null
            (Get-LogFileSummary).IsHealthy | Should -BeTrue
        }

        It "Should report unhealthy when the log has an error" {
            Set-TestLog -Lines (New-TestLogLines -Information 5 -ErrorLines 1) | Out-Null
            (Get-LogFileSummary).IsHealthy | Should -BeFalse
        }

        It "Should report unhealthy when the log has a critical entry" {
            Set-TestLog -Lines (New-TestLogLines -Information 5 -Critical 1) | Out-Null
            (Get-LogFileSummary).IsHealthy | Should -BeFalse
        }
    }

    Context "Error Handling" {
        It "Should return null when no log path configured" {
            $script:TestLogPath = $null
            Get-LogFileSummary | Should -BeNullOrEmpty
        }

        It "Should return null when log file does not exist" {
            $script:TestLogPath = Join-Path $TestDrive 'missing.log'
            Get-LogFileSummary | Should -BeNullOrEmpty
        }

        It "Should return null and warn when the file cannot be read" {
            Set-TestLog -Lines (New-TestLogLines -Information 1) | Out-Null
            Mock Get-Item { throw "Access denied" } -ParameterFilter { $Path -eq $script:TestLogPath }

            Get-LogFileSummary | Should -BeNullOrEmpty
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like "Failed to analyze log file*Access denied" }
        }
    }
}

Describe "Get-LogContentAnalysis" -Tag "Unit", "Private", "Reporting" {

    BeforeEach {
        Mock Write-Warning { }
    }

    Context "Parameter Validation" {
        It "Should throw on null LogFilePath" {
            { Get-LogContentAnalysis -LogFilePath $null } | Should -Throw
        }

        It "Should throw on empty LogFilePath" {
            { Get-LogContentAnalysis -LogFilePath "" } | Should -Throw
        }
    }

    Context "Counting" {
        It "Should count every line, including empty ones" {
            $path = Set-TestLog -Lines @('[Information] a', '', '[Information] b', '   ', '[Information] c')

            $result = Get-LogContentAnalysis -LogFilePath $path

            $result.LineCount | Should -Be 5
            $result.EmptyLineCount | Should -Be 2
            $result.InformationCount | Should -Be 3
        }

        It "Should return zero counts for an empty file" {
            $path = Set-TestLog

            $result = Get-LogContentAnalysis -LogFilePath $path

            $result.LineCount | Should -Be 0
            $result.ErrorCount | Should -Be 0
        }

        It "Should count each log level" {
            $path = Set-TestLog -Lines @(
                '[Information] [12345678-1234-1234-1234-123456789abc] info'
                '[Debug] [87654321-4321-4321-4321-cba987654321] debug'
                '[Verbose] verbose'
                '[Warning] warning'
                '[Error] error one'
                '[Error] error two'
                '[Critical] critical'
            )

            $result = Get-LogContentAnalysis -LogFilePath $path

            $result.InformationCount | Should -Be 1
            $result.DebugCount | Should -Be 1
            $result.VerboseCount | Should -Be 1
            $result.WarningCount | Should -Be 1
            $result.ErrorCount | Should -Be 2
            $result.CriticalCount | Should -Be 1
            $result.LineCount | Should -Be 7
        }

        It "Should count [Security] tags and 'Security event:' lines as security events" {
            $path = Set-TestLog -Lines @(
                '[Information] [Security] User authentication successful'
                '[Warning] [Security] Permission denied'
                '[Information] Security event: session timeout enforced'
                '[Information] Normal operation logged'
            )

            (Get-LogContentAnalysis -LogFilePath $path).SecurityEventCount | Should -Be 3
        }

        It "Should count only lines that carry a bracketed GUID correlation ID" {
            $path = Set-TestLog -Lines @(
                '[Information] [12345678-1234-1234-1234-123456789abc] With correlation'
                '[Information] Without correlation'
                '[Information] [not-a-guid] Short ID'
                '[Information] [87654321-4321-4321-4321-cba987654321] Another with correlation'
            )

            (Get-LogContentAnalysis -LogFilePath $path).CorrelationIdCount | Should -Be 2
        }
    }

    Context "Unreadable file" {
        It "Should warn and return zero counts when the file cannot be read" {
            $result = Get-LogContentAnalysis -LogFilePath (Join-Path $TestDrive 'does-not-exist.log')

            $result.LineCount | Should -Be 0
            $result.Keys.Count | Should -Be 10
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like 'Failed to perform content analysis*' }
        }
    }
}

Describe "Get-LogFileHealth" -Tag "Unit", "Private", "Reporting" {

    BeforeEach {
        Mock Get-LoggingSystemState {
            [PSCustomObject]@{ LogPath = $script:TestLogPath; CorrelationId = 'corr-123'; LogLevel = 'Information' }
        }
        Mock Write-Warning { }
    }

    Context "Healthy log" {
        It "Should score 100 and report Excellent with no issues" {
            $path = Set-TestLog -Lines (New-TestLogLines -Information 50 -Warning 5)

            $result = Get-LogFileHealth

            $result.PSObject.TypeNames[0] | Should -Be 'LogFileHealth'
            $result.HealthScore | Should -Be 100
            $result.HealthStatus | Should -Be 'Excellent'
            $result.ErrorRatio | Should -Be 0
            $result.LineCount | Should -Be 55
            @($result.Issues).Count | Should -Be 0
            @($result.Recommendations).Count | Should -Be 0
            $result.LogPath | Should -Be $path
        }
    }

    Context "Health deductions" {
        It "Should deduct 20 and recommend rotation for a file over 100 MB" {
            Set-TestLog -Lines (New-TestLogLines -Information 10) | Out-Null
            Set-TestLogMetadata -Length (150MB)

            $result = Get-LogFileHealth

            $result.HealthScore | Should -Be 80
            $result.HealthStatus | Should -Be 'Good'
            $result.FileSizeMB | Should -Be 150
            $result.Issues | Should -Be @('Large log file size: 150 MB')
            $result.Recommendations | Should -Be @('Consider log rotation or archiving')
        }

        It "Should deduct 30 when errors and critical entries exceed 10% of lines" {
            # 2 errors and 1 critical in 20 lines: 15%
            Set-TestLog -Lines (New-TestLogLines -Information 17 -ErrorLines 2 -Critical 1) | Out-Null

            $result = Get-LogFileHealth

            $result.HealthScore | Should -Be 70
            $result.HealthStatus | Should -Be 'Good'
            $result.ErrorRatio | Should -Be 15
            $result.Issues | Should -Be @('High error ratio: 15%')
            $result.Recommendations | Should -Be @('Investigate and resolve frequent errors')
        }

        It "Should not deduct for an error ratio of exactly 10%" {
            Set-TestLog -Lines (New-TestLogLines -Information 9 -ErrorLines 1) | Out-Null

            (Get-LogFileHealth).HealthScore | Should -Be 100
        }

        It "Should deduct 10 when the log has not been written for over 24 hours" {
            Set-TestLog -Lines (New-TestLogLines -Information 10) | Out-Null
            Set-TestLogMetadata -Length 1024 -LastWriteTime (Get-Date).AddHours(-30)

            $result = Get-LogFileHealth

            $result.HealthScore | Should -Be 90
            $result.HealthStatus | Should -Be 'Excellent'
            $result.HoursSinceLastWrite | Should -BeGreaterThan 29.9
            $result.Issues[0] | Should -BeLike 'No recent log activity*'
            $result.Recommendations | Should -Be @('Verify logging system is active')
        }

        It "Should report Fair when the error and activity deductions combine" {
            Set-TestLog -Lines (New-TestLogLines -Information 5 -ErrorLines 5) | Out-Null
            Set-TestLogMetadata -Length 1024 -LastWriteTime (Get-Date).AddDays(-2)

            $result = Get-LogFileHealth

            $result.HealthScore | Should -Be 60
            $result.HealthStatus | Should -Be 'Fair'
        }

        It "Should report Poor when every deduction applies" {
            Set-TestLog -Lines (New-TestLogLines -Information 5 -ErrorLines 4 -Critical 1) | Out-Null
            Set-TestLogMetadata -Length (150MB) -LastWriteTime (Get-Date).AddDays(-2)

            $result = Get-LogFileHealth

            $result.HealthScore | Should -Be 40
            $result.HealthStatus | Should -Be 'Poor'
            @($result.Issues).Count | Should -Be 3
            @($result.Recommendations).Count | Should -Be 3
        }
    }

    Context "No Log File Scenario" {
        It "Should report NoLogFile with a recommendation to initialize logging" {
            $script:TestLogPath = $null

            $result = Get-LogFileHealth

            $result.HealthStatus | Should -Be 'NoLogFile'
            $result.HealthScore | Should -Be 0
            $result.Issues | Should -Be @('No log file available for analysis')
            $result.Recommendations | Should -Be @('Initialize logging system and create log file')
        }
    }

    Context "Error Handling" {
        It "Should report Error with the failure message when the summary throws" {
            Mock Get-LoggingSystemState { throw "Simulated error" }

            $result = Get-LogFileHealth

            $result.HealthStatus | Should -Be 'Error'
            $result.HealthScore | Should -Be 0
            $result.Issues | Should -Be @('Health evaluation failed: Simulated error')
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -eq 'Failed to evaluate log file health: Simulated error' }
        }
    }
}

Describe "Get-LogFileStatistics" -Tag "Unit", "Private", "Reporting" {

    BeforeEach {
        Mock Get-LoggingSystemState {
            [PSCustomObject]@{ LogPath = $script:TestLogPath; CorrelationId = 'corr-123'; LogLevel = 'Information' }
        }
        Mock Write-Warning { }

        # 200 lines: 1 error, 2 warnings, 1 security event
        $lines = @(New-TestLogLines -Information 196 -Warning 2 -ErrorLines 1) + '[Information] [Security] audit entry'
        Set-TestLog -Lines $lines | Out-Null
        Set-TestLogMetadata -Length ([long](5.5MB)) -CreationTime (Get-Date).AddDays(-7)
    }

    Context "Parameter Validation" {
        It "Should reject Days of <Days>" -ForEach @(
            @{ Days = -1 }
            @{ Days = 0 }
            @{ Days = 31 }
        ) {
            { Get-LogFileStatistics -Days $Days } | Should -Throw
        }

        It "Should default to a 7 day analysis period" {
            (Get-LogFileStatistics).AnalysisPeriodDays | Should -Be 7
        }
    }

    Context "Statistics Calculation" {
        It "Should report entry count, rates and log path" {
            $result = Get-LogFileStatistics -Days 7

            $result.PSObject.TypeNames[0] | Should -Be 'LogFileStatistics'
            $result.TotalEntries | Should -Be 200
            $result.ErrorRate | Should -Be 0.5
            $result.WarningRate | Should -Be 1.0
            $result.SecurityEventRate | Should -Be 0.5
            $result.LogPath | Should -Be $script:TestLogPath
        }

        It "Should spread size growth and entries over the requested period" {
            $result = Get-LogFileStatistics -Days 14

            $result.AnalysisPeriodDays | Should -Be 14
            $result.AverageFileSizeGrowthMB | Should -Be 0.39
            $result.EstimatedDailyEntries | Should -Be 14
        }

        It "Should report the log file age from its creation time" {
            $result = Get-LogFileStatistics -Days 7

            $result.LogFileAge | Should -BeOfType [TimeSpan]
            [Math]::Round($result.LogFileAge.TotalDays) | Should -Be 7
        }
    }

    Context "Edge Cases" {
        It "Should report zero rates for an empty log" {
            Set-TestLog | Out-Null

            $result = Get-LogFileStatistics -Days 7

            $result.TotalEntries | Should -Be 0
            $result.ErrorRate | Should -Be 0
            $result.WarningRate | Should -Be 0
            $result.SecurityEventRate | Should -Be 0
        }

        It "Should return null and warn when no log file is available" {
            $script:TestLogPath = $null

            Get-LogFileStatistics -Days 7 | Should -BeNullOrEmpty
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -eq 'No log file available for statistical analysis' }
        }
    }

    Context "Error Handling" {
        It "Should return null and warn when the summary throws" {
            Mock Get-LoggingSystemState { throw "Log summary failed" }

            Get-LogFileStatistics -Days 7 | Should -BeNullOrEmpty
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -eq 'Failed to generate log file statistics: Log summary failed' }
        }
    }
}
