# Unit tests for Write-SecurityStructuredLogEntry.ps1 and the helpers it defines
BeforeAll {
    $here = $PSScriptRoot

    $sut = (Split-Path -Leaf $PSCommandPath) -replace '\.Tests\.', '.'

    . "$here\..\..\..\..\Private\Logging\$sut"

    # Real formatter, so the assertions read the JSON line the function actually writes
    . "$here\..\..\..\..\Private\Logging\Format-LogMessage.ps1"

    # Defines Get-LoggingSystemState, which every test mocks
    . "$here\..\..\..\..\Private\Logging\Initialize-LoggingConfiguration.ps1"
    . "$here\..\..\..\..\Private\Logging\Initialize-LoggingSystem.ps1"

    function New-LoggingState {
        param(
            $CorrelationId = 'system-correlation',
            $LogPath = 'C:\logs\security.log',
            $LogFileInitialized = $true,
            $SuppressConsoleOutput = $true
        )
        [PSCustomObject]@{
            CorrelationId = $CorrelationId
            LogPath = $LogPath
            LogFileInitialized = $LogFileInitialized
            SuppressConsoleOutput = $SuppressConsoleOutput
        }
    }
}

Describe "Write-SecurityStructuredLogEntry" -Tag @('Unit', 'Logging', 'Security') {

    BeforeEach {
        Mock Write-Warning { }
        Mock Write-Error { }
        Mock Write-Host { }
        Mock Out-File { }
        Mock Add-Content { }
        Mock Get-LoggingSystemState { New-LoggingState }
        $script:SecurityLoggingMetrics = $null
    }

    Context "Parameter Validation" {

        It "Should refuse the <LevelName> level for security entries" -ForEach @(
            @{ LevelName = 'Debug' }
            @{ LevelName = 'Verbose' }
        ) {
            { Write-SecurityStructuredLogEntry -Message "Test" -Level $LevelName } | Should -Throw
        }

        It "Should default to Information level and the SecurityAudit component" {
            Write-SecurityStructuredLogEntry -Message "Test"

            Should -Invoke Add-Content -Times 1 -Exactly -ParameterFilter {
                $entry = $Value | ConvertFrom-Json
                $entry.Level -eq 'Information' -and $entry.Component -eq 'SecurityAudit' -and $entry.Message -eq 'Test'
            }
        }

        It "Should use a custom component" {
            Write-SecurityStructuredLogEntry -Message "Test" -Component "CustomSecurity"

            Should -Invoke Add-Content -Times 1 -Exactly -ParameterFilter {
                ($Value | ConvertFrom-Json).Component -eq 'CustomSecurity'
            }
        }
    }

    Context "File entry" {

        It "Should write the entry to the logging system's log path" {
            Write-SecurityStructuredLogEntry -Message "AD object access attempt" -Level Warning

            Should -Invoke Add-Content -Times 1 -Exactly -ParameterFilter {
                $Path -eq 'C:\logs\security.log' -and ($Value | ConvertFrom-Json).Level -eq 'Warning'
            }
        }

        It "Should include structured data in the entry" {
            Write-SecurityStructuredLogEntry -Message "Test" -Data @{ EventType = "Access"; Resource = "Database" }

            Should -Invoke Add-Content -Times 1 -Exactly -ParameterFilter {
                $entry = $Value | ConvertFrom-Json
                $entry.EventType -eq 'Access' -and $entry.Resource -eq 'Database'
            }
        }

        It "Should include the ErrorRecord's exception, stack and error ID" {
            try {
                throw "Specific test exception message"
            } catch {
                $errorRecord = $_
            }

            Write-SecurityStructuredLogEntry -Message "Error occurred" -Level Error -ErrorRecord $errorRecord

            Should -Invoke Add-Content -Times 1 -Exactly -ParameterFilter {
                $entry = $Value | ConvertFrom-Json
                $entry.ErrorRecord.Exception -eq 'Specific test exception message' -and
                $entry.ErrorRecord.FullyQualifiedErrorId -eq 'Specific test exception message' -and
                $entry.ErrorRecord.ScriptStackTrace -like '*Write-SecurityStructuredLogEntry.Tests.ps1*'
            }
        }

        It "Should write Information entries regardless of the configured log level" {
            Mock Get-LoggingSystemState {
                $state = New-LoggingState
                $state | Add-Member -NotePropertyName LogLevel -NotePropertyValue 'Critical'
                $state
            }

            Write-SecurityStructuredLogEntry -Message "Security info" -Level "Information"

            Should -Invoke Add-Content -Times 1 -Exactly
        }

        It "Should count the entry in the security metrics" {
            Write-SecurityStructuredLogEntry -Message "One" -Level Warning
            Write-SecurityStructuredLogEntry -Message "Two" -Level Warning

            $script:SecurityLoggingMetrics.TotalSecurityEntries | Should -Be 2
            $script:SecurityLoggingMetrics.SecurityEntriesByLevel.Warning | Should -Be 2
            $script:SecurityLoggingMetrics.LastSecurityLogTime | Should -BeOfType [datetime]
        }
    }

    Context "Correlation ID" {

        It "Should use provided CorrelationId over system CorrelationId" {
            Write-SecurityStructuredLogEntry -Message "Test" -CorrelationId "custom-correlation-789"

            Should -Invoke Add-Content -Times 1 -Exactly -ParameterFilter {
                ($Value | ConvertFrom-Json).CorrelationId -eq 'custom-correlation-789'
            }
        }

        It "Should use system CorrelationId when none provided" {
            Write-SecurityStructuredLogEntry -Message "Test"

            Should -Invoke Add-Content -Times 1 -Exactly -ParameterFilter {
                ($Value | ConvertFrom-Json).CorrelationId -eq 'system-correlation'
            }
        }

        It "Should generate a new CorrelationId and warn when the system has none" {
            Mock Get-LoggingSystemState { New-LoggingState -CorrelationId $null }

            Write-SecurityStructuredLogEntry -Message "Test"

            Should -Invoke Add-Content -Times 1 -Exactly -ParameterFilter {
                ($Value | ConvertFrom-Json).CorrelationId -match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
            }
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
                $Message -eq 'Logging system not properly initialized for security logging'
            }
        }
    }

    Context "Error Handling" {

        It "Should fall back to a direct file write when formatting fails" {
            Mock Format-LogMessage { throw "Formatting error" }

            { Write-SecurityStructuredLogEntry -Message "Test" -Level Error -CorrelationId 'fb-1' } | Should -Not -Throw

            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
                $Message -eq 'CRITICAL: Security log entry failed: Formatting error'
            }
            Should -Invoke Add-Content -Times 1 -Exactly -ParameterFilter {
                $Path -eq 'C:\logs\security.log' -and
                $Value -like '*[[]SecurityAudit] [[]Error] SECURITY: Test (CorrelationId: fb-1)'
            }
        }

        It "Should write to the emergency file when the direct write also fails" {
            Mock Format-LogMessage { throw "Formatting error" }
            Mock Write-SecurityFileEntryDirect { throw "Direct write failed" }

            Write-SecurityStructuredLogEntry -Message "Critical security event" -Level Critical -CorrelationId 'em-1'

            Should -Invoke Out-File -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq "$env:TEMP\OrphanedSid-Security-Emergency.log" -and
                $InputObject -like '*[[]SECURITY-EMERGENCY] [[]Critical] Critical security event (CorrelationId: em-1)'
            }
        }

        It "Should write an error when every fallback fails" {
            Mock Format-LogMessage { throw "Formatting error" }
            Mock Write-SecurityFileEntryDirect { throw "Direct write failed" }
            Mock Out-File { throw "Emergency write failed" }

            Write-SecurityStructuredLogEntry -Message "Lost event"

            Should -Invoke Write-Error -Times 1 -Exactly -ParameterFilter {
                $Message -eq 'CRITICAL SECURITY LOGGING FAILURE: Unable to write security audit entry: Lost event'
            }
        }
    }
}

Describe "Write-SecurityConsoleEntry" -Tag @('Unit', 'Logging', 'Security') {
    BeforeEach {
        Mock Write-Host { }
        Mock Write-Error { }
        Mock Write-Warning { }
        Mock Get-LoggingSystemState { New-LoggingState -SuppressConsoleOutput $false }
    }

    It "Should write nothing when console output is suppressed" {
        Mock Get-LoggingSystemState { New-LoggingState -SuppressConsoleOutput $true }

        Write-SecurityConsoleEntry -FormattedMessage 'm' -Level Critical

        Should -Invoke Write-Host -Times 0 -Exactly
    }

    It "Should keep Information entries off the console" {
        Write-SecurityConsoleEntry -FormattedMessage 'm' -Level Information

        Should -Invoke Write-Host -Times 0 -Exactly
        Should -Invoke Write-Warning -Times 0 -Exactly
        Should -Invoke Write-Error -Times 0 -Exactly
    }

    It "Should send a <LevelName> entry to <Command> with the [SECURITY] prefix" -ForEach @(
        @{ LevelName = 'Critical'; Command = 'Write-Host' }
        @{ LevelName = 'Error'; Command = 'Write-Error' }
        @{ LevelName = 'Warning'; Command = 'Write-Warning' }
    ) {
        Write-SecurityConsoleEntry -FormattedMessage 'entry text' -Level $LevelName

        if ($Command -eq 'Write-Host') {
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { $Object -eq '[SECURITY] entry text' }
        } else {
            Should -Invoke $Command -Times 1 -Exactly -ParameterFilter { $Message -eq '[SECURITY] entry text' }
        }
    }
}

Describe "Write-SecurityFileEntry" -Tag @('Unit', 'Logging', 'Security') {
    BeforeEach {
        Mock Write-Warning { }
        Mock Write-Error { }
        Mock Add-Content { }
        Mock Write-SecurityFileEntryDirect { }
    }

    It "Should hand the entry to the direct writer when the log file is not initialized" {
        Mock Get-LoggingSystemState { New-LoggingState -LogFileInitialized $false }

        Write-SecurityFileEntry -FormattedMessage 'entry'

        Should -Invoke Write-SecurityFileEntryDirect -Times 1 -Exactly -ParameterFilter { $Message -eq 'entry' }
        Should -Invoke Add-Content -Times 0 -Exactly
    }

    It "Should warn and retry through the direct writer when the append fails" {
        Mock Get-LoggingSystemState { New-LoggingState }
        Mock Add-Content { throw 'locked' }

        Write-SecurityFileEntry -FormattedMessage 'entry'

        Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like '*attempting recovery: locked' }
        Should -Invoke Write-SecurityFileEntryDirect -Times 1 -Exactly
    }

    It "Should write an error when the retry also fails" {
        Mock Get-LoggingSystemState { New-LoggingState }
        Mock Add-Content { throw 'locked' }
        Mock Write-SecurityFileEntryDirect { throw 'still locked' }

        Write-SecurityFileEntry -FormattedMessage 'entry'

        Should -Invoke Write-Error -Times 1 -Exactly -ParameterFilter { $Message -eq 'CRITICAL: Security log entry could not be written: still locked' }
    }
}

Describe "Write-SecurityFileEntryDirect" -Tag @('Unit', 'Logging', 'Security') {
    BeforeEach {
        Mock Write-Warning { }
        Mock Write-Error { }
    }

    It "Should write to the temp security log when the log path fails" {
        Mock Get-LoggingSystemState { New-LoggingState }
        Mock Add-Content { throw 'denied' } -ParameterFilter { $Path -eq 'C:\logs\security.log' }
        Mock Add-Content { }

        Write-SecurityFileEntryDirect -Message 'entry'

        $expected = Join-Path $env:TEMP "OrphanedSid-Security-$(Get-Date -Format 'yyyyMMdd').log"
        Should -Invoke Add-Content -Times 1 -Exactly -ParameterFilter { $Path -eq $expected -and $Value -eq 'entry' }
        Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -eq "Security log written to emergency location: $expected" }
    }

    It "Should write an error when no location accepts the entry" {
        Mock Get-LoggingSystemState { New-LoggingState -LogPath $null }
        Mock Add-Content { throw 'denied' }

        Write-SecurityFileEntryDirect -Message 'entry'

        Should -Invoke Write-Error -Times 1 -Exactly -ParameterFilter { $Message -eq 'CRITICAL: Cannot write security log entry anywhere: denied' }
    }
}
