# Unit tests for Initialize-LoggingConfiguration.ps1
BeforeAll {
    $here = $PSScriptRoot

    $sut = (Split-Path -Leaf $PSCommandPath) -replace '\.Tests\.', '.'

    $modulePath = "$here\..\..\..\..\Private\Logging\$sut"

    . $modulePath
}

Describe "Initialize-LoggingConfiguration" -Tag @('Unit', 'Logging', 'Configuration') {

    BeforeAll {
    Mock Write-Verbose { } -Verifiable
    }

    Context "Shared Logging State Variables" {
        # These tests describe the state the file leaves behind when it loads. Other tests in this file
        # change that state, and a shuffled run may put them first, so the file is loaded again.
        BeforeEach {
            . $modulePath
        }

        
        It "Should initialize LogPath as null" {
            $script:LogPath | Should -BeNullOrEmpty
        }

        It "Should initialize LogFileInitialized as false" {
            $script:LogFileInitialized | Should -Be $false
        }

        It "Should initialize LogFileReinitAttempted as false" {
            $script:LogFileReinitAttempted | Should -Be $false
        }

        It "Should initialize SuppressConsoleOutput as false" {
            $script:SuppressConsoleOutput | Should -Be $false
        }

        It "Should initialize CorrelationId as null" {
            $script:CorrelationId | Should -BeNullOrEmpty
        }

        It "Should initialize LogLevel as Information" {
            $script:LogLevel | Should -Be 'Information'
        }
    }

    Context "Log Level Hierarchy" {
        
        It "Should define LogLevels with correct hierarchy" {
            $script:LogLevels | Should -Not -BeNullOrEmpty
            $script:LogLevels.Count | Should -Be 6
        }

        It "Should have Critical as highest priority (0)" {
            $script:LogLevels['Critical'] | Should -Be 0
        }

        It "Should have Error as priority 1" {
            $script:LogLevels['Error'] | Should -Be 1
        }

        It "Should have Warning as priority 2" {
            $script:LogLevels['Warning'] | Should -Be 2
        }

        It "Should have Information as priority 3" {
            $script:LogLevels['Information'] | Should -Be 3
        }

        It "Should have Debug as priority 4" {
            $script:LogLevels['Debug'] | Should -Be 4
        }

        It "Should have Verbose as lowest priority (5)" {
            $script:LogLevels['Verbose'] | Should -Be 5
        }
    }

    Context "Logging System Metadata" {
        # These tests describe the state the file leaves behind when it loads. Other tests in this file
        # change that state, and a shuffled run may put them first, so the file is loaded again.
        BeforeEach {
            . $modulePath
        }

        
        It "Should initialize LoggingSystemInfo with version" {
            $script:LoggingSystemInfo | Should -Not -BeNullOrEmpty
            $script:LoggingSystemInfo.Version | Should -Be '2.0.0'
        }

        It "Should set InitializedAt timestamp" {
            $script:LoggingSystemInfo.InitializedAt | Should -Not -BeNullOrEmpty
            $script:LoggingSystemInfo.InitializedAt | Should -BeOfType [DateTime]
        }

        It "Should initialize ModulesLoaded array" {
            $script:LoggingSystemInfo.ModulesLoaded | Should -Not -BeNullOrEmpty
            $script:LoggingSystemInfo.ModulesLoaded -contains 'Initialize-LoggingConfiguration' | Should -Be $true
        }

        It "Should set ConfigurationSource to Default" {
            $script:LoggingSystemInfo.ConfigurationSource | Should -Be 'Default'
        }
    }

    Context "Performance Tracking Metrics" {
        # These tests describe the state the file leaves behind when it loads. Other tests in this file
        # change that state, and a shuffled run may put them first, so the file is loaded again.
        BeforeEach {
            . $modulePath
        }

        
        It "Should initialize LoggingMetrics structure" {
            $script:LoggingMetrics | Should -Not -BeNullOrEmpty
            $script:LoggingMetrics.TotalLogEntries | Should -Be 0
        }

        It "Should initialize LogEntriesByLevel with all levels" {
            $script:LoggingMetrics.LogEntriesByLevel | Should -Not -BeNullOrEmpty
            $script:LoggingMetrics.LogEntriesByLevel.Count | Should -Be 6
            $script:LoggingMetrics.LogEntriesByLevel.Critical | Should -Be 0
            $script:LoggingMetrics.LogEntriesByLevel.Error | Should -Be 0
            $script:LoggingMetrics.LogEntriesByLevel.Warning | Should -Be 0
            $script:LoggingMetrics.LogEntriesByLevel.Information | Should -Be 0
            $script:LoggingMetrics.LogEntriesByLevel.Debug | Should -Be 0
            $script:LoggingMetrics.LogEntriesByLevel.Verbose | Should -Be 0
        }

        It "Should initialize timing metrics to zero" {
            $script:LoggingMetrics.AverageLogTimeMs | Should -Be 0
            $script:LoggingMetrics.TotalLogTimeMs | Should -Be 0
            $script:LoggingMetrics.LastLogEntryTime | Should -BeNullOrEmpty
        }
    }

    Context "Configuration Validation Rules" {
        
        It "Should define valid log levels array" {
            $script:LoggingValidation.ValidLogLevels | Should -Not -BeNullOrEmpty
            $script:LoggingValidation.ValidLogLevels.Count | Should -Be 6
            $script:LoggingValidation.ValidLogLevels -contains 'Critical' | Should -Be $true
            $script:LoggingValidation.ValidLogLevels -contains 'Error' | Should -Be $true
            $script:LoggingValidation.ValidLogLevels -contains 'Warning' | Should -Be $true
            $script:LoggingValidation.ValidLogLevels -contains 'Information' | Should -Be $true
            $script:LoggingValidation.ValidLogLevels -contains 'Debug' | Should -Be $true
            $script:LoggingValidation.ValidLogLevels -contains 'Verbose' | Should -Be $true
        }

        It "Should define maximum log file size limit" {
            $script:LoggingValidation.MaxLogFileSizeMB | Should -Be 100
        }

        It "Should define maximum retention days" {
            $script:LoggingValidation.MaxRetentionDays | Should -Be 30
        }

        It "Should define required path characters pattern" {
            $pattern = $script:LoggingValidation.RequiredPathCharacters
            ('C:\Logs\OrphanedSid\run.log' -match $pattern) | Should -BeTrue
            ('C:\Logs\OrphanedSid\run.txt' -match $pattern) | Should -BeFalse
            ('C:\Logs\bad|name.log' -match $pattern) | Should -BeFalse
        }
    }
}

Describe "Get-LoggingState" -Tag @('Unit', 'Logging', 'State') {

    Context "State Retrieval" {
        # These tests describe the state the file leaves behind when it loads. Other tests in this file
        # change that state, and a shuffled run may put them first, so the file is loaded again.
        BeforeEach {
            . $modulePath
        }

        
        It "Should report the current value of each state variable" {
            # Every variable is set away from its load-time default so a missing or miswired property fails
            $script:LogPath = 'C:\logs\state.log'
            $script:LogFileInitialized = $true
            $script:LogFileReinitAttempted = $true
            $script:SuppressConsoleOutput = $true
            $script:CorrelationId = 'state-correlation'
            $script:LogLevel = 'Debug'

            $state = Get-LoggingState

            $state.LogPath | Should -Be 'C:\logs\state.log'
            $state.LogFileInitialized | Should -BeTrue
            $state.LogFileReinitAttempted | Should -BeTrue
            $state.SuppressConsoleOutput | Should -BeTrue
            $state.CorrelationId | Should -Be 'state-correlation'
            $state.LogLevel | Should -Be 'Debug'
        }

        It "Should include the level hierarchy, system info, metrics and validation rules" {
            $state = Get-LoggingState

            $state.LogLevels['Warning'] | Should -Be 2
            $state.SystemInfo.Version | Should -Be '2.0.0'
            $state.Metrics.TotalLogEntries | Should -Be 0
            $state.ValidationRules.MaxLogFileSizeMB | Should -Be 100
        }

        It "Should return copies that a caller cannot use to change the logging state" {
            $state = Get-LoggingState

            $state.LogLevels['Warning'] = 99
            $state.SystemInfo.Version = 'tampered'
            $state.Metrics.TotalLogEntries = 99
            $state.ValidationRules.MaxLogFileSizeMB = 1

            $script:LogLevels['Warning'] | Should -Be 2
            $script:LoggingSystemInfo.Version | Should -Be '2.0.0'
            $script:LoggingMetrics.TotalLogEntries | Should -Be 0
            $script:LoggingValidation.MaxLogFileSizeMB | Should -Be 100
        }
    }
}

Describe "Update-LoggingMetrics" -Tag @('Unit', 'Logging', 'Metrics') {

    Context "Metrics Updates" {
        
        BeforeEach {
            # Reset metrics for each test
            $script:LoggingMetrics.TotalLogEntries = 0
            $script:LoggingMetrics.LogEntriesByLevel = @{
                Critical = 0; Error = 0; Warning = 0
                Information = 0; Debug = 0; Verbose = 0
            }
            $script:LoggingMetrics.TotalLogTimeMs = 0
            $script:LoggingMetrics.AverageLogTimeMs = 0
        }

        It "Should increment total log entries" {
            Update-LoggingMetrics -Level 'Information'
            $script:LoggingMetrics.TotalLogEntries | Should -Be 1
        }

        It "Should increment specific level counter" {
            Update-LoggingMetrics -Level 'Error'
            $script:LoggingMetrics.LogEntriesByLevel['Error'] | Should -Be 1
        }

        It "Should update last log entry time" {
            $beforeTime = Get-Date
            Update-LoggingMetrics -Level 'Information'
            $script:LoggingMetrics.LastLogEntryTime | Should -Not -BeNullOrEmpty
            $script:LoggingMetrics.LastLogEntryTime | Should -BeGreaterThan $beforeTime.AddSeconds(-1)
        }

        It "Should update timing metrics when ProcessingTimeMs provided" {
            Update-LoggingMetrics -Level 'Information' -ProcessingTimeMs 100
            $script:LoggingMetrics.TotalLogTimeMs | Should -Be 100
            $script:LoggingMetrics.AverageLogTimeMs | Should -Be 100
        }

        It "Should calculate correct average processing time" {
            Update-LoggingMetrics -Level 'Information' -ProcessingTimeMs 100
            Update-LoggingMetrics -Level 'Warning' -ProcessingTimeMs 200
            $script:LoggingMetrics.AverageLogTimeMs | Should -Be 150
        }
    }
}

Describe "Set-LogLevel and Get-LogLevel" -Tag @('Unit', 'Logging', 'Configuration') {

    Context "Log Level Management" {
        
        BeforeEach {
            # Reset to default
            $script:LogLevel = 'Information'
        }

        It "Should set log level correctly" {
            Set-LogLevel -Level 'Warning'
            $script:LogLevel | Should -Be 'Warning'
        }

        It "Should get current log level" {
            $script:LogLevel = 'Debug'
            Get-LogLevel | Should -Be 'Debug'
        }

        It "Should update configuration change timestamp" {
            $beforeTime = Get-Date
            Set-LogLevel -Level 'Error'
            $script:LoggingSystemInfo.LastConfigurationChange | Should -Not -BeNullOrEmpty
            $script:LoggingSystemInfo.LastConfigurationChange | Should -BeGreaterThan $beforeTime.AddSeconds(-1)
        }

        It "Should accept all valid log levels" {
            $validLevels = @('Critical', 'Error', 'Warning', 'Information', 'Debug', 'Verbose')
            foreach ($level in $validLevels) {
                Set-LogLevel -Level $level
                Get-LogLevel | Should -Be $level
            }
        }

        It "Should reject an unknown level and keep the current one" {
            { Set-LogLevel -Level 'Trace' } | Should -Throw
            Get-LogLevel | Should -Be 'Information'
        }
    }
}

