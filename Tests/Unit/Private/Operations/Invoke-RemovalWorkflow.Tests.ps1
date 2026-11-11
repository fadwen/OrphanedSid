#Requires -Version 5.1

<#
.SYNOPSIS
    Unit tests for Invoke-RemovalWorkflow, which reads an ACL, validates the SIDs, backs the ACL up,
    removes the allowed SIDs, writes the ACL back and verifies it.

.DESCRIPTION
    Every phase is a collaborator, and each is mocked; the tests check what the workflow passes
    between them, which phases a given outcome skips, and the result it builds.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\..\Classes\RemovalOperationResult.ps1"
    . "$PSScriptRoot\..\..\..\..\Classes\SecurityValidationResult.ps1"
    . "$PSScriptRoot\..\..\..\..\Private\Logging\Write-StructuredLog.ps1"
    . "$PSScriptRoot\..\..\..\..\Private\Logging\Write-RemovalSecurityLog.ps1"
    . "$PSScriptRoot\..\..\..\..\Private\ACL\Get-ACLForRemoval.ps1"
    . "$PSScriptRoot\..\..\..\..\Private\ACL\Invoke-SIDRemoval.ps1"
    . "$PSScriptRoot\..\..\..\..\Private\ACL\Set-ModifiedACL.ps1"
    . "$PSScriptRoot\..\..\..\..\Private\Security\Invoke-RemovalVerification.ps1"
    . "$PSScriptRoot\..\..\..\..\Private\Security\Invoke-SecurityValidation.ps1"
    . "$PSScriptRoot\..\..\..\..\Private\Backup\New-ACLBackup.ps1"
    . "$PSScriptRoot\..\..\..\..\Private\Utilities\Get-OrphanedSidModuleVersion.ps1"
    . "$PSScriptRoot\..\..\..\..\Private\Operations\Invoke-RemovalWorkflow.ps1"

    $script:dn = 'CN=Test,DC=domain,DC=com'
    $script:sid1 = 'S-1-5-21-1234567890-1234567890-1234567890-1001'
    $script:sid2 = 'S-1-5-21-1234567890-1234567890-1234567890-1002'
    # New-ACLBackup types its ACL parameter, so the ACL read is a real ActiveDirectorySecurity
    $script:readAcl = [System.DirectoryServices.ActiveDirectorySecurity]::new()
    $script:readAcl.SetSecurityDescriptorSddlForm('O:BAG:BAD:(A;;GA;;;SY)')
    $script:modifiedAcl = [PSCustomObject]@{ Modified = $true }
}

Describe "Invoke-RemovalWorkflow" -Tag "Unit", "Operations" {

    BeforeEach {
        $script:CurrentDomainSID = 'S-1-5-21-1234567890-1234567890-1234567890'

        Mock Write-StructuredLog { }
        Mock Write-RemovalSecurityLog { }
        Mock Get-ACLForRemoval { $script:readAcl }
        # Validation allows the first SID only
        Mock Invoke-SecurityValidation {
            [PSCustomObject]@{ IsValid = $true; RiskLevel = 'Low'; AllowedSIDs = @($script:sid1); BlockedSIDs = @(); Issues = @() }
        }
        # Like the real function: the full path of the file it wrote
        Mock New-ACLBackup { Join-Path $BackupPath 'CN_User1_20260101_120000.xml' }
        Mock Invoke-SIDRemoval {
            [PSCustomObject]@{ RemovedSIDs = @($script:sid1); FailedSIDs = @(); ModifiedACL = $script:modifiedAcl }
        }
        Mock Set-ModifiedACL { [PSCustomObject]@{ Success = $true } }
        Mock Invoke-RemovalVerification { [PSCustomObject]@{ Success = $true; ErrorMessage = $null; RemainingOrphanedSIDs = @() } }
    }

    Context "A successful run" {
        It "Removes the validated SIDs, writes the ACL back, verifies and reports success" {
            $result = Invoke-RemovalWorkflow -ObjectDistinguishedName $script:dn -OrphanedSIDs $script:sid1, $script:sid2 -CorrelationId 'wf-1'

            $result | Should -BeOfType 'RemovalOperationResult'
            $result.Success | Should -Be $true
            $result.ObjectDN | Should -Be $script:dn
            $result.CorrelationId | Should -Be 'wf-1'
            $result.ActualRemovals | Should -Be 1
            $result.FailedRemovals | Should -Be 0
            $result.RemovedSIDs | Should -Be @($script:sid1)
            $result.ErrorMessage | Should -BeNullOrEmpty
            $result.ProcessingTime | Should -BeOfType [TimeSpan]
        }

        It "Passes each phase's output to the next" {
            Invoke-RemovalWorkflow -ObjectDistinguishedName $script:dn -OrphanedSIDs $script:sid1, $script:sid2 -CorrelationId 'wf-2' | Out-Null

            Should -Invoke Get-ACLForRemoval -Times 1 -Exactly -ParameterFilter {
                $ObjectDistinguishedName -eq $script:dn -and $CorrelationId -eq 'wf-2'
            }
            Should -Invoke Invoke-SecurityValidation -Times 1 -Exactly -ParameterFilter {
                "$OrphanedSIDs" -eq "$($script:sid1) $($script:sid2)" -and $ObjectDN -eq $script:dn -and
                $CurrentDomainSID -eq $script:CurrentDomainSID -and $CorrelationId -eq 'wf-2'
            }
            # Only the SIDs validation allowed reach the removal and the verification
            Should -Invoke Invoke-SIDRemoval -Times 1 -Exactly -ParameterFilter {
                $ACL -eq $script:readAcl -and "$AllowedSIDs" -eq $script:sid1 -and -not $WhatIfMode -and $CorrelationId -eq 'wf-2'
            }
            Should -Invoke Set-ModifiedACL -Times 1 -Exactly -ParameterFilter {
                $ACL -eq $script:modifiedAcl -and $ObjectDN -eq $script:dn -and $CorrelationId -eq 'wf-2'
            }
            Should -Invoke Invoke-RemovalVerification -Times 1 -Exactly -ParameterFilter {
                $ObjectDN -eq $script:dn -and "$AllowedSIDs" -eq $script:sid1 -and $CorrelationId -eq 'wf-2'
            }
        }

        It "Writes an attempt and a success to the security log" {
            Invoke-RemovalWorkflow -ObjectDistinguishedName $script:dn -OrphanedSIDs $script:sid1 | Out-Null

            Should -Invoke Write-RemovalSecurityLog -Times 1 -Exactly -ParameterFilter { $Outcome -eq 'Attempt' -and $SecurityContext.SIDsToRemove -eq 1 }
            Should -Invoke Write-RemovalSecurityLog -Times 1 -Exactly -ParameterFilter { $Outcome -eq 'Success' -and $SecurityContext.ActualRemovals -eq 1 }
        }

        It "Generates a GUID correlation ID when none is given" {
            $result = Invoke-RemovalWorkflow -ObjectDistinguishedName $script:dn -OrphanedSIDs $script:sid1

            $result.CorrelationId | Should -Match "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
            Should -Invoke Get-ACLForRemoval -Times 1 -Exactly -ParameterFilter { $CorrelationId -eq $result.CorrelationId }
        }

        It "Reports partial removals" {
            Mock Invoke-SIDRemoval {
                [PSCustomObject]@{ RemovedSIDs = @($script:sid1); FailedSIDs = @($script:sid2); ModifiedACL = $script:modifiedAcl }
            }

            $result = Invoke-RemovalWorkflow -ObjectDistinguishedName $script:dn -OrphanedSIDs $script:sid1, $script:sid2

            $result.ActualRemovals | Should -Be 1
            $result.FailedRemovals | Should -Be 1
            $result.FailedSIDs | Should -Be @($script:sid2)
        }

        It "Succeeds without writing the ACL when nothing needed removing" {
            Mock Invoke-SIDRemoval { [PSCustomObject]@{ RemovedSIDs = @(); FailedSIDs = @(); ModifiedACL = $script:modifiedAcl } }

            $result = Invoke-RemovalWorkflow -ObjectDistinguishedName $script:dn -OrphanedSIDs $script:sid1

            $result.Success | Should -Be $true
            $result.ActualRemovals | Should -Be 0
            Should -Invoke Set-ModifiedACL -Times 0 -Exactly
            Should -Invoke Invoke-RemovalVerification -Times 0 -Exactly
        }

        It "Reports the intended removals as a count" {
            $result = Invoke-RemovalWorkflow -ObjectDistinguishedName $script:dn -OrphanedSIDs $script:sid1, $script:sid2

            $result.IntendedRemovals | Should -BeOfType [int]
            $result.IntendedRemovals | Should -Be 2
        }
    }

    Context "Security validation" {
        It "Stops before any change when validation fails, reporting the issues and blocked SIDs" {
            Mock Invoke-SecurityValidation {
                [PSCustomObject]@{ IsValid = $false; RiskLevel = 'Critical'; AllowedSIDs = @(); BlockedSIDs = @($script:sid1); Issues = @('protected SID', 'second issue') }
            }

            $result = Invoke-RemovalWorkflow -ObjectDistinguishedName $script:dn -OrphanedSIDs $script:sid1 -BackupPath 'C:\Backups'

            $result.Success | Should -Be $false
            $result.ErrorMessage | Should -Be 'Security validation failed: protected SID; second issue'
            $result.BlockedSIDs | Should -Be @($script:sid1)
            $result.SecurityValidation.RiskLevel | Should -Be 'Critical'
            Should -Invoke New-ACLBackup -Times 0 -Exactly
            Should -Invoke Invoke-SIDRemoval -Times 0 -Exactly
            Should -Invoke Set-ModifiedACL -Times 0 -Exactly
        }

        It "Carries the blocked SIDs of a validation that still passed" {
            Mock Invoke-SecurityValidation {
                [PSCustomObject]@{ IsValid = $true; RiskLevel = 'Medium'; AllowedSIDs = @($script:sid1); BlockedSIDs = @($script:sid2); Issues = @() }
            }

            $result = Invoke-RemovalWorkflow -ObjectDistinguishedName $script:dn -OrphanedSIDs $script:sid1, $script:sid2

            $result.Success | Should -Be $true
            $result.BlockedSIDs | Should -Be @($script:sid2)
            $result.SecurityValidation.RiskLevel | Should -Be 'Medium'
        }
    }

    Context "Backup" {
        It "Backs up the ACL it read before removing anything when a backup path is given" {
            Invoke-RemovalWorkflow -ObjectDistinguishedName $script:dn -OrphanedSIDs $script:sid1 -BackupPath 'C:\Backups' -CorrelationId 'wf-3' | Out-Null

            Should -Invoke New-ACLBackup -Times 1 -Exactly -ParameterFilter {
                $ObjectDN -eq $script:dn -and $ACL -eq $script:readAcl -and $BackupPath -eq 'C:\Backups' -and $CorrelationId -eq 'wf-3'
            }
        }
        It "Records the backup file in the result and in both security log entries (#49)" {
            $result = Invoke-RemovalWorkflow -ObjectDistinguishedName $script:dn -OrphanedSIDs $script:sid1 -BackupPath 'C:\Backups'

            $result.BackupFile | Should -Be 'C:\Backups\CN_User1_20260101_120000.xml'
            Should -Invoke Write-RemovalSecurityLog -Times 1 -Exactly -ParameterFilter {
                $Outcome -eq 'Attempt' -and $SecurityContext.BackupCreated -eq $true -and
                $SecurityContext.BackupFile -eq 'C:\Backups\CN_User1_20260101_120000.xml'
            }
            Should -Invoke Write-RemovalSecurityLog -Times 1 -Exactly -ParameterFilter {
                $Outcome -eq 'Success' -and $SecurityContext.BackupFile -eq 'C:\Backups\CN_User1_20260101_120000.xml' -and
                -not $SecurityContext.ContainsKey('BackupPath')
            }
        }

        It "Reports no backup file, and BackupCreated false, when no backup path is given (#49)" {
            $result = Invoke-RemovalWorkflow -ObjectDistinguishedName $script:dn -OrphanedSIDs $script:sid1

            $result.BackupFile | Should -BeNullOrEmpty
            Should -Invoke Write-RemovalSecurityLog -Times 1 -Exactly -ParameterFilter {
                $Outcome -eq 'Attempt' -and $SecurityContext.BackupCreated -eq $false
            }
        }

        It "Aborts without removing anything when the backup fails" {
            # A backup declined through ShouldProcess emits nothing
            Mock New-ACLBackup { }

            $result = Invoke-RemovalWorkflow -ObjectDistinguishedName $script:dn -OrphanedSIDs $script:sid1 -BackupPath 'C:\Backups'

            $result.Success | Should -Be $false
            $result.ErrorMessage | Should -Be 'Workflow failed: Failed to create ACL backup - aborting removal operation'
            Should -Invoke Invoke-SIDRemoval -Times 0 -Exactly
            Should -Invoke Set-ModifiedACL -Times 0 -Exactly
        }

        It "Takes no backup when no backup path is given" {
            Invoke-RemovalWorkflow -ObjectDistinguishedName $script:dn -OrphanedSIDs $script:sid1 | Out-Null

            Should -Invoke New-ACLBackup -Times 0 -Exactly
        }
    }

    Context "Preview modes" {
        It "Under -WhatIfMode previews the removal, takes no backup and writes nothing" {
            $result = Invoke-RemovalWorkflow -ObjectDistinguishedName $script:dn -OrphanedSIDs $script:sid1 -BackupPath 'C:\Backups' -WhatIfMode

            $result.Success | Should -Be $true
            Should -Invoke Invoke-SIDRemoval -Times 1 -Exactly -ParameterFilter { $WhatIfMode }
            Should -Invoke New-ACLBackup -Times 0 -Exactly
            Should -Invoke Set-ModifiedACL -Times 0 -Exactly
        }

        It "Under -WhatIf writes nothing and does not report success" {
            $result = Invoke-RemovalWorkflow -ObjectDistinguishedName $script:dn -OrphanedSIDs $script:sid1 -WhatIf

            $result.Success | Should -Be $false
            Should -Invoke Set-ModifiedACL -Times 0 -Exactly
            Should -Invoke Invoke-RemovalVerification -Times 0 -Exactly
        }
    }

    Context "Failures" {
        It "Reports a failure to write the ACL back, without verifying" {
            Mock Set-ModifiedACL { [PSCustomObject]@{ Success = $false; ErrorMessage = 'Access is denied' } }

            $result = Invoke-RemovalWorkflow -ObjectDistinguishedName $script:dn -OrphanedSIDs $script:sid1

            $result.Success | Should -Be $false
            $result.ErrorMessage | Should -Be 'Failed to apply ACL changes'
            Should -Invoke Invoke-RemovalVerification -Times 0 -Exactly
            Should -Invoke Write-RemovalSecurityLog -Times 1 -Exactly -ParameterFilter {
                $Outcome -eq 'Failure' -and $SecurityContext.Error -eq 'ACLApplicationFailure'
            }
        }

        It "Reports a failed verification with its message" {
            Mock Invoke-RemovalVerification {
                [PSCustomObject]@{ Success = $false; ErrorMessage = 'Verification failed: 1 of 1 SIDs still present'; RemainingOrphanedSIDs = @($script:sid1) }
            }

            $result = Invoke-RemovalWorkflow -ObjectDistinguishedName $script:dn -OrphanedSIDs $script:sid1

            $result.Success | Should -Be $false
            $result.ErrorMessage | Should -Be 'Verification failed: 1 of 1 SIDs still present'
            Should -Invoke Write-RemovalSecurityLog -Times 1 -Exactly -ParameterFilter {
                $Outcome -eq 'Failure' -and "$($SecurityContext.RemainingOrphanedSIDs)" -eq $script:sid1
            }
        }

        It "Turns an exception in <Phase> into a failed result and a security log failure" -ForEach @(
            @{ Phase = 'Get-ACLForRemoval'; Message = 'Access denied' }
            @{ Phase = 'Invoke-SIDRemoval'; Message = 'SID removal error' }
        ) {
            $script:phaseError = $Message
            Mock $Phase { throw $script:phaseError }

            $result = Invoke-RemovalWorkflow -ObjectDistinguishedName $script:dn -OrphanedSIDs $script:sid1 -CorrelationId 'wf-err'

            $result.Success | Should -Be $false
            $result.ErrorMessage | Should -Be "Workflow failed: $Message"
            $result.ProcessingTime | Should -BeOfType [TimeSpan]
            Should -Invoke Set-ModifiedACL -Times 0 -Exactly
            Should -Invoke Write-RemovalSecurityLog -Times 1 -Exactly -ParameterFilter {
                $Outcome -eq 'Failure' -and $CorrelationId -eq 'wf-err' -and $SecurityContext.Error -eq $script:phaseError
            }
        }
    }
}
