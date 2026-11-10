# Unit tests for Write-ADOperationSecurityLog.ps1
BeforeAll {
    $here = $PSScriptRoot

    $sut = (Split-Path -Leaf $PSCommandPath) -replace '\.Tests\.', '.'

    $modulePath = "$here\..\..\..\..\Private\Logging\$sut"

    . $modulePath

    . "$here\..\..\..\..\Private\Logging\Write-SecurityLog.ps1"
}

Describe "Write-ADOperationSecurityLog" -Tag @('Unit', 'Logging', 'Security', 'ActiveDirectory') {

    BeforeEach {
        # Mocked per test so every call count starts at zero
        Mock Write-SecurityLog { }
    }

    Context "Parameter Validation" {

        It "Should reject an Outcome outside Attempt, Success and Failure" {
            { Write-ADOperationSecurityLog -OperationName "Get-ADUser" -Outcome "Pending" } | Should -Throw
            Should -Invoke Write-SecurityLog -Times 0 -Exactly
        }

        It "Should reject an empty OperationName" {
            { Write-ADOperationSecurityLog -OperationName "" -Outcome "Success" } | Should -Throw
        }

        It "Should generate a GUID CorrelationId when not provided and use it in the context" {
            Write-ADOperationSecurityLog -OperationName "Get-ADUser" -Outcome "Success"

            Should -Invoke Write-SecurityLog -Times 1 -Exactly -ParameterFilter {
                $CorrelationId -match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -and
                $SecurityContext.CorrelationId -eq $CorrelationId
            }
        }

        It "Should create standardized audit context" {
            Write-ADOperationSecurityLog -OperationName "Get-ADUser" -Outcome "Success"

            Should -Invoke Write-SecurityLog -Times 1 -Exactly -ParameterFilter {
                $SecurityContext.OperationName -eq "Get-ADUser" -and
                $SecurityContext.Outcome -eq "Success" -and
                $SecurityContext.Component -eq "ADOperations" -and
                $SecurityContext.SecurityEventType -eq "ObjectAccess"
            }
        }

        It "Should include timestamp in audit context" {
            $script:BeforeTime = Get-Date
            Write-ADOperationSecurityLog -OperationName "Get-ADUser" -Outcome "Success"
            $script:AfterTime = Get-Date

            Should -Invoke Write-SecurityLog -Times 1 -Exactly -ParameterFilter {
                $SecurityContext.Timestamp -is [datetime] -and
                $SecurityContext.Timestamp -ge $script:BeforeTime -and
                $SecurityContext.Timestamp -le $script:AfterTime
            }
        }

        It "Should include user context information" {
            Write-ADOperationSecurityLog -OperationName "Get-ADUser" -Outcome "Success"

            Should -Invoke Write-SecurityLog -Times 1 -Exactly -ParameterFilter {
                $SecurityContext.UserContext -eq "$env:USERNAME@$env:COMPUTERNAME"
            }
        }

        It "Should use provided CorrelationId in context" {
            $testCorrelationId = "test-correlation-123"
            Write-ADOperationSecurityLog -OperationName "Get-ADUser" -Outcome "Success" -CorrelationId $testCorrelationId

            Should -Invoke Write-SecurityLog -Times 1 -Exactly -ParameterFilter {
                $SecurityContext.CorrelationId -eq $testCorrelationId -and
                $CorrelationId -eq $testCorrelationId
            }
        }

        It "Should merge additional security context" {
            $additionalContext = @{
                ObjectDN = "CN=TestUser,OU=Users,DC=domain,DC=com"
                Filter = "samAccountName -eq 'testuser'"
                Properties = @("Name", "SamAccountName", "DistinguishedName")
            }

            Write-ADOperationSecurityLog -OperationName "Get-ADUser" -Outcome "Success" -SecurityContext $additionalContext

            Should -Invoke Write-SecurityLog -Times 1 -Exactly -ParameterFilter {
                $SecurityContext.ObjectDN -eq "CN=TestUser,OU=Users,DC=domain,DC=com" -and
                $SecurityContext.Filter -eq "samAccountName -eq 'testuser'" -and
                ($SecurityContext.Properties -join ',') -eq 'Name,SamAccountName,DistinguishedName' -and
                $SecurityContext.Component -eq 'ADOperations'
            }
        }

        It "Should let additional context override a standard field" {
            Write-ADOperationSecurityLog -OperationName "Get-ADUser" -Outcome "Success" -SecurityContext @{ Component = 'Custom' }

            Should -Invoke Write-SecurityLog -Times 1 -Exactly -ParameterFilter {
                $SecurityContext.Component -eq 'Custom'
            }
        }

        It "Should send only the seven standard fields for an empty additional context" {
            Write-ADOperationSecurityLog -OperationName "Get-ADUser" -Outcome "Success" -SecurityContext @{}

            Should -Invoke Write-SecurityLog -Times 1 -Exactly -ParameterFilter {
                $SecurityContext.Count -eq 7
            }
        }
    }

    Context "Outcome-Based Message Generation" {

        It "Should write '<ExpectedMessage>' for the <OutcomeName> outcome" -ForEach @(
            @{ OutcomeName = 'Attempt'; Operation = 'Get-ADUser'; ExpectedMessage = 'Attempting Active Directory operation: Get-ADUser' }
            @{ OutcomeName = 'Success'; Operation = 'Set-ADUser'; ExpectedMessage = 'Successfully completed Active Directory operation: Set-ADUser' }
            @{ OutcomeName = 'Failure'; Operation = 'Remove-ADUser'; ExpectedMessage = 'Failed Active Directory operation: Remove-ADUser' }
        ) {
            Write-ADOperationSecurityLog -OperationName $Operation -Outcome $OutcomeName

            Should -Invoke Write-SecurityLog -Times 1 -Exactly -ParameterFilter {
                $Message -eq $ExpectedMessage -and
                $Outcome -eq $OutcomeName -and
                $SecurityEventType -eq 'ObjectAccess'
            }
        }

        It "Should name a custom AD operation in the message" {
            Write-ADOperationSecurityLog -OperationName "Custom-ADOperation" -Outcome "Success"

            Should -Invoke Write-SecurityLog -Times 1 -Exactly -ParameterFilter {
                $Message -eq "Successfully completed Active Directory operation: Custom-ADOperation"
            }
        }
    }

    Context "Write-SecurityLog Integration" {

        It "Should write one ObjectAccess entry per call" {
            foreach ($outcome in 'Attempt', 'Success', 'Failure') {
                Write-ADOperationSecurityLog -OperationName "Get-ADUser" -Outcome $outcome
            }

            Should -Invoke Write-SecurityLog -Times 3 -Exactly
            Should -Invoke Write-SecurityLog -Times 3 -Exactly -ParameterFilter { $SecurityEventType -eq "ObjectAccess" }
        }

        It "Should support traceability through CorrelationId" {
            $traceId = "compliance-trace-789"

            Write-ADOperationSecurityLog -OperationName "Get-ADUser" -Outcome "Attempt" -CorrelationId $traceId
            Write-ADOperationSecurityLog -OperationName "Get-ADUser" -Outcome "Success" -CorrelationId $traceId

            Should -Invoke Write-SecurityLog -Times 2 -Exactly -ParameterFilter {
                $CorrelationId -eq $traceId -and $SecurityContext.CorrelationId -eq $traceId
            }
        }
    }

    Context "Error Scenarios" {

        It "Should propagate a Write-SecurityLog failure" {
            Mock Write-SecurityLog { throw "Security log system failure" }

            { Write-ADOperationSecurityLog -OperationName "Get-ADUser" -Outcome "Success" } |
                Should -Throw -ExpectedMessage '*Security log system failure*'
        }
    }
}
