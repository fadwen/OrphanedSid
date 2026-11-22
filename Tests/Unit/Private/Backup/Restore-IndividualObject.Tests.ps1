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
    function Get-RestorationTarget { param($TargetObjectDN, $CorrelationId) }
    # The parameters are the real function's. A mock takes any parameter name, so it is the
    # contract tests, not this placeholder, that fail when the caller names one that is gone.
    function Set-ObjectACL { param($TargetObjectDN, $BackupData, [switch]$VerifyApplication, $CorrelationId) }
    function Write-RestoreSecurityLog { param($Outcome, $Message, $TargetObjectDN, $BackupFile, $CorrelationId, [hashtable]$Detail) }

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
        Mock Write-RestoreSecurityLog { }
    }

    Context 'Security log entries (#187)' {
        # A restore replaces the security descriptor of an object and left no security entry: with
        # -LogLevel Warning or Error the log of a restore that succeeded held only its header.
        BeforeEach {
            $script:restoreParameters = @{
                TargetObjectDN = $script:backup.ObjectDN
                BackupData     = $script:backup
                BackupFile     = 'C:\Backup\host1.xml'
                CorrelationId  = 'run-187'
            }
            # Read inside the parameter filters, where $TargetObjectDN and $BackupFile are the
            # parameters of the mock
            $script:expectedObject = $script:backup.ObjectDN
        }

        It 'Writes one entry for the attempt and one for the success, with the object, the file and the number of entries' {
            Mock Set-ObjectACL { [PSCustomObject]@{ Success = $true; ModificationsApplied = 7 } }

            Restore-IndividualObject @script:restoreParameters | Out-Null

            Should -Invoke Write-RestoreSecurityLog -Times 2 -Exactly
            Should -Invoke Write-RestoreSecurityLog -Times 1 -Exactly -ParameterFilter {
                $Outcome -eq 'Attempt' -and $TargetObjectDN -eq $script:expectedObject -and
                $BackupFile -eq 'C:\Backup\host1.xml' -and $CorrelationId -eq 'run-187'
            }
            Should -Invoke Write-RestoreSecurityLog -Times 1 -Exactly -ParameterFilter {
                $Outcome -eq 'Success' -and $TargetObjectDN -eq $script:expectedObject -and
                $BackupFile -eq 'C:\Backup\host1.xml' -and $CorrelationId -eq 'run-187' -and
                $Detail['EntriesRestored'] -eq 7
            }
        }

        It 'Writes the entry for the attempt before the ACL is written, and the one for the success after' {
            $script:steps = [System.Collections.Generic.List[string]]::new()
            Mock Write-RestoreSecurityLog { $script:steps.Add("entry $Outcome") }
            Mock Set-ObjectACL {
                $script:steps.Add('write')
                [PSCustomObject]@{ Success = $true; ModificationsApplied = 1 }
            }

            Restore-IndividualObject @script:restoreParameters | Out-Null

            $script:steps.Count | Should -Be 3
            $script:steps[0] | Should -Be 'entry Attempt'
            $script:steps[1] | Should -Be 'write'
            $script:steps[2] | Should -Be 'entry Success'
        }

        It 'Writes an entry for the failure, with the reason, when the write fails' {
            Mock Set-ObjectACL { [PSCustomObject]@{ Success = $false; ErrorMessage = 'ACL application failed: access denied' } }

            Restore-IndividualObject @script:restoreParameters -WarningAction SilentlyContinue | Out-Null

            Should -Invoke Write-RestoreSecurityLog -Times 2 -Exactly
            Should -Invoke Write-RestoreSecurityLog -Times 1 -Exactly -ParameterFilter { $Outcome -eq 'Attempt' }
            Should -Invoke Write-RestoreSecurityLog -Times 1 -Exactly -ParameterFilter {
                $Outcome -eq 'Failure' -and $TargetObjectDN -eq $script:expectedObject -and
                $BackupFile -eq 'C:\Backup\host1.xml' -and $CorrelationId -eq 'run-187' -and
                $Detail['Error'] -eq 'ACL application failed: access denied'
            }
        }

        It 'Writes an entry for the failure when the write raises an error' {
            Mock Set-ObjectACL { throw 'The server is not operational' }

            $result = Restore-IndividualObject @script:restoreParameters -WarningAction SilentlyContinue

            $result.Success | Should -BeFalse
            Should -Invoke Write-RestoreSecurityLog -Times 1 -Exactly -ParameterFilter { $Outcome -eq 'Attempt' }
            Should -Invoke Write-RestoreSecurityLog -Times 1 -Exactly -ParameterFilter {
                $Outcome -eq 'Failure' -and $Detail['Error'] -eq 'The server is not operational'
            }
            Should -Invoke Write-RestoreSecurityLog -Times 0 -Exactly -ParameterFilter { $Outcome -eq 'Success' }
        }

        It 'Writes an entry for the failure, and none for an attempt, when <What>' -ForEach @(
            @{ What = 'the backup fails its integrity check'; Reason = 'Backup validation failed: hash mismatch' }
            @{ What = 'the target fails its check'; Reason = 'Target validation failed: not found' }
        ) {
            if ($Reason -like 'Backup*') {
                Mock Test-BackupIntegrity { [PSCustomObject]@{ IsValid = $false; ErrorMessage = 'hash mismatch' } }
            } else {
                Mock Get-RestorationTarget { [PSCustomObject]@{ IsValid = $false; Issues = @('not found') } }
            }
            Mock Set-ObjectACL { [PSCustomObject]@{ Success = $true } }
            $expectedReason = $Reason

            Restore-IndividualObject @script:restoreParameters -WarningAction SilentlyContinue | Out-Null

            Should -Invoke Set-ObjectACL -Times 0 -Exactly
            Should -Invoke Write-RestoreSecurityLog -Times 1 -Exactly
            Should -Invoke Write-RestoreSecurityLog -Times 1 -Exactly -ParameterFilter {
                $Outcome -eq 'Failure' -and $TargetObjectDN -eq $script:expectedObject -and
                $Detail['Error'] -eq $expectedReason
            }
        }

        It 'Writes the entry for the attempt and none for a success under -WhatIf, where nothing is written' {
            # Set-ObjectACL reports success for a preview
            Mock Set-ObjectACL { [PSCustomObject]@{ Success = $true; ModificationsApplied = 7 } }
            $WhatIfPreference = $true

            $result = Restore-IndividualObject @script:restoreParameters

            $result.Success | Should -BeTrue
            Should -Invoke Write-RestoreSecurityLog -Times 1 -Exactly
            Should -Invoke Write-RestoreSecurityLog -Times 1 -Exactly -ParameterFilter { $Outcome -eq 'Attempt' }
        }
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
        It 'Reports the ACL operation failure without throwing, with its prefix once (#51)' {
            # The message Set-ObjectACL builds when Set-Acl fails
            Mock Set-ObjectACL { [PSCustomObject]@{ Success = $false; ErrorMessage = 'ACL application failed: access denied' } }

            $result = Restore-IndividualObject -TargetObjectDN $script:backup.ObjectDN -BackupData $script:backup -BackupFile 'C:\Backup\host1.xml' -CorrelationId 'test' -WarningAction SilentlyContinue

            $result.Success | Should -BeFalse
            $result.EntriesRestored | Should -Be 0
            $result.ErrorMessage | Should -Be 'ACL application failed: access denied'
        }

        It 'Stops before touching the ACL when the backup fails validation' {
            Mock Test-BackupIntegrity { [PSCustomObject]@{ IsValid = $false; ErrorMessage = 'hash mismatch' } }
            Mock Set-ObjectACL { [PSCustomObject]@{ Success = $true } }

            $result = Restore-IndividualObject -TargetObjectDN $script:backup.ObjectDN -BackupData $script:backup -BackupFile 'C:\Backup\host1.xml' -CorrelationId 'test' -WarningAction SilentlyContinue

            $result.Success | Should -BeFalse
            $result.ErrorMessage | Should -BeLike '*Backup validation failed*hash mismatch*'
            Should -Invoke Set-ObjectACL -Times 0 -Exactly
        }

        It 'Stops before touching the ACL when the target fails validation, listing every issue' {
            Mock Get-RestorationTarget { [PSCustomObject]@{ IsValid = $false; Issues = @('not found', 'no access') } }
            Mock Set-ObjectACL { [PSCustomObject]@{ Success = $true } }

            $result = Restore-IndividualObject -TargetObjectDN $script:backup.ObjectDN -BackupData $script:backup -BackupFile 'C:\Backup\host1.xml' -CorrelationId 'test' -WarningAction SilentlyContinue

            $result.Success | Should -BeFalse
            $result.ErrorMessage | Should -Be 'Target validation failed: not found; no access'
            Should -Invoke Set-ObjectACL -Times 0 -Exactly
        }
    }

    Context 'What it hands to its helpers' {
        It 'Validates the backup against the target at the requested level and checks write permission' {
            Mock Set-ObjectACL { [PSCustomObject]@{ Success = $true; ModificationsApplied = 1 } }

            Restore-IndividualObject -TargetObjectDN $script:backup.ObjectDN -BackupData $script:backup -BackupFile 'C:\Backup\host1.xml' -ValidationLevel 'Comprehensive' -CorrelationId 'corr-7' | Out-Null

            Should -Invoke Test-BackupIntegrity -Times 1 -Exactly -ParameterFilter {
                $ExpectedObjectDN -eq $script:backup.ObjectDN -and $ValidationLevel -eq 'Comprehensive' -and
                $BackupData.SDDL -eq $script:backup.SDDL -and $CorrelationId -eq 'corr-7'
            }
            Should -Invoke Get-RestorationTarget -Times 1 -Exactly -ParameterFilter {
                $TargetObjectDN -eq $script:backup.ObjectDN -and $CorrelationId -eq 'corr-7'
            }
            # The target is validated once, here; Set-ObjectACL does not check it (#51, #160)
            Should -Invoke Set-ObjectACL -Times 1 -Exactly -ParameterFilter {
                $TargetObjectDN -eq $script:backup.ObjectDN -and -not $VerifyApplication -and $CorrelationId -eq 'corr-7'
            }
        }
    }
}
