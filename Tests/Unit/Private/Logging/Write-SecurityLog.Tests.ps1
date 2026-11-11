# Unit tests for Write-SecurityLog.ps1
BeforeAll {
    $here = $PSScriptRoot

    $sut = (Split-Path -Leaf $PSCommandPath) -replace '\.Tests\.', '.'

    $modulePath = "$here\..\..\..\..\Private\Logging\$sut"

    . $modulePath

    # Mocked below; Pester can only mock a command that exists
    . "$here\..\..\..\..\Private\Logging\Write-SecurityStructuredLogEntry.ps1"
}

Describe "Write-SecurityLog" -Tag @('Unit', 'Logging', 'Security') {

    BeforeEach {
        Mock Write-Verbose { }
        Mock Write-Warning { }
        Mock Write-Error { }
        Mock Write-SecurityStructuredLogEntry { }
        Mock Out-File { }
    }

    Context "Parameter Validation" {

        It "Should reject an Outcome outside Attempt, Success and Failure" {
            { Write-SecurityLog -SecurityEventType "ObjectAccess" -Message "Test" -Outcome "Unknown" } | Should -Throw
            Should -Invoke Write-SecurityStructuredLogEntry -Times 0 -Exactly
        }

        It "Should reject an empty SecurityEventType" {
            { Write-SecurityLog -SecurityEventType "" -Message "Test" -Outcome "Success" } | Should -Throw
        }
    }

    Context "Security Log Entry Construction" {

        It "Should write one entry with the SecurityAudit component and the audit message" {
            Write-SecurityLog -SecurityEventType "ObjectAccess" -Message "AD user access" -Outcome "Success"

            Should -Invoke Write-SecurityStructuredLogEntry -Times 1 -Exactly -ParameterFilter {
                $Component -eq 'SecurityAudit' -and
                $Message -eq '[ObjectAccess] [Success] AD user access' -and
                $Data.SecurityEventType -eq 'ObjectAccess' -and
                $Data.Outcome -eq 'Success' -and
                -not $Data.ContainsKey('Message') -and
                $Data.Component -eq 'SecurityAudit'
            }
        }

        It "Should include timestamp in log entry" {
            $script:BeforeTime = Get-Date
            Write-SecurityLog -SecurityEventType "Authentication" -Message "Login attempt" -Outcome "Attempt"
            $script:AfterTime = Get-Date

            Should -Invoke Write-SecurityStructuredLogEntry -Times 1 -Exactly -ParameterFilter {
                $Data.Timestamp -is [datetime] -and
                $Data.Timestamp -ge $script:BeforeTime -and
                $Data.Timestamp -le $script:AfterTime
            }
        }

        It "Should include user context information" {
            Write-SecurityLog -SecurityEventType "Authorization" -Message "Permission check" -Outcome "Success"

            Should -Invoke Write-SecurityStructuredLogEntry -Times 1 -Exactly -ParameterFilter {
                $Data.UserContext -eq "$env:USERNAME@$env:COMPUTERNAME"
            }
        }

        It "Should include process ID" {
            Write-SecurityLog -SecurityEventType "ObjectAccess" -Message "File access" -Outcome "Success"

            Should -Invoke Write-SecurityStructuredLogEntry -Times 1 -Exactly -ParameterFilter {
                $Data.ProcessId -eq $PID
            }
        }

        It "Should use provided CorrelationId" {
            $testCorrelationId = "custom-correlation-456"
            Write-SecurityLog -SecurityEventType "ObjectAccess" -Message "Test" -Outcome "Success" -CorrelationId $testCorrelationId

            Should -Invoke Write-SecurityStructuredLogEntry -Times 1 -Exactly -ParameterFilter {
                $CorrelationId -eq $testCorrelationId -and $Data.CorrelationId -eq $testCorrelationId
            }
        }

        It "Should generate new CorrelationId when not provided" {
            Write-SecurityLog -SecurityEventType "ObjectAccess" -Message "Test" -Outcome "Success"

            Should -Invoke Write-SecurityStructuredLogEntry -Times 1 -Exactly -ParameterFilter {
                $CorrelationId -match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -and
                $Data.CorrelationId -eq $CorrelationId
            }
        }
    }

    Context "Log Level Determination" {

        It "Should use <ExpectedLevel> level for <OutcomeName> outcome" -ForEach @(
            @{ OutcomeName = 'Attempt'; ExpectedLevel = 'Information' }
            @{ OutcomeName = 'Success'; ExpectedLevel = 'Information' }
            @{ OutcomeName = 'Failure'; ExpectedLevel = 'Warning' }
        ) {
            Write-SecurityLog -SecurityEventType "Authentication" -Message "Login" -Outcome $OutcomeName

            Should -Invoke Write-SecurityStructuredLogEntry -Times 1 -Exactly -ParameterFilter {
                $Level -eq $ExpectedLevel
            }
        }
    }

    Context "Security Context Integration" {

        It "Should merge additional security context with keys prefixed Security_" {
            $securityContext = @{
                ObjectType = "User"
                ObjectId = "CN=TestUser,OU=Users,DC=domain,DC=com"
            }

            Write-SecurityLog -SecurityEventType "ObjectAccess" -Message "User read" -Outcome "Success" -SecurityContext $securityContext

            Should -Invoke Write-SecurityStructuredLogEntry -Times 1 -Exactly -ParameterFilter {
                $Data.Security_ObjectType -eq 'User' -and
                $Data.Security_ObjectId -eq 'CN=TestUser,OU=Users,DC=domain,DC=com' -and
                -not $Data.ContainsKey('ObjectType')
            }
        }

        It "Should send only the seven standard fields for an empty security context" {
            Write-SecurityLog -SecurityEventType "ObjectAccess" -Message "Test" -Outcome "Success" -SecurityContext @{}

            Should -Invoke Write-SecurityStructuredLogEntry -Times 1 -Exactly -ParameterFilter {
                $Data.Count -eq 7
            }
        }

        It "Should keep a context key that shares a standard field's name apart from it" {
            Write-SecurityLog -SecurityEventType "ObjectAccess" -Message "Test" -Outcome "Success" -SecurityContext @{ Outcome = 'Spoofed' }

            Should -Invoke Write-SecurityStructuredLogEntry -Times 1 -Exactly -ParameterFilter {
                $Data.Outcome -eq 'Success' -and $Data.Security_Outcome -eq 'Spoofed'
            }
        }
    }

    Context "Message Formatting" {

        It "Should keep special characters in the audit message" {
            $specialMessage = "Access to file: C:\temp\test file with spaces & symbols.txt"
            Write-SecurityLog -SecurityEventType "FileAccess" -Message $specialMessage -Outcome "Success"

            Should -Invoke Write-SecurityStructuredLogEntry -Times 1 -Exactly -ParameterFilter {
                $Message -eq "[FileAccess] [Success] $specialMessage"
            }
        }

        It "Should write verbose output with the audit message and correlation ID" {
            Write-SecurityLog -SecurityEventType "ObjectAccess" -Message "Test access" -Outcome "Success" -CorrelationId "test-123"

            Should -Invoke Write-Verbose -Times 1 -Exactly -ParameterFilter {
                $Message -eq 'SECURITY AUDIT: [ObjectAccess] [Success] Test access (CorrelationId: test-123)'
            }
        }
    }

    Context "Error Handling" {

        It "Should warn instead of throwing when structured logging fails" {
            Mock Write-SecurityStructuredLogEntry { throw "Log system failure" }

            { Write-SecurityLog -SecurityEventType "ObjectAccess" -Message "Test" -Outcome "Success" } | Should -Not -Throw

            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
                $Message -like '*Security log entry failed: Log system failure*[[]ObjectAccess] [[]Success] Test'
            }
            Should -Invoke Write-Verbose -Times 0 -Exactly
        }

        It "Should append the event to the fallback file when structured logging fails" {
            Mock Write-SecurityStructuredLogEntry { throw "Log system failure" }

            Write-SecurityLog -SecurityEventType "ObjectAccess" -Message "Test" -Outcome "Failure" -CorrelationId "fb-1"

            Should -Invoke Out-File -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq "$env:TEMP\OrphanedSid-Security-Fallback.log" -and
                $Append -and
                $InputObject -like '*[[]SecurityAudit] [[]Warning] [[]ObjectAccess] [[]Failure] Test (CorrelationId: fb-1)'
            }
        }

        It "Should write a critical error when the fallback file also fails" {
            Mock Write-SecurityStructuredLogEntry { throw "Log system failure" }
            Mock Out-File { throw "File system failure" }

            Write-SecurityLog -SecurityEventType "ObjectAccess" -Message "Test" -Outcome "Success"

            Should -Invoke Write-Error -Times 1 -Exactly -ParameterFilter {
                $Message -eq 'Critical: Unable to write security audit log entry: [ObjectAccess] [Success] Test'
            }
        }

        It "Should not touch the fallback file when structured logging succeeds" {
            Write-SecurityLog -SecurityEventType "ObjectAccess" -Message "Test" -Outcome "Success"

            Should -Invoke Out-File -Times 0 -Exactly
            Should -Invoke Write-Warning -Times 0 -Exactly
        }
    }
}
