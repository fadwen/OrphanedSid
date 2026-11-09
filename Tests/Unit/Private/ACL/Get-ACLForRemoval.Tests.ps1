#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
#Requires -Version 5.1

<#
.SYNOPSIS
    Unit tests for Get-ACLForRemoval, which reads an object's ACL through the retry wrapper.

.DESCRIPTION
    Tests the real function. Test-ValidDistinguishedName, Invoke-ADOperationWithRetry, Get-Acl and
    Write-StructuredLog are mocked. The earlier version of this file defined its own
    Get-ACLForRemoval and tested that.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\TestHelpers\ADCmdletStubs.ps1"
    . "$PSScriptRoot\..\..\..\..\Private\ACL\Get-ACLForRemoval.ps1"

    function Write-StructuredLog { param($Message, $Level, $Component, $CorrelationId, $LogPath, $Data) }
    function Test-ValidDistinguishedName { param($DistinguishedName, $CorrelationId) }
    function Invoke-ADOperationWithRetry { param([scriptblock]$ScriptBlock, $MaxRetries, $OperationName, $ObjectContext, $CorrelationId) }

    $script:dn = 'CN=Finance Share,OU=Groups,DC=contoso,DC=com'
    $script:acl = [PSCustomObject]@{
        Owner  = 'CONTOSO\Domain Admins'
        Access = @(
            [PSCustomObject]@{ IdentityReference = 'CONTOSO\Finance' }
            [PSCustomObject]@{ IdentityReference = 'S-1-5-21-1-2-3-9001' }
        )
    }
}

Describe 'Get-ACLForRemoval' -Tag 'Unit', 'ACL', 'Private' {

    BeforeEach {
        Mock Write-StructuredLog { }
        Mock Test-ValidDistinguishedName { $true }
        Mock Invoke-ADOperationWithRetry { & $ScriptBlock }
        Mock Get-Acl { $script:acl }
    }

    Context 'Parameter validation' {
        It 'Rejects an empty distinguished name' {
            { Get-ACLForRemoval -ObjectDistinguishedName '' } | Should -Throw
        }

        It 'Throws for a whitespace distinguished name' {
            { Get-ACLForRemoval -ObjectDistinguishedName '  ' } |
                Should -Throw -ExpectedMessage '*cannot be empty or whitespace*'
        }

        It 'Throws for a path traversal' {
            { Get-ACLForRemoval -ObjectDistinguishedName 'CN=..\Admins,DC=contoso,DC=com' } |
                Should -Throw -ExpectedMessage '*Path traversal detected*'
            Should -Invoke Get-Acl -Times 0 -Exactly
        }

        It 'Throws for a filesystem path offered as a distinguished name' {
            { Get-ACLForRemoval -ObjectDistinguishedName 'C:\Windows\System32' } |
                Should -Throw -ExpectedMessage '*got filesystem path*'
        }

        It 'Throws when the target does not exist' {
            Mock Test-ValidDistinguishedName { $false }

            { Get-ACLForRemoval -ObjectDistinguishedName $script:dn } |
                Should -Throw -ExpectedMessage '*Target path not found*'
            Should -Invoke Get-Acl -Times 0 -Exactly
        }
    }

    Context 'Reading the ACL' {
        It 'Returns the ACL read from the AD: drive path of the object' {
            $result = Get-ACLForRemoval -ObjectDistinguishedName $script:dn -CorrelationId 'read-1'

            $result | Should -Be $script:acl
            Should -Invoke Get-Acl -Times 1 -Exactly -ParameterFilter { $Path -eq "AD:\$($script:dn)" }
            Should -Invoke Test-ValidDistinguishedName -Times 1 -Exactly -ParameterFilter {
                $DistinguishedName -eq $script:dn -and $CorrelationId -eq 'read-1'
            }
        }

        It 'Trims the distinguished name before building the path' {
            Get-ACLForRemoval -ObjectDistinguishedName "  $($script:dn) " | Out-Null

            Should -Invoke Get-Acl -Times 1 -Exactly -ParameterFilter { $Path -eq "AD:\$($script:dn)" }
        }

        It 'Reads through the retry wrapper with three attempts' {
            Get-ACLForRemoval -ObjectDistinguishedName $script:dn | Out-Null

            Should -Invoke Invoke-ADOperationWithRetry -Times 1 -Exactly -ParameterFilter {
                $MaxRetries -eq 3 -and $OperationName -eq 'Get-ACL' -and $ObjectContext -eq $script:dn
            }
        }

        It 'Logs the number of access rules it read' {
            Get-ACLForRemoval -ObjectDistinguishedName $script:dn -CorrelationId 'read-2' | Out-Null

            Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter {
                $Level -eq 'Verbose' -and $Message -like '*Access rules: 2*' -and $CorrelationId -eq 'read-2'
            }
        }
    }

    Context 'Failures' {
        It 'Throws when the read returns nothing' {
            Mock Get-Acl { $null }

            { Get-ACLForRemoval -ObjectDistinguishedName $script:dn } |
                Should -Throw -ExpectedMessage '*Failed to retrieve ACL*'
        }

        It 'Rethrows a read failure after logging it at Error level' {
            Mock Get-Acl { throw 'Access is denied' }

            { Get-ACLForRemoval -ObjectDistinguishedName $script:dn -CorrelationId 'read-3' } |
                Should -Throw -ExpectedMessage '*Access is denied*'
            Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter {
                $Level -eq 'Error' -and $Message -like '*Access is denied*' -and $CorrelationId -eq 'read-3'
            }
        }
    }
}
