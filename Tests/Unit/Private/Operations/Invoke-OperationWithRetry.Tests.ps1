#Requires -Version 5.1

BeforeAll {
    . "$PSScriptRoot\..\..\..\..\Private\Operations\Invoke-OperationWithRetry.ps1"
}

Describe "Invoke-OperationWithRetry" -Tag "Unit", "Operations" {

    BeforeEach {
        Mock Start-Sleep { }
        # No jitter, so the waits are exactly the exponential backoff
        Mock Get-Random { 0 }
        $script:attempts = 0
    }

    Context "Parameter validation" {
        # Attempts, the first included: the public -MaxRetries 10 arrives as 11
        It "Rejects a MaxRetries of <_>" -ForEach @(0, 12) {
            { Invoke-OperationWithRetry -ScriptBlock { 'x' } -MaxRetries $_ } | Should -Throw
        }

        It "Accepts 11 attempts, the most the public -MaxRetries can ask for" {
            Invoke-OperationWithRetry -ScriptBlock { 'ok' } -MaxRetries 11 | Should -Be 'ok'
        }
    }

    Context "Success" {
        It "Returns what the script block returns, running it once" {
            $result = Invoke-OperationWithRetry -ScriptBlock { $script:attempts++; @{ Success = $true; Result = 'Operation completed' } }

            $result.Result | Should -Be 'Operation completed'
            $script:attempts | Should -Be 1
            Should -Invoke Start-Sleep -Times 0 -Exactly
        }

        It "Retries a transient failure and returns the later success" {
            $result = Invoke-OperationWithRetry -ScriptBlock {
                $script:attempts++
                if ($script:attempts -lt 3) { throw 'The operation returned because the timeout limit was exceeded' }
                'third time'
            }

            $result | Should -Be 'third time'
            $script:attempts | Should -Be 3
            Should -Invoke Start-Sleep -Times 2 -Exactly
        }
    }

    Context "Failure" {
        It "Rethrows a non-retryable error at once" {
            { Invoke-OperationWithRetry -ScriptBlock { $script:attempts++; throw 'Access is denied' } -MaxRetries 5 } |
                Should -Throw -ExpectedMessage 'Access is denied'

            $script:attempts | Should -Be 1
            Should -Invoke Start-Sleep -Times 0 -Exactly
        }

        It "Gives up after MaxRetries attempts at a retryable error and rethrows it" {
            { Invoke-OperationWithRetry -ScriptBlock { $script:attempts++; throw 'The server is not operational: network down' } -MaxRetries 4 } |
                Should -Throw -ExpectedMessage 'The server is not operational: network down'

            $script:attempts | Should -Be 4
            Should -Invoke Start-Sleep -Times 3 -Exactly
        }

        It "Uses three attempts by default" {
            { Invoke-OperationWithRetry -ScriptBlock { $script:attempts++; throw 'domain controller busy' } } | Should -Throw

            $script:attempts | Should -Be 3
        }

        It "Backs off exponentially between attempts: 1, 2 then 4 seconds" {
            { Invoke-OperationWithRetry -ScriptBlock { throw 'connection reset' } -MaxRetries 4 } | Should -Throw

            Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 1 }
            Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 2 }
            Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 4 }
        }

        It "Treats only errors matching a custom RetryableErrorPattern as retryable" {
            { Invoke-OperationWithRetry -ScriptBlock { $script:attempts++; throw 'quota exceeded' } -RetryableErrorPattern 'quota' -MaxRetries 2 } |
                Should -Throw -ExpectedMessage 'quota exceeded'
            $script:attempts | Should -Be 2

            $script:attempts = 0
            { Invoke-OperationWithRetry -ScriptBlock { $script:attempts++; throw 'timeout' } -RetryableErrorPattern 'quota' -MaxRetries 2 } |
                Should -Throw
            $script:attempts | Should -Be 1
        }
    }
}
