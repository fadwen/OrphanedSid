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
}
