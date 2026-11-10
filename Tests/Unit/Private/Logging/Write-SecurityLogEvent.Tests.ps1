# Unit tests for Write-SecurityLogEvent.ps1 and the helpers it defines: Build-SecurityContext,
# Protect-SecurityContext, Get-SecurityLogLevel and Write-CriticalSecurityEvent
BeforeAll {
    $here = $PSScriptRoot

    $sut = (Split-Path -Leaf $PSCommandPath) -replace '\.Tests\.', '.'

    $modulePath = "$here\..\..\..\..\Private\Logging\$sut"

    # Placeholders for collaborators defined in other files: Pester can only mock a command that
    # exists, and a mock takes the placeholder's parameters, so they match the real signatures
    function Protect-LogMessage {
        param([string]$Message)
        return $Message
    }

    function Write-StructuredLogEntry {
        param($Message, $Level, $Component, $CorrelationId, $LogPath, [hashtable]$Details)
    }

    . $modulePath
}

Describe "Write-SecurityLogEvent" -Tag @('Unit', 'Logging', 'Security') {

    BeforeEach {
        Mock Protect-LogMessage { "sanitized:$Message" }
        Mock Write-StructuredLogEntry { }
        Mock Write-Warning { }
    }

    Context "Basic functionality" {
        It "Should write one Security entry with the sanitized message" {
            Write-SecurityLogEvent -SecurityEventType "AuthenticationAttempt" -Message "Test message" -Outcome "Success" -CorrelationId 'c-1'

            Should -Invoke Write-StructuredLogEntry -Times 1 -Exactly -ParameterFilter {
                $Message -eq 'sanitized:Test message' -and
                $Component -eq 'Security' -and
                $CorrelationId -eq 'c-1' -and
                $Details.EventType -eq 'AuthenticationAttempt' -and
                $Details.Outcome -eq 'Success' -and
                $Details.Severity -eq 'Medium' -and
                $Details.CorrelationId -eq 'c-1'
            }
            Should -Invoke Write-Warning -Times 0 -Exactly
        }

        It "Should default Outcome to Attempt" {
            Write-SecurityLogEvent -SecurityEventType "DataValidation" -Message "Test"

            Should -Invoke Write-StructuredLogEntry -Times 1 -Exactly -ParameterFilter {
                $Details.Outcome -eq 'Attempt' -and $Level -eq 'Debug'
            }
        }

        It "Should reject an unknown SecurityEventType" {
            { Write-SecurityLogEvent -SecurityEventType "Login" -Message "Test" } | Should -Throw
        }

        It "Should map Outcome and Severity to the entry's level" {
            Write-SecurityLogEvent -SecurityEventType "PrivilegeUse" -Message "Denied" -Outcome "Failure" -Severity "High"

            Should -Invoke Write-StructuredLogEntry -Times 1 -Exactly -ParameterFilter { $Level -eq 'Error' }
        }

        It "Should merge the redacted security context into the entry" {
            $context = @{ UserId = "user123"; Password = "hunter2" }

            Write-SecurityLogEvent -SecurityEventType "CredentialAccess" -Message "Test" -Outcome "Success" -SecurityContext $context

            Should -Invoke Write-StructuredLogEntry -Times 1 -Exactly -ParameterFilter {
                $Details.UserId -eq 'sanitized:user123' -and $Details.Password -eq '[REDACTED]'
            }
        }

        It "Should not write a critical alert for a non-critical event" {
            Write-SecurityLogEvent -SecurityEventType "ObjectAccess" -Message "Read" -Outcome "Success" -Severity "High"

            Should -Invoke Write-StructuredLogEntry -Times 0 -Exactly -ParameterFilter { $Component -eq 'SecurityAlert' }
        }

        It "Should write a critical alert when <Case>" -ForEach @(
            @{ Case = 'the outcome is Critical'; OutcomeValue = 'Critical'; SeverityValue = 'Low' }
            @{ Case = 'the severity is Critical'; OutcomeValue = 'Success'; SeverityValue = 'Critical' }
        ) {
            Write-SecurityLogEvent -SecurityEventType "SystemAccess" -Message "Breach" -Outcome $OutcomeValue -Severity $SeverityValue -CorrelationId 'crit-1'

            Should -Invoke Write-StructuredLogEntry -Times 1 -Exactly -ParameterFilter {
                $Component -eq 'SecurityAlert' -and
                $Level -eq 'Critical' -and
                $Message -eq '*** CRITICAL SECURITY EVENT *** SystemAccess : sanitized:Breach' -and
                $Details.CriticalEvent -eq $true -and
                $Details.AlertLevel -eq 'IMMEDIATE' -and
                $Details.IncidentResponse -eq 'REQUIRED'
            }
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
                $Message -eq 'CRITICAL SECURITY EVENT: SystemAccess - sanitized:Breach (CorrelationId: crit-1)'
            }
        }

        It "Should warn instead of throwing when the entry cannot be written" {
            Mock Write-StructuredLogEntry { throw 'log offline' }

            { Write-SecurityLogEvent -SecurityEventType "ObjectAccess" -Message "Test" } | Should -Not -Throw

            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
                $Message -eq 'Failed to write security log event: log offline'
            }
        }
    }
}

Describe "Build-SecurityContext" -Tag @('Unit', 'Logging', 'Security') {
    BeforeEach {
        Mock Protect-LogMessage { $Message }
        Mock Write-Warning { }
    }

    It "Should include the event, process and user fields" {
        $context = Build-SecurityContext -SecurityEventType 'ObjectAccess' -Outcome 'Success' -Severity 'High' -CorrelationId 'b-1'

        $context.EventType | Should -Be 'ObjectAccess'
        $context.Outcome | Should -Be 'Success'
        $context.Severity | Should -Be 'High'
        $context.CorrelationId | Should -Be 'b-1'
        $context.UserContext | Should -Be "$env:USERNAME@$env:COMPUTERNAME"
        $context.ProcessId | Should -Be $PID
        $context.Timestamp | Should -Match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}$'
    }

    It "Should return the minimal context and warn when sanitizing fails" {
        Mock Protect-SecurityContext { throw 'bad context' }

        $context = Build-SecurityContext -SecurityEventType 'ObjectAccess' -Outcome 'Failure' -SecurityContext @{ A = 1 } -CorrelationId 'b-2'

        @($context.Keys | Sort-Object) | Should -Be @('CorrelationId', 'EventType', 'Outcome', 'Timestamp')
        $context.Outcome | Should -Be 'Failure'
        Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -eq 'Failed to build security context: bad context' }
    }
}

Describe "Protect-SecurityContext" -Tag @('Unit', 'Logging', 'Security') {
    BeforeEach {
        Mock Protect-LogMessage { "clean:$Message" }
    }

    It "Should redact the value of a sensitive key named <Key>" -ForEach @(
        @{ Key = 'Password' }
        @{ Key = 'ClientSecret' }
        @{ Key = 'AccessToken' }
        @{ Key = 'ApiEndpoint' }
        @{ Key = 'AuthHeader' }
    ) {
        $result = Protect-SecurityContext -SecurityContext @{ $Key = 'value' }
        $result[$Key] | Should -Be '[REDACTED]'
    }

    It "Should mark an empty sensitive value as [EMPTY]" {
        (Protect-SecurityContext -SecurityContext @{ Password = '' }).Password | Should -Be '[EMPTY]'
    }

    It "Should pass other values through Protect-LogMessage" {
        (Protect-SecurityContext -SecurityContext @{ Source = 'RemoteIP' }).Source | Should -Be 'clean:RemoteIP'
    }

    It "Should mark a null value as [NULL]" {
        (Protect-SecurityContext -SecurityContext @{ Source = $null }).Source | Should -Be '[NULL]'
    }
}

Describe "Get-SecurityLogLevel" -Tag @('Unit', 'Logging', 'Security') {
    It "Should map <OutcomeValue>/<SeverityValue> to <Expected>" -ForEach @(
        @{ OutcomeValue = 'Critical'; SeverityValue = 'Low'; Expected = 'Critical' }
        @{ OutcomeValue = 'Failure'; SeverityValue = 'Critical'; Expected = 'Critical' }
        @{ OutcomeValue = 'Failure'; SeverityValue = 'High'; Expected = 'Error' }
        @{ OutcomeValue = 'Failure'; SeverityValue = 'Medium'; Expected = 'Warning' }
        @{ OutcomeValue = 'Failure'; SeverityValue = 'Low'; Expected = 'Information' }
        @{ OutcomeValue = 'Warning'; SeverityValue = 'Low'; Expected = 'Warning' }
        @{ OutcomeValue = 'Success'; SeverityValue = 'Critical'; Expected = 'Information' }
        @{ OutcomeValue = 'Success'; SeverityValue = 'High'; Expected = 'Information' }
        @{ OutcomeValue = 'Success'; SeverityValue = 'Medium'; Expected = 'Debug' }
        @{ OutcomeValue = 'Attempt'; SeverityValue = 'Critical'; Expected = 'Warning' }
        @{ OutcomeValue = 'Attempt'; SeverityValue = 'High'; Expected = 'Information' }
        @{ OutcomeValue = 'Attempt'; SeverityValue = 'Low'; Expected = 'Debug' }
    ) {
        Get-SecurityLogLevel -Outcome $OutcomeValue -Severity $SeverityValue | Should -Be $Expected
    }
}

Describe "Write-CriticalSecurityEvent" -Tag @('Unit', 'Logging', 'Security') {
    It "Should leave the caller's security data unchanged" {
        Mock Write-StructuredLogEntry { }
        Mock Write-Warning { }
        $data = @{ EventType = 'X' }

        Write-CriticalSecurityEvent -SecurityEventType 'X' -Message 'm' -SecurityData $data

        $data.ContainsKey('CriticalEvent') | Should -BeFalse
    }

    It "Should write an error instead of throwing when the alert cannot be written" {
        Mock Write-StructuredLogEntry { throw 'alert sink down' }
        Mock Write-Error { }

        { Write-CriticalSecurityEvent -SecurityEventType 'X' -Message 'm' } | Should -Not -Throw

        Should -Invoke Write-Error -Times 1 -Exactly -ParameterFilter { $Message -eq 'Failed to write critical security event: alert sink down' }
    }
}
