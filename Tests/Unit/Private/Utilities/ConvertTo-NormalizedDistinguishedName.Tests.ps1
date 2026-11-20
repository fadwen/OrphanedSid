#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
#Requires -Version 5.1

<#
.SYNOPSIS
    Unit tests for ConvertTo-NormalizedDistinguishedName, which removes the blanks around the
    separators of a distinguished name.

.DESCRIPTION
    Tests the real function. It calls nothing else, so nothing is mocked.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\..\Private\Utilities\ConvertTo-NormalizedDistinguishedName.ps1"
}

Describe 'ConvertTo-NormalizedDistinguishedName' -Tag 'Unit', 'Utilities', 'Private' {

    Context 'Parameter Validation' {
        It 'Returns an empty string for an empty string' {
            ConvertTo-NormalizedDistinguishedName -DistinguishedName '' | Should-BeString '' -CaseSensitive
        }

        It 'Returns one string, also for text with a component that is not attribute=value' {
            # The components that were made before the bad one must not come out as well
            $typed = 'CN=Alice, OU=Sales,,DC=contoso,DC=com'

            $result = @(ConvertTo-NormalizedDistinguishedName -DistinguishedName $typed)

            $result | Should-BeCollection -Count 1
            $result[0] | Should-BeString $typed -CaseSensitive
        }
    }

    Context 'Core Functionality' {
        It 'Returns <Expected> for <Name>' -ForEach @(
            @{ Name = 'CN=Alice,OU=Sales,DC=contoso,DC=com'; Expected = 'CN=Alice,OU=Sales,DC=contoso,DC=com' }
            @{ Name = 'CN=Alice, OU=Sales, DC=contoso, DC=com'; Expected = 'CN=Alice,OU=Sales,DC=contoso,DC=com' }
            @{ Name = 'CN =Alice,OU=Sales,DC=contoso,DC=com'; Expected = 'CN=Alice,OU=Sales,DC=contoso,DC=com' }
            @{
                Name = '  CN = Alice , OU = Sales , DC = contoso , DC = com  '
                Expected = 'CN=Alice,OU=Sales,DC=contoso,DC=com'
            }
            @{ Name = 'DC=corp'; Expected = 'DC=corp' }
            @{
                Name = 'OID.2.5.4.11 = Sales, DC=contoso,DC=com'
                Expected = 'OID.2.5.4.11=Sales,DC=contoso,DC=com'
            }
        ) {
            ConvertTo-NormalizedDistinguishedName -DistinguishedName $Name |
                Should-BeString $Expected -CaseSensitive
        }

        It 'Leaves the letter case as it was typed' {
            ConvertTo-NormalizedDistinguishedName -DistinguishedName 'cn=alice, ou=SALES,dc=Contoso,dc=com' |
                Should-BeString 'cn=alice,ou=SALES,dc=Contoso,dc=com' -CaseSensitive
        }

        It 'Leaves the blanks inside a value alone' {
            $typed = 'OU = Domain  Controllers , DC=contoso,DC=com'

            ConvertTo-NormalizedDistinguishedName -DistinguishedName $typed |
                Should-BeString 'OU=Domain  Controllers,DC=contoso,DC=com' -CaseSensitive
        }

        It 'Takes only the first equals sign of a component as the separator' {
            ConvertTo-NormalizedDistinguishedName -DistinguishedName 'CN = a = b , DC=contoso,DC=com' |
                Should-BeString 'CN=a = b,DC=contoso,DC=com' -CaseSensitive
        }
    }

    Context 'Escaped characters' {
        It 'Keeps <Case>' -ForEach @(
            @{
                Case = 'an escaped comma inside one component'
                Name = 'CN=Doe\, Jane , OU=Staff, DC=contoso,DC=com'
                Expected = 'CN=Doe\, Jane,OU=Staff,DC=contoso,DC=com'
            }
            @{
                Case = 'an escaped equals sign inside a value'
                Name = 'CN=a\=b, DC=contoso,DC=com'
                Expected = 'CN=a\=b,DC=contoso,DC=com'
            }
            @{
                Case = 'an escaped blank at the end of a value'
                Name = 'CN=Trailing\ , OU=Staff,DC=contoso,DC=com'
                Expected = 'CN=Trailing\ ,OU=Staff,DC=contoso,DC=com'
            }
            @{
                Case = 'an escaped blank at the end of the whole name'
                Name = 'CN=Trailing\ '
                Expected = 'CN=Trailing\ '
            }
            @{
                Case = 'an escaped blank at the start of a value'
                Name = 'CN= \ Leading,DC=contoso,DC=com'
                Expected = 'CN=\ Leading,DC=contoso,DC=com'
            }
            @{
                Case = 'an escaped backslash before a blank that is not escaped'
                Name = 'CN=Ends\\ , DC=contoso,DC=com'
                Expected = 'CN=Ends\\,DC=contoso,DC=com'
            }
        ) {
            ConvertTo-NormalizedDistinguishedName -DistinguishedName $Name |
                Should-BeString $Expected -CaseSensitive
        }
    }

    Context 'Text that is not a distinguished name' {
        It 'Returns <Name> with only its ends trimmed' -ForEach @(
            @{ Name = '  not a name  '; Expected = 'not a name' }
            @{ Name = 'CN=Alice,,DC=contoso,DC=com'; Expected = 'CN=Alice,,DC=contoso,DC=com' }
            @{ Name = ' =Alice, DC=contoso,DC=com'; Expected = '=Alice, DC=contoso,DC=com' }
            @{ Name = 'C:\Backups\file.xml'; Expected = 'C:\Backups\file.xml' }
        ) {
            ConvertTo-NormalizedDistinguishedName -DistinguishedName $Name |
                Should-BeString $Expected -CaseSensitive
        }
    }
}
