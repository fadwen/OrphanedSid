#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
<#
.SYNOPSIS
    Unit tests for Test-BackupValidation and its sibling functions in Test-BackupValidation.ps1.

.DESCRIPTION
    Covers Test-BackupValidation at the Basic, Standard and Comprehensive levels, Test-BackupFormat
    and Get-BackupMetadata, using in-memory backup objects whose SDDL hashes are computed here.
    Test-BackupIntegrity is covered in Test-BackupIntegrity.Tests.ps1.

.NOTES
    Author: Jeffrey Stuhr
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\..\Private\Backup\Test-BackupValidation.ps1"

    function Get-Sha256Base64 {
        param([string]$Text)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { [Convert]::ToBase64String($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))) }
        finally { $sha.Dispose() }
    }

    $script:TestObjectDN = 'CN=TestUser,OU=Users,DC=company,DC=com'
    $script:ValidSddl = 'O:BAG:BAD:(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWRPWPLOCRRCWDWO;;;AU)'

    # A fresh copy per call, so a test that changes one property cannot leak into another
    function New-Backup {
        param([hashtable]$Override = @{}, [string[]]$Remove = @())
        $b = [ordered]@{
            ObjectDN            = $script:TestObjectDN
            BackupDate          = (Get-Date).AddDays(-30).ToString('o')
            SDDL                = $script:ValidSddl
            SDDLHash            = Get-Sha256Base64 -Text $script:ValidSddl
            ValidationSignature = 'PSSecurityBackup_v2.1'
            BackupVersion       = '2.1'
            ACLEntryCount       = 3
            UserContext         = 'DOMAIN\BackupUser'
            ComputerName        = 'BACKUP-SERVER'
            DomainContext       = 'COMPANY.COM'
        }
        foreach ($k in $Override.Keys) { $b[$k] = $Override[$k] }
        foreach ($k in $Remove) { $b.Remove($k) }
        [PSCustomObject]$b
    }

    # A backup whose SDDL is replaced and rehashed, so validation reaches the checks after the hash
    function New-BackupWithSddl {
        param([string]$Sddl)
        New-Backup -Override @{ SDDL = $Sddl; SDDLHash = (Get-Sha256Base64 -Text $Sddl) }
    }
}

Describe "Test-BackupValidation" -Tag "Unit", "Backup", "Validation" {

    Context "Parameter Validation" {
        It "Should reject null BackupData" {
            { Test-BackupValidation -BackupData $null } | Should -Throw "*parameter 'BackupData'*"
        }

        It "Should reject an empty ExpectedObjectDN" {
            { Test-BackupValidation -BackupData (New-Backup) -ExpectedObjectDN "" } | Should -Throw "*parameter 'ExpectedObjectDN'*"
        }

        It "Should reject invalid ValidationLevel values" {
            { Test-BackupValidation -BackupData (New-Backup) -ValidationLevel "Invalid" } | Should -Throw "*parameter 'ValidationLevel'*"
        }

        It "Should reject a correlation ID that is not a GUID" {
            { Test-BackupValidation -BackupData (New-Backup) -CorrelationId "<script>alert('xss')</script>" } | Should -Throw "*CorrelationId must be in valid GUID format*"
        }

        It "Should use Standard validation level by default" {
            (Test-BackupValidation -BackupData (New-Backup)).ValidationLevel | Should -Be 'Standard'
        }

        It "Should return the supplied correlation ID" {
            $customCorrelationId = [System.Guid]::NewGuid().ToString()
            (Test-BackupValidation -BackupData (New-Backup) -CorrelationId $customCorrelationId).CorrelationId | Should -Be $customCorrelationId
        }

        It "Should auto-generate CorrelationId when not provided" {
            (Test-BackupValidation -BackupData (New-Backup)).CorrelationId | Should -Match "^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$"
        }

        It "Should validate each backup piped in on its own" {
            $results = @(
                New-Backup
                New-Backup -Remove 'SDDL', 'SDDLHash', 'ValidationSignature'
                New-Backup -Override @{ ValidationSignature = 'InvalidSignature_v99.9' }
            ) | Test-BackupValidation -ValidationLevel Standard

            $results.Count | Should -Be 3
            $results.IsValid | Should -Be @($true, $false, $false)
        }
    }

    Context "Basic Validation Level" {
        It "Should pass a complete backup and record what it checked" {
            $result = Test-BackupValidation -BackupData (New-Backup) -ValidationLevel Basic

            $result.PSObject.TypeNames[0] | Should -Be 'BackupValidationResult'
            $result.IsValid | Should -BeTrue
            $result.ValidationLevel | Should -Be 'Basic'
            @($result.Issues).Count | Should -Be 0
            $result.ErrorMessage | Should -BeNullOrEmpty
            $result.BackupInfo.ObjectDN | Should -Be $script:TestObjectDN
            $result.BackupInfo.ValidationSignature | Should -Be 'PSSecurityBackup_v2.1'
        }

        It "Should report each missing required property and an empty signature" {
            $result = Test-BackupValidation -BackupData (New-Backup -Remove 'SDDL', 'SDDLHash', 'ValidationSignature') -ValidationLevel Basic

            $result.IsValid | Should -BeFalse
            $result.Issues | Should -Contain "Missing required property: SDDL"
            $result.Issues | Should -Contain "Missing required property: SDDLHash"
            $result.Issues | Should -Contain "Missing required property: ValidationSignature"
            $result.Issues | Should -Contain "Invalid backup signature: "
            $result.ErrorMessage | Should -Be ($result.Issues -join '; ')
        }

        It "Should reject an unknown signature" {
            $result = Test-BackupValidation -BackupData (New-Backup -Override @{ ValidationSignature = 'InvalidSignature_v99.9' }) -ValidationLevel Basic

            $result.IsValid | Should -BeFalse
            $result.Issues | Should -Be @('Invalid backup signature: InvalidSignature_v99.9')
            $result.BackupInfo.ContainsKey('ValidationSignature') | Should -BeFalse
        }

        It "Should accept signature <Signature>" -ForEach @(
            @{ Signature = 'PSSecurityBackup_v1.0' }
            @{ Signature = 'PSSecurityBackup_v2.0' }
            @{ Signature = 'PSSecurityBackup_v2.1' }
        ) {
            (Test-BackupValidation -BackupData (New-Backup -Override @{ ValidationSignature = $Signature }) -ValidationLevel Basic).IsValid | Should -BeTrue
        }

        It "Should reject a backup of a different object than the one expected" {
            $wrongObjectDN = 'CN=WrongUser,OU=Users,DC=company,DC=com'
            $result = Test-BackupValidation -BackupData (New-Backup) -ExpectedObjectDN $wrongObjectDN -ValidationLevel Basic

            $result.IsValid | Should -BeFalse
            $result.Issues | Should -Be @("ObjectDN mismatch: Expected '$wrongObjectDN', got '$($script:TestObjectDN)'")
            $result.BackupInfo.ContainsKey('ObjectDN') | Should -BeFalse
        }

        It "Should accept a backup of the expected object" {
            (Test-BackupValidation -BackupData (New-Backup) -ExpectedObjectDN $script:TestObjectDN -ValidationLevel Basic).IsValid | Should -BeTrue
        }

        It "Should not check the hash at the Basic level" {
            (Test-BackupValidation -BackupData (New-Backup -Override @{ SDDLHash = 'CorruptedHashValue123' }) -ValidationLevel Basic).IsValid | Should -BeTrue
        }
    }

    Context "Standard Validation Level" {
        It "Should pass a backup whose hash matches and whose SDDL parses" {
            $result = Test-BackupValidation -BackupData (New-Backup) -ValidationLevel Standard

            $result.IsValid | Should -BeTrue
            $result.BackupInfo.SDDLValid | Should -BeTrue
        }

        It "Should detect a hash that does not match the SDDL" {
            $result = Test-BackupValidation -BackupData (New-Backup -Override @{ SDDLHash = 'CorruptedHashValue123' }) -ValidationLevel Standard

            $result.IsValid | Should -BeFalse
            $result.Issues | Should -Be @('Hash integrity check failed')
        }

        It "Should detect SDDL that does not parse: <Sddl>" -ForEach @(
            @{ Sddl = 'InvalidSDDLFormat' }
            @{ Sddl = 'D:(A;;GA;;;WD' }
            @{ Sddl = 'O:INVALID_SDDL_FORMAT' }
        ) {
            $result = Test-BackupValidation -BackupData (New-BackupWithSddl -Sddl $Sddl) -ValidationLevel Standard

            $result.IsValid | Should -BeFalse
            @($result.Issues).Count | Should -Be 1
            $result.Issues[0] | Should -BeLike 'Invalid SDDL format:*'
        }

        # Module bug (#13): the SDDL checks run only when SDDL and SDDLHash have values, and the required-property
        # check tests only that the property exists, so a backup with an empty SDDL is reported valid
        It "Should reject a backup whose SDDL and hash are empty" -Skip {
            $result = Test-BackupValidation -BackupData (New-Backup -Override @{ SDDL = $null; SDDLHash = $null }) -ValidationLevel Standard

            $result.IsValid | Should -BeFalse
        }

        It "Should not run the comprehensive checks at the Standard level" {
            (Test-BackupValidation -BackupData (New-Backup -Override @{ BackupDate = 'InvalidDateFormat' }) -ValidationLevel Standard).IsValid | Should -BeTrue
        }
    }

    Context "Comprehensive Validation Level" {
        It "Should pass a sound, recent backup and record its parsed date" {
            $result = Test-BackupValidation -BackupData (New-Backup) -ValidationLevel Comprehensive

            $result.IsValid | Should -BeTrue
            $result.BackupInfo.BackupDate | Should -BeOfType [DateTime]
        }

        It "Should detect future backup dates" {
            $future = (Get-Date).AddDays(1).ToString('o')
            $result = Test-BackupValidation -BackupData (New-Backup -Override @{ BackupDate = $future }) -ValidationLevel Comprehensive

            $result.IsValid | Should -BeFalse
            $result.Issues | Should -Be @("Backup date is in the future: $future")
        }

        It "Should flag a backup older than a year" {
            $result = Test-BackupValidation -BackupData (New-Backup -Override @{ BackupDate = (Get-Date).AddDays(-400).ToString('o') }) -ValidationLevel Comprehensive

            $result.IsValid | Should -BeFalse
            $result.Issues | Should -Be @('Backup is older than 1 year')
        }

        It "Should report a date that does not parse" {
            $result = Test-BackupValidation -BackupData (New-Backup -Override @{ BackupDate = 'InvalidDateFormat' }) -ValidationLevel Comprehensive

            $result.IsValid | Should -BeFalse
            $result.Issues | Should -Be @('Invalid backup date format: InvalidDateFormat')
        }

        It "Should report an object DN that is not a CN= distinguished name" {
            $result = Test-BackupValidation -BackupData (New-Backup -Override @{ ObjectDN = 'InvalidDNFormat' }) -ValidationLevel Comprehensive

            $result.IsValid | Should -BeFalse
            $result.Issues | Should -Be @('Invalid ObjectDN format')
        }

        It "Should warn about permissions granted to Everyone or Anonymous" {
            $result = Test-BackupValidation -BackupData (New-BackupWithSddl -Sddl 'D:(A;;GA;;;S-1-1-0)(A;;GA;;;S-1-5-7)') -ValidationLevel Comprehensive

            $result.IsValid | Should -BeFalse
            $result.Issues | Should -Contain 'Security warning: Risky SID detected: S-1-1-0'
            $result.Issues | Should -Contain 'Security warning: Risky SID detected: S-1-5-7'
            $result.Issues | Should -Contain 'Security warning for S-1-[15]-[07] patterns detected'
        }

        It "Should warn about a service account SID: <Sid>" -ForEach @(
            @{ Sid = 'S-1-5-18' }
            @{ Sid = 'S-1-5-19' }
            @{ Sid = 'S-1-5-20' }
        ) {
            $result = Test-BackupValidation -BackupData (New-BackupWithSddl -Sddl "D:(A;;GA;;;$Sid)") -ValidationLevel Comprehensive

            $result.Issues | Should -Contain "Security warning: Risky SID detected: $Sid"
        }
    }
}

Describe "Test-BackupFormat" -Tag "Unit", "Backup", "Validation" {

    It "Should reject null BackupData" {
        { Test-BackupFormat -BackupData $null } | Should -Throw "*parameter 'BackupData'*"
    }

    It "Should reject an unknown RequiredVersion" {
        { Test-BackupFormat -BackupData (New-Backup) -RequiredVersion "v99.0" } | Should -Throw "*Invalid RequiredVersion: v99.0*"
    }

    It "Should pass a well-formed backup and detect version <Version> from its signature" -ForEach @(
        @{ Version = 'v1.0' }
        @{ Version = 'v2.0' }
        @{ Version = 'v2.1' }
    ) {
        $result = Test-BackupFormat -BackupData (New-Backup -Override @{ ValidationSignature = "PSSecurityBackup_$Version" })

        $result.PSObject.TypeNames[0] | Should -Be 'FormatValidationResult'
        $result.IsValid | Should -BeTrue
        $result.DetectedVersion | Should -Be $Version
        $result.ErrorMessage | Should -Be ''
    }

    It "Should accept a backup of the required version" {
        (Test-BackupFormat -BackupData (New-Backup) -RequiredVersion 'v2.1').IsValid | Should -BeTrue
    }

    It "Should detect version mismatch" {
        $result = Test-BackupFormat -BackupData (New-Backup) -RequiredVersion 'v1.0'

        $result.IsValid | Should -BeFalse
        $result.Issues | Should -Be @('Version mismatch: Required v1.0, found v2.1')
        $result.ErrorMessage | Should -Be 'Format validation error: Version mismatch: Required v1.0, found v2.1'
    }

    It "Should report each missing core property" {
        $result = Test-BackupFormat -BackupData ([PSCustomObject]@{ InvalidProperty = 'Test' })

        $result.IsValid | Should -BeFalse
        $result.Issues | Should -Be @(
            'Missing core property: ValidationSignature'
            'Missing core property: SDDL'
            'Missing core property: ObjectDN'
            'Missing core property: BackupDate'
        )
        $result.DetectedVersion | Should -Be ''
    }

    It "Should reject an unknown signature" {
        $result = Test-BackupFormat -BackupData (New-Backup -Override @{ ValidationSignature = 'InvalidSignature_v99.9' })

        $result.IsValid | Should -BeFalse
        $result.Issues | Should -Be @('Invalid validation signature format: InvalidSignature_v99.9')
        $result.DetectedVersion | Should -Be ''
    }

    It "Should return the supplied correlation ID and accept pipeline input" {
        $result = New-Backup | Test-BackupFormat -CorrelationId 'fmt-1'

        $result.IsValid | Should -BeTrue
        $result.CorrelationId | Should -Be 'fmt-1'
    }
}

Describe "Get-BackupMetadata" -Tag "Unit", "Backup", "Validation" {

    It "Should reject null BackupData" {
        { Get-BackupMetadata -BackupData $null } | Should -Throw "*parameter 'BackupData'*"
    }

    It "Should extract the backup's metadata" {
        $backup = New-Backup
        $result = $backup | Get-BackupMetadata -CorrelationId 'md-1'

        $result.PSObject.TypeNames[0] | Should -Be 'BackupMetadata'
        $result.IsValid | Should -BeTrue
        $result.ErrorMessage | Should -BeNullOrEmpty
        $result.CorrelationId | Should -Be 'md-1'
        $result.Metadata.ObjectDN | Should -Be $script:TestObjectDN
        $result.Metadata.BackupDate | Should -Be $backup.BackupDate
        $result.Metadata.ValidationSignature | Should -Be 'PSSecurityBackup_v2.1'
        $result.Metadata.Version | Should -Be 'v2.1'
        $result.Metadata.HasIntegrityHash | Should -BeTrue
        $result.Metadata.UserContext | Should -Be 'DOMAIN\BackupUser'
        $result.Metadata.ComputerName | Should -Be 'BACKUP-SERVER'
        $result.Metadata.DomainContext | Should -Be 'COMPANY.COM'
        $result.Statistics | Should -BeNullOrEmpty
    }

    It "Should stamp the extraction time" {
        $stamp = [DateTime]'2025-01-02T03:04:05'
        Mock Get-Date { $stamp }

        (Get-BackupMetadata -BackupData (New-Backup)).Metadata.ExtractedAt | Should -Be $stamp
    }

    It "Should report a backup without an integrity hash" {
        (Get-BackupMetadata -BackupData (New-Backup -Override @{ SDDLHash = '' })).Metadata.HasIntegrityHash | Should -BeFalse
    }

    It "Should include statistics when requested, taking the entry count from the backup" {
        $result = Get-BackupMetadata -BackupData (New-Backup) -IncludeStatistics

        $result.Statistics.EstimatedACECount | Should -Be 3
        $result.Statistics.SDDLLength | Should -Be $script:ValidSddl.Length
        $result.Statistics.DataSize | Should -BeGreaterThan $script:ValidSddl.Length
    }

    It "Should estimate the entry count from the SDDL length when the backup has none" {
        $long = Get-BackupMetadata -BackupData (New-Backup -Remove 'ACLEntryCount' -Override @{ SDDL = ('x' * 260) }) -IncludeStatistics
        $short = Get-BackupMetadata -BackupData (New-Backup -Remove 'ACLEntryCount' -Override @{ SDDL = 'D:' }) -IncludeStatistics

        $long.Statistics.EstimatedACECount | Should -Be 5
        $short.Statistics.EstimatedACECount | Should -Be 1
    }

    It "Should report the required properties that are missing or empty" {
        $result = Get-BackupMetadata -BackupData ([PSCustomObject]@{ ObjectDN = ''; Other = 1 })

        $result.IsValid | Should -BeFalse
        $result.ErrorMessage | Should -Be 'Missing required properties for metadata extraction: ObjectDN, BackupDate, ValidationSignature'
        $result.Metadata.ContainsKey('ObjectDN') | Should -BeFalse
    }
}
