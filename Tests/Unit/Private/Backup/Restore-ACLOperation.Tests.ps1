#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }

<#
.SYNOPSIS
    Unit tests for Set-ObjectACL, which applies a backup's SDDL to an Active Directory object.

.DESCRIPTION
    Runs the real Set-ObjectACL with its collaborators mocked: Confirm-RestorationSuccess,
    Set-Acl (the AD: drive does not exist on a test machine) and Write-Error.
    Get-RestorationTarget is mocked as well, to show that the function does not call it: the
    check of the target is its caller's. Restore-ACLOperation.Helpers.Tests.ps1 runs the real
    bodies of the helpers in the same file.

.NOTES
    Author: Jeffrey Stuhr
#>

BeforeAll {
    # Pester can only mock a command that exists; define placeholder AD cmdlets when RSAT is absent
    . "$PSScriptRoot\..\..\..\TestHelpers\ADCmdletStubs.ps1"

    . "$PSScriptRoot\..\..\..\..\Private\Backup\Restore-ACLOperation.ps1"
    . "$PSScriptRoot\..\..\..\..\Private\ActiveDirectory\Get-DirectoryObjectAcl.ps1"
    . "$PSScriptRoot\..\..\..\..\Private\ActiveDirectory\Set-DirectoryObjectAcl.ps1"

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
        # Set-ObjectACL does not check the target (#160). The mock refuses every target, so that
        # a call to it would turn a case that expects success into a failure.
        Mock Get-RestorationTarget {
            [PSCustomObject]@{ IsValid = $false; TargetObjectDN = $TargetObjectDN; Issues = @('must not be asked') }
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

        It "Should refuse backup data missing <Property> before writing anything" -ForEach @(
            @{ Property = 'SDDL' }
            @{ Property = 'ObjectDN' }
            @{ Property = 'ValidationSignature' }
        ) {
            $partial = New-TestBackup
            $partial.PSObject.Properties.Remove($Property)

            $expected = @{
                ErrorId         = 'BackupDataPropertyMissing,Set-ObjectACL'
                ExpectedMessage = "Backup data missing required property: $Property"
            }
            { Set-ObjectACL -TargetObjectDN $script:TestObjectDN -BackupData $partial } | Should -Throw @expected
            Should -Invoke Set-Acl -Times 0 -Exactly
        }

        It "Should generate a correlation ID when none is given and pass it to the verification" {
            $result = Set-ObjectACL -TargetObjectDN $script:TestObjectDN -BackupData $script:backup -VerifyApplication

            $result.CorrelationId | Should -Match "^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$"
            $generated = $result.CorrelationId
            Should -Invoke Confirm-RestorationSuccess -Times 1 -Exactly -ParameterFilter { $CorrelationId -eq $generated }
        }

        It "Should apply the ACL to each distinguished name piped in" {
            $other = 'CN=Other,OU=Users,DC=company,DC=com'

            $results = @($script:TestObjectDN, $other | Set-ObjectACL -BackupData $script:backup)

            $results.TargetObjectDN | Should -Be @($script:TestObjectDN, $other)
            Should -Invoke Set-Acl -Times 1 -Exactly -ParameterFilter { $Path -eq "AD:\$($script:TestObjectDN)" }
            Should -Invoke Set-Acl -Times 1 -Exactly -ParameterFilter { $Path -eq "AD:\$other" }
        }
    }

    Context "Applying the ACL" {
        It "Should write without checking the target, which its caller has checked (#160)" {
            $result = Set-ObjectACL -TargetObjectDN $script:TestObjectDN -BackupData $script:backup -CorrelationId 'acl-1'

            $result.Success | Should -BeTrue
            Should -Invoke Get-RestorationTarget -Times 0 -Exactly
            Should -Invoke Set-Acl -Times 1 -Exactly
        }

        It "Should have no switch that skips a check of the target (#160)" {
            (Get-Command -Name Set-ObjectACL).Parameters.ContainsKey('SkipTargetValidation') | Should -BeFalse
        }

        It "Should write a security descriptor built from the backup SDDL to the object's AD: path" {
            $null = Set-ObjectACL -TargetObjectDN $script:TestObjectDN -BackupData $script:backup

            # The descriptor puts the entries in canonical order, so they are compared as a set
            Should -Invoke Set-Acl -Times 1 -Exactly -ParameterFilter {
                $sddl = $AclObject.GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]::All)
                $Path -eq "AD:\$($script:TestObjectDN)" -and
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
        It "Should report the error of the directory for a target that does not exist, and write nothing else" {
            # The check of the target is the caller's. A caller that left it out gets the
            # failure of the write, as a result and not as an exception.
            Mock Set-Acl { throw "Cannot find path 'AD:\$($script:TestObjectDN)' because it does not exist." }

            $result = Set-ObjectACL -TargetObjectDN $script:TestObjectDN -BackupData $script:backup -CorrelationId 'acl-4'

            $result.Success | Should -BeFalse
            $result.ModificationsApplied | Should -Be 0
            $result.ErrorMessage | Should -Be "ACL application failed: Cannot find path 'AD:\$($script:TestObjectDN)' because it does not exist."
            Should -Invoke Get-RestorationTarget -Times 0 -Exactly
        }

        It "Should report an error that the verification raises as a failed result" {
            Mock Confirm-RestorationSuccess { throw 'The ACL could not be read back' }

            $result = Set-ObjectACL -TargetObjectDN $script:TestObjectDN -BackupData $script:backup -VerifyApplication -CorrelationId 'acl-5'

            $result.PSTypeNames[0] | Should -Be 'ACLOperationResult'
            $result.Success | Should -BeFalse
            $result.TargetObjectDN | Should -Be $script:TestObjectDN
            $result.ModificationsApplied | Should -Be 0
            $result.ErrorMessage | Should -Be 'ACL operation failed: The ACL could not be read back'
            $result.CorrelationId | Should -Be 'acl-5'
            Should -Invoke Write-Error -Times 1 -Exactly -ParameterFilter {
                $Message -eq "ACL operation failed for $($script:TestObjectDN) : The ACL could not be read back - CorrelationId: acl-5"
            }
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
