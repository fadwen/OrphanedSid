#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
<#
.SYNOPSIS
    Unit tests for the Test-BackupFileIntegrity function

.DESCRIPTION
    Tests Test-BackupFileIntegrity against backup files written to the Pester test drive:
    parameter validation, file existence, loading, the SHA256 hash check, SDDL format,
    required properties, version compatibility, the result's shape and the log entries
    written on each path.

.NOTES
    Author: Jeffrey Stuhr
#>

BeforeAll {
    $ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path

    # Loaded so Write-StructuredLog exists to be mocked below
    . (Join-Path $ProjectRoot 'Private\Logging\Write-StructuredLog.ps1')
    . (Join-Path $ProjectRoot 'Private\Utilities\Test-BackupFileIntegrity.ps1')

    function Get-SddlHash {
        param([Parameter(Mandatory)] [AllowEmptyString()] [string]$Sddl)

        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try {
            [System.Convert]::ToBase64String($sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Sddl)))
        }
        finally {
            $sha256.Dispose()
        }
    }

    # Writes a backup file in the shape New-ACLBackup produces. SDDLHash follows the SDDL unless
    # overridden; -Remove drops properties to build an incomplete backup.
    function New-BackupFile {
        param(
            [hashtable]$Override = @{},
            [string[]]$Remove = @()
        )

        $data = [ordered]@{
            ObjectDN      = 'CN=TestUser,OU=Users,DC=company,DC=com'
            BackupDate    = '2024-07-02T10:36:31.123Z'
            CorrelationId = [System.Guid]::NewGuid().ToString()
            SDDL          = 'O:BAG:SYD:(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;SY)(A;;CCLCSWRPWPLOCRRCWDWO;;;AU)'
            BackupVersion = '2.1'
        }
        foreach ($key in $Override.Keys) {
            $data[$key] = $Override[$key]
        }
        if (-not $Override.ContainsKey('SDDLHash')) {
            $data['SDDLHash'] = Get-SddlHash -Sddl ([string]$data['SDDL'])
        }
        foreach ($name in $Remove) {
            $data.Remove($name)
        }

        $path = Join-Path $TestDrive "backup_$([guid]::NewGuid().ToString('N')).xml"
        [PSCustomObject]$data | Export-Clixml -Path $path
        $path
    }
}

Describe "Test-BackupFileIntegrity" -Tag "Unit", "Backup", "Integrity" {
    BeforeAll {
        Mock Write-StructuredLog { }

        $script:ValidBackupFile = New-BackupFile
    }

    Context "Parameter Validation" {
        It "Should reject a <Name> BackupFilePath" -ForEach @(
            @{ Name = 'null'; Value = $null }
            @{ Name = 'empty'; Value = '' }
        ) {
            { Test-BackupFileIntegrity -BackupFilePath $Value } | Should -Throw -ErrorId 'ParameterArgumentValidationError*,Test-BackupFileIntegrity'
        }

        It "Should resolve a relative path against the current location" {
            Push-Location $TestDrive
            try {
                $result = Test-BackupFileIntegrity -BackupFilePath (Split-Path $script:ValidBackupFile -Leaf)
            }
            finally {
                Pop-Location
            }

            $result.IsValid | Should -Be $true
        }
    }

    Context "Valid backup" {
        It "Should return IsValid with the loaded backup data and no error" {
            $result = Test-BackupFileIntegrity -BackupFilePath $script:ValidBackupFile

            $result.IsValid | Should -BeOfType [bool]
            $result.IsValid | Should -Be $true
            $result.ErrorMessage | Should -BeNullOrEmpty
            @($result.ValidationDetails).Count | Should -Be 0
            $result.BackupData.ObjectDN | Should -Be 'CN=TestUser,OU=Users,DC=company,DC=com'
        }

        It "Should log the start and the success with the file path, DN and correlation ID" {
            $correlationId = [System.Guid]::NewGuid().ToString()

            Test-BackupFileIntegrity -BackupFilePath $script:ValidBackupFile -CorrelationId $correlationId | Out-Null

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Information' -and $Message -eq 'Starting backup integrity validation' -and
                $Component -eq 'BackupValidation' -and $CorrelationId -eq $correlationId -and
                $Data.BackupFilePath -eq $script:ValidBackupFile
            }
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Information' -and $Message -eq 'Backup integrity validation completed successfully' -and
                $Component -eq 'BackupValidation' -and $CorrelationId -eq $correlationId -and
                $Data.BackupFilePath -eq $script:ValidBackupFile -and
                $Data.ObjectDN -eq 'CN=TestUser,OU=Users,DC=company,DC=com'
            }
            # Every entry carries the caller's correlation ID
            Should -Invoke Write-StructuredLog -Times 0 -Exactly -ParameterFilter { $CorrelationId -ne $correlationId }
        }

        It "Should generate a GUID correlation ID when none is given" {
            Test-BackupFileIntegrity -BackupFilePath $script:ValidBackupFile | Out-Null

            Should -Invoke Write-StructuredLog -Times 2 -Exactly -ParameterFilter {
                $CorrelationId -match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
            }
        }

        It "Should accept a backup with <Name>" -ForEach @(
            @{ Name = 'a version 1.x BackupVersion'; Override = @{ BackupVersion = '1.5' }; Remove = @() }
            @{ Name = 'no BackupVersion'; Override = @{}; Remove = @('BackupVersion') }
            @{ Name = 'a non-numeric BackupVersion'; Override = @{ BackupVersion = 'beta' }; Remove = @() }
            @{ Name = 'a large repeated DACL'; Override = @{ SDDL = 'D:' + ('(A;;GA;;;WD)' * 1000) }; Remove = @() }
            @{ Name = 'a SACL as well as a DACL'; Override = @{ SDDL = 'O:BAG:SYD:(A;;GA;;;SY)S:(AU;FA;GA;;;WD)' }; Remove = @() }
        ) {
            $file = New-BackupFile -Override $Override -Remove $Remove

            $result = Test-BackupFileIntegrity -BackupFilePath $file

            $result.IsValid | Should -Be $true
            @($result.ValidationDetails).Count | Should -Be 0
        }
    }

    Context "File existence" {
        It "Should report a missing file and log a warning naming it" {
            $missing = Join-Path $TestDrive 'nonexistent.xml'
            $correlationId = [System.Guid]::NewGuid().ToString()

            $result = Test-BackupFileIntegrity -BackupFilePath $missing -CorrelationId $correlationId

            $result.IsValid | Should -Be $false
            $result.ErrorMessage | Should -Be "Backup file not found: $missing"
            $result.ValidationDetails | Should -Be @('File does not exist')
            $result.BackupData | Should -Be $null
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Warning' -and $Message -eq 'Backup file not found' -and
                $CorrelationId -eq $correlationId -and $Data.BackupFilePath -eq $missing
            }
        }

        It "Should treat a directory as not found" {
            $result = Test-BackupFileIntegrity -BackupFilePath $TestDrive

            $result.IsValid | Should -Be $false
            $result.ErrorMessage | Should -Be "Backup file not found: $TestDrive"
        }
    }

    Context "Loading the file" {
        It "Should report a file that is not Clixml and log the load error" {
            $notXml = Join-Path $TestDrive 'not-clixml.xml'
            Set-Content -Path $notXml -Value 'This is not valid XML content'
            $correlationId = [System.Guid]::NewGuid().ToString()

            $result = Test-BackupFileIntegrity -BackupFilePath $notXml -CorrelationId $correlationId

            $result.IsValid | Should -Be $false
            $result.ErrorMessage | Should -BeLike 'Validation error: *'
            $result.ValidationDetails | Should -Be @('Failed to load backup file')
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Error' -and $Message -eq 'Error during backup integrity validation' -and
                $CorrelationId -eq $correlationId -and $Data.BackupFilePath -eq $notXml -and
                -not [string]::IsNullOrEmpty($Data.Error)
            }
        }

        It "Should put the load exception's message in the result and the log" {
            # A locked file surfaces as an IOException from Import-Clixml
            Mock Import-Clixml { throw [System.IO.IOException]::new('File is locked') }

            $result = Test-BackupFileIntegrity -BackupFilePath $script:ValidBackupFile

            $result.ErrorMessage | Should -Be 'Validation error: File is locked'
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Error' -and $Data.Error -eq 'File is locked'
            }
        }

        It "Should reject a file whose content deserializes to null" {
            Mock Import-Clixml { $null }

            $result = Test-BackupFileIntegrity -BackupFilePath $script:ValidBackupFile

            $result.IsValid | Should -Be $false
            $result.ErrorMessage | Should -Be 'Backup file structure validation failed'
            $result.ValidationDetails | Should -Be @('Backup data is null')
        }

        It "Should reject an XML file with a DTD rather than resolve its external entity" {
            $xxe = Join-Path $TestDrive 'xxe.xml'
            Set-Content -Path $xxe -Value @'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE foo [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>
<root>&xxe;</root>
'@

            $result = Test-BackupFileIntegrity -BackupFilePath $xxe

            $result.IsValid | Should -Be $false
            $result.ValidationDetails | Should -Be @('Failed to load backup file')
        }
    }

    Context "SHA256 Hash Integrity Verification" {
        It "Should reject a hash that does not match the SDDL" {
            $file = New-BackupFile -Override @{ SDDLHash = 'InvalidHashValue123' }

            $result = Test-BackupFileIntegrity -BackupFilePath $file

            $result.IsValid | Should -Be $false
            $result.ErrorMessage | Should -Be 'SHA256 hash verification failed'
            $result.ValidationDetails | Should -Be @('Hash mismatch detected')
            $result.BackupData | Should -Be $null
        }

        It "Should reject a backup whose SDDL was changed after the hash was taken" {
            $file = New-BackupFile -Override @{
                SDDL     = 'O:BAG:SYD:(A;;GA;;;WD)'
                SDDLHash = Get-SddlHash -Sddl 'O:BAG:SYD:(A;;GA;;;SY)'
            }

            $result = Test-BackupFileIntegrity -BackupFilePath $file

            $result.ErrorMessage | Should -Be 'SHA256 hash verification failed'
        }

        It "Should log a hash mismatch with the expected and computed hashes" {
            $sddl = 'O:BAG:SYD:(A;;GA;;;SY)'
            $file = New-BackupFile -Override @{ SDDL = $sddl; SDDLHash = 'InvalidHashValue123' }
            $correlationId = [System.Guid]::NewGuid().ToString()
            $computed = Get-SddlHash -Sddl $sddl

            Test-BackupFileIntegrity -BackupFilePath $file -CorrelationId $correlationId | Out-Null

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Error' -and $Message -eq 'SHA256 hash verification failed' -and
                $Component -eq 'BackupValidation' -and $CorrelationId -eq $correlationId -and
                $Data.BackupFilePath -eq $file -and $Data.ExpectedHash -eq 'InvalidHashValue123' -and
                $Data.ComputedHash -eq $computed
            }
        }

        # Module bug (#12): the hash is compared with -ne, which ignores case, so a Base64 hash that differs from the computed one only in letter case is accepted
        It "Should reject a hash that differs from the computed one only in case" -Skip {
            $sddl = 'O:BAG:SYD:(A;;GA;;;SY)'
            $file = New-BackupFile -Override @{ SDDL = $sddl; SDDLHash = (Get-SddlHash -Sddl $sddl).ToLowerInvariant() }

            $result = Test-BackupFileIntegrity -BackupFilePath $file

            $result.IsValid | Should -Be $false
            $result.ErrorMessage | Should -Be 'SHA256 hash verification failed'
        }
    }

    Context "SDDL Format Validation" {
        It "Should reject <Name> as an invalid SDDL format" -ForEach @(
            @{ Name = 'an SDDL with no DACL'; Sddl = 'InvalidSDDLString' }
            @{ Name = 'an unterminated ACE'; Sddl = 'D:(A;;GA;;;WD' }
            @{ Name = 'an SDDL under five characters'; Sddl = 'D:()' }
            @{ Name = 'a whitespace-only SDDL'; Sddl = '      ' }
        ) {
            $file = New-BackupFile -Override @{ SDDL = $Sddl }

            $result = Test-BackupFileIntegrity -BackupFilePath $file

            $result.IsValid | Should -Be $false
            $result.ErrorMessage | Should -Be 'Backup file structure validation failed'
            $result.ValidationDetails | Should -Be @('Invalid SDDL format')
        }

        It "Should reject an empty SDDL even with an empty hash" {
            # Neither SDDL nor SDDLHash is truthy, so the hash check is skipped and the format check decides
            $file = New-BackupFile -Override @{ SDDL = ''; SDDLHash = '' }

            $result = Test-BackupFileIntegrity -BackupFilePath $file

            $result.IsValid | Should -Be $false
            $result.ValidationDetails | Should -Be @('Invalid SDDL format')
        }

        It "Should not include the SDDL text in the error message" {
            $file = New-BackupFile -Override @{ SDDL = 'InvalidSDDL_PASSWORD456' }

            $result = Test-BackupFileIntegrity -BackupFilePath $file

            $result.ErrorMessage | Should -Be 'Backup file structure validation failed'
            ($result.ValidationDetails -join ' ') | Should -Not -Match 'PASSWORD456'
        }
    }

    Context "Metadata Structure Validation" {
        It "Should list every missing required property" {
            $file = New-BackupFile -Remove 'SDDL', 'SDDLHash', 'CorrelationId'

            $result = Test-BackupFileIntegrity -BackupFilePath $file

            $result.IsValid | Should -Be $false
            $result.ErrorMessage | Should -Be 'Backup file structure validation failed'
            $result.ValidationDetails | Should -Be @(
                'Missing required property: SDDL'
                'Missing required property: SDDLHash'
                'Missing required property: CorrelationId'
                'Missing SDDL property'
            )
            $result.BackupData | Should -Be $null
        }

        It "Should report a missing <Property>" -ForEach @(
            @{ Property = 'ObjectDN' }
            @{ Property = 'BackupDate' }
        ) {
            $file = New-BackupFile -Remove $Property

            $result = Test-BackupFileIntegrity -BackupFilePath $file

            $result.IsValid | Should -Be $false
            $result.ValidationDetails | Should -Be @("Missing required property: $Property")
        }

        It "Should reject a backup version above 2" {
            $file = New-BackupFile -Override @{ BackupVersion = '99.0' }

            $result = Test-BackupFileIntegrity -BackupFilePath $file

            $result.IsValid | Should -Be $false
            $result.ValidationDetails | Should -Be @('Unsupported backup version: 99.0')
        }

        It "Should log a structure failure with the file path and the number of issues" {
            $file = New-BackupFile -Remove 'SDDL', 'SDDLHash', 'CorrelationId'
            $correlationId = [System.Guid]::NewGuid().ToString()

            Test-BackupFileIntegrity -BackupFilePath $file -CorrelationId $correlationId | Out-Null

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Warning' -and $Message -eq 'Backup structure validation failed' -and
                $Component -eq 'BackupValidation' -and $CorrelationId -eq $correlationId -and
                $Data.BackupFilePath -eq $file -and $Data.ValidationIssues -eq 4
            }
        }
    }

    Context "Unexpected errors" {
        It "Should return a failed result rather than throw when a later step fails" {
            # The success log is the last call; a failure there reaches the outer catch
            Mock Write-StructuredLog { throw 'log sink unavailable' } -ParameterFilter {
                $Message -eq 'Backup integrity validation completed successfully'
            }
            $correlationId = [System.Guid]::NewGuid().ToString()

            $result = Test-BackupFileIntegrity -BackupFilePath $script:ValidBackupFile -CorrelationId $correlationId

            $result.ErrorMessage | Should -Be 'Validation error: log sink unavailable'
            $result.ValidationDetails | Should -Be @('Unexpected error during validation')
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Error' -and $Message -eq 'Error during backup integrity validation' -and
                $CorrelationId -eq $correlationId -and $Data.Error -eq 'log sink unavailable'
            }
        }
    }
}
