#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
#Requires -Version 5.1

<#
.SYNOPSIS
    Unit tests for the helpers in Restore-ACLOperation.ps1 that Set-ObjectACL delegates to.

.DESCRIPTION
    Restore-ACLOperation.Tests.ps1 mocks Get-RestorationTarget, Confirm-RestorationSuccess and
    ConvertFrom-BackupToACL to test Set-ObjectACL in isolation, so their bodies were never run. These
    tests run them with only Get-ADObject and Get-Acl mocked.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\TestHelpers\ADCmdletStubs.ps1"
    . "$PSScriptRoot\..\..\..\..\Private\Backup\Restore-ACLOperation.ps1"

    $script:dn = 'CN=Finance Share,OU=Groups,DC=contoso,DC=com'
    # Two ACEs. Owner and group are BA, not DA: a domain-relative alias needs a domain to translate,
    # and the restore verification compares ACE substrings of SDDL text
    $script:sddl = 'O:BAG:BAD:(A;;LCRPLORC;;;S-1-5-21-1-2-3-9001)(A;;GA;;;S-1-5-21-1-2-3-512)'

    function New-AclDouble {
        param([string]$Sddl)
        $acl = [PSCustomObject]@{ Sddl = $Sddl }
        $acl | Add-Member -MemberType ScriptMethod -Name GetSecurityDescriptorSddlForm -Value { param($Sections) $this.Sddl }
        return $acl
    }
}

Describe 'Get-RestorationTarget' -Tag 'Unit', 'Backup', 'Private' {

    BeforeEach {
        Mock Get-ADObject { [PSCustomObject]@{ DistinguishedName = $Identity; objectClass = @('top', 'group') } }
        Mock Get-Acl { New-AclDouble -Sddl $script:sddl }
    }

    It 'Reports a readable, existing object with its most specific class' {
        $result = Get-RestorationTarget -TargetObjectDN $script:dn -CorrelationId 'tgt-1'

        $result.PSTypeNames | Should -Contain 'TargetValidationResult'
        $result.IsValid | Should -BeTrue
        $result.ObjectExists | Should -BeTrue
        $result.ObjectType | Should -Be 'group'
        $result.ACLReadable | Should -BeTrue
        $result.Issues | Should -BeNullOrEmpty
        $result.CorrelationId | Should -Be 'tgt-1'
        Should -Invoke Get-ADObject -Times 1 -Exactly -ParameterFilter { $Identity -eq $script:dn }
        Should -Invoke Get-Acl -Times 1 -Exactly -ParameterFilter { $Path -eq "AD:$($script:dn)" }
    }

    It 'Accepts the distinguished name from the pipeline' {
        $result = $script:dn | Get-RestorationTarget

        $result.IsValid | Should -BeTrue
        $result.TargetObjectDN | Should -Be $script:dn
    }

    It 'Rejects a null or empty distinguished name' {
        { Get-RestorationTarget -TargetObjectDN $null } | Should -Throw "*parameter 'TargetObjectDN'*"
        { Get-RestorationTarget -TargetObjectDN '' } | Should -Throw "*parameter 'TargetObjectDN'*"
    }

    It 'Generates a correlation ID when none is given' {
        (Get-RestorationTarget -TargetObjectDN $script:dn).CorrelationId | Should -Match '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$'
    }

    It 'Rejects a name that is not a distinguished name' {
        $result = Get-RestorationTarget -TargetObjectDN 'just-a-name'

        $result.IsValid | Should -BeFalse
        $result.Issues | Should -Contain 'Invalid DN format: just-a-name'
    }

    It 'Rejects a distinguished name carrying an injection pattern: <Pattern>' -ForEach @(
        @{ Pattern = 'CN=../../etc,DC=contoso,DC=com' }
        @{ Pattern = 'CN=C:\Windows,DC=contoso,DC=com' }
        @{ Pattern = 'CN=<script>alert(1),DC=contoso,DC=com' }
        @{ Pattern = 'CN=x; DROP TABLE users,DC=contoso,DC=com' }
        @{ Pattern = 'CN=javascript:alert(1),DC=contoso,DC=com' }
    ) {
        $result = Get-RestorationTarget -TargetObjectDN $Pattern

        $result.IsValid | Should -BeFalse
        $result.Issues[0] | Should -BeLike 'Invalid DN format:*'
    }

    It 'Reports an object that does not exist' {
        Mock Get-ADObject { throw 'Cannot find an object with identity' }

        $result = Get-RestorationTarget -TargetObjectDN $script:dn

        $result.IsValid | Should -BeFalse
        $result.ObjectExists | Should -BeFalse
        $result.ACLReadable | Should -BeNullOrEmpty
        $result.Issues[0] | Should -BeLike 'Target object not found or inaccessible:*Cannot find an object*'
        Should -Invoke Get-Acl -Times 0 -Exactly
    }

    It 'Reports an object whose ACL cannot be read' {
        Mock Get-Acl { throw 'Access is denied' }

        $result = Get-RestorationTarget -TargetObjectDN $script:dn

        $result.IsValid | Should -BeFalse
        $result.ObjectExists | Should -BeTrue
        $result.ACLReadable | Should -BeFalse
        $result.Issues[0] | Should -BeLike 'Cannot read current ACL:*Access is denied*'
    }

    It 'Reports the class when the AD module returns ObjectClass as a single string' {
        Mock Get-ADObject { [PSCustomObject]@{ DistinguishedName = $Identity; ObjectClass = 'user' } }

        (Get-RestorationTarget -TargetObjectDN $script:dn).ObjectType | Should -Be 'user'
    }

    It 'Validates an existing, readable object without probing write access' {
        # No domain controller is reachable here; only the two mocked cmdlets are consulted
        $result = Get-RestorationTarget -TargetObjectDN $script:dn

        $result.IsValid | Should -BeTrue
        $result.PSObject.Properties.Name | Should -Not -Contain 'WritePermissions'
        (Get-Command Get-RestorationTarget).Parameters.Keys | Should -Not -Contain 'CheckPermissions'
    }
}
Describe 'Confirm-RestorationSuccess' -Tag 'Unit', 'Backup', 'Private' {

    BeforeEach {
        Mock Get-Acl { New-AclDouble -Sddl $script:sddl }
        $script:expected = [PSCustomObject]@{ ObjectDN = $script:dn; SDDL = $script:sddl }
    }

    It 'Verifies when every expected entry is present' {
        $result = Confirm-RestorationSuccess -TargetObjectDN $script:dn -ExpectedData $script:expected -CorrelationId 'ver-1'

        $result.PSTypeNames | Should -Contain 'RestorationVerificationResult'
        $result.IsVerified | Should -BeTrue
        $result.ExpectedEntries | Should -Be 2
        $result.ActualEntries | Should -Be 2
        $result.MatchedEntries | Should -Be 2
        $result.MatchPercentage | Should -Be 100
        $result.ToleranceLevel | Should -Be 'Standard'
        $result.VerificationIssues | Should -BeNullOrEmpty
        $result.CorrelationId | Should -Be 'ver-1'
        Should -Invoke Get-Acl -Times 1 -Exactly -ParameterFilter { $Path -eq "AD:$($script:dn)" }
    }

    It 'Passes at Standard tolerance when four of five entries match, and fails at Strict' {
        $five = 'D:(A;;GA;;;S-1-5-21-1-2-3-1)(A;;GA;;;S-1-5-21-1-2-3-2)(A;;GA;;;S-1-5-21-1-2-3-3)(A;;GA;;;S-1-5-21-1-2-3-4)(A;;GA;;;S-1-5-21-1-2-3-5)'
        $four = 'D:(A;;GA;;;S-1-5-21-1-2-3-1)(A;;GA;;;S-1-5-21-1-2-3-2)(A;;GA;;;S-1-5-21-1-2-3-3)(A;;GA;;;S-1-5-21-1-2-3-4)'
        Mock Get-Acl { New-AclDouble -Sddl $four }
        $expected = [PSCustomObject]@{ ObjectDN = $script:dn; SDDL = $five }

        $standard = Confirm-RestorationSuccess -TargetObjectDN $script:dn -ExpectedData $expected
        $strict = Confirm-RestorationSuccess -TargetObjectDN $script:dn -ExpectedData $expected -ToleranceLevel 'Strict'

        $standard.IsVerified | Should -BeTrue
        $standard.MatchPercentage | Should -Be 80
        $strict.IsVerified | Should -BeFalse
        $strict.VerificationIssues | Should -Contain 'Verification failed with Strict tolerance'
        $strict.VerificationIssues | Should -Contain 'Expected 5 entries, found 4, matched 4'
    }

    It 'Passes at Permissive tolerance when only two of three entries match' {
        $three = 'D:(A;;GA;;;S-1-5-21-1-2-3-1)(A;;GA;;;S-1-5-21-1-2-3-2)(A;;GA;;;S-1-5-21-1-2-3-3)'
        $two = 'D:(A;;GA;;;S-1-5-21-1-2-3-1)(A;;GA;;;S-1-5-21-1-2-3-2)'
        Mock Get-Acl { New-AclDouble -Sddl $two }
        $expected = [PSCustomObject]@{ ObjectDN = $script:dn; SDDL = $three }

        (Confirm-RestorationSuccess -TargetObjectDN $script:dn -ExpectedData $expected -ToleranceLevel 'Permissive').IsVerified | Should -BeTrue
        (Confirm-RestorationSuccess -TargetObjectDN $script:dn -ExpectedData $expected).IsVerified | Should -BeFalse
    }

    It 'Notes a large entry count difference' {
        Mock Get-Acl { New-AclDouble -Sddl 'D:' }
        $expected = [PSCustomObject]@{ ObjectDN = $script:dn; SDDL = 'D:(A;;GA;;;S-1-5-21-1-2-3-1)(A;;GA;;;S-1-5-21-1-2-3-2)(A;;GA;;;S-1-5-21-1-2-3-3)(A;;GA;;;S-1-5-21-1-2-3-4)' }

        $result = Confirm-RestorationSuccess -TargetObjectDN $script:dn -ExpectedData $expected

        $result.IsVerified | Should -BeFalse
        $result.VerificationIssues | Should -Contain 'Significant entry count difference detected'
    }

    It 'Verifies an empty expected ACL only against an empty current one' {
        $expected = [PSCustomObject]@{ ObjectDN = $script:dn; SDDL = 'D:' }

        (Confirm-RestorationSuccess -TargetObjectDN $script:dn -ExpectedData $expected).IsVerified | Should -BeFalse
        Mock Get-Acl { New-AclDouble -Sddl 'D:' }
        (Confirm-RestorationSuccess -TargetObjectDN $script:dn -ExpectedData $expected).IsVerified | Should -BeTrue
    }

    It 'Rejects a missing target, missing expected data or an unknown tolerance' {
        { Confirm-RestorationSuccess -TargetObjectDN '' -ExpectedData $script:expected } | Should -Throw "*parameter 'TargetObjectDN'*"
        { Confirm-RestorationSuccess -TargetObjectDN $script:dn -ExpectedData $null } | Should -Throw "*parameter 'ExpectedData'*"
        { Confirm-RestorationSuccess -TargetObjectDN $script:dn -ExpectedData $script:expected -ToleranceLevel 'Loose' } | Should -Throw "*parameter 'ToleranceLevel'*"
    }

    It 'Reports a current ACL that cannot be read' {
        Mock Get-Acl { throw 'The server is not operational' }

        $result = Confirm-RestorationSuccess -TargetObjectDN $script:dn -ExpectedData $script:expected

        $result.IsVerified | Should -BeFalse
        $result.VerificationIssues[0] | Should -BeLike 'Failed to read current ACL:*not operational*'
        $result.ExpectedEntries | Should -Be 0
    }
}

Describe 'ConvertFrom-BackupToACL' -Tag 'Unit', 'Backup', 'Private' {

    It 'Builds a security descriptor from the backup SDDL and counts its entries' {
        $result = ConvertFrom-BackupToACL -BackupData ([PSCustomObject]@{ SDDL = $script:sddl }) -CorrelationId 'cv-1'

        $result.PSTypeNames | Should -Contain 'ACLConversionResult'
        $result.Success | Should -BeTrue
        $result.SecurityDescriptor | Should -BeOfType [System.DirectoryServices.ActiveDirectorySecurity]
        $result.SecurityDescriptor.GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]::All) | Should -BeLike '*S-1-5-21-1-2-3-9001*'
        $result.ACECount | Should -Be 2
        $result.SDDLLength | Should -Be $script:sddl.Length
        $result.SourceSDDL | Should -Be $script:sddl
        $result.CorrelationId | Should -Be 'cv-1'
    }

    It 'Accepts the backup data from the pipeline' {
        ([PSCustomObject]@{ SDDL = $script:sddl } | ConvertFrom-BackupToACL).Success | Should -BeTrue
    }

    It 'Rejects null backup data' {
        { ConvertFrom-BackupToACL -BackupData $null } | Should -Throw "*parameter 'BackupData'*"
    }

    It 'Fails without throwing when the backup has no SDDL' {
        $result = ConvertFrom-BackupToACL -BackupData ([PSCustomObject]@{ ObjectDN = $script:dn })

        $result.Success | Should -BeFalse
        $result.SecurityDescriptor | Should -BeNullOrEmpty
        $result.ErrorMessage | Should -Be 'BackupData object does not contain SDDL property'
    }

    It 'Fails without throwing when the SDDL does not parse' {
        $result = ConvertFrom-BackupToACL -BackupData ([PSCustomObject]@{ SDDL = 'this is not sddl' })

        $result.Success | Should -BeFalse
        $result.ErrorMessage | Should -BeLike 'SDDL conversion failed:*'
        $result.SourceSDDL | Should -Be 'this is not sddl'
        $result.SDDLLength | Should -Be 16
    }
}
