#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
#Requires -Version 5.1

<#
.SYNOPSIS
    Unit tests for Remove-OrphanedSidEntry, the per-object entry point into the removal workflow.

.DESCRIPTION
    Tests the real function with Invoke-RemovalWorkflow mocked. The earlier version of this file
    defined its own Remove-OrphanedSidEntry (1,300 lines of it) and tested that.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\..\Classes\RemovalOperationResult.ps1"
    . "$PSScriptRoot\..\..\..\..\Private\Core\Remove-OrphanedSidEntry.ps1"

    function Write-StructuredLog { param($Message, $Level, $Component, $CorrelationId, $LogPath, $Data) }
    function Invoke-RemovalWorkflow { param($ObjectDistinguishedName, $OrphanedSIDs, $BackupPath, [switch]$WhatIfMode, $CorrelationId) }

    $script:dnA = 'CN=A,OU=Groups,DC=contoso,DC=com'
    $script:dnB = 'CN=B,OU=Groups,DC=contoso,DC=com'
    $script:sids = @('S-1-5-21-111-222-333-9001', 'S-1-5-21-111-222-333-9002')
}

Describe 'Remove-OrphanedSidEntry' -Tag 'Unit', 'Core', 'Private' {

    BeforeEach {
        Mock Write-StructuredLog { }
        Mock Invoke-RemovalWorkflow {
            $r = [RemovalOperationResult]::new()
            $r.ObjectDN = $ObjectDistinguishedName
            $r.Success = $true
            $r.ActualRemovals = 2
            $r
        }
    }

    Context 'Parameter validation' {
        It 'Rejects an empty ObjectDN' {
            { Remove-OrphanedSidEntry -ObjectDN '' -OrphanedSIDs $script:sids -Confirm:$false } | Should -Throw
        }

        It 'Rejects an empty SID list' {
            { Remove-OrphanedSidEntry -ObjectDN $script:dnA -OrphanedSIDs @() -Confirm:$false } | Should -Throw
        }
    }

    Context 'Delegation to the workflow' {
        It 'Hands the object, SIDs, backup path and correlation ID to Invoke-RemovalWorkflow' {
            $result = Remove-OrphanedSidEntry -ObjectDN $script:dnA -OrphanedSIDs $script:sids -BackupPath 'C:\Backup\run' -CorrelationId 'rm-1' -Confirm:$false

            $result.Success | Should -BeTrue
            $result.ObjectDN | Should -Be $script:dnA
            Should -Invoke Invoke-RemovalWorkflow -Times 1 -Exactly -ParameterFilter {
                $ObjectDistinguishedName -eq $script:dnA -and
                ($OrphanedSIDs -join ',') -eq ($script:sids -join ',') -and
                $BackupPath -eq 'C:\Backup\run' -and
                $CorrelationId -eq 'rm-1' -and
                -not $WhatIfMode
            }
        }

        It 'Runs the workflow once per object, by parameter or from the pipeline' {
            $byParameter = @(Remove-OrphanedSidEntry -ObjectDN $script:dnA, $script:dnB -OrphanedSIDs $script:sids -Confirm:$false)
            $piped = @($script:dnA, $script:dnB | Remove-OrphanedSidEntry -OrphanedSIDs $script:sids -Confirm:$false)

            $byParameter.Count | Should -Be 2
            $piped.Count | Should -Be 2
            $piped.ObjectDN | Should -Be @($script:dnA, $script:dnB)
            Should -Invoke Invoke-RemovalWorkflow -Times 4 -Exactly
        }

        It 'Passes -WhatIfMode through without a confirmation prompt' {
            Remove-OrphanedSidEntry -ObjectDN $script:dnA -OrphanedSIDs $script:sids -WhatIfMode | Out-Null

            Should -Invoke Invoke-RemovalWorkflow -Times 1 -Exactly -ParameterFilter { $WhatIfMode }
        }

        It 'Still runs the workflow under -WhatIf, which the workflow itself honours' {
            Remove-OrphanedSidEntry -ObjectDN $script:dnA -OrphanedSIDs $script:sids -WhatIf | Out-Null

            Should -Invoke Invoke-RemovalWorkflow -Times 1 -Exactly
        }

        It 'Logs start and completion at Verbose level with the correlation ID' {
            Remove-OrphanedSidEntry -ObjectDN $script:dnA -OrphanedSIDs $script:sids -CorrelationId 'rm-2' -Confirm:$false | Out-Null

            Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Message -like 'Starting SID removal*' -and $CorrelationId -eq 'rm-2' }
            Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Message -like '*completed*Success: True*' -and $CorrelationId -eq 'rm-2' }
        }
    }

    Context 'Failures' {
        It 'Returns a failed result for the object when the workflow throws, and continues with the next' {
            Mock Invoke-RemovalWorkflow {
                if ($ObjectDistinguishedName -eq $script:dnA) { throw 'LDAP server unavailable' }
                $r = [RemovalOperationResult]::new(); $r.ObjectDN = $ObjectDistinguishedName; $r.Success = $true; $r
            }

            $results = @($script:dnA, $script:dnB | Remove-OrphanedSidEntry -OrphanedSIDs $script:sids -CorrelationId 'rm-3' -Confirm:$false)

            $results.Count | Should -Be 2
            $failed = $results | Where-Object ObjectDN -eq $script:dnA
            $failed.Success | Should -BeFalse
            $failed.ErrorMessage | Should -BeLike '*LDAP server unavailable*'
            $failed.IntendedRemovals | Should -Be 2
            $failed.CorrelationId | Should -Be 'rm-3'
            ($results | Where-Object ObjectDN -eq $script:dnB).Success | Should -BeTrue
            Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Level -eq 'Error' -and $Message -like "*$($script:dnA)*LDAP server unavailable*" }
        }
    }
}
