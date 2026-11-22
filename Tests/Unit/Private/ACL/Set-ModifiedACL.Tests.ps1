#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
#Requires -Version 5.1

<#
.SYNOPSIS
    Unit tests for Set-ModifiedACL, which writes a modified ACL back to an Active Directory object.

.DESCRIPTION
    Tests the real function with its three collaborators mocked: Test-ValidDistinguishedName decides
    whether the target exists, Invoke-ADOperationWithRetry runs the Set-Acl and Get-Acl script
    blocks, and Write-StructuredLog records.
#>

BeforeAll {
    # As OrphanedSid.psm1 does: in the module the code under test runs under strict mode
    Set-StrictMode -Version Latest

    . "$PSScriptRoot\..\..\..\TestHelpers\ADCmdletStubs.ps1"
    . "$PSScriptRoot\..\..\..\..\Private\ACL\Set-ModifiedACL.ps1"
    . "$PSScriptRoot\..\..\..\..\Private\ACL\Get-AclAccessRule.ps1"
    . "$PSScriptRoot\..\..\..\..\Private\ActiveDirectory\Get-DirectoryObjectAcl.ps1"
    . "$PSScriptRoot\..\..\..\..\Private\ActiveDirectory\Set-DirectoryObjectAcl.ps1"

    # Placeholders for the collaborators so they can be mocked; the real ones live in other files
    function Write-StructuredLog { param($Message, $Level, $Component, $CorrelationId, $LogPath, $Data) }
    function Test-ValidDistinguishedName { param($DistinguishedName, $CorrelationId) }
    function Invoke-ADOperationWithRetry { param([scriptblock]$ScriptBlock, $MaxRetries, $OperationName, $ObjectContext, $CorrelationId) }

    $script:dn = 'CN=Finance Share,OU=Groups,DC=contoso,DC=com'
    # A real security descriptor with three entries, because the write goes through
    # Set-DirectoryObjectAcl, which accepts nothing else. The trustees are well-known SIDs, so
    # reading them back needs no domain.
    $script:acl = [System.DirectoryServices.ActiveDirectorySecurity]::new()
    foreach ($sid in 'S-1-5-32-544', 'S-1-5-18', 'S-1-5-11') {
        $rule = [System.DirectoryServices.ActiveDirectoryAccessRule]::new(
            [System.Security.Principal.SecurityIdentifier]$sid,
            [System.DirectoryServices.ActiveDirectoryRights]::GenericRead,
            [System.Security.AccessControl.AccessControlType]::Allow)
        $script:acl.AddAccessRule($rule)
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

        It 'Throws for a whitespace ObjectDN, and writes nothing' {
            $expected = @{
                ErrorId         = 'DistinguishedNameEmpty,Set-ModifiedACL'
                ExpectedMessage = 'ObjectDN parameter cannot be empty or whitespace'
                ExceptionType   = [System.ArgumentException]
            }
            { Set-ModifiedACL -ACL $script:acl -ObjectDN '   ' } | Should -Throw @expected
            Should -Invoke Set-Acl -Times 0 -Exactly
        }

        It 'Throws for an ACL argument that holds no object, and writes nothing' {
            # An empty string passes ValidateNotNull and is still no ACL
            { Set-ModifiedACL -ACL '' -ObjectDN $script:dn } |
                Should -Throw -ErrorId 'AclMissing,Set-ModifiedACL' -ExpectedMessage 'ACL parameter must not be null'
            Should -Invoke Set-Acl -Times 0 -Exactly
        }

        # A refused name ends the function whatever it looks like. The two cases differ in that: the
        # first is no name at all, and the second has the form of one and lacks a DC= component.
        It 'Throws for a name that is refused as not well formed, and writes nothing: <Name>' -ForEach @(
            @{ Name = 'not-a-distinguished-name' }
            @{ Name = 'CN=Gone,OU=Groups' }
        ) {
            Mock Test-ValidDistinguishedName { $false }

            $expected = @{
                ErrorId         = 'DistinguishedNameRefused,Set-ModifiedACL'
                ExpectedMessage = "*was refused because it is not well formed: $Name"
            }
            { Set-ModifiedACL -ACL $script:acl -ObjectDN $Name } | Should -Throw @expected
            Should -Invoke Set-Acl -Times 0 -Exactly
            # The error leaves the function without passing its catch, which is what logs at Error
            Should -Invoke Write-StructuredLog -Times 0 -Exactly -ParameterFilter { $Level -eq 'Error' }
        }
    }

    Context 'Applying the ACL' {
        It 'Writes the ACL to the AD: drive path of the object and verifies it' {
            $result = Set-ModifiedACL -ACL $script:acl -ObjectDN $script:dn -CorrelationId 'apply-1'

            $result.PSTypeNames | Should -Contain 'ACLApplicationResult'
            $result.Success | Should -BeTrue
            $result.Verified | Should -BeTrue
            $result.VerificationError | Should -BeNullOrEmpty
            $result.ErrorMessage | Should -BeNullOrEmpty
            Should -Invoke Set-Acl -Times 1 -Exactly -ParameterFilter {
                $Path -eq "AD:\$($script:dn)" -and $AclObject -eq $script:acl
            }
            Should -Invoke Get-Acl -Times 1 -Exactly -ParameterFilter { $Path -eq "AD:\$($script:dn)" }
        }

        It 'Writes to an object whose name holds <Case> (#128)' -ForEach @(
            @{ Case = 'a run of dots'; Name = 'OU=Misc...,DC=contoso,DC=com' }
            @{ Case = 'two dots and the name of a system folder'; Name = 'OU=..System32,DC=contoso,DC=com' }
        ) {
            $result = Set-ModifiedACL -ACL $script:acl -ObjectDN $Name

            $result.Success | Should -BeTrue
            Should -Invoke Set-Acl -Times 1 -Exactly -ParameterFilter { $Path -eq "AD:\$Name" }
        }

        It 'Trims the distinguished name before building the path' {
            Set-ModifiedACL -ACL $script:acl -ObjectDN "  $($script:dn)  " | Out-Null

            Should -Invoke Set-Acl -Times 1 -Exactly -ParameterFilter { $Path -eq "AD:\$($script:dn)" }
        }

        It 'Retries the write three times and the verification twice' {
            Set-ModifiedACL -ACL $script:acl -ObjectDN $script:dn -CorrelationId 'apply-3' | Out-Null

            Should -Invoke Invoke-ADOperationWithRetry -Times 1 -Exactly -ParameterFilter { $MaxRetries -eq 3 -and $CorrelationId -eq 'apply-3' }
            Should -Invoke Invoke-ADOperationWithRetry -Times 1 -Exactly -ParameterFilter { $MaxRetries -eq 2 -and $CorrelationId -eq 'apply-3' }
        }

        It 'Returns the same four fields for a write that was made and for one that failed (#157)' {
            # The result once carried a sentence that the operation was compliant with enterprise
            # security policies, a network flag that was guessed from the text of the error, and
            # three fields about a backup that this function does not take
            $made = Set-ModifiedACL -ACL $script:acl -ObjectDN $script:dn -CorrelationId 'apply-2'
            Mock Set-Acl { throw 'Access is denied' }
            $failed = Set-ModifiedACL -ACL $script:acl -ObjectDN $script:dn -CorrelationId 'apply-2'

            $expected = 'ErrorMessage', 'Success', 'VerificationError', 'Verified'
            @($made.PSObject.Properties.Name | Sort-Object) | Should -Be $expected
            @($failed.PSObject.Properties.Name | Sort-Object) | Should -Be $expected
            $failed.PSTypeNames | Should -Contain 'ACLApplicationResult'
        }
    }

    Context 'Under -WhatIf' {
        It 'Writes nothing and reports no success' {
            $result = Set-ModifiedACL -ACL $script:acl -ObjectDN $script:dn -WhatIf

            $result.Success | Should -BeFalse
            $result.Verified | Should -BeFalse
            $result.ErrorMessage | Should -BeNullOrEmpty
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
            $result.Verified | Should -BeFalse
            Should -Invoke Get-Acl -Times 0 -Exactly
        }

        It 'Carries the message of the error that was caught, whatever it was' {
            Mock Set-Acl { throw 'The network path was not found' }

            $result = Set-ModifiedACL -ACL $script:acl -ObjectDN $script:dn

            $result.Success | Should -BeFalse
            $result.ErrorMessage | Should -BeLike '*The network path was not found*'
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

            # Once, where the catch of the function builds the failed result
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Error' -and $CorrelationId -eq 'fail-1' -and
                $Message -eq "Failed to apply ACL changes to $($script:dn) : boom"
            }
        }
    }
}
