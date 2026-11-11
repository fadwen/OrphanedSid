#Requires -Version 5.1

BeforeAll {
    $script:ProjectRoot = Split-Path (Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent) -Parent

    . (Join-Path $ProjectRoot 'Classes\SecurityValidationResult.ps1')
    . (Join-Path $ProjectRoot 'Private\Security\Invoke-SecurityValidation.ps1')
    . (Join-Path $ProjectRoot 'Private\SID\Test-SIDSecurity.ps1')
    . (Join-Path $ProjectRoot 'Private\Logging\Write-StructuredLog.ps1')

    $script:userSid = 'S-1-5-21-1234567890-1234567890-1234567890-1001'
    $script:adminSid = 'S-1-5-21-1234567890-1234567890-1234567890-512'
    $script:systemSid = 'S-1-5-18'

    # What Test-SIDSecurity returns for each test SID: the system SID is blocked, the admin SID
    # needs elevated confirmation, anything else is allowed
    function New-SidValidation {
        param([string]$Sid)
        $v = [SecurityValidationResult]::new()
        if ($Sid -eq $script:systemSid) {
            $v.IsValid = $false
            $v.RiskLevel = 'Critical'
            $v.Issues = @('SID is in protected SIDs list - removal blocked by security policy')
        } elseif ($Sid -eq $script:adminSid) {
            $v.RiskLevel = 'High'
            $v.RequiresElevatedConfirmation = $true
        }
        $v
    }
}

Describe 'Invoke-SecurityValidation' -Tag 'Unit', 'Private', 'Security' {
    BeforeEach {
        Mock Write-StructuredLog { }
        Mock Test-SIDSecurity { New-SidValidation -Sid $SIDString }
    }

    Context 'Parameter validation' {
        It 'Rejects a null, empty or empty-string OrphanedSIDs' {
            { Invoke-SecurityValidation -OrphanedSIDs $null } | Should -Throw
            { Invoke-SecurityValidation -OrphanedSIDs @() } | Should -Throw
            { Invoke-SecurityValidation -OrphanedSIDs @('') } | Should -Throw
        }
    }

    Context 'Combining the per-SID validations' {
        It 'Allows every SID that passes, at Low risk' {
            $sids = @($script:userSid, 'S-1-5-21-1234567890-1234567890-1234567890-1002')

            $result = Invoke-SecurityValidation -OrphanedSIDs $sids

            $result | Should -BeOfType 'SecurityValidationResult'
            $result.IsValid | Should -Be $true
            $result.RiskLevel | Should -Be 'Low'
            $result.AllowedSIDs | Should -Be $sids
            $result.BlockedSIDs.Count | Should -Be 0
            $result.Issues.Count | Should -Be 0
            $result.RequiresElevatedConfirmation | Should -Be $false
        }

        It 'Blocks a SID that fails, carrying its issues, and rates the batch Critical' {
            $result = Invoke-SecurityValidation -OrphanedSIDs @($script:systemSid, $script:userSid)

            $result.IsValid | Should -Be $false
            $result.RiskLevel | Should -Be 'Critical'
            $result.BlockedSIDs | Should -Be @($script:systemSid)
            $result.AllowedSIDs | Should -Be @($script:userSid)
            $result.Issues | Should -Be @('SID is in protected SIDs list - removal blocked by security policy')
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Warning' -and $Message -eq "SID blocked from removal: $($script:systemSid) (Validation failed)"
            }
        }

        It 'Allows a SID needing elevated confirmation but flags it and rates the batch High' {
            $result = Invoke-SecurityValidation -OrphanedSIDs @($script:userSid, $script:adminSid)

            $result.IsValid | Should -Be $true
            $result.RiskLevel | Should -Be 'High'
            $result.RequiresElevatedConfirmation | Should -Be $true
            $result.AllowedSIDs | Should -Be @($script:userSid, $script:adminSid)
            $result.Issues | Should -Be @("High-risk SID detected: $($script:adminSid)")
        }

        It 'Keeps the batch Critical when a blocked SID precedes a high-risk one' {
            $result = Invoke-SecurityValidation -OrphanedSIDs @($script:systemSid, $script:adminSid)

            $result.RiskLevel | Should -Be 'Critical'
        }

        It 'Validates each SID at Standard level with the object, domain and correlation context' {
            $objectDN = 'CN=TestObject,DC=test,DC=com'
            $domainSid = 'S-1-5-21-1234567890-1234567890-1234567890'

            Invoke-SecurityValidation -OrphanedSIDs @($script:userSid, $script:adminSid) -ObjectDN $objectDN -CurrentDomainSID $domainSid -CorrelationId 'sec-1' | Out-Null

            Should -Invoke Test-SIDSecurity -Times 2 -Exactly
            foreach ($sid in $script:userSid, $script:adminSid) {
                Should -Invoke Test-SIDSecurity -Times 1 -Exactly -ParameterFilter {
                    $SIDString -eq $sid -and $ObjectDN -eq $objectDN -and $ValidationLevel -eq 'Standard' -and
                    $CurrentDomainSID -eq $domainSid -and $CorrelationId -eq 'sec-1'
                }
            }
        }

        It 'Returns one result per SID piped to it' {
            $results = @($script:userSid, $script:systemSid | Invoke-SecurityValidation)

            $results.Count | Should -Be 2
            $results[0].AllowedSIDs | Should -Be @($script:userSid)
            $results[1].BlockedSIDs | Should -Be @($script:systemSid)
        }

        It 'Logs the outcome with the allowed and blocked counts' {
            Invoke-SecurityValidation -OrphanedSIDs @($script:systemSid, $script:userSid) -CorrelationId 'sec-2' | Out-Null

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Verbose' -and $CorrelationId -eq 'sec-2' -and
                $Message -eq 'Security validation completed - Valid: False, Allowed: 1, Blocked: 1'
            }
        }
    }

    Context 'Error handling' {
        It 'Fails closed as Critical, and logs the error, when a SID check throws' {
            Mock Test-SIDSecurity { throw 'Simulated validation error for testing' }

            $result = Invoke-SecurityValidation -OrphanedSIDs @($script:userSid) -CorrelationId 'sec-3'

            $result.IsValid | Should -Be $false
            $result.RiskLevel | Should -Be 'Critical'
            $result.Issues | Should -Be @('Validation error: Simulated validation error for testing')
            $result.AllowedSIDs.Count | Should -Be 0
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Error' -and $CorrelationId -eq 'sec-3' -and $Message -like '*Simulated validation error for testing'
            }
        }
    }
}
