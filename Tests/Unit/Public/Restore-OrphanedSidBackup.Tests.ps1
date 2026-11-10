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

        It 'Collects targets from the pipeline' {
            'CN=A,DC=contoso,DC=com', 'CN=B,DC=contoso,DC=com', 'CN=C,DC=contoso,DC=com' |
                Restore-OrphanedSidBackup -BackupPath $script:backupDir -Force | Out-Null

            Should -Invoke -ModuleName OrphanedSid Start-OrchestrationWorkflow -Times 3 -Exactly
            foreach ($dn in 'CN=A,DC=contoso,DC=com', 'CN=B,DC=contoso,DC=com', 'CN=C,DC=contoso,DC=com') {
                Should -Invoke -ModuleName OrphanedSid Start-OrchestrationWorkflow -Times 1 -Exactly -ParameterFilter { $Parameters.TargetObjectDN -eq $dn }
            }
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
