#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
#Requires -Version 5.1

<#
.SYNOPSIS
    Unit tests for Find-OrphanedSIDsInObject, the per-object detection step the engine runs.

.DESCRIPTION
    Tests the real function with its two collaborators mocked: Get-ObjectAccessRule returns the access
    rules for an object and Test-AccessRuleForOrphanedSID decides whether one rule names an orphaned
    SID. The function had no tests before; the engine tests mock it away.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\..\Classes\OrphanedSIDResult.ps1"
    . "$PSScriptRoot\..\..\..\..\Private\SID\Invoke-SIDProcessing.ps1"

    function Write-StructuredLog { param($Message, $Level, $Component, $CorrelationId, $LogPath, $Data) }
    function Get-ObjectAccessRule { param($ADObject, [switch]$IncludeInherited, $CorrelationId) }
    function Test-AccessRuleForOrphanedSID { param($AccessRule, $ObjectDN, $ObjectClass, $CurrentDomainSID, $MaxRetries, $CorrelationId) }

    function New-TestObject {
        param([string]$Dn, [string]$Class = 'group', [switch]$NoDescriptor)
        $o = [PSCustomObject]@{ DistinguishedName = $Dn; ObjectClass = $Class }
        if (-not $NoDescriptor) { $o | Add-Member -NotePropertyName nTSecurityDescriptor -NotePropertyValue ([PSCustomObject]@{ Owner = 'CONTOSO\Domain Admins' }) }
        return $o
    }

    function New-TestRule { param([string]$Sid) [PSCustomObject]@{ IdentityReference = $Sid; ActiveDirectoryRights = 'GenericRead' } }

    function New-TestResult {
        param([string]$Dn, [string]$Sid)
        $r = [OrphanedSIDResult]::new(); $r.ObjectDN = $Dn; $r.OrphanedSID = $Sid; $r
    }

    $script:domainSid = 'S-1-5-21-111-222-333'
    $script:dnA = 'CN=Host 1,OU=Orphaned,DC=contoso,DC=com'
    $script:dnB = 'CN=Host 2,OU=Orphaned,DC=contoso,DC=com'
}

Describe 'Find-OrphanedSIDsInObject' -Tag 'Unit', 'SID', 'Private' {

    BeforeEach {
        Mock Write-StructuredLog { }
        # Three rules per object; the one ending in 9001 is the orphan
        Mock Get-ObjectAccessRule {
            @((New-TestRule -Sid 'CONTOSO\Domain Admins'), (New-TestRule -Sid "$($script:domainSid)-9001"), (New-TestRule -Sid 'NT AUTHORITY\SYSTEM'))
        }
        Mock Test-AccessRuleForOrphanedSID {
            if ($AccessRule.IdentityReference -like '*-9001') { New-TestResult -Dn $ObjectDN -Sid $AccessRule.IdentityReference }
        }
    }

    Context 'Detection' {
        It 'Returns one result per orphaned access rule, carrying the object DN' {
            $results = @(Find-OrphanedSIDsInObject -ADObject (New-TestObject -Dn $script:dnA) -CurrentDomainSID $script:domainSid -CorrelationId 'det-1')

            $results.Count | Should -Be 1
            $results[0] | Should -BeOfType [OrphanedSIDResult]
            $results[0].ObjectDN | Should -Be $script:dnA
            $results[0].OrphanedSID | Should -Be "$($script:domainSid)-9001"
            Should -Invoke Test-AccessRuleForOrphanedSID -Times 3 -Exactly -ParameterFilter {
                $ObjectDN -eq $script:dnA -and $ObjectClass -eq 'group' -and $CurrentDomainSID -eq $script:domainSid -and $CorrelationId -eq 'det-1'
            }
        }

        It 'Passes -MaxRetries to every access rule test, 3 by default (#89)' {
            Find-OrphanedSIDsInObject -ADObject (New-TestObject -Dn $script:dnA) -MaxRetries 7 | Out-Null
            Find-OrphanedSIDsInObject -ADObject (New-TestObject -Dn $script:dnB) | Out-Null

            Should -Invoke Test-AccessRuleForOrphanedSID -Times 3 -Exactly -ParameterFilter { $ObjectDN -eq $script:dnA -and $MaxRetries -eq 7 }
            Should -Invoke Test-AccessRuleForOrphanedSID -Times 3 -Exactly -ParameterFilter { $ObjectDN -eq $script:dnB -and $MaxRetries -eq 3 }
        }

        It 'Passes -IncludeInherited through to the access rule retrieval' {
            Find-OrphanedSIDsInObject -ADObject (New-TestObject -Dn $script:dnA) -IncludeInherited | Out-Null

            Should -Invoke Get-ObjectAccessRule -Times 1 -Exactly -ParameterFilter { $IncludeInherited }
        }

        It 'Attaches the processing statistics to each result' {
            $results = @(Find-OrphanedSIDsInObject -ADObject (New-TestObject -Dn $script:dnA))

            $results[0].ProcessingStatistics.ObjectDN | Should -Be $script:dnA
            $results[0].ProcessingStatistics.AccessRulesRetrieved | Should -Be 3
            $results[0].ProcessingStatistics.ProcessedSIDs | Should -Be 3
            $results[0].ProcessingStatistics.OrphanedSIDsFound | Should -Be 1
            $results[0].ProcessingStatistics.ErrorsEncountered | Should -Be 0
            $results[0].ProcessingStatistics.Duration | Should -BeGreaterOrEqual 0
        }

        It 'Counts an Unverified result apart from the orphaned ones' {
            Mock Test-AccessRuleForOrphanedSID {
                if ($AccessRule.IdentityReference -like '*-9001') {
                    $r = New-TestResult -Dn $ObjectDN -Sid $AccessRule.IdentityReference
                    $r.VerificationStatus = 'Unverified'
                    $r
                }
            }

            $results = @(Find-OrphanedSIDsInObject -ADObject (New-TestObject -Dn $script:dnA))

            $results.Count | Should -Be 1
            $results[0].ProcessingStatistics.UnverifiedSIDsFound | Should -Be 1
            $results[0].ProcessingStatistics.OrphanedSIDsFound | Should -Be 0
        }

        It 'Returns nothing for an object with no orphaned rules' {
            Mock Test-AccessRuleForOrphanedSID { $null }

            $results = @(Find-OrphanedSIDsInObject -ADObject (New-TestObject -Dn $script:dnA))

            $results.Count | Should -Be 0
        }

        It 'Processes every object when several arrive by parameter' {
            $results = @(Find-OrphanedSIDsInObject -ADObject (New-TestObject -Dn $script:dnA), (New-TestObject -Dn $script:dnB))

            $results.Count | Should -Be 2
            $results.ObjectDN | Should -Be @($script:dnA, $script:dnB)
            Should -Invoke Get-ObjectAccessRule -Times 2 -Exactly
        }

        It 'Processes every object from the pipeline' {
            $results = @((New-TestObject -Dn $script:dnA), (New-TestObject -Dn $script:dnB) | Find-OrphanedSIDsInObject)

            $results.Count | Should -Be 2
        }
    }

    Context 'Objects it skips' {
        It 'Skips an error object from the pipeline and keeps going' {
            $errorObject = [PSCustomObject]@{ IsError = $true; ErrorMessage = 'search base not found' }

            $results = @(Find-OrphanedSIDsInObject -ADObject $errorObject, (New-TestObject -Dn $script:dnB))

            $results.Count | Should -Be 1
            $results[0].ObjectDN | Should -Be $script:dnB
            Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Message -eq 'Skipping error object: search base not found' }
        }

        It 'Skips an object without a distinguished name' {
            $results = @(Find-OrphanedSIDsInObject -ADObject ([PSCustomObject]@{ Name = 'nameless' }))

            $results.Count | Should -Be 0
            Should -Invoke Get-ObjectAccessRule -Times 0 -Exactly
            Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Message -like 'Object missing DistinguishedName*' }
        }

        It 'Skips an object without a security descriptor and still processes the next' {
            $results = @(Find-OrphanedSIDsInObject -ADObject (New-TestObject -Dn $script:dnA -NoDescriptor), (New-TestObject -Dn $script:dnB))

            $results.Count | Should -Be 1
            $results[0].ObjectDN | Should -Be $script:dnB
            Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Message -eq "No security descriptor found for $($script:dnA)" }
        }

        It 'Returns nothing when no access rules come back' {
            Mock Get-ObjectAccessRule { $null }

            $results = @(Find-OrphanedSIDsInObject -ADObject (New-TestObject -Dn $script:dnA))

            $results.Count | Should -Be 0
            Should -Invoke Test-AccessRuleForOrphanedSID -Times 0 -Exactly
        }
    }

    Context 'Failures' {
        It 'Warns about a rule that cannot be evaluated and evaluates the rest' {
            Mock Test-AccessRuleForOrphanedSID {
                if ($AccessRule.IdentityReference -eq 'NT AUTHORITY\SYSTEM') { throw 'resolver unavailable' }
                if ($AccessRule.IdentityReference -like '*-9001') { New-TestResult -Dn $ObjectDN -Sid $AccessRule.IdentityReference }
            }

            $results = @(Find-OrphanedSIDsInObject -ADObject (New-TestObject -Dn $script:dnA))

            $results.Count | Should -Be 1
            $results[0].ProcessingStatistics.ErrorsEncountered | Should -Be 1
            $results[0].ProcessingStatistics.ProcessedSIDs | Should -Be 2
            Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Level -eq 'Warning' -and $Message -like '*resolver unavailable*' }
        }

        It 'Logs at Error level and returns nothing when the access rules cannot be read' {
            Mock Get-ObjectAccessRule { throw 'descriptor unreadable' }

            $results = @(Find-OrphanedSIDsInObject -ADObject (New-TestObject -Dn $script:dnA) -CorrelationId 'det-2')

            $results.Count | Should -Be 0
            Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter {
                $Level -eq 'Error' -and $Message -like "*$($script:dnA)*descriptor unreadable*" -and $CorrelationId -eq 'det-2'
            }
        }
    }
}
