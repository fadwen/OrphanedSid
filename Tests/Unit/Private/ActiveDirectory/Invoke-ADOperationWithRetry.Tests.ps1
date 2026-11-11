#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
BeforeAll {
    function Write-StructuredLog {
        param($Level, $Message, $Data)
    }

    # Placeholder for Private/Operations/Invoke-OperationWithRetry.ps1 so it can be mocked. The retry
    # behaviour itself is covered by that function's own tests; Invoke-ADOperationWithRetry only
    # delegates to it and logs around the call.
    function Invoke-OperationWithRetry {
        param(
            [scriptblock]$ScriptBlock,
            [int]$MaxRetries,
            [string]$OperationName,
            [string]$CorrelationId
        )
    }

    . "$PSScriptRoot\..\..\..\..\Private\Logging\Write-ADOperationSecurityLog.ps1"
    . "$PSScriptRoot\..\..\..\..\Private\ActiveDirectory\Invoke-ADOperationWithRetry.ps1"
}

Describe "Invoke-ADOperationWithRetry" -Tag 'Unit' {

    BeforeEach {
        Mock Write-ADOperationSecurityLog { }
        Mock Write-StructuredLog { }
        Mock Invoke-OperationWithRetry { & $ScriptBlock }
    }

    Context "Parameter validation" {
        It "Rejects a null ScriptBlock" {
            { Invoke-ADOperationWithRetry -ScriptBlock $null } |
                Should -Throw -ExpectedMessage "*ScriptBlock*"
            Should -Invoke Invoke-OperationWithRetry -Times 0 -Exactly
        }

        # Attempts, the first included: the public -MaxRetries 10 arrives as 11
        It "Rejects MaxRetries <Value> outside 1-11" -ForEach @(
            @{ Value = 0 }
            @{ Value = 12 }
        ) {
            { Invoke-ADOperationWithRetry -ScriptBlock { 'x' } -MaxRetries $Value } |
                Should -Throw -ExpectedMessage "*MaxRetries*"
            Should -Invoke Invoke-OperationWithRetry -Times 0 -Exactly
        }

        It "Rejects an empty OperationName" {
            { Invoke-ADOperationWithRetry -ScriptBlock { 'x' } -OperationName '' } |
                Should -Throw -ExpectedMessage "*OperationName*"
        }
    }

    Context "Delegation to Invoke-OperationWithRetry" {
        It "Passes ScriptBlock, MaxRetries, OperationName and CorrelationId through" {
            $operation = { 'delegated' }
            $correlationId = [System.Guid]::NewGuid().ToString()

            Invoke-ADOperationWithRetry -ScriptBlock $operation -MaxRetries 7 -OperationName 'Read ACL' -CorrelationId $correlationId

            Should -Invoke Invoke-OperationWithRetry -Times 1 -Exactly -ParameterFilter {
                $ScriptBlock -eq $operation -and
                $MaxRetries -eq 7 -and
                $OperationName -eq 'Read ACL' -and
                $CorrelationId -eq $correlationId
            }
        }

        It "Uses MaxRetries 3 and OperationName 'AD Operation' by default" {
            Invoke-ADOperationWithRetry -ScriptBlock { 'x' }

            Should -Invoke Invoke-OperationWithRetry -Times 1 -Exactly -ParameterFilter {
                $MaxRetries -eq 3 -and $OperationName -eq 'AD Operation' -and -not [string]::IsNullOrEmpty($CorrelationId)
            }
        }

        It "Returns the value Invoke-OperationWithRetry returns" {
            Mock Invoke-OperationWithRetry { @{ Status = 'Complete'; Items = @(1, 2, 3) } }

            $result = Invoke-ADOperationWithRetry -ScriptBlock { 'ignored' }

            $result.Status | Should -Be 'Complete'
            $result.Items.Count | Should -Be 3
        }

        It "Returns every element of an array result" {
            Mock Invoke-OperationWithRetry { @('Item1', 'Item2', 'Item3') }

            $result = Invoke-ADOperationWithRetry -ScriptBlock { 'ignored' }

            $result | Should -Be @('Item1', 'Item2', 'Item3')
        }

        It "Rethrows the error Invoke-OperationWithRetry throws" {
            Mock Invoke-OperationWithRetry { throw [System.InvalidOperationException]::new('DC unavailable') }

            { Invoke-ADOperationWithRetry -ScriptBlock { 'x' } } |
                Should -Throw -ExpectedMessage 'DC unavailable' -ExceptionType ([System.InvalidOperationException])
        }
    }

    Context "Security logging" {
        It "Logs an Attempt with the base security context before running the operation" {
            $correlationId = [System.Guid]::NewGuid().ToString()

            Invoke-ADOperationWithRetry -ScriptBlock { 'x' } -MaxRetries 4 -OperationName 'Query' -ObjectContext 'CN=Test' -CorrelationId $correlationId

            Should -Invoke Write-ADOperationSecurityLog -Times 1 -Exactly -ParameterFilter {
                $Outcome -eq 'Attempt' -and
                $OperationName -eq 'Query' -and
                $CorrelationId -eq $correlationId -and
                $SecurityContext.ObjectContext -eq 'CN=Test' -and
                $SecurityContext.MaxRetries -eq 4 -and
                $SecurityContext.ADAccessType -eq 'Sensitive' -and
                $SecurityContext.OperationType -eq 'SingleOperation'
            }
        }

        It "Uses ObjectContext 'Unknown' when none is given" {
            Invoke-ADOperationWithRetry -ScriptBlock { 'x' }

            Should -Invoke Write-ADOperationSecurityLog -Times 1 -Exactly -ParameterFilter {
                $Outcome -eq 'Attempt' -and $SecurityContext.ObjectContext -eq 'Unknown'
            }
        }

        It "Logs Success with the result type name and no Failure" {
            $correlationId = [System.Guid]::NewGuid().ToString()
            Mock Invoke-OperationWithRetry { @{ Status = 'Complete' } }

            Invoke-ADOperationWithRetry -ScriptBlock { 'x' } -OperationName 'Query' -ObjectContext 'CN=Test' -CorrelationId $correlationId

            Should -Invoke Write-ADOperationSecurityLog -Times 1 -Exactly -ParameterFilter {
                $Outcome -eq 'Success' -and
                $OperationName -eq 'Query' -and
                $CorrelationId -eq $correlationId -and
                $SecurityContext.ResultType -eq 'Hashtable' -and
                $SecurityContext.ObjectContext -eq 'CN=Test'
            }
            Should -Invoke Write-ADOperationSecurityLog -Times 0 -Exactly -ParameterFilter { $Outcome -eq 'Failure' }
        }

        It "Logs Success with ResultType 'NoResult' when the operation returns nothing" {
            Mock Invoke-OperationWithRetry { }

            $result = Invoke-ADOperationWithRetry -ScriptBlock { }

            $result | Should -BeNullOrEmpty
            Should -Invoke Write-ADOperationSecurityLog -Times 1 -Exactly -ParameterFilter {
                $Outcome -eq 'Success' -and $SecurityContext.ResultType -eq 'NoResult'
            }
        }

        It "Does not add ResultType to the Attempt context" {
            Invoke-ADOperationWithRetry -ScriptBlock { 'x' }

            Should -Invoke Write-ADOperationSecurityLog -Times 1 -Exactly -ParameterFilter {
                $Outcome -eq 'Attempt' -and -not $SecurityContext.ContainsKey('ResultType')
            }
        }

        It "Logs Failure with the error message and category, and no Success" {
            $correlationId = [System.Guid]::NewGuid().ToString()
            Mock Invoke-OperationWithRetry { throw 'Object not found' }

            { Invoke-ADOperationWithRetry -ScriptBlock { 'x' } -OperationName 'Lookup' -CorrelationId $correlationId } |
                Should -Throw -ExpectedMessage 'Object not found'

            Should -Invoke Write-ADOperationSecurityLog -Times 1 -Exactly -ParameterFilter {
                $Outcome -eq 'Failure' -and
                $OperationName -eq 'Lookup' -and
                $CorrelationId -eq $correlationId -and
                $SecurityContext.ErrorMessage -eq 'Object not found' -and
                $SecurityContext.FailureCategory -eq 'OperationFailed' -and
                $SecurityContext.ADAccessType -eq 'Sensitive'
            }
            Should -Invoke Write-ADOperationSecurityLog -Times 0 -Exactly -ParameterFilter { $Outcome -eq 'Success' }
            Should -Invoke Write-ADOperationSecurityLog -Times 1 -Exactly -ParameterFilter { $Outcome -eq 'Attempt' }
        }
    }
}
