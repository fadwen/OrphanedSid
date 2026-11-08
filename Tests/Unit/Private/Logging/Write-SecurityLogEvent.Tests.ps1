# Pester 3.4 tests for Write-SecurityLogEvent.ps1
# Create stubs for missing functions that the function depends on
# Import the script content for testing
BeforeAll {
    $here = $PSScriptRoot

    $sut = (Split-Path -Leaf $PSCommandPath) -replace '\.Tests\.', '.'

    $modulePath = "$here\..\..\..\..\Private\Logging\$sut"

    function Protect-LogMessage {
        param([string]$Message)
        return $Message
    }

    function Write-StructuredLogEntry {
        param($Message, $Level, $Component, $Data, $CorrelationId)
        # Stub implementation - just return success
    }

    . $modulePath
}

Describe "Write-SecurityLogEvent" -Tag @('Unit', 'Logging', 'Security') {

    # Mock dependencies inside Describe block for Pester 3.4 compatibility
    BeforeAll {
    Mock Protect-LogMessage {
            param([string]$Message)
            return $Message
        }
        
        Mock Write-StructuredLogEntry {
            param($Message, $Level, $Component, $Data, $CorrelationId)
            # Mock implementation - just return success
        }
    }

    Context "Basic functionality" {
        It "Should accept mandatory parameters without throwing exceptions" {
            { Write-SecurityLogEvent -SecurityEventType "AuthenticationAttempt" -Message "Test message" -Outcome "Success" } | Should -Not -Throw
        }

        It "Should accept all valid SecurityEventType values" {
            $validEventTypes = @('DataValidation', 'CredentialAccess', 'PrivilegeUse', 'ObjectAccess', 'SystemAccess', 'ConfigurationChange', 'AuthenticationAttempt', 'AuthorizationCheck')
            foreach ($eventType in $validEventTypes) {
                { Write-SecurityLogEvent -SecurityEventType $eventType -Message "Test event" -Outcome "Success" } | Should -Not -Throw
            }
        }

        It "Should accept all valid Outcome values" {
            $validOutcomes = @('Success', 'Failure', 'Attempt', 'Warning', 'Critical')
            foreach ($outcome in $validOutcomes) {
                { Write-SecurityLogEvent -SecurityEventType "AuthenticationAttempt" -Message "Test event" -Outcome $outcome } | Should -Not -Throw
            }
        }

        It "Should accept optional parameters" {
            $context = @{ UserId = "user123"; SessionId = "session456" }
            $correlationId = [System.Guid]::NewGuid().ToString()
            { Write-SecurityLogEvent -SecurityEventType "AuthenticationAttempt" -Message "Test event" -Outcome "Success" -SecurityContext $context -CorrelationId $correlationId -Severity "High" } | Should -Not -Throw
        }
    }
}
