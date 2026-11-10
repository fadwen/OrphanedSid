#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }

<#
.SYNOPSIS
    Tests for the identity resolution helpers in Resolve-SIDIdentity.ps1 that run against the real
    Test-SIDFormat and Test-WellKnownSID.

.DESCRIPTION
    Test-AccessRuleForOrphanedSID.Tests.ps1 covers the helpers with the format checks mocked. These
    tests load the real Test-SIDFormat.ps1, so they show which SIDs the helpers actually pass on to
    the orphan check, and cover the string-extraction and routing branches that file does not.
#>

BeforeAll {
    $rootPath = Split-Path (Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent) -Parent

    function Write-StructuredLog { param($Message, $Level, $Component, $CorrelationId, $LogPath, $Data) }

    . (Join-Path $rootPath 'Classes\OrphanedSIDResult.ps1')
    . (Join-Path $rootPath 'Private\SID\Test-SIDFormat.ps1')
    . (Join-Path $rootPath 'Private\SID\Resolve-SIDIdentity.ps1')

    Mock Write-StructuredLog { }

    $script:dn = 'CN=Finance Share,OU=Groups,DC=contoso,DC=com'
    $script:userSid = 'S-1-5-21-1234567890-1234567890-1234567890-1001'
}

Describe 'Test-SIDValidityAndType with the real format checks' -Tag 'Unit', 'SID', 'Private' {

    BeforeEach {
        $script:Config = $null
    }

    It 'Passes a domain user SID on for the orphan check' {
        Test-SIDValidityAndType -SIDString $script:userSid -CorrelationId 'val-1' | Should -BeTrue

        Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
            $Message -eq "SID $($script:userSid) passed validation and is not well-known" -and $CorrelationId -eq 'val-1'
        }
    }

    It 'Excludes the well-known SID <_>' -ForEach @(
        'S-1-5-32-544'
        'S-1-5-18'
        'S-1-1-0'
        'S-1-5-21-1234567890-1234567890-1234567890-512'
    ) {
        Test-SIDValidityAndType -SIDString $_ | Should -BeFalse
        Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter { $Message -eq "Skipping well-known SID: $_" }
    }

    It "Excludes the malformed SID '<_>'" -ForEach @('S-1-5', 'NotASID','S-1-5-21-ABC-1-2-3') {
        Test-SIDValidityAndType -SIDString $_ | Should -BeFalse
        Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter { $Message -eq "Invalid SID format: $_" }
    }

    It 'Excludes a domain SID listed in the configured ProtectedSIDs' {
        $script:Config = @{ ProtectedSIDs = @($script:userSid) }

        Test-SIDValidityAndType -SIDString $script:userSid | Should -BeFalse
    }
}

Describe 'Get-StringFromIdentityReference' -Tag 'Unit', 'SID', 'Private' {

    It 'Refuses a null identity reference at binding' {
        { Get-StringFromIdentityReference -IdentityReference $null } | Should -Throw
    }

    It 'Trims the extracted value' {
        Get-StringFromIdentityReference -IdentityReference ([PSCustomObject]@{ Value = "  $($script:userSid)  " }) |
            Should -Be $script:userSid
    }

    It 'Returns nothing, and logs why, when the value is only whitespace' {
        $result = Get-StringFromIdentityReference -IdentityReference ([PSCustomObject]@{ Value = '   ' }) -ObjectDN $script:dn

        $result | Should -BeNullOrEmpty
        Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
            $Message -eq "Empty or null string value extracted from identity reference for $($script:dn)"
        }
    }

    It 'Reads the Value property of an NTAccount rather than translating it' {
        Get-StringFromIdentityReference -IdentityReference ([System.Security.Principal.NTAccount]'CONTOSO\someone') |
            Should -Be 'CONTOSO\someone'
    }

    It 'Returns nothing when ToString throws' {
        $reference = [PSCustomObject]@{ Name = 'broken' }
        $reference | Add-Member -MemberType ScriptMethod -Name ToString -Value { throw 'cannot render' } -Force

        Get-StringFromIdentityReference -IdentityReference $reference -ObjectDN $script:dn | Should -BeNullOrEmpty
        Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
            $Message -like "Failed to convert identity reference to string using ToString for $($script:dn)*cannot render*"
        }
    }
}

Describe 'Resolve-IdentityReference routing' -Tag 'Unit', 'SID', 'Private' {

    It 'Hands an NTAccount to Convert-NTAccountToSID with the object DN and correlation ID' {
        Mock Convert-NTAccountToSID { 'S-1-5-21-1-2-3-4' }
        Mock Get-StringFromIdentityReference { }

        $result = Resolve-IdentityReference -IdentityReference ([System.Security.Principal.NTAccount]'CONTOSO\someone') -ObjectDN $script:dn -CorrelationId 'route-1'

        $result | Should -Be 'S-1-5-21-1-2-3-4'
        Should -Invoke Convert-NTAccountToSID -Times 1 -Exactly -ParameterFilter {
            $NTAccount.Value -eq 'CONTOSO\someone' -and $ObjectDN -eq $script:dn -and $CorrelationId -eq 'route-1'
        }
        Should -Invoke Get-StringFromIdentityReference -Times 0 -Exactly
    }

    It 'Takes a SecurityIdentifier value directly without string extraction' {
        Mock Get-StringFromIdentityReference { }

        Resolve-IdentityReference -IdentityReference ([System.Security.Principal.SecurityIdentifier]$script:userSid) |
            Should -Be $script:userSid
        Should -Invoke Get-StringFromIdentityReference -Times 0 -Exactly
    }

    It 'Returns nothing when string extraction yields nothing' {
        Mock Get-StringFromIdentityReference { $null }
        Mock Test-SIDFormat { $true }

        Resolve-IdentityReference -IdentityReference ([PSCustomObject]@{ Value = 'x' }) | Should -BeNullOrEmpty
        Should -Invoke Test-SIDFormat -Times 0 -Exactly
    }
}

Describe 'Convert-NTAccountToSID logging' -Tag 'Unit', 'SID', 'Private' {

    It 'Logs a successful translation with the correlation ID' {
        Convert-NTAccountToSID -NTAccount ([System.Security.Principal.NTAccount]'BUILTIN\Administrators') -CorrelationId 'nt-1' |
            Should -Be 'S-1-5-32-544'

        Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
            $Message -eq "Successfully translated NTAccount 'BUILTIN\Administrators' to SID: S-1-5-32-544" -and $CorrelationId -eq 'nt-1'
        }
    }
}
