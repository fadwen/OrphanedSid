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
    # As OrphanedSid.psm1 does: in the module the code under test runs under strict mode
    Set-StrictMode -Version Latest

    . "$PSScriptRoot\..\..\..\..\Private\Backup\New-ACLBackup.ps1"
    . "$PSScriptRoot\..\..\..\..\Private\Backup\Initialize-BackupFolder.ps1"
    . "$PSScriptRoot\..\..\..\..\Private\ACL\Get-AclAccessRule.ps1"
    . "$PSScriptRoot\..\..\..\..\Private\Utilities\Get-OrphanedSidModuleVersion.ps1"

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
            $expected = @{
                ErrorId         = 'DistinguishedNameEmpty,New-ACLBackup'
                ExpectedMessage = 'ObjectDN parameter cannot be empty or whitespace'
                ExceptionType   = [System.ArgumentException]
            }
            { New-ACLBackup -ObjectDN '   ' -ACL $script:acl -BackupPath $script:backupDir } | Should -Throw @expected
            Test-Path $script:backupDir | Should -BeFalse
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Error' -and $Message -eq 'ObjectDN parameter cannot be empty or whitespace'
            }
        }
    }

    Context 'Writing the backup' {
        It 'Backs up an object whose name contains square brackets, under a file name without them (#119)' {
            $dn = 'OU=Payroll [EU],OU=Groups,DC=contoso,DC=com'

            $file = New-ACLBackup -ObjectDN $dn -ACL $script:acl -BackupPath $script:backupDir

            Test-Path -LiteralPath $file -PathType Leaf | Should -BeTrue
            [System.IO.Path]::GetFileName($file) | Should -Not -Match '[\[\]]'
            (Import-Clixml -LiteralPath $file).ObjectDN | Should -Be $dn
        }

        It 'Records the number of access rules, read from the security descriptor itself (#121)' {
            $acl = New-TestAcl -Sids 'S-1-5-21-111-222-333-9001', 'S-1-5-21-111-222-333-9002', 'S-1-5-32-544'

            $file = New-ACLBackup -ObjectDN $script:dn -ACL $acl -BackupPath $script:backupDir

            (Import-Clixml -LiteralPath $file).ACLEntryCount | Should -Be 3
            Should -Invoke Write-StructuredLog -Times 0 -Exactly -ParameterFilter { $Message -like '*contains no access entries*' }
        }

        It 'Writes the backup into a folder whose name contains square brackets (#119)' {
            $folder = Join-Path $TestDrive "Backup [prod] $([guid]::NewGuid().ToString('N'))"

            $file = New-ACLBackup -ObjectDN $script:dn -ACL $script:acl -BackupPath $folder

            Test-Path -LiteralPath $file -PathType Leaf | Should -BeTrue
            [System.IO.Path]::GetDirectoryName($file) | Should -Be $folder
            (Import-Clixml -LiteralPath $file).ObjectDN | Should -Be $script:dn
        }

        It 'Creates the folder and one Clixml file named from the sanitized DN and a timestamp' {
            $result = New-ACLBackup -ObjectDN $script:dn -ACL $script:acl -BackupPath $script:backupDir

            $files = @(Get-ChildItem $script:backupDir -File)
            $files.Count | Should -Be 1
            $files[0].Name | Should -Match '^CN_Finance_Share_OU_Groups_DC_contoso_DC_com_\d{8}_\d{6}\.xml$'
            # The full path of the file written, which the removal result reports (#49)
            $result | Should -BeOfType [string]
            $result | Should -Be $files[0].FullName
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

        It 'Records BackupDate as the current UTC time, with a Z that means it (#52)' {
            $before = [DateTime]::UtcNow.AddSeconds(-1)

            New-ACLBackup -ObjectDN $script:dn -ACL $script:acl -BackupPath $script:backupDir | Out-Null

            $after = [DateTime]::UtcNow.AddSeconds(1)
            $stored = (Import-Clixml (Get-ChildItem $script:backupDir -File | Select-Object -First 1).FullName).BackupDate
            $parsed = [DateTimeOffset]::ParseExact($stored, "yyyy-MM-dd'T'HH:mm:ss.fffK", [System.Globalization.CultureInfo]::InvariantCulture)
            $parsed.Offset | Should -Be ([TimeSpan]::Zero)
            $parsed.UtcDateTime | Should -BeGreaterOrEqual $before
            $parsed.UtcDateTime | Should -BeLessOrEqual $after
        }

        It 'Trims the DN before using it' {
            New-ACLBackup -ObjectDN "  $($script:dn)  " -ACL $script:acl -BackupPath $script:backupDir | Out-Null

            $data = Import-Clixml (Get-ChildItem $script:backupDir -File | Select-Object -First 1).FullName
            $data.ObjectDN | Should -Be $script:dn
        }

        It 'Accepts the DN from the pipeline' {
            $result = $script:dn | New-ACLBackup -ACL $script:acl -BackupPath $script:backupDir

            $result | Should -Be (Get-ChildItem $script:backupDir -File).FullName

        }

        It 'Truncates a very long DN so the whole path stays under 260 characters' {
            $longDn = 'CN=' + ('x' * 260) + ',DC=contoso,DC=com'

            New-ACLBackup -ObjectDN $longDn -ACL $script:acl -BackupPath $script:backupDir | Out-Null

            $file = Get-ChildItem $script:backupDir -File | Select-Object -First 1
            $file.Name | Should -Match '^CN_x+_[0-9a-f]{8}_truncated_\d{8}_\d{6}\.xml$'
            $file.FullName.Length | Should -BeLessOrEqual 259
            (Import-Clixml -Path $file.FullName).ObjectDN | Should -Be $longDn
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter { $Message -like 'Filename truncated*' }
        }

        It 'Fits the name to a deep backup folder' {
            # Deep enough to leave exactly 60 characters for the name, whatever TestDrive's own length
            $roomForName = 60
            # The name budget reserves room for a same-second counter after the timestamp
            $depth = 259 - '_yyyyMMdd_HHmmss_99.xml'.Length - $roomForName - ($script:backupDir.TrimEnd('\').Length + 1) - 1
            $deep = Join-Path $script:backupDir ('d' * $depth)
            $null = New-Item -Path $deep -ItemType Directory -Force
            $longDn = 'CN=' + ('y' * 200) + ',DC=contoso,DC=com'

            New-ACLBackup -ObjectDN $longDn -ACL $script:acl -BackupPath $deep | Out-Null

            $file = Get-ChildItem $deep -File | Select-Object -First 1
            $file.FullName.Length | Should -BeLessOrEqual 259
            ($file.Name.Length - '_yyyyMMdd_HHmmss.xml'.Length) | Should -Be $roomForName
            (Import-Clixml -Path $file.FullName).ObjectDN | Should -Be $longDn
        }

        It 'Keeps both backups of one object taken in the same second' {
            $script:fixedTime = [datetime]::new(2026, 1, 1, 12, 0, 0)
            Mock Get-Date { if ($Format) { $script:fixedTime.ToString($Format) } else { $script:fixedTime } }

            $firstFile = New-ACLBackup -ObjectDN $script:dn -ACL $script:acl -BackupPath $script:backupDir
            $secondFile = New-ACLBackup -ObjectDN $script:dn -ACL $script:acl -BackupPath $script:backupDir

            # Each call reports the file it wrote, not the other one
            $firstFile | Should -BeLike '*_20260101_120000.xml'
            $secondFile | Should -BeLike '*_20260101_120000_2.xml'
            $names = @(Get-ChildItem $script:backupDir -File | ForEach-Object Name)
            $names.Count | Should -Be 2
            @($names | Where-Object { $_ -match '_20260101_120000\.xml$' }).Count | Should -Be 1
            @($names | Where-Object { $_ -match '_20260101_120000_2\.xml$' }).Count | Should -Be 1
        }
        It 'Gives two long DNs that share a prefix different file names' {
            $prefix = 'CN=' + ('z' * 230)
            $first = "$prefix,OU=One,DC=contoso,DC=com"
            $second = "$prefix,OU=Two,DC=contoso,DC=com"
            # Both backups in the same second, so only the name can tell them apart
            $script:fixedTime = [datetime]::new(2026, 1, 1, 12, 0, 0)
            Mock Get-Date { if ($Format) { $script:fixedTime.ToString($Format) } else { $script:fixedTime } }

            New-ACLBackup -ObjectDN $first -ACL $script:acl -BackupPath $script:backupDir | Out-Null
            New-ACLBackup -ObjectDN $second -ACL $script:acl -BackupPath $script:backupDir | Out-Null

            $files = @(Get-ChildItem $script:backupDir -File)
            $files.Count | Should -Be 2
            @($files | ForEach-Object { (Import-Clixml -Path $_.FullName).ObjectDN } | Sort-Object) | Should -Be @($first, $second)
        }

        It 'Refuses a backup folder too long to hold any backup file' {
            $tooDeep = 'C:\' + ('p' * 230)

            $expected = @{
                ErrorId         = 'BackupPathTooLong,New-ACLBackup'
                ExpectedMessage = "Backup folder path is too long to hold a backup file within the 260-character limit: $tooDeep"
                ExceptionType   = [System.IO.PathTooLongException]
            }
            { New-ACLBackup -ObjectDN ('CN=' + ('w' * 100) + ',DC=contoso,DC=com') -ACL $script:acl -BackupPath $tooDeep } |
                Should -Throw @expected
            # Logged once, where the check is made: the error leaves the function from there
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'Error' }
        }

        It 'Backs up an ACL with no entries and warns' {
            $empty = [System.DirectoryServices.ActiveDirectorySecurity]::new()

            New-ACLBackup -ObjectDN $script:dn -ACL $empty -BackupPath $script:backupDir | Should -Exist

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
        It 'Writes nothing and returns nothing' {
            $result = New-ACLBackup -ObjectDN $script:dn -ACL $script:acl -BackupPath $script:backupDir -WhatIf

            $result | Should -BeNullOrEmpty
            @(Get-ChildItem $script:backupDir -File -ErrorAction SilentlyContinue).Count | Should -Be 0
            Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Message -like '*cancelled*' }
        }
    }

    Context 'Integrity check after writing' {
        It 'Deletes the file and throws when the stored hash does not read back' {
            Mock Import-Clixml { [PSCustomObject]@{ SDDLHash = 'different'; ObjectDN = $script:dn } }

            $expected = @{
                ErrorId         = 'BackupIntegrityCheckFailed,New-ACLBackup'
                ExpectedMessage = 'Backup integrity check failed - SHA256 hash mismatch detected'
                ExceptionType   = [System.IO.InvalidDataException]
            }
            { New-ACLBackup -ObjectDN $script:dn -ACL $script:acl -BackupPath $script:backupDir -CorrelationId 'bk-4' } |
                Should -Throw @expected
            @(Get-ChildItem $script:backupDir -File).Count | Should -Be 0
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Error' -and $CorrelationId -eq 'bk-4' -and
                $Message -eq "Failed to create ACL backup for $($script:dn) : Backup integrity check failed - SHA256 hash mismatch detected"
            }
        }

        It 'Deletes the file and throws when the stored DN does not read back' {
            $expectedSddl = $script:acl.GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]::All)
            Mock Import-Clixml { [PSCustomObject]@{ SDDLHash = (Get-Sha256Base64 -Text $expectedSddl); ObjectDN = 'CN=Other,DC=contoso,DC=com' } }

            $expected = @{
                ErrorId         = 'BackupIntegrityCheckFailed,New-ACLBackup'
                ExpectedMessage = 'Backup integrity check failed - ObjectDN mismatch detected'
                ExceptionType   = [System.IO.InvalidDataException]
            }
            { New-ACLBackup -ObjectDN $script:dn -ACL $script:acl -BackupPath $script:backupDir } |
                Should -Throw @expected
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

        It 'Ends with BackupFolderNotCreated when a part of the backup path is a file (#161)' {
            # Nothing but the log is mocked. New-Item returns nothing and reports no error here.
            $file = Join-Path $TestDrive "a-file-$([guid]::NewGuid().ToString('N')).txt"
            Set-Content -LiteralPath $file -Value 'not a folder' -Encoding ascii
            $folder = Join-Path $file 'Backup'

            $expected = @{
                ErrorId         = 'BackupFolderNotCreated,New-ACLBackup'
                ExpectedMessage = "The backup folder '$folder' could not be created: *may be a file."
                ExceptionType   = [System.IO.IOException]
            }
            { New-ACLBackup -ObjectDN $script:dn -ACL $script:acl -BackupPath $folder -CorrelationId 'bk-5' } |
                Should -Throw @expected
            # The folder is not logged as created, and the failure is logged once with the reason
            Should -Invoke Write-StructuredLog -Times 0 -Exactly -ParameterFilter {
                $Message -like 'Created backup directory*'
            }
            $logged = "Failed to create ACL backup for $($script:dn) : " +
                "The backup folder '$folder' could not be created*"
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Error' -and $CorrelationId -eq 'bk-5' -and $Message -like $logged
            }
        }

        It 'Ends with BackupFolderNotCreated, and the reason, when the parent denies new folders (#161)' {
            # Nothing but the log is mocked: adding a folder to the parent is denied for this
            # case, and allowed again afterwards. The entry does not keep the folder from being
            # removed with the test drive.
            $parent = Join-Path $TestDrive "NoNewFolders-$([guid]::NewGuid().ToString('N'))"
            $null = New-Item -Path $parent -ItemType Directory
            $folder = Join-Path $parent 'Backup'
            $account = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            $null = & icacls.exe $parent /deny "${account}:(AD,WD)"
            try {
                $caught = $null
                try {
                    New-ACLBackup -ObjectDN $script:dn -ACL $script:acl -BackupPath $folder
                } catch {
                    $caught = $_
                }
            } finally {
                $null = & icacls.exe $parent /remove:d $account
            }

            $caught | Should -Not -BeNullOrEmpty
            $caught.FullyQualifiedErrorId | Should -Be 'BackupFolderNotCreated,New-ACLBackup'
            $caught.Exception.InnerException | Should -BeOfType [System.UnauthorizedAccessException]
            $reason = $caught.Exception.InnerException.Message
            $caught.Exception.Message | Should -Be "The backup folder '$folder' could not be created: $reason"
            Test-Path -LiteralPath $folder | Should -BeFalse
            Should -Invoke Write-StructuredLog -Times 0 -Exactly -ParameterFilter {
                $Message -like 'Created backup directory*'
            }
        }

        It 'Logs the folder as created only when it created it' {
            $second = 'CN=Second,OU=Groups,DC=contoso,DC=com'
            New-ACLBackup -ObjectDN $script:dn -ACL $script:acl -BackupPath $script:backupDir | Out-Null
            New-ACLBackup -ObjectDN $second -ACL $script:acl -BackupPath $script:backupDir | Out-Null

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Information' -and $Message -eq "Created backup directory: $($script:backupDir)"
            }
        }
    }
}
