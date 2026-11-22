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
    # As OrphanedSid.psm1 does: in the module the code under test runs under strict mode
    Set-StrictMode -Version Latest

    . "$PSScriptRoot\..\..\..\..\Private\ACL\Invoke-SIDRemoval.ps1"
    . "$PSScriptRoot\..\..\..\..\Private\ACL\Get-AclAccessRule.ps1"

    function Write-StructuredLog { param($Message, $Level, $Component, $CorrelationId, $LogPath, $Data) }

    function New-TestAce {
        param([string]$Sid, [string]$Rights = 'GenericRead', [switch]$Inherited)
        [PSCustomObject]@{
            IdentityReference     = [PSCustomObject]@{ Value = $Sid }
            ActiveDirectoryRights = $Rights
            IsInherited           = [bool]$Inherited
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
            $expected = @{
                ErrorId         = 'SidFormatInvalid,Invoke-SIDRemoval'
                ExpectedMessage = '*Invalid SID format: CONTOSO\Finance*'
                ExceptionType   = [System.ArgumentException]
            }
            { Invoke-SIDRemoval -ACL $script:acl -AllowedSIDs 'CONTOSO\Finance' } | Should -Throw @expected
            $script:acl.Removed.Count | Should -Be 0
        }

        It 'Throws for an ACL argument that holds no object' {
            # An empty string passes ValidateNotNull and is still no ACL
            { Invoke-SIDRemoval -ACL '' -AllowedSIDs $script:orphan1 } |
                Should -Throw -ErrorId 'AclMissing,Invoke-SIDRemoval' -ExpectedMessage 'ACL parameter cannot be null or empty.'
        }

        It 'Throws for an object whose access rules cannot be read, and adds nothing to it (#121)' {
            $bare = [PSCustomObject]@{ Owner = 'CONTOSO\Domain Admins' }

            # The catch of the function logs the error and raises it again, so the error ID keeps
            # its first part and ends in the name of this function
            { Invoke-SIDRemoval -ACL $bare -AllowedSIDs $script:orphan1 } |
                Should -Throw -ErrorId 'AclAccessRulesUnavailable,Invoke-SIDRemoval'

            $bare.PSObject.Properties['Access'] | Should -BeNullOrEmpty
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Error' -and $Message -like 'Error in ACL SID removal processing:*'
            }
        }

        It 'Removes the entry from a real security descriptor in a runspace that a host created (#121)' {
            # On PowerShell 7 an ACL object has no Access property in such a runspace. The function
            # used to read that property, find no rules, and report success with nothing removed.
            $root = (Resolve-Path -LiteralPath "$PSScriptRoot\..\..\..\..").Path
            $inRunspace = {
                param($Root, $Orphan)
                function Write-StructuredLog { param($Message, $Level, $Component, $CorrelationId, $LogPath, $Data) }
                . (Join-Path $Root 'Private\ACL\Get-AclAccessRule.ps1')
                . (Join-Path $Root 'Private\ACL\Invoke-SIDRemoval.ps1')
                $acl = [System.DirectoryServices.ActiveDirectorySecurity]::new()
                $acl.SetSecurityDescriptorSddlForm("O:BAG:BAD:(A;;GA;;;BA)(A;;RPWP;;;$Orphan)")
                $result = Invoke-SIDRemoval -ACL $acl -AllowedSIDs $Orphan -ObjectDN 'OU=Test,DC=contoso,DC=com'
                $remaining = $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])
                [PSCustomObject]@{
                    Removed   = @($result.RemovedSIDs)
                    Remaining = @($remaining | ForEach-Object { $_.IdentityReference.Value })
                }
            }
            $shell = [powershell]::Create()
            try {
                $run = $shell.AddScript($inRunspace.ToString()).AddArgument($root).AddArgument($script:orphan1).Invoke()
                $failures = @($shell.Streams.Error | ForEach-Object { "$_" })
            }
            finally {
                $shell.Dispose()
            }

            $failures | Should -BeNullOrEmpty
            @($run).Count | Should -Be 1
            @($run[0].Removed) | Should -Be @($script:orphan1)
            @($run[0].Remaining) | Should -Be @('S-1-5-32-544')
        }
    }

    Context 'Removing orphaned entries' {
        It 'Removes every ACE whose identity is in the allowed list and keeps the rest' {
            $result = Invoke-SIDRemoval -ACL $script:acl -AllowedSIDs $script:orphan1, $script:orphan2 -ObjectDN $script:dn -CorrelationId 'rm-1'

            $result.PSTypeNames | Should -Contain 'SIDRemovalResult'
            $result.Success | Should -BeTrue
            $result.RemovedSIDs | Should -Be @($script:orphan1, $script:orphan2)
            $result.FoundSIDs | Should -Be @($script:orphan1, $script:orphan2)
            $result.FailedSIDs | Should -BeNullOrEmpty
            $result.ErrorMessage | Should -BeNullOrEmpty
            $result.ModifiedACL | Should -Be $script:acl
            $script:acl.Removed | Should -Be @($script:orphan1, $script:orphan2)
            @($script:acl.Access).Count | Should -Be 1
            @($script:acl.Access)[0].IdentityReference.Value | Should -Be $script:keep
        }

        It 'Returns the fields that the workflow reads and that it found out, and no other (#157)' {
            # The result once carried a fixed duration of 100 milliseconds, fixed memory figures,
            # a sentence that the removal had completed successfully also when it had not, and
            # several fields under two names
            $result = Invoke-SIDRemoval -ACL $script:acl -AllowedSIDs $script:orphan1 -ObjectDN $script:dn

            $expected = 'ErrorMessage', 'FailedSIDs', 'FoundSIDs', 'ModifiedACL', 'RemovedSIDs', 'Success'
            @($result.PSObject.Properties.Name | Sort-Object) | Should -Be $expected
        }

        It 'Leaves an ACL alone when none of the allowed SIDs appear in it' {
            $result = Invoke-SIDRemoval -ACL $script:acl -AllowedSIDs 'S-1-5-21-111-222-333-7777'

            $result.Success | Should -BeTrue
            $result.FoundSIDs | Should -BeNullOrEmpty
            $result.RemovedSIDs | Should -BeNullOrEmpty
            $script:acl.Removed.Count | Should -Be 0
            @($script:acl.Access).Count | Should -Be 3
        }

        It 'Removes only the allowed SIDs, not every unresolved one' {
            $result = Invoke-SIDRemoval -ACL $script:acl -AllowedSIDs $script:orphan2

            $result.RemovedSIDs | Should -Be @($script:orphan2)
            @($script:acl.Access | ForEach-Object { $_.IdentityReference.Value }) |
                Should -Be @($script:keep, $script:orphan1)
        }

        It 'Reports a SID once when it holds several ACEs' {
            $acl = New-TestAcl -Aces @(
                (New-TestAce -Sid $script:orphan1 -Rights 'GenericRead')
                (New-TestAce -Sid $script:orphan1 -Rights 'WriteProperty')
            )

            $result = Invoke-SIDRemoval -ACL $acl -AllowedSIDs $script:orphan1

            $result.RemovedSIDs | Should -Be @($script:orphan1)
            $result.FoundSIDs | Should -Be @($script:orphan1)
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

    Context 'Inherited entries' {
        It 'Neither removes nor counts an inherited entry, which belongs to a parent object (#46)' {
            $acl = New-TestAcl -Aces @(
                (New-TestAce -Sid $script:orphan1 -Inherited)
                (New-TestAce -Sid $script:orphan2)
            )

            $result = Invoke-SIDRemoval -ACL $acl -AllowedSIDs $script:orphan1, $script:orphan2 -ObjectDN $script:dn

            @($result.RemovedSIDs) | Should -Be @($script:orphan2)
            @($acl.Removed) | Should -Be @($script:orphan2)
            @($acl.Access | Where-Object { $_.IdentityReference.Value -eq $script:orphan1 }).Count | Should -Be 1
        }
    }

    Context 'WhatIf mode' {
        It 'Reports what it would remove and changes nothing' {
            $result = Invoke-SIDRemoval -ACL $script:acl -AllowedSIDs $script:orphan1, $script:orphan2 -WhatIfMode

            $result.FoundSIDs | Should -Be @($script:orphan1, $script:orphan2)
            $result.RemovedSIDs | Should -BeNullOrEmpty
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
            $result.FailedSIDs | Should -Be @($script:orphan1)
            $result.RemovedSIDs | Should -Be @($script:orphan2)
            # The message of the error that was caught, with the SID it was caught for. It was
            # the fixed text 'Access denied during removal', whatever the error had been.
            $result.ErrorMessage | Should -BeLike "$($script:orphan1): *denied*"
            $result.ErrorMessage | Should -Not -BeLike "*$($script:orphan2)*"
            Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter {
                $Level -eq 'Error' -and $Message -like "FAILED to process SID $($script:orphan1)*denied*"
            }
        }

        It 'Reports every SID with its own error when every removal failed' {
            $acl = New-TestAcl -FailFor $script:orphan1, $script:orphan2 -Aces @(
                (New-TestAce -Sid $script:orphan1)
                (New-TestAce -Sid $script:orphan2)
            )

            $result = Invoke-SIDRemoval -ACL $acl -AllowedSIDs $script:orphan1, $script:orphan2

            $result.Success | Should -BeFalse
            $result.FailedSIDs.Count | Should -Be 2
            $result.RemovedSIDs | Should -BeNullOrEmpty
            $messages = @($result.ErrorMessage -split '; ')
            $messages.Count | Should -Be 2
            $messages[0] | Should -BeLike "$($script:orphan1): *"
            $messages[1] | Should -BeLike "$($script:orphan2): *"
        }
    }
}
