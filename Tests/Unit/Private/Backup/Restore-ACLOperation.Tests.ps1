#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }

<#
.SYNOPSIS
    Unit tests for Set-ObjectACL, which applies a backup's SDDL to an Active Directory object.

.DESCRIPTION
    Runs the real Set-ObjectACL with its collaborators mocked: Get-RestorationTarget and
    Confirm-RestorationSuccess, Set-Acl (the AD: drive does not exist on a test machine) and
    Write-Error. Restore-ACLOperation.Helpers.Tests.ps1 runs the real bodies of the helpers in the
    same file.

.NOTES
    Author: Jeffrey Stuhr
#>

BeforeAll {
    # Pester can only mock a command that exists; define placeholder AD cmdlets when RSAT is absent
    . "$PSScriptRoot\..\..\..\TestHelpers\ADCmdletStubs.ps1"

    . "$PSScriptRoot\..\..\..\..\Private\Backup\Restore-ACLOperation.ps1"

    $script:TestObjectDN = 'CN=TestUser,OU=Users,DC=company,DC=com'
    # Three ACEs on well-known aliases, so the SDDL round-trips through ActiveDirectorySecurity without a domain
    $script:TestSddl = 'O:BAG:BAD:(A;;RPWP;;;SY)(A;;GA;;;BA)(A;;RP;;;AU)'

    function New-TestBackup {
        param([string]$Sddl = $script:TestSddl)
        [PSCustomObject]@{
            ObjectDN            = $script:TestObjectDN
            SDDL                = $Sddl
            ValidationSignature = 'PSSecurityBackup_v2.1'
        }
    }
}

Describe "Set-ObjectACL" -Tag "Unit", "Backup", "RestoreACL" {

    BeforeEach {
        Mock Write-Error { }
        Mock Set-Acl { }
        Mock Get-RestorationTarget {
            [PSCustomObject]@{ IsValid = $true; TargetObjectDN = $TargetObjectDN; Issues = @() }
        }
        Mock Confirm-RestorationSuccess {
            [PSCustomObject]@{ IsVerified = $true; TargetObjectDN = $TargetObjectDN; MatchPercentage = 100 }
        }
        $script:backup = New-TestBackup
    }

    Context "Parameter Validation" {
        It "Should reject a null or empty TargetObjectDN" {
            { Set-ObjectACL -TargetObjectDN $null -BackupData $script:backup } | Should -Throw "*parameter 'TargetObjectDN'*"
            { Set-ObjectACL -TargetObjectDN '' -BackupData $script:backup } | Should -Throw "*parameter 'TargetObjectDN'*"
        }

        It "Should reject null BackupData" {
            { Set-ObjectACL -TargetObjectDN $script:TestObjectDN -BackupData $null } | Should -Throw "*parameter 'BackupData'*"
        }

        It "Should refuse backup data missing <Property> before touching the target" -ForEach @(
            @{ Property = 'SDDL' }
            @{ Property = 'ObjectDN' }
            @{ Property = 'ValidationSignature' }
        ) {
            $partial = New-TestBackup
            $partial.PSObject.Properties.Remove($Property)

            { Set-ObjectACL -TargetObjectDN $script:TestObjectDN -BackupData $partial } | Should -Throw "*Backup data missing required property: $Property*"
            Should -Invoke Get-RestorationTarget -Times 0 -Exactly
            Should -Invoke Set-Acl -Times 0 -Exactly
        }

        It "Should generate a correlation ID when none is given and pass it to target validation" {
            $result = Set-ObjectACL -TargetObjectDN $script:TestObjectDN -BackupData $script:backup

            $result.CorrelationId | Should -Match "^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$"
            $generated = $result.CorrelationId
            Should -Invoke Get-RestorationTarget -Times 1 -Exactly -ParameterFilter { $CorrelationId -eq $generated }
        }

        It "Should apply the ACL to each distinguished name piped in" {
            $other = 'CN=Other,OU=Users,DC=company,DC=com'

            $results = @($script:TestObjectDN, $other | Set-ObjectACL -BackupData $script:backup)

            $results.TargetObjectDN | Should -Be @($script:TestObjectDN, $other)
            Should -Invoke Set-Acl -Times 1 -Exactly -ParameterFilter { $Path -eq "AD:$($script:TestObjectDN)" }
            Should -Invoke Set-Acl -Times 1 -Exactly -ParameterFilter { $Path -eq "AD:$other" }
        }
    }

    Context "Applying the ACL" {
        It "Should validate the target with its DN and correlation ID first" {
            $null = Set-ObjectACL -TargetObjectDN $script:TestObjectDN -BackupData $script:backup -CorrelationId 'acl-1'

            Should -Invoke Get-RestorationTarget -Times 1 -Exactly -ParameterFilter {
                $TargetObjectDN -eq $script:TestObjectDN -and $CorrelationId -eq 'acl-1'
            }
        }

        It "Should write a security descriptor built from the backup SDDL to the object's AD: path" {
            $null = Set-ObjectACL -TargetObjectDN $script:TestObjectDN -BackupData $script:backup

            # The descriptor puts the entries in canonical order, so they are compared as a set
            Should -Invoke Set-Acl -Times 1 -Exactly -ParameterFilter {
                $sddl = $AclObject.GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]::All)
                $Path -eq "AD:$($script:TestObjectDN)" -and
                $AclObject -is [System.DirectoryServices.ActiveDirectorySecurity] -and
                $sddl.StartsWith('O:BAG:BAD:') -and $sddl.Length -eq $script:TestSddl.Length -and
                $sddl.Contains('(A;;RPWP;;;SY)') -and $sddl.Contains('(A;;GA;;;BA)') -and $sddl.Contains('(A;;RP;;;AU)')
            }
        }

        It "Should report success with the number of entries applied" {
            $result = Set-ObjectACL -TargetObjectDN $script:TestObjectDN -BackupData $script:backup -CorrelationId 'acl-2'

            $result.PSTypeNames[0] | Should -Be 'ACLOperationResult'
            $result.Success | Should -BeTrue
            $result.TargetObjectDN | Should -Be $script:TestObjectDN
            $result.ModificationsApplied | Should -Be 3
            $result.VerificationResult | Should -BeNullOrEmpty
            $result.ErrorMessage | Should -BeNullOrEmpty
            $result.WhatIfMode | Should -BeFalse
            $result.CorrelationId | Should -Be 'acl-2'
            $result.Duration | Should -BeOfType [TimeSpan]
            Should -Invoke Write-Error -Times 0 -Exactly
        }

        It "Should not verify unless asked" {
            $null = Set-ObjectACL -TargetObjectDN $script:TestObjectDN -BackupData $script:backup

            Should -Invoke Confirm-RestorationSuccess -Times 0 -Exactly
        }

        It "Should verify the applied ACL against the backup with -VerifyApplication" {
            $result = Set-ObjectACL -TargetObjectDN $script:TestObjectDN -BackupData $script:backup -VerifyApplication -CorrelationId 'acl-3'

            $result.VerificationResult.IsVerified | Should -BeTrue
            $result.VerificationResult.MatchPercentage | Should -Be 100
            Should -Invoke Confirm-RestorationSuccess -Times 1 -Exactly -ParameterFilter {
                $TargetObjectDN -eq $script:TestObjectDN -and
                $ExpectedData.SDDL -eq $script:TestSddl -and
                $CorrelationId -eq 'acl-3'
            }
        }
    }

    Context "Under -WhatIf" {
        It "Should not write the ACL, and should report the entries it would apply" {
            $result = Set-ObjectACL -TargetObjectDN $script:TestObjectDN -BackupData $script:backup -WhatIf

            $result.Success | Should -BeTrue
            $result.WhatIfMode | Should -BeTrue
            $result.ModificationsApplied | Should -Be 3
            Should -Invoke Set-Acl -Times 0 -Exactly
        }

        It "Should skip verification even with -VerifyApplication" {
            $result = Set-ObjectACL -TargetObjectDN $script:TestObjectDN -BackupData $script:backup -VerifyApplication -WhatIf

            $result.VerificationResult | Should -BeNullOrEmpty
            Should -Invoke Confirm-RestorationSuccess -Times 0 -Exactly
        }
    }

    Context "Failures" {
        It "Should fail without writing when the target does not validate" {
            Mock Get-RestorationTarget { [PSCustomObject]@{ IsValid = $false; Issues = @('Object not found') } }

            $result = Set-ObjectACL -TargetObjectDN $script:TestObjectDN -BackupData $script:backup -CorrelationId 'acl-4'

            $result.Success | Should -BeFalse
            $result.ModificationsApplied | Should -Be 0
            $result.ErrorMessage | Should -Be 'ACL operation failed: Target object validation failed: Object not found'
            Should -Invoke Set-Acl -Times 0 -Exactly
            Should -Invoke Write-Error -Times 1 -Exactly -ParameterFilter {
                $Message -eq "ACL operation failed for $($script:TestObjectDN) : Target object validation failed: Object not found - CorrelationId: acl-4"
            }
        }

        It "Should not check the target again with -SkipTargetValidation (#51)" {
            Mock Get-RestorationTarget { [PSCustomObject]@{ IsValid = $false; Issues = @('must not be asked') } }

            $result = Set-ObjectACL -TargetObjectDN $script:TestObjectDN -BackupData $script:backup -SkipTargetValidation

            $result.Success | Should -BeTrue
            Should -Invoke Get-RestorationTarget -Times 0 -Exactly
            Should -Invoke Set-Acl -Times 1 -Exactly
        }

        It "Should report the reasons Get-RestorationTarget gives for rejecting the target" {
            Mock Get-RestorationTarget {
                [PSCustomObject]@{ IsValid = $false; Issues = @('Target object not found or inaccessible: no such object', 'Cannot read current ACL: denied') }
            }

            $result = Set-ObjectACL -TargetObjectDN $script:TestObjectDN -BackupData $script:backup

            $result.ErrorMessage | Should -BeLike '*Target object validation failed: Target object not found or inaccessible: no such object; Cannot read current ACL: denied*'
        }

        It "Should report a Set-Acl failure and skip verification" {
            Mock Set-Acl { throw 'Access denied' }

            $result = Set-ObjectACL -TargetObjectDN $script:TestObjectDN -BackupData $script:backup -VerifyApplication

            $result.Success | Should -BeFalse
            $result.ErrorMessage | Should -Be 'ACL application failed: Access denied'
            $result.ModificationsApplied | Should -Be 0
            Should -Invoke Confirm-RestorationSuccess -Times 0 -Exactly
            Should -Invoke Write-Error -Times 1 -Exactly -ParameterFilter { $Message -eq 'ACL application failed: Access denied' }
        }

        It "Should redact a password in the Set-Acl error" {
            Mock Set-Acl { throw 'Bind failed for PASSWORD123 and password456' }

            $result = Set-ObjectACL -TargetObjectDN $script:TestObjectDN -BackupData $script:backup

            $result.ErrorMessage | Should -Be 'ACL application failed: Bind failed for [REDACTED] and [REDACTED]'
        }

        It "Should report SDDL that does not parse without calling Set-Acl" {
            $result = Set-ObjectACL -TargetObjectDN $script:TestObjectDN -BackupData (New-TestBackup -Sddl 'InvalidSDDLString')

            $result.Success | Should -BeFalse
            $result.ErrorMessage | Should -BeLike 'ACL application failed:*'
            Should -Invoke Set-Acl -Times 0 -Exactly
        }
    }
}
