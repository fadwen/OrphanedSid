#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
#Requires -Version 5.1

<#
.SYNOPSIS
    Unit tests for Assert-DistinguishedNameInput, the check of a public command's collected input.

.DESCRIPTION
    Tests the real function. It calls nothing else, so nothing is mocked.
#>

BeforeAll {
    # As OrphanedSid.psm1 does: in the module the code under test runs under strict mode
    Set-StrictMode -Version Latest

    . "$PSScriptRoot\..\..\..\..\Private\Utilities\Assert-DistinguishedNameInput.ps1"
}

Describe 'Assert-DistinguishedNameInput' -Tag 'Unit', 'Utilities', 'Private' {

    Context 'Parameter Validation' {
        It 'Rejects an input kind it does not know' {
            { Assert-DistinguishedNameInput -DistinguishedName 'OU=A,DC=contoso,DC=com' -InputKind 'Group' } |
                Should -Throw -ExpectedMessage "*Cannot validate argument on parameter 'InputKind'*"
        }
    }

    Context 'Core Functionality' {
        It 'Returns nothing and raises nothing for <InputKind> when a name is given' -ForEach @(
            @{ InputKind = 'SearchBase' }
            @{ InputKind = 'RestoreTarget' }
        ) {
            $result = @(Assert-DistinguishedNameInput -DistinguishedName 'OU=A,DC=contoso,DC=com' -InputKind $InputKind -ErrorAction Stop)

            $result.Count | Should -Be 0
        }

        It 'Takes the list that a public command collects its names in' {
            $names = [System.Collections.Generic.List[string]]::new()
            $names.Add('OU=A,DC=contoso,DC=com')
            $names.Add('OU=B,DC=contoso,DC=com')

            $result = @(Assert-DistinguishedNameInput -DistinguishedName $names -InputKind SearchBase -ErrorAction Stop)

            $result.Count | Should -Be 0
        }
    }

    Context 'Error Handling' {
        It 'Ends with <ErrorId> for an empty <InputKind> list' -ForEach @(
            @{ InputKind = 'SearchBase'; ErrorId = 'SearchBaseNotUsable'; Message = 'No usable search base in the input.*-SearchBase is not given at all.' }
            @{ InputKind = 'RestoreTarget'; ErrorId = 'RestoreTargetNotUsable'; Message = 'No usable restore target in the input.*DistinguishedName property.' }
        ) {
            $empty = [System.Collections.Generic.List[string]]::new()

            $expected = @{
                ErrorId         = "$ErrorId,Assert-DistinguishedNameInput"
                ExpectedMessage = $Message
                ExceptionType   = [System.ArgumentException]
            }
            { Assert-DistinguishedNameInput -DistinguishedName $empty -InputKind $InputKind } | Should -Throw @expected
        }

        It 'Reports the category InvalidArgument' {
            $caught = $null
            try {
                Assert-DistinguishedNameInput -DistinguishedName @() -InputKind SearchBase
            } catch {
                $caught = $_
            }

            $caught | Should -Not -BeNullOrEmpty
            $caught.CategoryInfo.Category | Should -Be 'InvalidArgument'
        }

        It 'Is not silenced by -ErrorAction SilentlyContinue' {
            { Assert-DistinguishedNameInput -DistinguishedName @() -InputKind RestoreTarget -ErrorAction SilentlyContinue } |
                Should -Throw -ErrorId 'RestoreTargetNotUsable,Assert-DistinguishedNameInput'
        }
    }
}
