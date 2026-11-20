#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }

<#
.SYNOPSIS
    Unit tests for the Restore-OrphanedSidBackup public command.

.DESCRIPTION
    Covers parameter validation, one orchestration call per target, the per-target failure object,
    the CSV export and the session lifecycle. The restore workflow itself is mocked; it has its own
    tests under Tests/Unit/Private/Backup.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\TestHelpers\ADCmdletStubs.ps1"
    Import-Module "$PSScriptRoot\..\..\..\OrphanedSid.psd1" -Force
}

Describe 'Restore-OrphanedSidBackup' -Tag 'Unit', 'Public' {

    BeforeEach {
        Mock -ModuleName OrphanedSid Start-OrphanedSidSession { @{ CorrelationId = $CorrelationId } }
        Mock -ModuleName OrphanedSid Stop-OrphanedSidSession { }
        Mock -ModuleName OrphanedSid Write-StructuredLog { }
        Mock -ModuleName OrphanedSid Start-OrchestrationWorkflow {
            [PSCustomObject]@{
                PSTypeName      = 'RestoreWorkflowResult'
                Success         = $true
                TargetObjectDN  = $Parameters.TargetObjectDN
                EntriesRestored = 3
                ErrorMessage    = $null
                CorrelationId   = $Parameters.CorrelationId
            }
        }

        $script:backupDir = Join-Path $TestDrive 'Backup\20260101_120000'
        New-Item -Path $script:backupDir -ItemType Directory -Force | Out-Null
        # The workflow is mocked, so the file only has to be there
        $script:backupFile = Join-Path $script:backupDir 'CN_A_DC_contoso_DC_com_20260101_120000.xml'
        Set-Content -LiteralPath $script:backupFile -Value '<Objs />' -Encoding ascii
    }

    Context 'Parameter validation' {
        It 'Requires -BackupPath' {
            # Omitting it would prompt in an interactive host, so the declaration is checked instead
            $attribute = (Get-Command Restore-OrphanedSidBackup).Parameters['BackupPath'].Attributes |
                Where-Object { $_ -is [Parameter] }
            $attribute.Mandatory | Should -Be $true
        }

        It 'Rejects a -BackupPath that does not exist' {
            { Restore-OrphanedSidBackup -TargetObjectDN 'CN=A,DC=contoso,DC=com' -BackupPath 'C:\no\backup' -Force } |
                Should -Throw '*Backup folder not found*'
        }

        It 'Accepts the DistinguishedName and SearchBase aliases' {
            Restore-OrphanedSidBackup -SearchBase 'CN=A,DC=contoso,DC=com' -BackupPath $script:backupDir -Force | Out-Null
            Restore-OrphanedSidBackup -DistinguishedName 'CN=B,DC=contoso,DC=com' -BackupPath $script:backupDir -Force | Out-Null

            Should -Invoke -ModuleName OrphanedSid Start-OrchestrationWorkflow -Times 1 -Exactly -ParameterFilter { $Parameters.TargetObjectDN -eq 'CN=A,DC=contoso,DC=com' }
            Should -Invoke -ModuleName OrphanedSid Start-OrchestrationWorkflow -Times 1 -Exactly -ParameterFilter { $Parameters.TargetObjectDN -eq 'CN=B,DC=contoso,DC=com' }
        }

        It 'Requires -BackupFile in a parameter set of its own, and keeps the folder as the default (#160)' {
            $command = Get-Command Restore-OrphanedSidBackup
            $ofFile = $command.Parameters['BackupFile'].Attributes | Where-Object { $_ -is [Parameter] }
            $ofFolder = $command.Parameters['BackupPath'].Attributes | Where-Object { $_ -is [Parameter] }

            $ofFile.Mandatory | Should -Be $true
            $ofFile.ParameterSetName | Should -Be 'BackupFile'
            $ofFolder.ParameterSetName | Should -Be 'BackupPath'
            $command.DefaultParameterSet | Should -Be 'BackupPath'
        }

        It 'Rejects a -BackupFile that <Case>' -ForEach @(
            @{ Case = 'does not exist'; UseFolder = $false }
            @{ Case = 'is a folder'; UseFolder = $true }
        ) {
            $path = Join-Path $TestDrive 'no-such-backup.xml'
            if ($UseFolder) { $path = $script:backupDir }

            { Restore-OrphanedSidBackup -TargetObjectDN 'CN=A,DC=contoso,DC=com' -BackupFile $path -Force } |
                Should -Throw '*Backup file not found*'
            Should -Invoke -ModuleName OrphanedSid Start-OrchestrationWorkflow -Times 0 -Exactly
        }

        It 'Rejects -BackupPath together with -BackupFile' {
            $both = @{ BackupPath = $script:backupDir; BackupFile = $script:backupFile }

            { Restore-OrphanedSidBackup -TargetObjectDN 'CN=A,DC=contoso,DC=com' @both -Force } |
                Should -Throw -ErrorId 'AmbiguousParameterSet,Restore-OrphanedSidBackup'
            Should -Invoke -ModuleName OrphanedSid Start-OrchestrationWorkflow -Times 0 -Exactly
        }

        It 'Keeps <ParameterName> at position <Expected>, where it was with one parameter set (#160)' -ForEach @(
            @{ ParameterName = 'TargetObjectDN'; Expected = 0 }
            @{ ParameterName = 'BackupPath'; Expected = 1 }
            @{ ParameterName = 'OutputPath'; Expected = 2 }
            @{ ParameterName = 'LogPath'; Expected = 3 }
            @{ ParameterName = 'CorrelationId'; Expected = 4 }
            @{ ParameterName = 'LogLevel'; Expected = 5 }
        ) {
            # With two parameter sets PowerShell gives no position by the order of declaration
            $set = (Get-Command Restore-OrphanedSidBackup).ParameterSets | Where-Object { $_.Name -eq 'BackupPath' }
            $declared = $set.Parameters | Where-Object { $_.Name -eq $ParameterName }

            $declared.Position | Should -Be $Expected
        }

        It 'Gives -BackupFile no position' {
            $set = (Get-Command Restore-OrphanedSidBackup).ParameterSets | Where-Object { $_.Name -eq 'BackupFile' }
            $declared = $set.Parameters | Where-Object { $_.Name -eq 'BackupFile' }

            $declared.Position | Should -BeLessThan 0
        }

        It 'Takes the target and the backup folder by position' {
            Restore-OrphanedSidBackup 'CN=A,DC=contoso,DC=com' $script:backupDir -Force | Out-Null

            Should -Invoke -ModuleName OrphanedSid Start-OrchestrationWorkflow -Times 1 -Exactly -ParameterFilter {
                $Parameters.TargetObjectDN -eq 'CN=A,DC=contoso,DC=com' -and $Parameters.BackupPath -eq $script:backupDir
            }
        }
    }

    Context 'Orchestration' {
        It 'Calls the restore workflow once per target with the backup path' {
            Restore-OrphanedSidBackup -TargetObjectDN 'CN=A,DC=contoso,DC=com', 'CN=B,DC=contoso,DC=com' `
                -BackupPath $script:backupDir -Force -CorrelationId 'rs-1' | Out-Null

            Should -Invoke -ModuleName OrphanedSid Start-OrchestrationWorkflow -Times 2 -Exactly -ParameterFilter {
                $OperationType -eq 'Restore' -and $Parameters.BackupPath -eq $script:backupDir -and
                $Parameters.CorrelationId -eq 'rs-1' -and $CorrelationId -eq 'rs-1' -and -not $Parameters.ContainsKey('WhatIf')
            }
            Should -Invoke -ModuleName OrphanedSid Start-OrchestrationWorkflow -Times 1 -Exactly -ParameterFilter { $Parameters.TargetObjectDN -eq 'CN=A,DC=contoso,DC=com' }
            Should -Invoke -ModuleName OrphanedSid Start-OrchestrationWorkflow -Times 1 -Exactly -ParameterFilter { $Parameters.TargetObjectDN -eq 'CN=B,DC=contoso,DC=com' }
        }

        It 'Calls the restore workflow with the backup file, and with no backup path, for -BackupFile (#160)' {
            Restore-OrphanedSidBackup -TargetObjectDN 'CN=A,DC=contoso,DC=com' -BackupFile $script:backupFile -Force -CorrelationId 'rs-3' | Out-Null

            Should -Invoke -ModuleName OrphanedSid Start-OrchestrationWorkflow -Times 1 -Exactly -ParameterFilter {
                $OperationType -eq 'Restore' -and $Parameters.TargetObjectDN -eq 'CN=A,DC=contoso,DC=com' -and
                $Parameters.BackupFile -eq $script:backupFile -and -not $Parameters.ContainsKey('BackupPath') -and
                $Parameters.CorrelationId -eq 'rs-3' -and -not $Parameters.ContainsKey('WhatIf')
            }
            Should -Invoke -ModuleName OrphanedSid Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Message -eq "Backup source: $($script:backupFile)"
            }
        }

        It 'Calls the restore workflow with no backup file for -BackupPath' {
            Restore-OrphanedSidBackup -TargetObjectDN 'CN=A,DC=contoso,DC=com' -BackupPath $script:backupDir -Force | Out-Null

            Should -Invoke -ModuleName OrphanedSid Start-OrchestrationWorkflow -Times 1 -Exactly -ParameterFilter {
                $Parameters.BackupPath -eq $script:backupDir -and -not $Parameters.ContainsKey('BackupFile')
            }
            Should -Invoke -ModuleName OrphanedSid Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Message -eq "Backup source: $($script:backupDir)"
            }
        }

        It 'Passes WhatIf to the workflow for -BackupFile and still calls it' {
            Restore-OrphanedSidBackup -TargetObjectDN 'CN=A,DC=contoso,DC=com' -BackupFile $script:backupFile -WhatIf | Out-Null

            Should -Invoke -ModuleName OrphanedSid Start-OrchestrationWorkflow -Times 1 -Exactly -ParameterFilter {
                $Parameters.WhatIf -eq $true -and $Parameters.BackupFile -eq $script:backupFile
            }
        }

        It 'Collects targets from the pipeline' {
            'CN=A,DC=contoso,DC=com', 'CN=B,DC=contoso,DC=com', 'CN=C,DC=contoso,DC=com' |
                Restore-OrphanedSidBackup -BackupPath $script:backupDir -Force | Out-Null

            Should -Invoke -ModuleName OrphanedSid Start-OrchestrationWorkflow -Times 3 -Exactly
            foreach ($dn in 'CN=A,DC=contoso,DC=com', 'CN=B,DC=contoso,DC=com', 'CN=C,DC=contoso,DC=com') {
                Should -Invoke -ModuleName OrphanedSid Start-OrchestrationWorkflow -Times 1 -Exactly -ParameterFilter { $Parameters.TargetObjectDN -eq $dn }
            }
        }

        It 'Restores piped AD objects by their DistinguishedName (#79)' {
            # The AD adapter answers 'TargetObjectDN' with an empty collection; by-property binding
            # to a [string[]] parameter took that and failed with "an empty array"
            $adLike = [PSCustomObject]@{
                DistinguishedName = 'CN=FromAD,DC=contoso,DC=com'
                TargetObjectDN    = [System.Collections.Generic.List[object]]::new()
                SearchBase        = [System.Collections.Generic.List[object]]::new()
            }
            $adLike | Restore-OrphanedSidBackup -BackupPath $script:backupDir -Force | Out-Null

            Should -Invoke -ModuleName OrphanedSid Start-OrchestrationWorkflow -Times 1 -Exactly -ParameterFilter {
                $Parameters.TargetObjectDN -eq 'CN=FromAD,DC=contoso,DC=com'
            }
        }

        It 'Restores Import-Csv rows by their DistinguishedName' {
            [PSCustomObject]@{ DistinguishedName = 'CN=Row,DC=contoso,DC=com' } |
                Restore-OrphanedSidBackup -BackupPath $script:backupDir -Force | Out-Null

            Should -Invoke -ModuleName OrphanedSid Start-OrchestrationWorkflow -Times 1 -Exactly -ParameterFilter {
                $Parameters.TargetObjectDN -eq 'CN=Row,DC=contoso,DC=com'
            }
        }

        It 'Refuses input with no usable DN and restores nothing' {
            { [PSCustomObject]@{ Name = 'NoDN' } | Restore-OrphanedSidBackup -BackupPath $script:backupDir -Force -ErrorAction SilentlyContinue } |
                Should -Throw '*No usable restore target*' -ErrorId 'RestoreTargetNotUsable,Restore-OrphanedSidBackup'

            Should -Invoke -ModuleName OrphanedSid Start-OrchestrationWorkflow -Times 0 -Exactly
        }

        It 'Passes WhatIf to the workflow and still calls it' {
            Restore-OrphanedSidBackup -TargetObjectDN 'CN=A,DC=contoso,DC=com' -BackupPath $script:backupDir -WhatIf | Out-Null

            Should -Invoke -ModuleName OrphanedSid Start-OrchestrationWorkflow -Times 1 -Exactly -ParameterFilter {
                $Parameters.WhatIf -eq $true
            }
        }

        It 'Writes one result per target to the pipeline' {
            $results = @(Restore-OrphanedSidBackup -TargetObjectDN 'CN=A,DC=contoso,DC=com', 'CN=B,DC=contoso,DC=com' `
                -BackupPath $script:backupDir -Force)

            $results.Count | Should -Be 2
            $results.TargetObjectDN | Should -Be @('CN=A,DC=contoso,DC=com', 'CN=B,DC=contoso,DC=com')
            Should -Invoke -ModuleName OrphanedSid Write-StructuredLog -Times 1 -Exactly -ParameterFilter { $Message -eq 'Successful restores: 2' }
            Should -Invoke -ModuleName OrphanedSid Write-StructuredLog -Times 1 -Exactly -ParameterFilter { $Message -eq 'Total ACL entries restored: 6' }
        }

        It 'Turns a workflow exception into a failed result and continues with the next target' {
            Mock -ModuleName OrphanedSid Start-OrchestrationWorkflow {
                if ($Parameters.TargetObjectDN -like 'CN=Bad*') { throw 'no backup for this object' }
                [PSCustomObject]@{ Success = $true; TargetObjectDN = $Parameters.TargetObjectDN; EntriesRestored = 1 }
            }

            $results = @(Restore-OrphanedSidBackup -TargetObjectDN 'CN=Bad,DC=contoso,DC=com', 'CN=Good,DC=contoso,DC=com' `
                -BackupPath $script:backupDir -Force)

            $results.Count | Should -Be 2
            $bad = $results | Where-Object TargetObjectDN -like 'CN=Bad*'
            $bad.Success | Should -BeFalse
            $bad.ErrorMessage | Should -Be 'no backup for this object'
            $bad.EntriesRestored | Should -Be 0
            ($results | Where-Object TargetObjectDN -like 'CN=Good*').Success | Should -BeTrue
            Should -Invoke -ModuleName OrphanedSid Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Error' -and $Message -eq 'Restore failed for CN=Bad,DC=contoso,DC=com : no backup for this object'
            }
            Should -Invoke -ModuleName OrphanedSid Write-StructuredLog -Times 1 -Exactly -ParameterFilter { $Message -eq 'Failed restores: 1' }
        }
    }

    Context 'Output file and lifecycle' {
        It 'Exports the results as CSV when -OutputPath is given' {
            $csv = Join-Path $TestDrive 'restore.csv'

            Restore-OrphanedSidBackup -TargetObjectDN 'CN=A,DC=contoso,DC=com' -BackupPath $script:backupDir -Force -OutputPath $csv | Out-Null

            $rows = @(Import-Csv $csv)
            $rows.Count | Should -Be 1
            $rows[0].TargetObjectDN | Should -Be 'CN=A,DC=contoso,DC=com'
            $rows[0].EntriesRestored | Should -Be '3'
            # Import-Csv skips a #TYPE line, so the first line is read as text (#159)
            @(Get-Content -LiteralPath $csv -TotalCount 1)[0] |
                Should -Be '"Success","TargetObjectDN","EntriesRestored","ErrorMessage","CorrelationId"'
            Should -Invoke -ModuleName OrphanedSid Write-StructuredLog -Times 1 -Exactly -ParameterFilter { $Message -eq "Restore results exported to: $csv" }
        }

        It 'Writes no CSV under -WhatIf and logs that none was written (#50)' {
            $csv = Join-Path $TestDrive 'restore-whatif.csv'

            Restore-OrphanedSidBackup -TargetObjectDN 'CN=A,DC=contoso,DC=com' -BackupPath $script:backupDir -OutputPath $csv -WhatIf | Out-Null

            Test-Path $csv | Should -BeFalse
            Should -Invoke -ModuleName OrphanedSid Write-StructuredLog -Times 0 -ParameterFilter { $Message -like '*exported to:*' }
            Should -Invoke -ModuleName OrphanedSid Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Message -eq "WhatIf: results would be exported to $csv; no file was written"
            }
        }

        It 'Starts the session under its own command name' {
            Restore-OrphanedSidBackup -TargetObjectDN 'CN=A,DC=contoso,DC=com' -BackupPath $script:backupDir -Force | Out-Null

            Should -Invoke -ModuleName OrphanedSid Start-OrphanedSidSession -Times 1 -Exactly -ParameterFilter {
                $CommandName -eq 'Restore-OrphanedSidBackup' -and $RequireActiveDirectory
            }
        }

        It 'Stops the session after the run with the correlation ID' {
            Restore-OrphanedSidBackup -TargetObjectDN 'CN=A,DC=contoso,DC=com' -BackupPath $script:backupDir -Force -CorrelationId 'rs-2' | Out-Null

            Should -Invoke -ModuleName OrphanedSid Stop-OrphanedSidSession -Times 1 -Exactly -ParameterFilter { $CorrelationId -eq 'rs-2' }
        }
    }
}
