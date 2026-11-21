#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
#Requires -Version 5.1

BeforeAll {
    # As OrphanedSid.psm1 does: in the module the code under test runs under strict mode
    Set-StrictMode -Version Latest

    . (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\TestHelpers\ADCmdletStubs.ps1')
    . (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\Private\ActiveDirectory\Get-DirectoryObjectAcl.ps1')

    function Get-TestAcl {
        param([string]$Sddl)
        $acl = [System.DirectoryServices.ActiveDirectorySecurity]::new()
        $acl.SetSecurityDescriptorSddlForm($Sddl)
        $acl
    }
}

Describe 'Get-DirectoryObjectAcl' -Tag 'Unit', 'Private' {
    BeforeEach {
        $script:driveAcl = Get-TestAcl -Sddl 'O:BAG:BAD:(A;;GA;;;BA)'
        $script:attributeAcl = Get-TestAcl -Sddl 'O:BAG:BAD:(A;;GA;;;SY)'
        Mock -CommandName Get-Acl -MockWith { $script:driveAcl }
        Mock -CommandName Get-ADObject -MockWith {
            [PSCustomObject]@{ DistinguishedName = $Identity; nTSecurityDescriptor = $script:attributeAcl }
        }
    }

    Context 'Parameter Validation' {
        It 'Declares DistinguishedName as a mandatory string' {
            Get-Command -Name Get-DirectoryObjectAcl |
                Should-HaveParameter -ParameterName DistinguishedName -Type ([string]) -Mandatory
        }

        It 'Rejects a name that is only whitespace, and reads nothing' {
            { Get-DirectoryObjectAcl -DistinguishedName '   ' } |
                Should-Throw -FullyQualifiedErrorId 'DistinguishedNameEmpty,Get-DirectoryObjectAcl'

            Should-Invoke -CommandName Get-Acl -Times 0 -Exactly
            Should-Invoke -CommandName Get-ADObject -Times 0 -Exactly
        }
    }

    Context 'Core Functionality' {
        It 'Reads a plain name through the AD: drive' {
            $dn = 'OU=Finance,DC=contoso,DC=com'

            $result = Get-DirectoryObjectAcl -DistinguishedName $dn

            [object]::ReferenceEquals($result, $script:driveAcl) | Should-BeTrue
            Should-Invoke -CommandName Get-Acl -Times 1 -Exactly -ParameterFilter { $Path -eq "AD:\$dn" }
            Should-Invoke -CommandName Get-ADObject -Times 0 -Exactly
        }

        It 'Reads <Name> through the AD: drive, which reads a dot or a slash as part of the name' -ForEach @(
            @{ Name = 'OU=Misc...,DC=contoso,DC=com' }
            @{ Name = 'OU=Inbound/Outbound,DC=contoso,DC=com' }
        ) {
            $result = Get-DirectoryObjectAcl -DistinguishedName $Name

            [object]::ReferenceEquals($result, $script:driveAcl) | Should-BeTrue
            Should-Invoke -CommandName Get-Acl -Times 1 -Exactly -ParameterFilter { $Path -eq "AD:\$Name" }
            Should-Invoke -CommandName Get-ADObject -Times 0 -Exactly
        }

        It 'Removes whitespace around the name before reading' {
            $null = Get-DirectoryObjectAcl -DistinguishedName '  OU=Finance,DC=contoso,DC=com  '

            Should-Invoke -CommandName Get-Acl -Times 1 -Exactly -ParameterFilter {
                $Path -eq 'AD:\OU=Finance,DC=contoso,DC=com'
            }
        }

        It 'Reads <Name> from the nTSecurityDescriptor attribute, not through the AD: drive' -ForEach @(
            @{ Name = 'OU=Payroll [EU],DC=contoso,DC=com' }
            @{ Name = 'OU=Sales*,DC=contoso,DC=com' }
            @{ Name = 'CN=Who?,OU=Finance,DC=contoso,DC=com' }
            @{ Name = 'OU=Pay`*,DC=contoso,DC=com' }
            @{ Name = 'OU=Tick`Name,DC=contoso,DC=com' }
            @{ Name = 'CN=Doe\, Jane,OU=Staff,DC=contoso,DC=com' }
            @{ Name = 'OU=Research\+Development,DC=contoso,DC=com' }
            @{ Name = 'CN=Below,OU=Trailing\\,DC=contoso,DC=com' }
        ) {
            $result = Get-DirectoryObjectAcl -DistinguishedName $Name

            [object]::ReferenceEquals($result, $script:attributeAcl) | Should-BeTrue
            Should-Invoke -CommandName Get-ADObject -Times 1 -Exactly -ParameterFilter {
                $Identity -eq $Name -and @($Properties) -contains 'nTSecurityDescriptor'
            }
            Should-Invoke -CommandName Get-Acl -Times 0 -Exactly
        }
    }

    Context 'Error Handling' {
        It 'Ends with the error of Get-Acl when the read through the AD: drive fails' {
            Mock -CommandName Get-Acl -MockWith { throw 'Access is denied' }

            { Get-DirectoryObjectAcl -DistinguishedName 'OU=Finance,DC=contoso,DC=com' } |
                Should-Throw -ExceptionMessage '*Access is denied*'
        }

        It 'Ends with the error of Get-ADObject when the read of the attribute fails' {
            Mock -CommandName Get-ADObject -MockWith { throw 'Directory object not found' }

            { Get-DirectoryObjectAcl -DistinguishedName 'OU=Payroll [EU],DC=contoso,DC=com' } |
                Should-Throw -ExceptionMessage '*Directory object not found*'
        }

        It 'Still ends when the caller asks for errors to be ignored' {
            Mock -CommandName Get-Acl -MockWith { throw 'Access is denied' }

            $dn = 'OU=Finance,DC=contoso,DC=com'

            { Get-DirectoryObjectAcl -DistinguishedName $dn -ErrorAction SilentlyContinue } |
                Should-Throw -ExceptionMessage '*Access is denied*'
        }
    }
}
