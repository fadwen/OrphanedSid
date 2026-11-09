#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
#Requires -Version 5.1

<#
.SYNOPSIS
    Regression tests for the single-object path of Invoke-RestoreWorkflow.

.DESCRIPTION
    In 1.0.0 a restore of one object failed with "Could not find file '<folder>\C'": with exactly one
    matching backup, Sort-Object returned the path itself rather than an array, and [0] on a string is
    its first character. These tests run the real workflow against real Clixml files in TestDrive and
    capture which file it hands to Restore-IndividualObject.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\..\Private\Backup\Test-BackupValidation.ps1"
    . "$PSScriptRoot\..\..\..\..\Private\Backup\Restore-ACLOperation.ps1"
    . "$PSScriptRoot\..\..\..\..\Private\Backup\Invoke-RestoreWorkflow.ps1"

    function Write-StructuredLog { param($Message, $Level, $Component, $CorrelationId, $LogPath, $Data) }

    function New-BackupFile {
        param([string]$Folder, [string]$ObjectDN, [datetime]$WrittenAt)
        $safe = $ObjectDN -replace '[\\/:*?"<>|,=]', '_' -replace '\s+', '_'
        $path = Join-Path $Folder "${safe}_$($WrittenAt.ToString('yyyyMMdd_HHmmss')).xml"
        [PSCustomObject]@{ ObjectDN = $ObjectDN; SDDL = 'D:(A;;GA;;;S-1-5-21-1-2-3-512)' } | Export-Clixml -Path $path
        (Get-Item $path).LastWriteTime = $WrittenAt
        return $path
    }

    $script:host1 = 'CN=EdgeCase Orphan Host 1,OU=Orphaned,DC=contoso,DC=com'
    $script:host2 = 'CN=EdgeCase Orphan Host 2,OU=Orphaned,DC=contoso,DC=com'
}

Describe 'Invoke-RestoreWorkflow single-object restore' -Tag 'Unit', 'Backup', 'Private' {

    BeforeEach {
        $script:folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:folder | Out-Null
        Mock Write-Warning { }
        Mock Restore-IndividualObject {
            [PSCustomObject]@{ Success = $true; TargetObjectDN = $TargetObjectDN; BackupFile = $BackupFile; EntriesRestored = 1; ErrorMessage = $null }
        }
    }

    It 'Restores from the one backup that matches when the folder holds only that file' {
        $file = New-BackupFile -Folder $script:folder -ObjectDN $script:host1 -WrittenAt (Get-Date).AddMinutes(-5)

        $result = Invoke-RestoreWorkflow -TargetObjectDN $script:host1 -BackupPath $script:folder -Confirm:$false

        $result.Success | Should -BeTrue
        Should -Invoke Restore-IndividualObject -Times 1 -Exactly -ParameterFilter { $BackupFile -eq $file -and $TargetObjectDN -eq $script:host1 }
    }

    It 'Restores from the one matching backup when the folder holds backups of other objects too' {
        $file = New-BackupFile -Folder $script:folder -ObjectDN $script:host1 -WrittenAt (Get-Date).AddMinutes(-5)
        New-BackupFile -Folder $script:folder -ObjectDN $script:host2 -WrittenAt (Get-Date).AddMinutes(-5) | Out-Null

        Invoke-RestoreWorkflow -TargetObjectDN $script:host1 -BackupPath $script:folder -Confirm:$false | Out-Null

        Should -Invoke Restore-IndividualObject -Times 1 -Exactly -ParameterFilter { $BackupFile -eq $file }
    }

    It 'Takes the newest backup when several match the object' {
        New-BackupFile -Folder $script:folder -ObjectDN $script:host1 -WrittenAt (Get-Date).AddDays(-2) | Out-Null
        $newest = New-BackupFile -Folder $script:folder -ObjectDN $script:host1 -WrittenAt (Get-Date).AddMinutes(-1)

        Invoke-RestoreWorkflow -TargetObjectDN $script:host1 -BackupPath $script:folder -Confirm:$false | Out-Null

        Should -Invoke Restore-IndividualObject -Times 1 -Exactly -ParameterFilter { $BackupFile -eq $newest }
    }

    It 'Restores each object when several are passed one after another, as from a CSV' {
        $file1 = New-BackupFile -Folder $script:folder -ObjectDN $script:host1 -WrittenAt (Get-Date).AddMinutes(-5)
        $file2 = New-BackupFile -Folder $script:folder -ObjectDN $script:host2 -WrittenAt (Get-Date).AddMinutes(-5)

        $results = foreach ($dn in $script:host1, $script:host2) {
            Invoke-RestoreWorkflow -TargetObjectDN $dn -BackupPath $script:folder -Confirm:$false
        }

        @($results | Where-Object Success).Count | Should -Be 2
        Should -Invoke Restore-IndividualObject -Times 1 -Exactly -ParameterFilter { $BackupFile -eq $file1 }
        Should -Invoke Restore-IndividualObject -Times 1 -Exactly -ParameterFilter { $BackupFile -eq $file2 }
    }
}
