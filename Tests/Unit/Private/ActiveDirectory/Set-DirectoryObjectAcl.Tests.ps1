#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
#Requires -Version 5.1

BeforeAll {
    # As OrphanedSid.psm1 does: in the module the code under test runs under strict mode
    Set-StrictMode -Version Latest

    . (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\TestHelpers\ADCmdletStubs.ps1')
    . (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\Private\ActiveDirectory\Set-DirectoryObjectAcl.ps1')
}

Describe 'Set-DirectoryObjectAcl' -Tag 'Unit', 'Private' {
    BeforeEach {
        $script:acl = [System.DirectoryServices.ActiveDirectorySecurity]::new()
        $script:acl.SetSecurityDescriptorSddlForm('O:BAG:BAD:(A;;GA;;;BA)')
        Mock -CommandName Set-Acl -MockWith { }
        Mock -CommandName Set-ADObject -MockWith { }
    }

    Context 'Parameter Validation' {
        It 'Declares <ParameterName> as a mandatory parameter' -ForEach @(
            @{ ParameterName = 'DistinguishedName'; ParameterType = [string] }
            @{ ParameterName = 'AclObject'; ParameterType = [System.Security.AccessControl.ObjectSecurity] }
        ) {
            Get-Command -Name Set-DirectoryObjectAcl |
                Should-HaveParameter -ParameterName $ParameterName -Type $ParameterType -Mandatory
        }

        It 'Rejects a name that is only whitespace, and writes nothing' {
            { Set-DirectoryObjectAcl -DistinguishedName '   ' -AclObject $script:acl } |
                Should-Throw -FullyQualifiedErrorId 'DistinguishedNameEmpty,Set-DirectoryObjectAcl'

            Should-Invoke -CommandName Set-Acl -Times 0 -Exactly
            Should-Invoke -CommandName Set-ADObject -Times 0 -Exactly
        }
    }

    Context 'Core Functionality' {
        It 'Writes a plain name through the AD: drive' {
            $dn = 'OU=Finance,DC=contoso,DC=com'

            Set-DirectoryObjectAcl -DistinguishedName $dn -AclObject $script:acl

            Should-Invoke -CommandName Set-Acl -Times 1 -Exactly -ParameterFilter {
                $Path -eq "AD:\$dn" -and [object]::ReferenceEquals($AclObject, $script:acl)
            }
            Should-Invoke -CommandName Set-ADObject -Times 0 -Exactly
        }

        It 'Writes <Name> to the nTSecurityDescriptor attribute, not through the AD: drive' -ForEach @(
            @{ Name = 'OU=Payroll [EU],DC=contoso,DC=com' }
            @{ Name = 'OU=Sales*,DC=contoso,DC=com' }
            @{ Name = 'CN=Who?,OU=Finance,DC=contoso,DC=com' }
            @{ Name = 'OU=Pay`*,DC=contoso,DC=com' }
            @{ Name = 'OU=Tick`Name,DC=contoso,DC=com' }
            @{ Name = 'CN=Doe\, Jane,OU=Staff,DC=contoso,DC=com' }
            @{ Name = 'OU=Research\+Development,DC=contoso,DC=com' }
            @{ Name = 'CN=Below,OU=Trailing\\,DC=contoso,DC=com' }
        ) {
            Set-DirectoryObjectAcl -DistinguishedName $Name -AclObject $script:acl

            Should-Invoke -CommandName Set-ADObject -Times 1 -Exactly -ParameterFilter {
                $Identity -eq $Name -and [object]::ReferenceEquals($Replace['nTSecurityDescriptor'], $script:acl)
            }
            Should-Invoke -CommandName Set-Acl -Times 0 -Exactly
        }

        It 'Writes nothing to the pipeline' {
            $dn = 'OU=Finance,DC=contoso,DC=com'

            $output = @(Set-DirectoryObjectAcl -DistinguishedName $dn -AclObject $script:acl)

            $output.Count | Should-Be 0
        }
    }

    Context 'Error Handling' {
        It 'Ends with the error of Set-Acl when the write through the AD: drive fails' {
            Mock -CommandName Set-Acl -MockWith { throw 'Access is denied' }

            { Set-DirectoryObjectAcl -DistinguishedName 'OU=Finance,DC=contoso,DC=com' -AclObject $script:acl } |
                Should-Throw -ExceptionMessage '*Access is denied*'
        }

        It 'Ends with the error of Set-ADObject when the write of the attribute fails' {
            Mock -CommandName Set-ADObject -MockWith { throw 'Insufficient access rights' }

            $dn = 'OU=Payroll [EU],DC=contoso,DC=com'

            { Set-DirectoryObjectAcl -DistinguishedName $dn -AclObject $script:acl } |
                Should-Throw -ExceptionMessage '*Insufficient access rights*'
        }
    }
}
