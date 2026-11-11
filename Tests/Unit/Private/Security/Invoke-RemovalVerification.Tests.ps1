#Requires -Version 5.1

<#
.SYNOPSIS
    Pester tests for Invoke-RemovalVerification

.DESCRIPTION
    Reads the object's ACL back after a removal and reports any of the removed SIDs still present.
    Get-Acl, the retry wrapper and the replication pause are mocked.
#>

BeforeAll {
    function Write-StructuredLog { param($Message, $Level, $Component, $CorrelationId, $Data) }
    function Invoke-ADOperationWithRetry { param([scriptblock]$ScriptBlock, $MaxRetries, $OperationName, $ObjectContext, $CorrelationId) }

    . "$PSScriptRoot\..\..\..\..\Private\Security\Invoke-RemovalVerification.ps1"

    $script:dn = 'CN=Test,DC=contoso,DC=com'

    # An ACL whose access rules name the given SIDs, as Get-Acl on the AD: drive returns it
    function New-TestAcl {
        param([string[]]$Sid, [string[]]$InheritedSid = @())
        [PSCustomObject]@{
            Access = @(
                $Sid | ForEach-Object {
                    [PSCustomObject]@{ IdentityReference = [System.Security.Principal.SecurityIdentifier]$_; IsInherited = $false }
                }
                $InheritedSid | ForEach-Object {
                    [PSCustomObject]@{ IdentityReference = [System.Security.Principal.SecurityIdentifier]$_; IsInherited = $true }
                }
            )
        }
    }
}

Describe "Invoke-RemovalVerification" -Tag 'Unit', 'Private', 'Security' {

    BeforeEach {
        Mock Write-StructuredLog { }
        Mock Start-Sleep { }
        Mock Invoke-ADOperationWithRetry { & $ScriptBlock }
        Mock Get-Acl { New-TestAcl -Sid 'S-1-5-32-544' }
    }

    Context "Parameter validation" {
        It "Rejects an empty ObjectDN" {
            { Invoke-RemovalVerification -ObjectDN "" -AllowedSIDs @("S-1-5-21-1-2-3-1001") } | Should -Throw "*argument is null or empty*"
        }

        It "Rejects an empty AllowedSIDs list" {
            { Invoke-RemovalVerification -ObjectDN $script:dn -AllowedSIDs @() } | Should -Throw "*AllowedSIDs*"
        }

        It "Fails, without reading the ACL, for a whitespace-only ObjectDN" {
            $result = Invoke-RemovalVerification -ObjectDN "   " -AllowedSIDs @("S-1-5-21-1-2-3-1001")

            $result.Success | Should -Be $false
            $result.ErrorMessage | Should -Be 'Verification error: ObjectDN parameter cannot be empty or whitespace'
            Should -Invoke Get-Acl -Times 0 -Exactly
        }

        It "Reads the ACL from the trimmed DN" {
            Invoke-RemovalVerification -ObjectDN "  $($script:dn)  " -AllowedSIDs @("S-1-5-21-1-2-3-1001") | Out-Null

            Should -Invoke Get-Acl -Times 1 -Exactly -ParameterFilter { $Path -eq "AD:\$($script:dn)" }
        }
    }

    Context "ACL verification" {
        It "Succeeds when none of the removed SIDs remain" {
            Mock Get-Acl { New-TestAcl -Sid 'S-1-5-21-1-2-3-2000', 'S-1-5-32-544' }

            $result = Invoke-RemovalVerification -ObjectDN $script:dn -AllowedSIDs @("S-1-5-21-1-2-3-1001")

            $result.Success | Should -Be $true
            $result.ErrorMessage | Should -BeNullOrEmpty
            @($result.RemainingOrphanedSIDs).Count | Should -Be 0
        }

        It "Succeeds against an empty ACL" {
            Mock Get-Acl { [PSCustomObject]@{ Access = @() } }

            (Invoke-RemovalVerification -ObjectDN $script:dn -AllowedSIDs @("S-1-5-21-1-2-3-1001", "S-1-5-21-1-2-3-1002")).Success |
                Should -Be $true
        }

        It "Reports the one removed SID that is still present" {
            Mock Get-Acl { New-TestAcl -Sid 'S-1-5-21-1-2-3-1001', 'S-1-5-32-544' }

            $result = Invoke-RemovalVerification -ObjectDN $script:dn -AllowedSIDs @("S-1-5-21-1-2-3-1001")

            $result.Success | Should -Be $false
            @($result.RemainingOrphanedSIDs) | Should -Be @('S-1-5-21-1-2-3-1001')
            $result.ErrorMessage | Should -Be 'Verification failed: 1 of 1 SIDs still present'
        }

        It "Reports every removed SID still present, and only those" {
            Mock Get-Acl { New-TestAcl -Sid 'S-1-5-21-1-2-3-1001', 'S-1-5-21-1-2-3-1002', 'S-1-5-32-544' }
            $targetSIDs = @("S-1-5-21-1-2-3-1001", "S-1-5-21-1-2-3-1002", "S-1-5-21-1-2-3-1003")

            $result = Invoke-RemovalVerification -ObjectDN $script:dn -AllowedSIDs $targetSIDs

            $result.Success | Should -Be $false
            @($result.RemainingOrphanedSIDs) | Should -Be @('S-1-5-21-1-2-3-1001', 'S-1-5-21-1-2-3-1002')
            $result.ErrorMessage | Should -Be 'Verification failed: 2 of 3 SIDs still present'
        }
    }

    Context "Inherited entries" {
        It "Succeeds when only an inherited entry for a removed SID remains (#46)" {
            Mock Get-Acl { New-TestAcl -Sid 'S-1-5-32-544' -InheritedSid 'S-1-5-21-1-2-3-1001' }

            $result = Invoke-RemovalVerification -ObjectDN $script:dn -AllowedSIDs @("S-1-5-21-1-2-3-1001")

            $result.Success | Should -Be $true
        }
    }

    Context "Retry, replication delay and errors" {
        It "Waits 500 ms for replication before reading the ACL" {
            Invoke-RemovalVerification -ObjectDN $script:dn -AllowedSIDs @("S-1-5-21-1-2-3-1001") | Out-Null

            Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Milliseconds -eq 500 }
        }

        It "Reads the ACL through the retry wrapper with three retries" {
            Invoke-RemovalVerification -ObjectDN $script:dn -AllowedSIDs @("S-1-5-21-1-2-3-1001") | Out-Null

            Should -Invoke Invoke-ADOperationWithRetry -Times 1 -Exactly -ParameterFilter {
                $MaxRetries -eq 3 -and $OperationName -eq 'Get-ACL-Verification' -and $ObjectContext -eq $script:dn
            }
        }

        It "Returns a failure, and logs it at Error level, when the ACL cannot be read" {
            Mock Get-Acl { throw [System.TimeoutException]::new("Operation timed out") }

            $result = Invoke-RemovalVerification -ObjectDN $script:dn -AllowedSIDs @("S-1-5-21-1-2-3-1001") -CorrelationId 'ver-err'

            $result.Success | Should -Be $false
            $result.ErrorMessage | Should -Be 'Verification error: Operation timed out'
            @($result.RemainingOrphanedSIDs).Count | Should -Be 0
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Error' -and $CorrelationId -eq 'ver-err' -and
                $Message -eq "Verification error for $($script:dn) : Verification error: Operation timed out"
            }
        }
    }

    Context "Logging and correlation" {
        It "Logs the start with the number of SIDs at Debug level" {
            Invoke-RemovalVerification -ObjectDN $script:dn -AllowedSIDs @("S-1-5-21-1-2-3-1001", "S-1-5-21-1-2-3-1002", "S-1-5-21-1-2-3-1003") | Out-Null

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Debug' -and $Message -eq "Starting removal verification for $($script:dn) (Verifying 3 SIDs)"
            }
        }

        It "Logs a successful verification at Verbose level" {
            Invoke-RemovalVerification -ObjectDN $script:dn -AllowedSIDs @("S-1-5-21-1-2-3-1001") | Out-Null

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Verbose' -and $Message -eq "Verification successful: All 1 SIDs removed from $($script:dn)"
            }
        }

        It "Logs a failed verification at Warning level" {
            Mock Get-Acl { New-TestAcl -Sid 'S-1-5-21-1-2-3-1001' }

            Invoke-RemovalVerification -ObjectDN $script:dn -AllowedSIDs @("S-1-5-21-1-2-3-1001") | Out-Null

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Warning' -and $Message -eq "Verification failed for $($script:dn) : Verification failed: 1 of 1 SIDs still present"
            }
        }

        It "Uses the caller's correlation ID on every log entry" {
            Invoke-RemovalVerification -ObjectDN $script:dn -AllowedSIDs @("S-1-5-21-1-2-3-1001") -CorrelationId 'ver-1' | Out-Null

            Should -Invoke Write-StructuredLog -Times 2 -Exactly -ParameterFilter { $CorrelationId -eq 'ver-1' }
            Should -Invoke Write-StructuredLog -Times 0 -Exactly -ParameterFilter { $CorrelationId -ne 'ver-1' }
        }

        It "Passes the caller's correlation ID to the audited ACL read" {
            Invoke-RemovalVerification -ObjectDN $script:dn -AllowedSIDs @("S-1-5-21-1-2-3-1001") -CorrelationId 'ver-2' | Out-Null

            Should -Invoke Invoke-ADOperationWithRetry -Times 1 -Exactly -ParameterFilter { $CorrelationId -eq 'ver-2' }
        }

        It "Generates a GUID correlation ID when none is given" {
            Invoke-RemovalVerification -ObjectDN $script:dn -AllowedSIDs @("S-1-5-21-1-2-3-1001") | Out-Null

            Should -Invoke Write-StructuredLog -Times 2 -Exactly -ParameterFilter {
                $CorrelationId -match '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$'
            }
        }
    }
}
