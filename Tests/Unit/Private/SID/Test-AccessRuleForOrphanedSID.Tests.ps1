#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
#Requires -Version 5.1

<#
.SYNOPSIS
    Unit tests for Test-AccessRuleForOrphanedSID and the identity resolution helpers in
    Resolve-SIDIdentity.ps1.

.DESCRIPTION
    Resolve-SIDIdentity.Tests.ps1 checks that the functions exist and accept their parameters; these
    tests run them. Test-SIDFormat, Test-WellKnownSID, Test-OrphanedSID, Get-SIDAnalysis and
    New-OrphanedSIDResult are mocked, so the identity resolution logic is what is under test.
    NTAccount translation uses BUILTIN accounts, which resolve on any Windows machine.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\..\Classes\OrphanedSIDResult.ps1"
    . "$PSScriptRoot\..\..\..\..\Private\SID\Resolve-SIDIdentity.ps1"

    function Write-StructuredLog { param($Message, $Level, $Component, $CorrelationId, $LogPath, $Data) }
    function Test-SIDFormat { param($SID) }
    function Test-WellKnownSID { param($SID) }
    function Test-OrphanedSID { param($SID, $CorrelationId) }
    function Get-SIDAnalysis { param($SIDString, $CurrentDomainSID) }
    function New-OrphanedSIDResult { param($ObjectDN, $ObjectClass, $OrphanedSID, $AccessRule, $LikelySource, $Confidence, $Notes, $ProcessingMethod, $VerificationStatus, $VerificationError, $CorrelationId) }

    $script:dn = 'CN=Finance Share,OU=Groups,DC=contoso,DC=com'
    $script:orphanSid = 'S-1-5-21-111-222-333-9001'
    $script:domainSid = 'S-1-5-21-111-222-333'
}

Describe 'Resolve-IdentityReference' -Tag 'Unit', 'SID', 'Private' {

    BeforeEach {
        Mock Write-StructuredLog { }
        Mock Test-SIDFormat { $SID -match '^S-1-\d+(-\d+)+$' }
    }

    It 'Returns the value of a SecurityIdentifier' {
        $sid = [System.Security.Principal.SecurityIdentifier]$script:orphanSid

        Resolve-IdentityReference -IdentityReference $sid -ObjectDN $script:dn | Should -Be $script:orphanSid
    }

    It 'Translates an NTAccount that exists' {
        $account = [System.Security.Principal.NTAccount]'BUILTIN\Administrators'

        Resolve-IdentityReference -IdentityReference $account -ObjectDN $script:dn | Should -Be 'S-1-5-32-544'
    }

    It 'Marks an NTAccount that cannot be translated as an orphaned account' {
        $account = [System.Security.Principal.NTAccount]'NOSUCHDOMAIN\nosuchuser'

        $result = Resolve-IdentityReference -IdentityReference $account -ObjectDN $script:dn -CorrelationId 'res-1'

        $result | Should -Be 'ORPHANED_ACCOUNT:NOSUCHDOMAIN\nosuchuser'
        Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Level -eq 'Information' -and $Message -like 'ORPHANED ACCOUNT DETECTED:*nosuchuser*' -and $CorrelationId -eq 'res-1' }
    }

    It 'Reads the Value property of a deserialized identity reference' {
        $deserialized = [PSCustomObject]@{ Value = $script:orphanSid }

        Resolve-IdentityReference -IdentityReference $deserialized -ObjectDN $script:dn | Should -Be $script:orphanSid
    }

    It 'Returns nothing for a deserialized reference whose value is not a SID' {
        $deserialized = [PSCustomObject]@{ Value = 'CONTOSO\someone' }

        Resolve-IdentityReference -IdentityReference $deserialized -ObjectDN $script:dn | Should -BeNullOrEmpty
        Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Message -like 'Extracted string is not a valid SID format: CONTOSO\someone*' }
    }

    It 'Accepts a plain SID string' {
        Resolve-IdentityReference -IdentityReference $script:orphanSid -ObjectDN $script:dn | Should -Be $script:orphanSid
    }

    It 'Returns nothing for a reference with an empty value' {
        Resolve-IdentityReference -IdentityReference ([PSCustomObject]@{ Value = '' }) -ObjectDN $script:dn | Should -BeNullOrEmpty
    }

    It 'Warns and returns nothing when the format check itself throws' {
        Mock Test-SIDFormat { throw 'format checker broken' }

        Resolve-IdentityReference -IdentityReference $script:orphanSid -ObjectDN $script:dn | Should -BeNullOrEmpty
        Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Level -eq 'Warning' -and $Message -like '*format checker broken*' }
    }
}

Describe 'Convert-NTAccountToSID' -Tag 'Unit', 'SID', 'Private' {

    BeforeEach { Mock Write-StructuredLog { } }

    It 'Translates a well-known account' {
        Convert-NTAccountToSID -NTAccount ([System.Security.Principal.NTAccount]'NT AUTHORITY\SYSTEM') | Should -Be 'S-1-5-18'
    }

    It 'Returns the orphaned-account marker when translation fails' {
        Convert-NTAccountToSID -NTAccount ([System.Security.Principal.NTAccount]'NOSUCHDOMAIN\ghost') | Should -Be 'ORPHANED_ACCOUNT:NOSUCHDOMAIN\ghost'
    }
}

Describe 'Test-SIDValidityAndType' -Tag 'Unit', 'SID', 'Private' {

    BeforeEach {
        Mock Write-StructuredLog { }
        Mock Test-SIDFormat { $SID -match '^S-1-\d+(-\d+)+$' }
        Mock Test-WellKnownSID { $SID -eq 'S-1-5-18' }
    }

    It 'Accepts a well-formed SID that is not well known' {
        Test-SIDValidityAndType -SIDString $script:orphanSid | Should -BeTrue
    }

    It 'Rejects a malformed SID' {
        Test-SIDValidityAndType -SIDString 'not-a-sid' | Should -BeFalse
        Should -Invoke Test-WellKnownSID -Times 0 -Exactly
    }

    It 'Rejects a well-known SID' {
        Test-SIDValidityAndType -SIDString 'S-1-5-18' | Should -BeFalse
        Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Message -eq 'Skipping well-known SID: S-1-5-18' }
    }

    It 'Rejects, with a warning, when a check throws' {
        Mock Test-WellKnownSID { throw 'list unavailable' }

        Test-SIDValidityAndType -SIDString $script:orphanSid | Should -BeFalse
        Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Level -eq 'Warning' -and $Message -like '*list unavailable*' }
    }
}

Describe 'Get-StringFromIdentityReference' -Tag 'Unit', 'SID', 'Private' {

    BeforeEach { Mock Write-StructuredLog { } }

    It 'Prefers the Value property' {
        Get-StringFromIdentityReference -IdentityReference ([PSCustomObject]@{ Value = 'from-value' }) | Should -Be 'from-value'
    }

    It 'Falls back to ToString when there is no Value property' {
        Get-StringFromIdentityReference -IdentityReference 'plain-string' | Should -Be 'plain-string'
    }
}

Describe 'Test-AccessRuleForOrphanedSID' -Tag 'Unit', 'SID', 'Private' {

    BeforeEach {
        Mock Write-StructuredLog { }
        Mock Test-SIDFormat { $SID -match '^S-1-\d+(-\d+)+$' }
        Mock Test-WellKnownSID { $SID -eq 'S-1-5-18' }
        Mock Test-OrphanedSID {
            $status = if ($SID -eq $script:orphanSid) { 'Orphaned' } else { 'Exists' }
            [PSCustomObject]@{ PSTypeName = 'SIDLookupResult'; SID = $SID; Status = $status; IsOrphaned = ($status -eq 'Orphaned'); ErrorMessage = $null }
        }
        Mock Get-SIDAnalysis { [PSCustomObject]@{ LikelySource = 'Deleted Account'; Confidence = 'High'; Notes = 'same domain' } }
        Mock New-OrphanedSIDResult {
            $r = [OrphanedSIDResult]::new(); $r.ObjectDN = $ObjectDN; $r.OrphanedSID = $OrphanedSID; $r.LikelySource = $LikelySource; $r.Confidence = $Confidence
            if ($VerificationStatus) { $r.VerificationStatus = $VerificationStatus }
            $r.VerificationError = $VerificationError
            $r
        }
        $script:orphanRule = [PSCustomObject]@{ IdentityReference = [System.Security.Principal.SecurityIdentifier]$script:orphanSid; ActiveDirectoryRights = 'GenericRead' }
        $script:validRule = [PSCustomObject]@{ IdentityReference = [System.Security.Principal.SecurityIdentifier]'S-1-5-21-111-222-333-1105' }
    }

    It 'Builds a result for an orphaned SID with the analysis attached' {
        $result = Test-AccessRuleForOrphanedSID -AccessRule $script:orphanRule -ObjectDN $script:dn -ObjectClass 'group' -CurrentDomainSID $script:domainSid -CorrelationId 'rule-1'

        $result | Should -BeOfType [OrphanedSIDResult]
        $result.OrphanedSID | Should -Be $script:orphanSid
        $result.LikelySource | Should -Be 'Deleted Account'
        $result.Confidence | Should -Be 'High'
        Should -Invoke Get-SIDAnalysis -Times 1 -Exactly -ParameterFilter { $SIDString -eq $script:orphanSid -and $CurrentDomainSID -eq $script:domainSid }
        Should -Invoke New-OrphanedSIDResult -Times 1 -Exactly -ParameterFilter {
            $ObjectDN -eq $script:dn -and $ObjectClass -eq 'group' -and $AccessRule -eq $script:orphanRule -and
            $Notes -eq 'same domain' -and $ProcessingMethod -eq 'Identity-Resolution' -and $CorrelationId -eq 'rule-1'
        }
    }

    It 'Marks an orphaned result as verified' {
        $result = Test-AccessRuleForOrphanedSID -AccessRule $script:orphanRule -ObjectDN $script:dn

        $result.VerificationStatus | Should -Be 'Orphaned'
    }

    It 'Builds an Unverified result, without analysis, when the lookup failed' {
        Mock Test-OrphanedSID {
            [PSCustomObject]@{ PSTypeName = 'SIDLookupResult'; SID = $SID; Status = 'Unverified'; IsOrphaned = $false; ErrorMessage = 'Get-ADObject: The server is not operational' }
        }

        $result = Test-AccessRuleForOrphanedSID -AccessRule $script:orphanRule -ObjectDN $script:dn -CorrelationId 'rule-2'

        $result | Should -BeOfType [OrphanedSIDResult]
        $result.OrphanedSID | Should -Be $script:orphanSid
        $result.VerificationStatus | Should -Be 'Unverified'
        $result.VerificationError | Should -Be 'Get-ADObject: The server is not operational'
        $result.Confidence | Should -Be 'Low'
        Should -Invoke Get-SIDAnalysis -Times 0 -Exactly
        Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Level -eq 'Warning' -and $Message -like "UNVERIFIED SID: $($script:orphanSid)*not operational*" -and $CorrelationId -eq 'rule-2' }
    }

    It 'Passes its correlation ID to the orphan check' {
        $null = Test-AccessRuleForOrphanedSID -AccessRule $script:orphanRule -ObjectDN $script:dn -CorrelationId 'rule-3'

        Should -Invoke Test-OrphanedSID -Times 1 -Exactly -ParameterFilter { $CorrelationId -eq 'rule-3' }
    }

    It 'Returns nothing for a SID that still resolves' {
        Test-AccessRuleForOrphanedSID -AccessRule $script:validRule -ObjectDN $script:dn | Should -BeNullOrEmpty
        Should -Invoke New-OrphanedSIDResult -Times 0 -Exactly
    }

    It 'Returns nothing for a well-known SID without asking the directory' {
        $rule = [PSCustomObject]@{ IdentityReference = [System.Security.Principal.SecurityIdentifier]'S-1-5-18' }

        Test-AccessRuleForOrphanedSID -AccessRule $rule -ObjectDN $script:dn | Should -BeNullOrEmpty
        Should -Invoke Test-OrphanedSID -Times 0 -Exactly
    }

    It 'Returns nothing for a rule without an identity reference' {
        Test-AccessRuleForOrphanedSID -AccessRule ([PSCustomObject]@{ ActiveDirectoryRights = 'GenericRead' }) -ObjectDN $script:dn | Should -BeNullOrEmpty
        Should -Invoke Test-OrphanedSID -Times 0 -Exactly
    }

    It 'Returns nothing for a rule whose identity cannot be resolved to a SID' {
        $rule = [PSCustomObject]@{ IdentityReference = [PSCustomObject]@{ Value = 'CONTOSO\someone' } }

        Test-AccessRuleForOrphanedSID -AccessRule $rule -ObjectDN $script:dn | Should -BeNullOrEmpty
        Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Message -like 'Failed to resolve identity reference*' }
    }

    It 'Warns and returns nothing when the orphan check throws' {
        Mock Test-OrphanedSID { throw 'directory unreachable' }

        Test-AccessRuleForOrphanedSID -AccessRule $script:orphanRule -ObjectDN $script:dn | Should -BeNullOrEmpty
        Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Level -eq 'Warning' -and $Message -like "*$($script:dn)*directory unreachable*" }
    }
}
