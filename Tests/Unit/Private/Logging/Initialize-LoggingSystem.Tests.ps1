# Unit tests for Initialize-LoggingSystem.ps1
BeforeAll {
    $here = $PSScriptRoot

    $sut = (Split-Path -Leaf $PSCommandPath) -replace '\.Tests\.', '.'

    $modulePath = "$here\..\..\..\..\Private\Logging\$sut"

    . $modulePath

    $here = $PSScriptRoot

    $modulePath = Split-Path $here -Parent

    . "$here\..\..\..\..\Private\Logging\Initialize-LoggingConfiguration.ps1"
}

Describe "Initialize-LoggingSystem" -Tag @('Unit', 'Logging', 'Initialization') {

    BeforeAll {
    Mock Write-Verbose { } -Verifiable
        Mock Write-Error { throw $Message } -Verifiable
    }

    Context "Parameter Validation" {
        
        BeforeEach {
            # Reset logging state before each test
            $script:CorrelationId = $null
            $script:LogLevel = 'Information'
            $script:SuppressConsoleOutput = $false
            $script:LogFileInitialized = $false
            $script:LogFileReinitAttempted = $false
        }

        It "Should reject a LogLevel outside the hierarchy" {
            { Initialize-LoggingSystem -LogLevel 'Trace' } | Should -Throw
            $script:LogLevel | Should -Be 'Information'
        }

        It "Should generate new CorrelationId when not provided" {
            Initialize-LoggingSystem
            $script:CorrelationId | Should -Not -BeNullOrEmpty
            $script:CorrelationId | Should -Match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        }

        It "Should reject empty string CorrelationId" {
            { Initialize-LoggingSystem -CorrelationId "" } | Should -Throw
        }

        It "Should generate new CorrelationId when whitespace provided" {
            Initialize-LoggingSystem -CorrelationId "   "
            $script:CorrelationId | Should -Not -BeNullOrEmpty
            $script:CorrelationId | Should -Match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        }
    }

    Context "State Initialization" {
        
        BeforeEach {
            # Reset logging state before each test
            $script:CorrelationId = $null
            $script:LogLevel = 'Information'
            $script:SuppressConsoleOutput = $false
            $script:LogFileInitialized = $false
            $script:LogFileReinitAttempted = $false
        }

        It "Should set CorrelationId correctly" {
            $testCorrelationId = [System.Guid]::NewGuid().ToString()
            Initialize-LoggingSystem -CorrelationId $testCorrelationId
            $script:CorrelationId | Should -Be $testCorrelationId
        }

        It "Should set LogLevel correctly" {
            Initialize-LoggingSystem -LogLevel 'Debug'
            $script:LogLevel | Should -Be 'Debug'
        }

        It "Should default to Information log level" {
            Initialize-LoggingSystem
            $script:LogLevel | Should -Be 'Information'
        }

        It "Should set SuppressConsoleOutput when switch provided" {
            Initialize-LoggingSystem -SuppressConsoleOutput
            $script:SuppressConsoleOutput | Should -Be $true
        }

        It "Should default SuppressConsoleOutput to false" {
            Initialize-LoggingSystem
            $script:SuppressConsoleOutput | Should -Be $false
        }

        It "Should reset LogFileInitialized to false" {
            $script:LogFileInitialized = $true
            Initialize-LoggingSystem
            $script:LogFileInitialized | Should -Be $false
        }

        It "Should reset LogFileReinitAttempted to false" {
            $script:LogFileReinitAttempted = $true
            Initialize-LoggingSystem
            $script:LogFileReinitAttempted | Should -Be $false
        }
    }

    Context "Error Handling" {
        
        It "Should report a failure while setting state as a terminating error" {
            # The verbose line inside the try block fails; the catch rewraps it with -ErrorAction Stop
            Mock Write-Verbose { throw "System error" } -ParameterFilter { $Message -eq 'Logging system state initialized successfully' }

            { Initialize-LoggingSystem } | Should -Throw -ExpectedMessage '*Failed to initialize logging system state: System error*'
        }
    }
}

Describe "Get-LoggingSystemState" -Tag @('Unit', 'Logging', 'State') {

    Context "State Retrieval" {

        BeforeEach {
            Initialize-LoggingSystem -CorrelationId "test-123" -LogLevel "Warning" -SuppressConsoleOutput
            $script:LogPath = 'C:\logs\system.log'
        }

        It "Should carry the LoggingSystemState type name" {
            (Get-LoggingSystemState).PSObject.TypeNames | Should -Contain 'LoggingSystemState'
        }

        It "Should report the state Initialize-LoggingSystem set" {
            $state = Get-LoggingSystemState

            $state.CorrelationId | Should -Be "test-123"
            $state.LogLevel | Should -Be "Warning"
            $state.SuppressConsoleOutput | Should -BeTrue
            $state.LogFileInitialized | Should -BeFalse
            $state.LogFileReinitAttempted | Should -BeFalse
        }

        It "Should report the current log path" {
            (Get-LoggingSystemState).LogPath | Should -Be 'C:\logs\system.log'
        }

        It "Should list the available log levels" {
            @((Get-LoggingSystemState).AvailableLogLevels | Sort-Object) |
                Should -Be @('Critical', 'Debug', 'Error', 'Information', 'Verbose', 'Warning')
        }

        It "Should stamp the time it was read" {
            $before = Get-Date
            $state = Get-LoggingSystemState
            $state.Timestamp | Should -BeGreaterOrEqual $before
            $state.Timestamp | Should -BeLessOrEqual (Get-Date)
        }

        It "Should return a snapshot that does not write back to the state" {
            $state = Get-LoggingSystemState
            $state.CorrelationId = "modified"
            $script:CorrelationId | Should -Be "test-123"
        }
    }
}

Describe "Test-LogLevel" -Tag @('Unit', 'Logging', 'LevelTesting') {

    Context "Log Level Comparison" {
        
        BeforeEach {
            # Initialize with known log level
            Initialize-LoggingSystem -LogLevel "Information"
        }

        It "Should return true for Critical when system level is Information" {
            Test-LogLevel -Level 'Critical' | Should -Be $true
        }

        It "Should return true for Error when system level is Information" {
            Test-LogLevel -Level 'Error' | Should -Be $true
        }

        It "Should return true for Warning when system level is Information" {
            Test-LogLevel -Level 'Warning' | Should -Be $true
        }

        It "Should return true for Information when system level is Information" {
            Test-LogLevel -Level 'Information' | Should -Be $true
        }

        It "Should return false for Debug when system level is Information" {
            Test-LogLevel -Level 'Debug' | Should -Be $false
        }

        It "Should return false for Verbose when system level is Information" {
            Test-LogLevel -Level 'Verbose' | Should -Be $false
        }

        It "Should handle Critical system level correctly" {
            Initialize-LoggingSystem -LogLevel "Critical"
            Test-LogLevel -Level 'Critical' | Should -Be $true
            Test-LogLevel -Level 'Error' | Should -Be $false
            Test-LogLevel -Level 'Warning' | Should -Be $false
            Test-LogLevel -Level 'Information' | Should -Be $false
        }

        It "Should handle Debug system level correctly" {
            Initialize-LoggingSystem -LogLevel "Debug"
            Test-LogLevel -Level 'Critical' | Should -Be $true
            Test-LogLevel -Level 'Error' | Should -Be $true
            Test-LogLevel -Level 'Warning' | Should -Be $true
            Test-LogLevel -Level 'Information' | Should -Be $true
            Test-LogLevel -Level 'Debug' | Should -Be $true
            Test-LogLevel -Level 'Verbose' | Should -Be $false
        }

        It "Should handle Verbose system level correctly" {
            Initialize-LoggingSystem -LogLevel "Verbose"
            Test-LogLevel -Level 'Critical' | Should -Be $true
            Test-LogLevel -Level 'Error' | Should -Be $true
            Test-LogLevel -Level 'Warning' | Should -Be $true
            Test-LogLevel -Level 'Information' | Should -Be $true
            Test-LogLevel -Level 'Debug' | Should -Be $true
            Test-LogLevel -Level 'Verbose' | Should -Be $true
        }
    }

    Context "Error Handling" {
        
        BeforeEach {
            # Mock warning output for invalid level tests
            Mock Write-Warning { } 
        }

        It "Should reject invalid message level" {
            { Test-LogLevel -Level 'InvalidLevel' } | Should -Throw
        }

        It "Should return false and warn when the system level is invalid" {
            $originalLogLevel = $script:LogLevel
            $script:LogLevel = 'InvalidLevel'
            try {
                $result = Test-LogLevel -Level 'Information'
            } finally {
                $script:LogLevel = $originalLogLevel
            }

            $result | Should -Be $false
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
                $Message -eq "Invalid log level comparison: Message='Information', System='InvalidLevel'"
            }
        }
    }
}

