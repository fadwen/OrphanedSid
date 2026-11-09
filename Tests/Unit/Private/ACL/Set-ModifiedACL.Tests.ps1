#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
#Requires -Version 5.1

<#
.SYNOPSIS
    Unit tests for Set-ModifiedACL, which writes a modified ACL back to an Active Directory object.

.DESCRIPTION
    Tests the real function with its three collaborators mocked: Test-ValidDistinguishedName decides
    whether the target exists, Invoke-ADOperationWithRetry runs the Set-Acl and Get-Acl script
    blocks, and Write-StructuredLog records. The earlier version of this file defined its own
    Set-ModifiedACL and tested that, so none of the function's branches were covered.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\TestHelpers\ADCmdletStubs.ps1"
    . "$PSScriptRoot\..\..\..\..\Private\ACL\Set-ModifiedACL.ps1"

    # Placeholders for the collaborators so they can be mocked; the real ones live in other files
    function Write-StructuredLog { param($Message, $Level, $Component, $CorrelationId, $LogPath, $Data) }
    function Test-ValidDistinguishedName { param($DistinguishedName, $CorrelationId) }
    function Invoke-ADOperationWithRetry { param([scriptblock]$ScriptBlock, $MaxRetries, $OperationName, $ObjectContext, $CorrelationId) }

    $script:dn = 'CN=Finance Share,OU=Groups,DC=contoso,DC=com'
    $script:acl = [PSCustomObject]@{
        Access = @(
            [PSCustomObject]@{ IdentityReference = 'CONTOSO\Domain Admins' }
            [PSCustomObject]@{ IdentityReference = 'CONTOSO\Finance' }
            [PSCustomObject]@{ IdentityReference = 'NT AUTHORITY\SYSTEM' }
        )
    }
}

Describe 'Set-ModifiedACL' -Tag 'Unit', 'ACL', 'Private' {

    BeforeEach {
        Mock Write-StructuredLog { }
        Mock Test-ValidDistinguishedName { $true }
        # The retry wrapper runs the block it is given, so Set-Acl and Get-Acl below are what run
        Mock Invoke-ADOperationWithRetry { & $ScriptBlock }
        Mock Set-Acl { }
        Mock Get-Acl { [PSCustomObject]@{ Access = @() } }
    }

    Context 'Parameter validation' {
        It 'Rejects a null ACL' {
            { Set-ModifiedACL -ACL $null -ObjectDN $script:dn } | Should -Throw
        }

        It 'Rejects an empty ObjectDN' {
            { Set-ModifiedACL -ACL $script:acl -ObjectDN '' } | Should -Throw
        }

        It 'Throws for a whitespace ObjectDN' {
            { Set-ModifiedACL -ACL $script:acl -ObjectDN '   ' } |
                Should -Throw -ExpectedMessage '*cannot be empty or whitespace*'
        }

        It 'Throws for a distinguished name that smuggles a path traversal' {
            { Set-ModifiedACL -ACL $script:acl -ObjectDN 'CN=..\..\Windows\System32,DC=contoso,DC=com' } |
                Should -Throw -ExpectedMessage '*Path traversal detected*'
            Should -Invoke Set-Acl -Times 0 -Exactly
        }

        It 'Throws for a malformed target that does not exist' {
            Mock Test-ValidDistinguishedName { $false }

            { Set-ModifiedACL -ACL $script:acl -ObjectDN 'not-a-distinguished-name' } |
                Should -Throw -ExpectedMessage '*Target path not found*'
        }

        It 'Returns a failed result for a well-formed target that does not exist' {
            Mock Test-ValidDistinguishedName { $false }

            $result = Set-ModifiedACL -ACL $script:acl -ObjectDN 'CN=Gone,OU=Groups,DC=contoso,DC=com'

            $result.Success | Should -BeFalse
            $result.ErrorMessage | Should -BeLike '*Target path not found*'
            $result.ErrorCategory | Should -Be 'OperationalError'
            Should -Invoke Set-Acl -Times 0 -Exactly
        }
    }

    Context 'Applying the ACL' {
        It 'Writes the ACL to the AD: drive path of the object and verifies it' {
            $result = Set-ModifiedACL -ACL $script:acl -ObjectDN $script:dn -CorrelationId 'apply-1'

            $result.PSTypeNames | Should -Contain 'ACLApplicationResult'
            $result.Success | Should -BeTrue
            $result.Verified | Should -BeTrue
            $result.Path | Should -Be $script:dn
            $result.CorrelationId | Should -Be 'apply-1'
            $result.RulesApplied | Should -Be 3
            $result.AccessEntriesApplied | Should -Be 3
            $result.ErrorMessage | Should -BeNullOrEmpty
            Should -Invoke Set-Acl -Times 1 -Exactly -ParameterFilter {
                $Path -eq "AD:\$($script:dn)" -and $AclObject -eq $script:acl
            }
            Should -Invoke Get-Acl -Times 1 -Exactly -ParameterFilter { $Path -eq "AD:\$($script:dn)" }
        }

        It 'Trims the distinguished name before building the path' {
            Set-ModifiedACL -ACL $script:acl -ObjectDN "  $($script:dn)  " | Out-Null

            Should -Invoke Set-Acl -Times 1 -Exactly -ParameterFilter { $Path -eq "AD:\$($script:dn)" }
        }

        It 'Retries the write three times and the verification twice' {
            Set-ModifiedACL -ACL $script:acl -ObjectDN $script:dn | Out-Null

            Should -Invoke Invoke-ADOperationWithRetry -Times 1 -Exactly -ParameterFilter { $MaxRetries -eq 3 }
            Should -Invoke Invoke-ADOperationWithRetry -Times 1 -Exactly -ParameterFilter { $MaxRetries -eq 2 }
        }

        It 'Records duration, audit and performance details on success' {
            $result = Set-ModifiedACL -ACL $script:acl -ObjectDN $script:dn -CorrelationId 'apply-2'

            $result.Duration | Should -BeOfType [TimeSpan]
            $result.AuditTrail | Should -BeLike "*$($script:dn)*apply-2*"
            $result.PerformanceMetrics.Success | Should -BeTrue
            $result.TroubleshootingInfo | Should -BeNullOrEmpty
            $result.ComplianceValidation | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Under -WhatIf' {
        It 'Writes nothing and reports no success' {
            $result = Set-ModifiedACL -ACL $script:acl -ObjectDN $script:dn -WhatIf

            $result.Success | Should -BeFalse
            $result.Verified | Should -BeFalse
            $result.RulesApplied | Should -Be 0
            Should -Invoke Set-Acl -Times 0 -Exactly
            Should -Invoke Get-Acl -Times 0 -Exactly
            Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Message -like '*skipped due to WhatIf*' }
        }
    }

    Context 'Failures' {
        It 'Returns a failed result when the write fails, without throwing' {
            Mock Set-Acl { throw 'Access is denied' }

            $result = Set-ModifiedACL -ACL $script:acl -ObjectDN $script:dn

            $result.Success | Should -BeFalse
            $result.ErrorMessage | Should -BeLike '*Access is denied*'
            $result.ErrorCategory | Should -Be 'OperationalError'
            $result.NetworkError | Should -BeFalse
            $result.TroubleshootingInfo | Should -BeLike "*$($script:dn)*"
            $result.ComplianceValidation | Should -BeNullOrEmpty
            Should -Invoke Get-Acl -Times 0 -Exactly
        }

        It 'Flags a network failure' {
            Mock Set-Acl { throw 'The network path was not found' }

            $result = Set-ModifiedACL -ACL $script:acl -ObjectDN $script:dn

            $result.Success | Should -BeFalse
            $result.NetworkError | Should -BeTrue
        }

        It 'Reports success with a failed verification when the read-back fails' {
            Mock Get-Acl { throw 'The server is not operational' }

            $result = Set-ModifiedACL -ACL $script:acl -ObjectDN $script:dn

            $result.Success | Should -BeTrue
            $result.Verified | Should -BeFalse
            $result.VerificationError | Should -BeLike '*not operational*'
            Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Level -eq 'Warning' -and $Message -like '*verification failed*' }
        }

        It 'Logs the failure at Error level with the correlation ID' {
            Mock Set-Acl { throw 'boom' }

            Set-ModifiedACL -ACL $script:acl -ObjectDN $script:dn -CorrelationId 'fail-1' | Out-Null

            Should -Invoke Write-StructuredLog -ParameterFilter { $Level -eq 'Error' -and $CorrelationId -eq 'fail-1' }
        }
    }
}
