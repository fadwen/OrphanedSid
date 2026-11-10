#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
# Unit tests for Write-RemovalSecurityLog: security audit logging for SID removal operations

BeforeAll {
    # Pester can only mock a command that exists. The real Write-StructuredLog lives in another file;
    # this placeholder is what the Mock below replaces when the file runs on its own.
    if (-not (Get-Command Write-StructuredLog -ErrorAction SilentlyContinue)) {
        function Write-StructuredLog { param($Message, $Level, $Component, $CorrelationId, $LogPath, $Data) }
    }

    $functionPath = "$PSScriptRoot\..\..\..\..\Private\Logging\Write-RemovalSecurityLog.ps1"

    if (Test-Path $functionPath) {
        . $functionPath
    } else {
        throw "Could not find Write-RemovalSecurityLog.ps1 at $functionPath"
    }

    $dependencies = @(
        "$PSScriptRoot\..\..\..\..\Private\Logging\Write-SecurityLog.ps1"
    )

    foreach ($dep in $dependencies) {
        if (Test-Path $dep) {
            . $dep
        }
    }
}

Describe "Write-RemovalSecurityLog" -Tag @('Unit', 'Logging', 'Security') {
    BeforeEach {
        # Both collaborators are mocked so no log entry is written
        Mock Write-StructuredLog { }
        Mock Write-SecurityLog { }
        Mock Write-Warning { }
    }

    Context "Parameter Validation" {
        It "Should reject a SecurityEventType outside the removal event types" {
            { Write-RemovalSecurityLog -SecurityEventType "Authentication" -Message "Test message" -Outcome "Success" } | Should -Throw
            Should -Invoke Write-SecurityLog -Times 0 -Exactly
        }

        It "Should reject an Outcome outside Attempt, Success and Failure" {
            { Write-RemovalSecurityLog -SecurityEventType "PrivilegeUse" -Message "Test message" -Outcome "Done" } | Should -Throw
        }
    }

    Context "Security Event Generation" {
        It "Should call Write-SecurityLog with correct parameters" {
            Write-RemovalSecurityLog -SecurityEventType "PrivilegeUse" -Message "Test removal operation" -Outcome "Success"

            Should -Invoke Write-SecurityLog -Times 1 -Exactly -ParameterFilter {
                $SecurityEventType -eq "PrivilegeUse" -and
                $Message -eq "Test removal operation" -and
                $Outcome -eq "Success"
            }
        }

        It "Should include enhanced security context in logging" {
            $customContext = @{ SIDType = 'User'; Domain = 'TestDomain' }
            Write-RemovalSecurityLog -SecurityEventType "ObjectAccess" -Message "SID removal" -Outcome "Failure" -SecurityContext $customContext -CorrelationId 'ctx-1'

            Should -Invoke Write-SecurityLog -Times 1 -Exactly -ParameterFilter {
                $SecurityContext.Operation -eq 'SIDRemoval' -and
                $SecurityContext.Component -eq 'RemovalSecurityLogging' -and
                $SecurityContext.EventType -eq 'ObjectAccess' -and
                $SecurityContext.Outcome -eq 'Failure' -and
                $SecurityContext.User -eq $env:USERNAME -and
                $SecurityContext.Computer -eq $env:COMPUTERNAME -and
                $SecurityContext.CorrelationId -eq 'ctx-1' -and
                $SecurityContext.Timestamp -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$' -and
                $SecurityContext.SIDType -eq 'User' -and
                $SecurityContext.Domain -eq 'TestDomain'
            }
        }

        It "Should generate correlation ID if not provided" {
            Write-RemovalSecurityLog -SecurityEventType "PrivilegeUse" -Message "Test message" -Outcome "Success"

            Should -Invoke Write-SecurityLog -Times 1 -Exactly -ParameterFilter {
                $CorrelationId -match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
            }
        }

        It "Should use provided correlation ID" {
            $testCorrelationId = [System.Guid]::NewGuid().ToString()
            Write-RemovalSecurityLog -SecurityEventType "PrivilegeUse" -Message "Test message" -Outcome "Success" -CorrelationId $testCorrelationId

            Should -Invoke Write-SecurityLog -Times 1 -Exactly -ParameterFilter {
                $CorrelationId -eq $testCorrelationId
            }
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $CorrelationId -eq $testCorrelationId
            }
        }

        It "Should also write an operational structured log entry" {
            Write-RemovalSecurityLog -SecurityEventType "AuditTrail" -Message "Removed 3 SIDs" -Outcome "Success"

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Message -eq 'SECURITY EVENT: AuditTrail - Removed 3 SIDs (Outcome: Success)' -and $Level -eq 'Information'
            }
        }
    }

    Context "Failure handling" {
        It "Should log the failure and a fallback entry when Write-SecurityLog throws" {
            Mock Write-SecurityLog { throw 'audit store offline' }

            { Write-RemovalSecurityLog -SecurityEventType "PrivilegeUse" -Message "Remove" -Outcome "Attempt" -CorrelationId 'f-1' } | Should -Not -Throw

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Error' -and $Message -eq 'Failed to write security audit log: audit store offline' -and $CorrelationId -eq 'f-1'
            }
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Warning' -and $Message -eq 'SECURITY EVENT (FALLBACK): PrivilegeUse - Remove (Outcome: Attempt)'
            }
            Should -Invoke Write-Warning -Times 0 -Exactly
        }

        It "Should warn with the correlation ID when the fallback entry also fails" {
            Mock Write-SecurityLog { throw 'audit store offline' }
            Mock Write-StructuredLog { throw 'log offline' } -ParameterFilter { $Level -eq 'Warning' }

            Write-RemovalSecurityLog -SecurityEventType "PrivilegeUse" -Message "Remove" -Outcome "Attempt" -CorrelationId 'f-2'

            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
                $Message -eq 'Critical: Security audit logging failed completely for correlation ID: f-2'
            }
        }
    }
}
