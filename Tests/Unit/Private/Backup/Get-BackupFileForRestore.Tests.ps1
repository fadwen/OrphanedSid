#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
#Requires -Version 5.1

<#
.SYNOPSIS
    Unit tests for Get-BackupFileForRestore, which selects the backup files of a restore.

.DESCRIPTION
    Runs the real function against real Clixml files in TestDrive. Invoke-RestoreWorkflow calls it
    for a restore from a folder, and the tests of the workflow cover what the workflow makes of its
    two errors; these cases are about the selection and about the errors themselves.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\..\Private\Backup\Get-BackupFileForRestore.ps1"

    function New-BackupFile {
        param([string]$Folder, [string]$ObjectDN, [datetime]$WrittenAt)
        $safe = $ObjectDN -replace '[\\/:*?"<>|,=]', '_' -replace '\s+', '_'
        $path = Join-Path $Folder "${safe}_$($WrittenAt.ToString('yyyyMMdd_HHmmss')).xml"
        [PSCustomObject]@{ ObjectDN = $ObjectDN; SDDL = 'D:(A;;GA;;;S-1-5-21-1-2-3-512)' } | Export-Clixml -Path $path
        (Get-Item $path).LastWriteTime = $WrittenAt
        return $path
    }

    $script:sales = 'OU=Sales,DC=contoso,DC=com'
    $script:alice = 'CN=Alice,OU=Sales,DC=contoso,DC=com'
    $script:bob = 'CN=Bob,OU=Desk,OU=Sales,DC=contoso,DC=com'
    $script:carol = 'CN=Carol,OU=PreSales,DC=contoso,DC=com'
}

Describe 'Get-BackupFileForRestore' -Tag 'Unit', 'Backup', 'Private' {

    BeforeEach {
        $script:folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:folder | Out-Null
        Mock Write-Warning { }
    }

    Context 'A single object' {
        It 'Selects the newest backup of the object and calls the restore a single one' {
            New-BackupFile -Folder $script:folder -ObjectDN $script:alice -WrittenAt (Get-Date).AddDays(-2) | Out-Null
            $newest = New-BackupFile -Folder $script:folder -ObjectDN $script:alice -WrittenAt (Get-Date).AddMinutes(-1)
            New-BackupFile -Folder $script:folder -ObjectDN $script:bob -WrittenAt (Get-Date).AddMinutes(-1) | Out-Null

            $result = Get-BackupFileForRestore -TargetObjectDN $script:alice -BackupPath $script:folder

            $result.PSObject.TypeNames[0] | Should -Be 'RestoreBackupSelection'
            $result.RestoreMode | Should -Be 'Single'
            @($result.BackupFiles).Count | Should -Be 1
            @($result.BackupFiles)[0] | Should -Be $newest
        }

        It 'Matches the name of the object without regard to case' {
            $file = New-BackupFile -Folder $script:folder -ObjectDN $script:alice -WrittenAt (Get-Date).AddMinutes(-1)

            $result = Get-BackupFileForRestore -TargetObjectDN $script:alice.ToUpperInvariant() -BackupPath $script:folder

            @($result.BackupFiles)[0] | Should -Be $file
        }

        It 'Ends with BackupNotFoundForObject when the folder holds only backups of other objects' {
            New-BackupFile -Folder $script:folder -ObjectDN $script:bob -WrittenAt (Get-Date).AddMinutes(-1) | Out-Null

            $expected = @{
                ErrorId         = 'BackupNotFoundForObject,Get-BackupFileForRestore'
                ExpectedMessage = "No backup files found for object $($script:alice) in path $($script:folder)"
                ExceptionType   = [System.IO.FileNotFoundException]
            }
            { Get-BackupFileForRestore -TargetObjectDN $script:alice -BackupPath $script:folder } |
                Should -Throw @expected
        }
    }

    Context 'A container' {
        It 'Selects one backup of every object at or under the container and calls the restore a bulk one' {
            $ofSales = New-BackupFile -Folder $script:folder -ObjectDN $script:sales -WrittenAt (Get-Date).AddMinutes(-3)
            $ofAlice = New-BackupFile -Folder $script:folder -ObjectDN $script:alice -WrittenAt (Get-Date).AddMinutes(-2)
            $ofBob = New-BackupFile -Folder $script:folder -ObjectDN $script:bob -WrittenAt (Get-Date).AddMinutes(-1)
            # OU=PreSales ends in the same letters as OU=Sales and is another container
            New-BackupFile -Folder $script:folder -ObjectDN $script:carol -WrittenAt (Get-Date).AddMinutes(-1) | Out-Null

            $result = Get-BackupFileForRestore -TargetObjectDN $script:sales -BackupPath $script:folder

            $result.RestoreMode | Should -Be 'Bulk'
            @($result.BackupFiles).Count | Should -Be 3
            @($result.BackupFiles | Sort-Object) | Should -Be @($ofSales, $ofAlice, $ofBob | Sort-Object)
        }

        It 'Selects nothing, without an error, when no backup is of an object in the container' {
            New-BackupFile -Folder $script:folder -ObjectDN $script:carol -WrittenAt (Get-Date).AddMinutes(-1) | Out-Null

            $result = Get-BackupFileForRestore -TargetObjectDN $script:sales -BackupPath $script:folder

            $result.RestoreMode | Should -Be 'Bulk'
            @($result.BackupFiles).Count | Should -Be 0
        }
    }

    Context 'The folder' {
        It 'Ends with BackupFilesNotFound when the folder holds no backup file' {
            Set-Content -LiteralPath (Join-Path $script:folder 'notes.txt') -Value 'not a backup' -Encoding ascii

            $expected = @{
                ErrorId         = 'BackupFilesNotFound,Get-BackupFileForRestore'
                ExpectedMessage = "No backup files found in directory: $($script:folder)"
                ExceptionType   = [System.IO.FileNotFoundException]
            }
            { Get-BackupFileForRestore -TargetObjectDN $script:alice -BackupPath $script:folder } |
                Should -Throw @expected
        }

        It 'Ends with the error of the file system for a folder that cannot be listed (#156)' {
            # The folder holds a backup of the object. Reading it is denied for this case, and
            # allowed again afterwards so that the test drive can be removed. A run that is
            # killed before the finally leaves the folder under %TEMP% with the entry on it:
            # icacls <folder> /reset removes the entry, and the folder can then be deleted.
            New-BackupFile -Folder $script:folder -ObjectDN $script:alice -WrittenAt (Get-Date).AddMinutes(-1) | Out-Null
            $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            $null = & icacls.exe $script:folder /deny "${identity}:(RD)"
            try {
                $caught = $null
                try {
                    Get-BackupFileForRestore -TargetObjectDN $script:alice -BackupPath $script:folder
                } catch {
                    $caught = $_
                }
            } finally {
                $null = & icacls.exe $script:folder /remove:d $identity
            }

            $caught | Should -Not -BeNullOrEmpty
            $caught.Exception | Should -BeOfType [System.UnauthorizedAccessException]
            $caught.FullyQualifiedErrorId | Should -BeLike '*,Get-BackupFileForRestore'
            $caught.FullyQualifiedErrorId | Should -Not -BeLike 'BackupFilesNotFound,*'
        }

        It 'Selects files by the extension .xml exactly' {
            $file = New-BackupFile -Folder $script:folder -ObjectDN $script:alice -WrittenAt (Get-Date).AddMinutes(-1)
            Copy-Item -LiteralPath $file -Destination (Join-Path $script:folder 'copy-of-alice.xmlbak')
            Copy-Item -LiteralPath $file -Destination (Join-Path $script:folder 'notes.txt')

            $result = Get-BackupFileForRestore -TargetObjectDN $script:alice -BackupPath $script:folder

            @($result.BackupFiles).Count | Should -Be 1
            @($result.BackupFiles)[0] | Should -Be $file
            Should -Invoke Write-Warning -Times 0 -Exactly
        }

        It 'Warns about a file that cannot be read and selects from the others' {
            $file = New-BackupFile -Folder $script:folder -ObjectDN $script:alice -WrittenAt (Get-Date).AddMinutes(-1)
            $broken = Join-Path $script:folder 'broken.xml'
            Set-Content -LiteralPath $broken -Value '<not clixml' -Encoding ascii

            $result = Get-BackupFileForRestore -TargetObjectDN $script:alice -BackupPath $script:folder

            @($result.BackupFiles).Count | Should -Be 1
            @($result.BackupFiles)[0] | Should -Be $file
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
                $Message -like "Failed to process backup file '$broken':*"
            }
        }
    }
}
