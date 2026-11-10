#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
#Requires -Version 5.1

<#
.SYNOPSIS
    Unit tests for Invoke-SIDRemoval, which strips the allowed orphaned SIDs out of an ACL object.

.DESCRIPTION
    Tests the real function against an ACL double: an object with an Access collection of ACEs and a
    RemoveAccessRuleSpecific method that removes from that collection and records the call, which is
    all the function uses of System.DirectoryServices.ActiveDirectorySecurity.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\..\Private\ACL\Invoke-SIDRemoval.ps1"

    function Write-StructuredLog { param($Message, $Level, $Component, $CorrelationId, $LogPath, $Data) }

    function New-TestAce {
        param([string]$Sid, [string]$Rights = 'GenericRead')
        [PSCustomObject]@{
            IdentityReference     = [PSCustomObject]@{ Value = $Sid }
            ActiveDirectoryRights = $Rights
        }
    }

    # An ACL double. $FailFor names SIDs whose removal throws, to drive the per-ACE catch.
    function New-TestAcl {
        param([object[]]$Aces, [string[]]$FailFor = @())
        $acl = [PSCustomObject]@{
            Access  = [System.Collections.ArrayList]::new($Aces)
            Removed = [System.Collections.Generic.List[string]]::new()
            FailFor = $FailFor
        }
        $acl | Add-Member -MemberType ScriptMethod -Name RemoveAccessRuleSpecific -Value {
            param($Ace)
            if ($this.FailFor -contains $Ace.IdentityReference.Value) { throw "Access is denied for $($Ace.IdentityReference.Value)" }
            $this.Removed.Add($Ace.IdentityReference.Value)
            $this.Access.Remove($Ace)
        }
        return $acl
    }

    $script:orphan1 = 'S-1-5-21-111-222-333-9001'
    $script:orphan2 = 'S-1-5-21-111-222-333-9002'
    $script:keep = 'S-1-5-21-111-222-333-1105'
    $script:dn = 'CN=Finance Share,OU=Groups,DC=contoso,DC=com'
}

Describe 'Invoke-SIDRemoval' -Tag 'Unit', 'ACL', 'Private' {

    BeforeEach {
        Mock Write-StructuredLog { }
        $script:acl = New-TestAcl -Aces @(
            (New-TestAce -Sid $script:keep -Rights 'GenericAll')
            (New-TestAce -Sid $script:orphan1)
            (New-TestAce -Sid $script:orphan2 -Rights 'WriteProperty')
        )
    }

    Context 'Parameter validation' {
        It 'Rejects a null ACL' {
            { Invoke-SIDRemoval -ACL $null -AllowedSIDs $script:orphan1 } | Should -Throw
        }

        It 'Rejects an empty allowed list' {
            { Invoke-SIDRemoval -ACL $script:acl -AllowedSIDs @() } | Should -Throw
        }

        It 'Throws for a SID that is not in S-x-y-z form' {
            { Invoke-SIDRemoval -ACL $script:acl -AllowedSIDs 'CONTOSO\Finance' } |
                Should -Throw -ExpectedMessage '*Invalid SID format: CONTOSO\Finance*'
            $script:acl.Removed.Count | Should -Be 0
        }

        It 'Throws for an object that is not an ACL' {
            $notAnAcl = [PSCustomObject]@{ InvalidProperty = 1 }

            { Invoke-SIDRemoval -ACL $notAnAcl -AllowedSIDs $script:orphan1 } |
                Should -Throw -ExpectedMessage '*must have Access property*'
        }

        It 'Treats an object without an Access collection as an empty ACL' {
            $bare = [PSCustomObject]@{ Owner = 'CONTOSO\Domain Admins' }

            $result = Invoke-SIDRemoval -ACL $bare -AllowedSIDs $script:orphan1

            $result.Success | Should -BeTrue
            $result.SIDFound | Should -BeFalse
            $result.RulesProcessed | Should -Be 0
            @($bare.Access).Count | Should -Be 0
        }
    }

    Context 'Removing orphaned entries' {
        It 'Removes every ACE whose identity is in the allowed list and keeps the rest' {
            $result = Invoke-SIDRemoval -ACL $script:acl -AllowedSIDs $script:orphan1, $script:orphan2 -ObjectDN $script:dn -CorrelationId 'rm-1'

            $result.PSTypeNames | Should -Contain 'SIDRemovalResult'
            $result.Success | Should -BeTrue
            $result.SIDFound | Should -BeTrue
            $result.RemovedSIDs | Should -Be @($script:orphan1, $script:orphan2)
            $result.FoundSIDs | Should -Be @($script:orphan1, $script:orphan2)
            $result.FailedSIDs | Should -BeNullOrEmpty
            $result.RulesFound | Should -Be 2
            $result.RulesRemoved | Should -Be 2
            $result.RulesProcessed | Should -Be 3
            $result.PreservedSIDs | Should -Be @($script:keep)
            $result.DryRun | Should -BeFalse
            $result.CorrelationId | Should -Be 'rm-1'
            $result.ModifiedACL | Should -Be $script:acl
            $script:acl.Removed | Should -Be @($script:orphan1, $script:orphan2)
            @($script:acl.Access).Count | Should -Be 1
        }

        It 'Leaves an ACL alone when none of the allowed SIDs appear in it' {
            $result = Invoke-SIDRemoval -ACL $script:acl -AllowedSIDs 'S-1-5-21-111-222-333-7777'

            $result.Success | Should -BeTrue
            $result.SIDFound | Should -BeFalse
            $result.RulesFound | Should -Be 0
            $result.RemovedSIDs | Should -BeNullOrEmpty
            $result.PreservedSIDs.Count | Should -Be 3
            $script:acl.Removed.Count | Should -Be 0
        }

        It 'Removes only the allowed SIDs, not every unresolved one' {
            $result = Invoke-SIDRemoval -ACL $script:acl -AllowedSIDs $script:orphan2

            $result.RemovedSIDs | Should -Be @($script:orphan2)
            $result.PreservedSIDs | Should -Be @($script:keep, $script:orphan1)
        }

        It 'Reports a SID once when it holds several ACEs' {
            $acl = New-TestAcl -Aces @(
                (New-TestAce -Sid $script:orphan1 -Rights 'GenericRead')
                (New-TestAce -Sid $script:orphan1 -Rights 'WriteProperty')
            )

            $result = Invoke-SIDRemoval -ACL $acl -AllowedSIDs $script:orphan1

            $result.RemovedSIDs | Should -Be @($script:orphan1)
            $result.RulesRemoved | Should -Be 1
            $acl.Removed.Count | Should -Be 2
            @($acl.Access).Count | Should -Be 0
        }

        It 'Logs each removal at Verbose level with the rights it carried' {
            Invoke-SIDRemoval -ACL $script:acl -AllowedSIDs $script:orphan2 -CorrelationId 'rm-2' | Out-Null

            Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter {
                $Level -eq 'Verbose' -and $Message -like "REMOVED ACE: $($script:orphan2) - WriteProperty" -and $CorrelationId -eq 'rm-2'
            }
        }
    }

    Context 'WhatIf mode' {
        It 'Reports what it would remove and changes nothing' {
            $result = Invoke-SIDRemoval -ACL $script:acl -AllowedSIDs $script:orphan1, $script:orphan2 -WhatIfMode

            $result.DryRun | Should -BeTrue
            $result.SIDFound | Should -BeTrue
            $result.FoundSIDs | Should -Be @($script:orphan1, $script:orphan2)
            $result.RemovedSIDs | Should -BeNullOrEmpty
            $result.RulesRemoved | Should -Be 0
            $result.Success | Should -BeTrue
            $script:acl.Removed.Count | Should -Be 0
            @($script:acl.Access).Count | Should -Be 3
            Should -Invoke Write-StructuredLog -Times 2 -Exactly -ParameterFilter { $Message -like 'WOULD REMOVE ACE:*' }
        }
    }

    Context 'Failures during removal' {
        It 'Records a SID whose removal threw and carries on with the others' {
            $acl = New-TestAcl -FailFor $script:orphan1 -Aces @(
                (New-TestAce -Sid $script:keep)
                (New-TestAce -Sid $script:orphan1)
                (New-TestAce -Sid $script:orphan2)
            )

            $result = Invoke-SIDRemoval -ACL $acl -AllowedSIDs $script:orphan1, $script:orphan2

            $result.Success | Should -BeFalse
            $result.PartialSuccess | Should -BeTrue
            $result.FailedSIDs | Should -Be @($script:orphan1)
            $result.RemovedSIDs | Should -Be @($script:orphan2)
            $result.ErrorMessage | Should -Be 'Access denied during removal'
            Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter {
                $Level -eq 'Error' -and $Message -like "FAILED to process SID $($script:orphan1)*denied*"
            }
        }

        It 'Reports no partial success when every removal failed' {
            $acl = New-TestAcl -FailFor $script:orphan1, $script:orphan2 -Aces @(
                (New-TestAce -Sid $script:orphan1)
                (New-TestAce -Sid $script:orphan2)
            )

            $result = Invoke-SIDRemoval -ACL $acl -AllowedSIDs $script:orphan1, $script:orphan2

            $result.Success | Should -BeFalse
            $result.PartialSuccess | Should -BeFalse
            $result.FailedSIDs.Count | Should -Be 2
            $result.RemovedSIDs | Should -BeNullOrEmpty
        }
    }
}
