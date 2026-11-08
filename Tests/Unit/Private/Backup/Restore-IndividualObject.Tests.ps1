#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }

<#
.SYNOPSIS
    Unit tests for Restore-IndividualObject, the per-object step of the restore workflow.

.DESCRIPTION
    Invoke-RestoreWorkflow.Tests.ps1 mocks this function away, so its result object was never built
    in a test. On a domain controller every restore applied the ACL and then reported failure with
    "The term 'if' is not recognized", because the success result used `[int](if ...)` where only
    `$(if ...)` is an expression. These tests build the real result with the three helpers mocked.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\..\Private\Backup\Invoke-RestoreWorkflow.ps1"

    # Placeholders so the helpers can be mocked; the real ones live in other files
    function Write-StructuredLog { param($Message, $Level, $Component, $CorrelationId, $LogPath, $Data) }
    function Test-BackupIntegrity { param($BackupData, $ExpectedObjectDN, $ValidationLevel, $CorrelationId) }
    function Get-RestorationTarget { param($TargetObjectDN, [switch]$CheckPermissions, $CorrelationId) }
    function Set-ObjectACL { param($TargetObjectDN, $BackupData, [switch]$VerifyApplication, $CorrelationId) }

    $script:backup = [PSCustomObject]@{
        ObjectDN = 'CN=Host 1,OU=Orphaned,DC=contoso,DC=com'
        SDDL     = 'O:DAG:DAD:(A;;GR;;;WD)'
    }
}

Describe 'Restore-IndividualObject' -Tag 'Unit', 'Backup', 'Private' {

    BeforeEach {
        Mock Write-StructuredLog { }
        Mock Test-BackupIntegrity { [PSCustomObject]@{ IsValid = $true } }
        Mock Get-RestorationTarget { [PSCustomObject]@{ IsValid = $true; Issues = @() } }
    }

    Context 'Successful restore' {
        It 'Reports success and the number of entries the ACL operation applied' {
            Mock Set-ObjectACL { [PSCustomObject]@{ Success = $true; ModificationsApplied = 7 } }

            $result = Restore-IndividualObject -TargetObjectDN $script:backup.ObjectDN -BackupData $script:backup -BackupFile 'C:\Backup\host1.xml' -CorrelationId 'test'

            $result.Success | Should -BeTrue
            $result.EntriesRestored | Should -Be 7
            $result.ErrorMessage | Should -BeNullOrEmpty
            $result.PSTypeNames | Should -Contain 'RestoreWorkflowResult'
        }

        It 'Reports zero entries when the ACL operation counted none' {
            Mock Set-ObjectACL { [PSCustomObject]@{ Success = $true } }

            $result = Restore-IndividualObject -TargetObjectDN $script:backup.ObjectDN -BackupData $script:backup -BackupFile 'C:\Backup\host1.xml' -CorrelationId 'test'

            $result.Success | Should -BeTrue
            $result.EntriesRestored | Should -Be 0
        }

        It 'Passes -VerifyRestoration through to the ACL operation' {
            Mock Set-ObjectACL { [PSCustomObject]@{ Success = $true; ModificationsApplied = 1 } }

            Restore-IndividualObject -TargetObjectDN $script:backup.ObjectDN -BackupData $script:backup -BackupFile 'C:\Backup\host1.xml' -VerifyRestoration -CorrelationId 'test' | Out-Null

            Should -Invoke Set-ObjectACL -Times 1 -Exactly -ParameterFilter { $VerifyApplication }
        }
    }

    Context 'Failed restore' {
        It 'Reports the ACL operation failure without throwing' {
            Mock Set-ObjectACL { [PSCustomObject]@{ Success = $false; ErrorMessage = 'access denied' } }

            $result = Restore-IndividualObject -TargetObjectDN $script:backup.ObjectDN -BackupData $script:backup -BackupFile 'C:\Backup\host1.xml' -CorrelationId 'test' -WarningAction SilentlyContinue

            $result.Success | Should -BeFalse
            $result.EntriesRestored | Should -Be 0
            $result.ErrorMessage | Should -BeLike '*ACL application failed*access denied*'
        }

        It 'Stops before touching the ACL when the backup fails validation' {
            Mock Test-BackupIntegrity { [PSCustomObject]@{ IsValid = $false; ErrorMessage = 'hash mismatch' } }
            Mock Set-ObjectACL { [PSCustomObject]@{ Success = $true } }

            $result = Restore-IndividualObject -TargetObjectDN $script:backup.ObjectDN -BackupData $script:backup -BackupFile 'C:\Backup\host1.xml' -CorrelationId 'test' -WarningAction SilentlyContinue

            $result.Success | Should -BeFalse
            $result.ErrorMessage | Should -BeLike '*Backup validation failed*hash mismatch*'
            Should -Invoke Set-ObjectACL -Times 0 -Exactly
        }
    }
}
