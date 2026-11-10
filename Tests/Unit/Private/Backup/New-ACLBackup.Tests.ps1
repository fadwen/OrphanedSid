#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
#Requires -Version 5.1

<#
.SYNOPSIS
    Unit tests for New-ACLBackup, which writes one Clixml backup of an object's ACL.

.DESCRIPTION
    Tests the real function with a real System.DirectoryServices.ActiveDirectorySecurity object, which
    needs no domain to build, and a TestDrive backup folder. Only Write-StructuredLog is mocked.

    ActiveDirectorySecurity.Access resolves identities and returns nothing on PowerShell 7 without a
    domain, so the entry count is not asserted; the SDDL and its hash are.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\..\Private\Backup\New-ACLBackup.ps1"

    function Write-StructuredLog { param($Message, $Level, $Component, $CorrelationId, $LogPath, $Data) }

    function New-TestAcl {
        param([string[]]$Sids = @('S-1-5-21-111-222-333-9001'))
        $acl = [System.DirectoryServices.ActiveDirectorySecurity]::new()
        foreach ($sid in $Sids) {
            $rule = [System.DirectoryServices.ActiveDirectoryAccessRule]::new(
                [System.Security.Principal.SecurityIdentifier]$sid,
                [System.DirectoryServices.ActiveDirectoryRights]::GenericRead,
                [System.Security.AccessControl.AccessControlType]::Allow)
            $acl.AddAccessRule($rule)
        }
        return $acl
    }

    function Get-Sha256Base64 {
        param([string]$Text)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { [Convert]::ToBase64String($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))) }
        finally { $sha.Dispose() }
    }

    $script:dn = 'CN=Finance Share,OU=Groups,DC=contoso,DC=com'
}

Describe 'New-ACLBackup' -Tag 'Unit', 'Backup', 'Private' {

    BeforeEach {
        Mock Write-StructuredLog { }
        $script:acl = New-TestAcl
        # A folder of its own per test; TestDrive persists across the tests in a Describe
        $script:backupDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    }

    Context 'Parameter validation' {
        It 'Rejects an empty ObjectDN' {
            { New-ACLBackup -ObjectDN '' -ACL $script:acl -BackupPath $script:backupDir } | Should -Throw -ExpectedMessage "*Cannot validate argument on parameter 'ObjectDN'*"
        }

        It 'Rejects a null ACL' {
            { New-ACLBackup -ObjectDN $script:dn -ACL $null -BackupPath $script:backupDir } | Should -Throw -ExpectedMessage "*Cannot validate argument on parameter 'ACL'*"
        }

        It 'Rejects an empty BackupPath' {
            { New-ACLBackup -ObjectDN $script:dn -ACL $script:acl -BackupPath '' } | Should -Throw -ExpectedMessage "*Cannot validate argument on parameter 'BackupPath'*"
        }

        It 'Throws for a whitespace ObjectDN and writes nothing' {
            { New-ACLBackup -ObjectDN '   ' -ACL $script:acl -BackupPath $script:backupDir } |
                Should -Throw -ExpectedMessage '*cannot be empty or whitespace*'
            Test-Path $script:backupDir | Should -BeFalse
        }
    }

    Context 'Writing the backup' {
        It 'Creates the folder and one Clixml file named from the sanitized DN and a timestamp' {
            $result = New-ACLBackup -ObjectDN $script:dn -ACL $script:acl -BackupPath $script:backupDir

            $result | Should -BeTrue
            $files = @(Get-ChildItem $script:backupDir -File)
            $files.Count | Should -Be 1
            $files[0].Name | Should -Match '^CN_Finance_Share_OU_Groups_DC_contoso_DC_com_\d{8}_\d{6}\.xml$'
        }

        It 'Stores the SDDL, its SHA256, the DN and the signature the restore path validates' {
            New-ACLBackup -ObjectDN $script:dn -ACL $script:acl -BackupPath $script:backupDir -CorrelationId 'bk-1' | Out-Null

            $data = Import-Clixml (Get-ChildItem $script:backupDir -File | Select-Object -First 1).FullName
            $expectedSddl = $script:acl.GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]::All)
            $data.ObjectDN | Should -Be $script:dn
            $data.SDDL | Should -Be $expectedSddl
            $data.SDDL | Should -BeLike '*S-1-5-21-111-222-333-9001*'
            $data.SDDLHash | Should -Be (Get-Sha256Base64 -Text $expectedSddl)
            $data.ValidationSignature | Should -Be 'PSSecurityBackup_v2.1'
            $data.BackupVersion | Should -Be '2.1'
            $data.CorrelationId | Should -Be 'bk-1'
            $data.BackupMethod | Should -Be 'New-ACLBackup'
            $data.UserContext | Should -Be $env:USERNAME
            $data.BackupDate | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$'
        }

        It 'Trims the DN before using it' {
            New-ACLBackup -ObjectDN "  $($script:dn)  " -ACL $script:acl -BackupPath $script:backupDir | Out-Null

            $data = Import-Clixml (Get-ChildItem $script:backupDir -File | Select-Object -First 1).FullName
            $data.ObjectDN | Should -Be $script:dn
        }

        It 'Accepts the DN from the pipeline' {
            $script:dn | New-ACLBackup -ACL $script:acl -BackupPath $script:backupDir | Should -BeTrue

            @(Get-ChildItem $script:backupDir -File).Count | Should -Be 1
        }

        It 'Truncates a very long DN in the filename' {
            $longDn = 'CN=' + ('x' * 260) + ',DC=contoso,DC=com'

            New-ACLBackup -ObjectDN $longDn -ACL $script:acl -BackupPath $script:backupDir | Out-Null

            $file = Get-ChildItem $script:backupDir -File | Select-Object -First 1
            $file.Name | Should -BeLike '*_truncated_*.xml'
            $file.BaseName.Length | Should -BeLessThan 240
            Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Message -like 'Filename truncated*' }
        }

        It 'Backs up an ACL with no entries and warns' {
            $empty = [System.DirectoryServices.ActiveDirectorySecurity]::new()

            New-ACLBackup -ObjectDN $script:dn -ACL $empty -BackupPath $script:backupDir | Should -BeTrue

            Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Level -eq 'Warning' -and $Message -like '*no access entries*' }
        }

        It 'Logs the written file at Information level' {
            New-ACLBackup -ObjectDN $script:dn -ACL $script:acl -BackupPath $script:backupDir -CorrelationId 'bk-2' | Out-Null

            Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter {
                $Level -eq 'Information' -and $Message -like 'Successfully backed up ACL to:*' -and $CorrelationId -eq 'bk-2'
            }
        }
    }

    Context 'Under -WhatIf' {
        It 'Writes nothing and returns false' {
            $result = New-ACLBackup -ObjectDN $script:dn -ACL $script:acl -BackupPath $script:backupDir -WhatIf

            $result | Should -BeFalse
            @(Get-ChildItem $script:backupDir -File -ErrorAction SilentlyContinue).Count | Should -Be 0
            Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Message -like '*cancelled*' }
        }
    }

    Context 'Integrity check after writing' {
        It 'Deletes the file and throws when the stored hash does not read back' {
            Mock Import-Clixml { [PSCustomObject]@{ SDDLHash = 'different'; ObjectDN = $script:dn } }

            { New-ACLBackup -ObjectDN $script:dn -ACL $script:acl -BackupPath $script:backupDir } |
                Should -Throw -ExpectedMessage '*hash mismatch*'
            @(Get-ChildItem $script:backupDir -File).Count | Should -Be 0
        }

        It 'Deletes the file and throws when the stored DN does not read back' {
            $expectedSddl = $script:acl.GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]::All)
            Mock Import-Clixml { [PSCustomObject]@{ SDDLHash = (Get-Sha256Base64 -Text $expectedSddl); ObjectDN = 'CN=Other,DC=contoso,DC=com' } }

            { New-ACLBackup -ObjectDN $script:dn -ACL $script:acl -BackupPath $script:backupDir } |
                Should -Throw -ExpectedMessage '*ObjectDN mismatch*'
            @(Get-ChildItem $script:backupDir -File).Count | Should -Be 0
        }
    }

    Context 'Failures' {
        It 'Rethrows a write failure after logging it with the correlation ID' {
            Mock Export-Clixml { throw 'Disk full' }

            { New-ACLBackup -ObjectDN $script:dn -ACL $script:acl -BackupPath $script:backupDir -CorrelationId 'bk-3' } |
                Should -Throw -ExpectedMessage '*Disk full*'
            Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter {
                $Level -eq 'Error' -and $Message -like '*Disk full*' -and $CorrelationId -eq 'bk-3' -and $Data.Function -eq 'New-ACLBackup'
            }
        }
    }
}
