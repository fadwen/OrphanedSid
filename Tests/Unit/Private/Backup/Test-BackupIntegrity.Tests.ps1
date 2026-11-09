#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
#Requires -Version 5.1

<#
.SYNOPSIS
    Unit tests for Test-BackupIntegrity, the check every restore runs before applying a backup.

.DESCRIPTION
    Test-BackupValidation.Tests.ps1 covers the sibling functions in the same file; this one covers
    Test-BackupIntegrity itself at each validation level. Nothing is mocked: the function works on the
    backup object alone.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\..\Private\Backup\Test-BackupValidation.ps1"

    function Get-Sha256Base64 {
        param([string]$Text)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { [Convert]::ToBase64String($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))) }
        finally { $sha.Dispose() }
    }

    function New-Backup {
        param([hashtable]$Override = @{})
        $sddl = 'D:(A;;LCRPLORC;;;S-1-5-21-1-2-3-9001)(A;;GA;;;S-1-5-21-1-2-3-512)'
        $b = [ordered]@{
            ObjectDN            = 'CN=Finance Share,OU=Groups,DC=contoso,DC=com'
            BackupDate          = (Get-Date).AddDays(-1).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
            SDDL                = $sddl
            SDDLHash            = Get-Sha256Base64 -Text $sddl
            ValidationSignature = 'PSSecurityBackup_v2.1'
        }
        foreach ($k in $Override.Keys) { $b[$k] = $Override[$k] }
        [PSCustomObject]$b
    }
}

Describe 'Test-BackupIntegrity' -Tag 'Unit', 'Backup', 'Private' {

    Context 'A sound backup' {
        It 'Is valid at every level: <Level>' -ForEach @(
            @{ Level = 'Basic' }
            @{ Level = 'Standard' }
            @{ Level = 'Comprehensive' }
        ) {
            $result = Test-BackupIntegrity -BackupData (New-Backup) -ValidationLevel $Level -CorrelationId 'bi-1'

            $result.PSTypeNames | Should -Contain 'BackupValidationResult'
            $result.IsValid | Should -BeTrue
            $result.ValidationLevel | Should -Be $Level
            $result.Issues | Should -BeNullOrEmpty
            $result.ErrorMessage | Should -BeNullOrEmpty
            $result.BackupInfo.ObjectDN | Should -Be 'CN=Finance Share,OU=Groups,DC=contoso,DC=com'
            $result.CorrelationId | Should -Be 'bi-1'
        }

        It 'Defaults to the Standard level' {
            (Test-BackupIntegrity -BackupData (New-Backup)).ValidationLevel | Should -Be 'Standard'
        }

        It 'Accepts the backup from the pipeline' {
            (New-Backup | Test-BackupIntegrity).IsValid | Should -BeTrue
        }

        It 'Accepts the two earlier signatures too' {
            foreach ($sig in 'PSSecurityBackup_v1.0', 'PSSecurityBackup_v2.0') {
                (Test-BackupIntegrity -BackupData (New-Backup -Override @{ ValidationSignature = $sig })).IsValid | Should -BeTrue
            }
        }
    }

    Context 'Structure checks, applied at every level' {
        It 'Reports each missing required property' {
            $partial = [PSCustomObject]@{ ObjectDN = 'CN=A,DC=contoso,DC=com'; SDDL = 'D:' }

            $result = Test-BackupIntegrity -BackupData $partial -ValidationLevel 'Basic'

            $result.IsValid | Should -BeFalse
            $result.Issues | Should -Contain 'Missing required property: BackupDate'
            $result.Issues | Should -Contain 'Missing required property: SDDLHash'
            $result.Issues | Should -Contain 'Missing required property: ValidationSignature'
            $result.ErrorMessage | Should -BeLike '*Missing required property: BackupDate;*'
        }

        It 'Rejects an unknown signature' {
            $result = Test-BackupIntegrity -BackupData (New-Backup -Override @{ ValidationSignature = 'SomethingElse_v9' })

            $result.IsValid | Should -BeFalse
            $result.Issues[0] | Should -BeLike 'Invalid backup signature: SomethingElse_v9. Expected:*v2.1*'
        }

        It 'Rejects a backup taken from a different object than the one being restored' {
            $result = Test-BackupIntegrity -BackupData (New-Backup) -ExpectedObjectDN 'CN=Other,DC=contoso,DC=com'

            $result.IsValid | Should -BeFalse
            $result.Issues[0] | Should -BeLike "ObjectDN mismatch: Expected 'CN=Other,DC=contoso,DC=com', found 'CN=Finance Share*"
        }

        It 'Accepts a matching expected object' {
            (Test-BackupIntegrity -BackupData (New-Backup) -ExpectedObjectDN 'CN=Finance Share,OU=Groups,DC=contoso,DC=com').IsValid | Should -BeTrue
        }
    }

    Context 'Integrity checks, from Standard up' {
        It 'Does not check the hash at the Basic level' {
            (Test-BackupIntegrity -BackupData (New-Backup -Override @{ SDDLHash = 'tampered' }) -ValidationLevel 'Basic').IsValid | Should -BeTrue
        }

        It 'Rejects a hash that does not match the SDDL' {
            $result = Test-BackupIntegrity -BackupData (New-Backup -Override @{ SDDLHash = 'tampered' })

            $result.IsValid | Should -BeFalse
            $result.Issues[0] | Should -BeLike 'SDDL integrity check failed: Hash mismatch (expected: tampered, calculated: *'
        }

        It 'Rejects an SDDL that does not parse' {
            $bad = 'this is not sddl'
            $result = Test-BackupIntegrity -BackupData (New-Backup -Override @{ SDDL = $bad; SDDLHash = (Get-Sha256Base64 -Text $bad) })

            $result.IsValid | Should -BeFalse
            $result.Issues[0] | Should -BeLike 'Invalid SDDL format:*'
        }
    }

    Context 'Comprehensive checks' {
        It 'Flags a backup dated in the future' {
            $result = Test-BackupIntegrity -BackupData (New-Backup -Override @{ BackupDate = (Get-Date).AddDays(2).ToString('o') }) -ValidationLevel 'Comprehensive'

            $result.IsValid | Should -BeFalse
            $result.Issues[0] | Should -BeLike 'Backup date is in the future:*'
        }

        It 'Flags a backup older than a year' {
            $result = Test-BackupIntegrity -BackupData (New-Backup -Override @{ BackupDate = (Get-Date).AddDays(-400).ToString('o') }) -ValidationLevel 'Comprehensive'

            $result.IsValid | Should -BeFalse
            $result.Issues[0] | Should -BeLike 'Backup is older than 1 year:*'
        }

        It 'Flags a date that does not parse' {
            $result = Test-BackupIntegrity -BackupData (New-Backup -Override @{ BackupDate = 'yesterday-ish' }) -ValidationLevel 'Comprehensive'

            $result.IsValid | Should -BeFalse
            $result.Issues[0] | Should -Be 'Invalid backup date format: yesterday-ish'
        }

        It 'Flags an object DN that is not a distinguished name' {
            $result = Test-BackupIntegrity -BackupData (New-Backup -Override @{ ObjectDN = 'just-a-name' }) -ValidationLevel 'Comprehensive'

            $result.IsValid | Should -BeFalse
            $result.Issues | Should -Contain 'Invalid ObjectDN format: just-a-name'
        }

        It 'Flags permissions granted to Everyone or Anonymous' {
            $sddl = 'D:(A;;GA;;;S-1-1-0)(A;;GA;;;S-1-5-7)'
            $result = Test-BackupIntegrity -BackupData (New-Backup -Override @{ SDDL = $sddl; SDDLHash = (Get-Sha256Base64 -Text $sddl) }) -ValidationLevel 'Comprehensive'

            $result.IsValid | Should -BeFalse
            $result.Issues | Should -Contain 'Security warning: SDDL contains potentially risky permission: S-1-1-0'
            $result.Issues | Should -Contain 'Security warning: SDDL contains potentially risky permission: S-1-5-7'
        }

        It 'Does not run the comprehensive checks at the Standard level' {
            (Test-BackupIntegrity -BackupData (New-Backup -Override @{ BackupDate = 'yesterday-ish' })).IsValid | Should -BeTrue
        }
    }
}
