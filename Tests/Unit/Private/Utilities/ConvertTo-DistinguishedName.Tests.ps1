#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }

<#
.SYNOPSIS
    Unit tests for ConvertTo-DistinguishedName.

.DESCRIPTION
    The function reads the DN out of whatever a public command received for -SearchBase or
    -TargetObjectDN. The cases are the shapes operators pipe: strings, Active Directory objects,
    Import-Csv rows and hashtables, plus input that holds no DN at all.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\..\Private\Utilities\ConvertTo-DistinguishedName.ps1"
}

Describe 'ConvertTo-DistinguishedName' -Tag 'Unit', 'Private' {

    Context 'Strings' {
        It 'Trims a DN string' {
            ConvertTo-DistinguishedName -InputObject '  OU=A,DC=contoso,DC=com ' | Should -BeExactly 'OU=A,DC=contoso,DC=com'
        }

        It 'Drops blank and null entries' {
            $result = @(ConvertTo-DistinguishedName -InputObject 'OU=A,DC=contoso,DC=com', '', '   ', $null)

            $result.Count | Should -Be 1
            $result[0] | Should -BeExactly 'OU=A,DC=contoso,DC=com'
        }

        It 'Returns nothing for no input' {
            @(ConvertTo-DistinguishedName).Count | Should -Be 0
            @(ConvertTo-DistinguishedName -InputObject $null).Count | Should -Be 0
        }
    }

    Context 'Objects' {
        It 'Reads DistinguishedName from an object whose other properties answer any name' {
            # The AD adapter returns an empty collection for SearchBase and TargetObjectDN
            $adLike = [PSCustomObject]@{
                SearchBase        = [System.Collections.Generic.List[object]]::new()
                TargetObjectDN    = [System.Collections.Generic.List[object]]::new()
                DistinguishedName = 'OU=FromAD,DC=contoso,DC=com'
            }

            ConvertTo-DistinguishedName -InputObject $adLike | Should -BeExactly 'OU=FromAD,DC=contoso,DC=com'
        }

        It 'Reads the DistinguishedName column of an Import-Csv row' {
            $row = 'ObjectDN,DistinguishedName', 'x," CN=Row,DC=contoso,DC=com "' | ConvertFrom-Csv

            ConvertTo-DistinguishedName -InputObject $row | Should -BeExactly 'CN=Row,DC=contoso,DC=com'
        }

        It 'Reads the DistinguishedName key of a hashtable' {
            ConvertTo-DistinguishedName -InputObject @{ DistinguishedName = 'OU=Hash,DC=contoso,DC=com' } |
                Should -BeExactly 'OU=Hash,DC=contoso,DC=com'
        }

        It 'Takes the first value of a DistinguishedName held in a collection' {
            $wrapped = [PSCustomObject]@{ DistinguishedName = [System.Collections.Generic.List[object]]@('OU=Wrapped,DC=contoso,DC=com') }

            ConvertTo-DistinguishedName -InputObject $wrapped | Should -BeExactly 'OU=Wrapped,DC=contoso,DC=com'
        }

        It 'Keeps the order of mixed input' {
            $mixed = @('OU=1,DC=c', [PSCustomObject]@{ DistinguishedName = 'OU=2,DC=c' }, @{ DistinguishedName = 'OU=3,DC=c' })
            $result = @(ConvertTo-DistinguishedName -InputObject $mixed)

            $result | Should -Be @('OU=1,DC=c', 'OU=2,DC=c', 'OU=3,DC=c')
        }
    }

    Context 'Input that holds no DN' {
        It 'Writes a non-terminating error naming the type, and skips the item' {
            $result = @(ConvertTo-DistinguishedName -InputObject ([PSCustomObject]@{ Name = 'x' }), 'OU=Kept,DC=c' -ErrorAction SilentlyContinue -ErrorVariable errors)

            $result | Should -Be @('OU=Kept,DC=c')
            @($errors).Count | Should -Be 1
            $errors[0].FullyQualifiedErrorId | Should -BeLike 'NotADistinguishedName*'
            $errors[0].Exception.Message | Should -BeLike '*System.Management.Automation.PSCustomObject*no DistinguishedName property*'
        }

        It 'Reports a hashtable without the key' {
            $result = @(ConvertTo-DistinguishedName -InputObject @{ Name = 'x' } -ErrorAction SilentlyContinue -ErrorVariable errors)

            $result.Count | Should -Be 0
            @($errors).Count | Should -Be 1
        }

        It 'Drops an object whose DistinguishedName is blank without an error' {
            $result = @(ConvertTo-DistinguishedName -InputObject ([PSCustomObject]@{ DistinguishedName = '  ' }) -ErrorAction SilentlyContinue -ErrorVariable errors)

            $result.Count | Should -Be 0
            @($errors).Count | Should -Be 0
        }
    }
}
