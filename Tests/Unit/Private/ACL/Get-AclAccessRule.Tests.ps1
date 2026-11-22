#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
#Requires -Version 5.1

BeforeAll {
    # As OrphanedSid.psm1 does: in the module the code under test runs under strict mode
    Set-StrictMode -Version Latest

    $script:FunctionFile = Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\Private\ACL\Get-AclAccessRule.ps1'
    . $script:FunctionFile

    $script:Orphan = 'S-1-5-21-1111111111-2222222222-3333333333-1999'
    $script:Sddl = "O:BAG:BAD:(A;;GA;;;BA)(A;;RPWP;;;$script:Orphan)"
}

Describe 'Get-AclAccessRule' -Tag 'Unit', 'Private' {
    Context 'Parameter Validation' {
        It 'Declares Acl as a mandatory parameter' {
            Get-Command -Name Get-AclAccessRule | Should-HaveParameter -ParameterName Acl -Mandatory
        }

        It 'Rejects a null security descriptor' {
            { Get-AclAccessRule -Acl $null } | Should-Throw -ExceptionType ([System.Management.Automation.ParameterBindingException])
        }
    }

    Context 'Core Functionality' {
        It 'Gets each rule of a directory security descriptor, with the trustee as a SID' {
            $acl = [System.DirectoryServices.ActiveDirectorySecurity]::new()
            $acl.SetSecurityDescriptorSddlForm($script:Sddl)

            $rules = @(Get-AclAccessRule -Acl $acl)

            $rules | Should-BeCollection -Count 2
            $rules | Should-All { $_.IdentityReference -is [System.Security.Principal.SecurityIdentifier] }
            $trustees = @($rules | ForEach-Object { $_.IdentityReference.Value } | Sort-Object)
            $trustees[0] | Should-Be $script:Orphan
            $trustees[1] | Should-Be 'S-1-5-32-544'
        }

        It 'Gets the rules in a runspace that a host created, where ACL objects may have no Access property' {
            # On PowerShell 7 the Access property comes from type data that such a runspace does
            # not load. The runspace only dot-sources this one function; it loads no class.
            $inRunspace = {
                param($FunctionFile, $Sddl)
                . $FunctionFile
                $acl = [System.DirectoryServices.ActiveDirectorySecurity]::new()
                $acl.SetSecurityDescriptorSddlForm($Sddl)
                @(Get-AclAccessRule -Acl $acl).Count
            }
            $shell = [powershell]::Create()
            try {
                $null = $shell.AddScript($inRunspace.ToString()).AddArgument($script:FunctionFile).AddArgument($script:Sddl)
                $count = $shell.Invoke()
                $failures = @($shell.Streams.Error | ForEach-Object { "$_" })
            } finally {
                $shell.Dispose()
            }

            $failures | Should-BeCollection -Count 0
            $count | Should-BeCollection -Count 1
            $count[0] | Should-Be 2
        }

        It 'Gets the entries of the Access property of an object that is not a security descriptor' {
            $first = [PSCustomObject]@{ IdentityReference = [PSCustomObject]@{ Value = $script:Orphan } }
            $second = [PSCustomObject]@{ IdentityReference = [PSCustomObject]@{ Value = 'S-1-5-32-544' } }
            $double = [PSCustomObject]@{ Access = @($first, $second) }

            $rules = @(Get-AclAccessRule -Acl $double)

            $rules | Should-BeCollection -Count 2
            [object]::ReferenceEquals($rules[0], $first) | Should-BeTrue
            [object]::ReferenceEquals($rules[1], $second) | Should-BeTrue
        }

        It 'Gets nothing from an object whose Access property is empty' {
            $rules = @(Get-AclAccessRule -Acl ([PSCustomObject]@{ Access = @() }))

            $rules.Count | Should-Be 0
        }
    }

    Context 'Error Handling' {
        It 'Ends with an error for an object whose rules cannot be read' {
            $bare = [PSCustomObject]@{ Owner = 'CONTOSO\Domain Admins' }

            { Get-AclAccessRule -Acl $bare } |
                Should-Throw -FullyQualifiedErrorId 'AclAccessRulesUnavailable,Get-AclAccessRule'
        }
    }
}
