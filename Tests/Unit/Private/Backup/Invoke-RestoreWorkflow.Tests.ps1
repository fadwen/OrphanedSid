#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
<#
.SYNOPSIS
    Unit tests for Invoke-RestoreWorkflow, which finds backups and restores one object or many.

.DESCRIPTION
    Tests the real workflow against Clixml backup files written to the Pester test drive: parameter
    validation, single-file, directory and bulk mode, what the workflow hands to
    Restore-IndividualObject, how it reports failures, and the result it builds. Restore-IndividualObject
    is mocked; Restore-IndividualObject.Tests.ps1 covers its real body and
    Invoke-RestoreWorkflow.SingleObject.Tests.ps1 covers backup selection in detail.

.NOTES
    Author: Jeffrey Stuhr
#>

BeforeAll {
    # Dot-source the function under test and the files its begin block would otherwise load
    . "$PSScriptRoot\..\..\..\..\Private\Backup\Test-BackupIntegrity.ps1"
    . "$PSScriptRoot\..\..\..\..\Private\Backup\Restore-ACLOperation.ps1"
    . "$PSScriptRoot\..\..\..\..\Private\Backup\Invoke-RestoreWorkflow.ps1"

    function New-BackupFile {
        param(
            [string]$Folder,
            [string]$ObjectDN,
            [datetime]$WrittenAt = (Get-Date).AddMinutes(-5),
            [string]$Extension = '.xml'
        )
        $safe = $ObjectDN -replace '[\\/:*?"<>|,=]', '_' -replace '\s+', '_'
        $path = Join-Path $Folder "${safe}_$($WrittenAt.ToString('yyyyMMdd_HHmmss'))$Extension"
        [PSCustomObject]@{ ObjectDN = $ObjectDN; SDDL = 'D:(A;;GA;;;S-1-5-21-1-2-3-512)' } | Export-Clixml -Path $path
        (Get-Item -LiteralPath $path).LastWriteTime = $WrittenAt
        return $path
    }

    function New-TestFolder {
        # $env:TEMP, and so TestDrive, is an 8.3 short path on the GitHub runners; the workflow returns
        # long paths, so the folder is expanded before any path is built from it
        $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $folder | Out-Null
        (Get-Item -LiteralPath $folder).FullName
    }

    $script:TargetDN = 'CN=TestUser,OU=Users,DC=company,DC=com'
    $script:OuDN = 'OU=Users,DC=company,DC=com'
}

Describe "Invoke-RestoreWorkflow" -Tag "Unit", "Backup", "RestoreWorkflow" {

    BeforeEach {
        Mock Write-Warning { }
        Mock Write-Error { }
        Mock Restore-IndividualObject {
            [PSCustomObject]@{
                Success         = $true
                TargetObjectDN  = $TargetObjectDN
                BackupFile      = $BackupFile
                EntriesRestored = 4
                CorrelationId   = $CorrelationId
                ErrorMessage    = $null
            }
        }
        $script:folder = New-TestFolder
        $script:singleFile = New-BackupFile -Folder $script:folder -ObjectDN $script:TargetDN
    }

    Context "Parameter Validation" {
        It "Should reject a null or empty TargetObjectDN" {
            { Invoke-RestoreWorkflow -TargetObjectDN $null -BackupFile $script:singleFile } | Should -Throw "*parameter 'TargetObjectDN'*"
            { Invoke-RestoreWorkflow -TargetObjectDN '' -BackupFile $script:singleFile } | Should -Throw "*parameter 'TargetObjectDN'*"
        }

        It "Should reject a TargetObjectDN that is not a distinguished name: <BadDN>" -ForEach @(
            @{ BadDN = 'InvalidDN' }
            @{ BadDN = '../../windows/system32' }
            @{ BadDN = 'C:\Windows\System32' }
            @{ BadDN = "<script>alert('xss')</script>" }
            @{ BadDN = "'; DROP TABLE users; --" }
        ) {
            { Invoke-RestoreWorkflow -TargetObjectDN $BadDN -BackupFile $script:singleFile } | Should -Throw "*Invalid target object DN format*"
            Should -Invoke Restore-IndividualObject -Times 0 -Exactly
        }

        It "Should require either BackupFile or BackupPath" {
            { Invoke-RestoreWorkflow -TargetObjectDN $script:TargetDN } | Should -Throw "*Either BackupFile or BackupPath must be specified*"
        }

        It "Should report a BackupFile that does not exist with its full path" {
            $missing = Join-Path $script:folder 'nonexistent.xml'
            { Invoke-RestoreWorkflow -TargetObjectDN $script:TargetDN -BackupFile $missing } | Should -Throw "*Backup file not found: $missing*"
        }

        It "Should report a BackupPath that does not exist" {
            $missing = Join-Path $script:folder 'NoSuchFolder'
            { Invoke-RestoreWorkflow -TargetObjectDN $script:TargetDN -BackupPath $missing } | Should -Throw "*Backup directory not found: $missing*"
        }

        It "Should refuse a backup file whose extension is not .xml or .clixml" {
            $exe = Join-Path $script:folder 'malicious.exe'
            'dummy content' | Out-File $exe -Force

            { Invoke-RestoreWorkflow -TargetObjectDN $script:TargetDN -BackupFile $exe } | Should -Throw "*Invalid file extension. Only .xml and .clixml files are allowed*"
            Should -Invoke Restore-IndividualObject -Times 0 -Exactly
        }

        It "Should accept a .clixml backup file" {
            $clixml = New-BackupFile -Folder $script:folder -ObjectDN $script:TargetDN -Extension '.clixml'

            $result = Invoke-RestoreWorkflow -TargetObjectDN $script:TargetDN -BackupFile $clixml

            $result.Success | Should -BeTrue
            Should -Invoke Restore-IndividualObject -Times 1 -Exactly -ParameterFilter { $BackupFile -eq $clixml }
        }

        It "Should reject an invalid ValidationLevel" {
            { Invoke-RestoreWorkflow -TargetObjectDN $script:TargetDN -BackupFile $script:singleFile -ValidationLevel 'Invalid' } | Should -Throw "*parameter 'ValidationLevel'*"
        }

        It "Should trim whitespace from TargetObjectDN before matching backups" {
            $result = Invoke-RestoreWorkflow -TargetObjectDN "  $($script:TargetDN)  " -BackupPath $script:folder

            $result.Success | Should -BeTrue
            Should -Invoke Restore-IndividualObject -Times 1 -Exactly -ParameterFilter {
                $TargetObjectDN -eq $script:TargetDN -and $BackupFile -eq $script:singleFile
            }
        }

        It "Should restore each distinguished name piped in" {
            $second = 'CN=Second,OU=Users,DC=company,DC=com'
            $secondFile = New-BackupFile -Folder $script:folder -ObjectDN $second

            $results = @($script:TargetDN, $second | Invoke-RestoreWorkflow -BackupPath $script:folder)

            $results.Count | Should -Be 2
            $results.TargetObjectDN | Should -Be @($script:TargetDN, $second)
            Should -Invoke Restore-IndividualObject -Times 1 -Exactly -ParameterFilter { $BackupFile -eq $script:singleFile }
            Should -Invoke Restore-IndividualObject -Times 1 -Exactly -ParameterFilter { $BackupFile -eq $secondFile }
        }
    }

    Context "Single Backup File" {
        It "Should hand the backup's object, data, file, level and correlation ID to Restore-IndividualObject" {
            $null = Invoke-RestoreWorkflow -TargetObjectDN $script:TargetDN -BackupFile $script:singleFile -ValidationLevel 'Comprehensive' -CorrelationId 'wf-1'

            Should -Invoke Restore-IndividualObject -Times 1 -Exactly -ParameterFilter {
                $TargetObjectDN -eq $script:TargetDN -and
                $BackupData.ObjectDN -eq $script:TargetDN -and
                $BackupData.SDDL -eq 'D:(A;;GA;;;S-1-5-21-1-2-3-512)' -and
                $BackupFile -eq $script:singleFile -and
                $ValidationLevel -eq 'Comprehensive' -and
                -not $VerifyRestoration -and
                $CorrelationId -eq 'wf-1'
            }
        }

        It "Should refuse a backup file recorded for a different object, and restore nothing" {
            $otherFile = New-BackupFile -Folder $script:folder -ObjectDN 'CN=Someone Else,OU=Users,DC=company,DC=com'

            $result = Invoke-RestoreWorkflow -TargetObjectDN $script:TargetDN -BackupFile $otherFile -WarningAction SilentlyContinue

            Should -Invoke Restore-IndividualObject -Times 0 -Exactly
            $result.Success | Should -BeFalse
            $result.TargetObjectDN | Should -Be "Unknown (from $otherFile)"
            $result.ErrorMessage | Should -Be "Backup file $otherFile is a backup of 'CN=Someone Else,OU=Users,DC=company,DC=com', not of '$($script:TargetDN)'"
        }
        It "Should default to the Standard validation level" {
            $result = Invoke-RestoreWorkflow -TargetObjectDN $script:TargetDN -BackupFile $script:singleFile

            $result.ValidationLevel | Should -Be 'Standard'
            Should -Invoke Restore-IndividualObject -Times 1 -Exactly -ParameterFilter { $ValidationLevel -eq 'Standard' }
        }

        It "Should pass -VerifyRestoration through" {
            $null = Invoke-RestoreWorkflow -TargetObjectDN $script:TargetDN -BackupFile $script:singleFile -VerifyRestoration

            Should -Invoke Restore-IndividualObject -Times 1 -Exactly -ParameterFilter { $VerifyRestoration }
        }

        It "Should generate a correlation ID when none is given and use it for the restore" {
            $result = Invoke-RestoreWorkflow -TargetObjectDN $script:TargetDN -BackupFile $script:singleFile

            $result.CorrelationId | Should -Match "^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$"
            $generated = $result.CorrelationId
            Should -Invoke Restore-IndividualObject -Times 1 -Exactly -ParameterFilter { $CorrelationId -eq $generated }
        }

        It "Should return the individual result with the workflow properties added" {
            $result = Invoke-RestoreWorkflow -TargetObjectDN $script:TargetDN -BackupFile $script:singleFile -ValidationLevel 'Basic'

            $result.PSTypeNames[0] | Should -Be 'RestoreWorkflowResult'
            $result.Success | Should -BeTrue
            $result.EntriesRestored | Should -Be 4
            $result.BackupFile | Should -Be $script:singleFile
            $result.ValidationLevel | Should -Be 'Basic'
            $result.WhatIfMode | Should -BeFalse
            $result.Duration | Should -BeOfType [TimeSpan]
            $result.CompletedAt | Should -BeOfType [DateTime]
            $result.PSObject.Properties.Name | Should -Not -Contain 'RestoreMode'
        }

        It "Should record three completed workflow steps" {
            $result = Invoke-RestoreWorkflow -TargetObjectDN $script:TargetDN -BackupFile $script:singleFile

            $result.WorkflowSteps.StepName | Should -Be @('Input Validation', 'Backup Discovery and Mode Detection', 'Bulk Restoration Processing')
            $result.WorkflowSteps.Status | Should -Be @('Completed', 'Completed', 'Completed')
            $result.WorkflowSteps[1].RestoreMode | Should -Be 'Single'
            $result.WorkflowSteps[1].BackupFiles | Should -Be @($script:singleFile)
            $result.WorkflowSteps[2].ProcessedObjects | Should -Be 1
            $result.WorkflowSteps[2].SuccessfulRestores | Should -Be 1
            $result.WorkflowSteps[2].FailedRestores | Should -Be 0
        }

        It "Should still run the restore under -WhatIf, which Set-ObjectACL previews, and flag the result" {
            $result = Invoke-RestoreWorkflow -TargetObjectDN $script:TargetDN -BackupFile $script:singleFile -WhatIf

            $result.WhatIfMode | Should -BeTrue
            Should -Invoke Restore-IndividualObject -Times 1 -Exactly
        }
    }

    Context "Failures" {
        It "Should report a failed restore and warn with its reason" {
            Mock Restore-IndividualObject {
                [PSCustomObject]@{ Success = $false; TargetObjectDN = $TargetObjectDN; EntriesRestored = 0; ErrorMessage = 'Target validation failed: Object not found' }
            }

            $result = Invoke-RestoreWorkflow -TargetObjectDN $script:TargetDN -BackupFile $script:singleFile

            $result.Success | Should -BeFalse
            $result.ErrorMessage | Should -Be 'Target validation failed: Object not found'
            $result.WorkflowSteps[2].FailedRestores | Should -Be 1
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
                $Message -eq "Failed to restore: $($script:TargetDN) - Target validation failed: Object not found"
            }
        }

        It "Should turn an exception from Restore-IndividualObject into a failed result naming the file" {
            Mock Restore-IndividualObject { throw 'Backup validation failed' }

            $result = Invoke-RestoreWorkflow -TargetObjectDN $script:TargetDN -BackupFile $script:singleFile -CorrelationId 'wf-err'

            $result.PSTypeNames[0] | Should -Be 'RestoreWorkflowResult'
            $result.Success | Should -BeFalse
            $result.ErrorMessage | Should -Be 'Backup validation failed'
            $result.TargetObjectDN | Should -Be "Unknown (from $($script:singleFile))"
            $result.BackupFile | Should -Be $script:singleFile
            $result.CorrelationId | Should -Be 'wf-err'
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
                $Message -eq "Failed to process backup file $($script:singleFile) : Backup validation failed"
            }
        }

        It "Should report a backup file that cannot be read" {
            Mock Import-Clixml { throw [System.IO.IOException]::new('File is locked') }

            $result = Invoke-RestoreWorkflow -TargetObjectDN $script:TargetDN -BackupFile $script:singleFile

            $result.Success | Should -BeFalse
            $result.ErrorMessage | Should -Be 'File is locked'
            Should -Invoke Restore-IndividualObject -Times 0 -Exactly
        }

        It "Should fail the discovery step for an empty backup folder and write the error" {
            $empty = New-TestFolder

            $result = Invoke-RestoreWorkflow -TargetObjectDN $script:TargetDN -BackupPath $empty -CorrelationId 'wf-empty'

            $result.Success | Should -BeFalse
            $result.RestoreMode | Should -Be 'Single'
            $result.EntriesRestored | Should -Be 0
            $result.ErrorMessage | Should -Be "No backup files found in directory: $empty"
            $result.WorkflowSteps[-1].StepName | Should -Be 'Backup Discovery and Mode Detection'
            $result.WorkflowSteps[-1].Status | Should -Be 'Failed'
            $result.WorkflowSteps[-1].ErrorMessage | Should -Be "No backup files found in directory: $empty"
            Should -Invoke Write-Error -Times 1 -Exactly -ParameterFilter {
                $Message -like "Restore workflow failed for $($script:TargetDN) : No backup files found*wf-empty"
            }
        }

        It "Should skip an unreadable backup in the folder with a warning and restore from the rest" {
            $corrupted = Join-Path $script:folder 'corrupted.xml'
            'Invalid XML Content' | Out-File $corrupted -Force

            $result = Invoke-RestoreWorkflow -TargetObjectDN $script:TargetDN -BackupPath $script:folder

            $result.Success | Should -BeTrue
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like "Failed to process backup file '$corrupted'*" }
            Should -Invoke Restore-IndividualObject -Times 1 -Exactly -ParameterFilter { $BackupFile -eq $script:singleFile }
        }

        It "Should read only .xml files from the backup folder" {
            # A newer backup of the same object with another extension must not be chosen
            $null = New-BackupFile -Folder $script:folder -ObjectDN $script:TargetDN -WrittenAt (Get-Date) -Extension '.txt'

            $null = Invoke-RestoreWorkflow -TargetObjectDN $script:TargetDN -BackupPath $script:folder

            Should -Invoke Restore-IndividualObject -Times 1 -Exactly
            Should -Invoke Restore-IndividualObject -Times 1 -Exactly -ParameterFilter { $BackupFile -eq $script:singleFile }
        }
    }

    Context "Bulk Restoration" {
        BeforeEach {
            $script:userFiles = foreach ($n in 1..3) {
                New-BackupFile -Folder $script:folder -ObjectDN "CN=User$n,OU=Users,DC=company,DC=com"
            }
            $script:outsideFile = New-BackupFile -Folder $script:folder -ObjectDN 'CN=Other,OU=Sales,DC=company,DC=com'
        }

        It "Should restore every object under the OU and summarise the run" {
            $result = Invoke-RestoreWorkflow -TargetObjectDN $script:OuDN -BackupPath $script:folder -CorrelationId 'bulk-1'

            $result.PSTypeNames[0] | Should -Be 'RestoreWorkflowResult'
            $result.RestoreMode | Should -Be 'Bulk'
            $result.Success | Should -BeTrue
            $result.TargetObjectDN | Should -Be $script:OuDN
            $result.TotalObjects | Should -Be 4
            $result.SuccessfulRestores | Should -Be 4
            $result.FailedRestores | Should -Be 0
            $result.EntriesRestored | Should -Be 16
            $result.ErrorMessage | Should -BeNullOrEmpty
            $result.CorrelationId | Should -Be 'bulk-1'
            Should -Invoke Restore-IndividualObject -Times 0 -Exactly -ParameterFilter { $BackupFile -eq $script:outsideFile }
            Should -Invoke Restore-IndividualObject -Times 4 -Exactly -ParameterFilter { $CorrelationId -eq 'bulk-1' }
        }

        It "Should return one typed individual result per restored object" {
            $result = Invoke-RestoreWorkflow -TargetObjectDN $script:OuDN -BackupPath $script:folder

            $result.IndividualResults.Count | Should -Be 4
            $result.IndividualResults | ForEach-Object { $_.PSTypeNames[0] | Should -Be 'RestoreWorkflowResult' }
            ($result.IndividualResults.TargetObjectDN | Sort-Object) | Should -Be @(
                'CN=TestUser,OU=Users,DC=company,DC=com'
                'CN=User1,OU=Users,DC=company,DC=com'
                'CN=User2,OU=Users,DC=company,DC=com'
                'CN=User3,OU=Users,DC=company,DC=com'
            )
        }

        It "Should take in every backup under a domain root" {
            $result = Invoke-RestoreWorkflow -TargetObjectDN 'DC=company,DC=com' -BackupPath $script:folder

            $result.RestoreMode | Should -Be 'Bulk'
            $result.TotalObjects | Should -Be 5
        }

        It "Should report partial failure, count only successful entries and warn for each failure" {
            Mock Restore-IndividualObject {
                [PSCustomObject]@{ Success = $false; TargetObjectDN = $TargetObjectDN; EntriesRestored = 0; ErrorMessage = 'Simulated failure' }
            } -ParameterFilter { $TargetObjectDN -eq 'CN=User2,OU=Users,DC=company,DC=com' }

            $result = Invoke-RestoreWorkflow -TargetObjectDN $script:OuDN -BackupPath $script:folder

            $result.Success | Should -BeFalse
            $result.SuccessfulRestores | Should -Be 3
            $result.FailedRestores | Should -Be 1
            $result.TotalObjects | Should -Be 4
            $result.EntriesRestored | Should -Be 12
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
                $Message -eq 'Failed to restore: CN=User2,OU=Users,DC=company,DC=com - Simulated failure'
            }
        }

        It "Should continue with the other objects after one throws" {
            Mock Restore-IndividualObject { throw 'Validation failed for user' } -ParameterFilter {
                $TargetObjectDN -eq 'CN=User1,OU=Users,DC=company,DC=com'
            }

            $result = Invoke-RestoreWorkflow -TargetObjectDN $script:OuDN -BackupPath $script:folder

            $result.TotalObjects | Should -Be 4
            $result.SuccessfulRestores | Should -Be 3
            $result.FailedRestores | Should -Be 1
            @($result.IndividualResults | Where-Object { -not $_.Success }).ErrorMessage | Should -Be 'Validation failed for user'
        }

        It "Should report failure with nothing restored when no backup is under the OU" {
            $result = Invoke-RestoreWorkflow -TargetObjectDN 'OU=NoMatch,DC=company,DC=com' -BackupPath $script:folder

            $result.Success | Should -BeFalse
            $result.RestoreMode | Should -Be 'Bulk'
            $result.TotalObjects | Should -Be 0
            $result.SuccessfulRestores | Should -Be 0
            $result.EntriesRestored | Should -Be 0
            Should -Invoke Restore-IndividualObject -Times 0 -Exactly
        }
    }
}
