#Requires -Version 5.1

<#
.SYNOPSIS
    Pester tests for Get-ObjectAccessRule and the retrieval strategies in Get-SecurityDescriptor.ps1

.DESCRIPTION
    Get-ObjectAccessRule tries Get-Acl, then the object's own nTSecurityDescriptor (deserialized,
    ActiveDirectorySecurity, byte array, Base64 or a generic byte collection), then a fresh
    Get-ADObject query. Each strategy is reached here with real security descriptors built from SDDL.
#>

BeforeAll {
    function Write-StructuredLog { param($Message, $Level = 'Information', $CorrelationId, $Data) }

    # Pester can only mock a command that exists, so Get-ADObject is stubbed when RSAT is absent.
    # The shared stubs, not a local global Get-ADObject: a global defined here with a shorter
    # parameter list outlived the file, and Mock then built later files' Get-ADObject mocks from it,
    # so -IncludeDeletedObjects never reached the mock body.
    . "$PSScriptRoot\..\..\..\TestHelpers\ADCmdletStubs.ps1"

    . "$PSScriptRoot\..\..\..\..\Private\Security\Get-SecurityDescriptor.ps1"

    # One explicit Allow for SYSTEM and one inherited ReadProperty for Administrators. Both SIDs
    # translate on any Windows machine, which the descriptor's Access property needs.
    $script:Sddl = 'O:BAG:BAD:(A;;GA;;;SY)(A;ID;RP;;;BA)'

    function New-TestDescriptor {
        $sd = [System.DirectoryServices.ActiveDirectorySecurity]::new()
        $sd.SetSecurityDescriptorSddlForm($script:Sddl)
        $sd
    }

    function New-TestObject {
        param($Descriptor, [string]$Dn = 'CN=TestUser,OU=Users,DC=domain,DC=com')
        [PSCustomObject]@{ DistinguishedName = $Dn; nTSecurityDescriptor = $Descriptor }
    }

    $script:DescriptorBytes = (New-TestDescriptor).GetSecurityDescriptorBinaryForm()

    # What Get-Acl returns for an AD: path: a real ActiveDirectorySecurity. Two explicit entries and
    # one inherited, for SIDs no machine can translate.
    function New-AclFromSddl {
        param([string]$Sddl)
        $acl = [System.DirectoryServices.ActiveDirectorySecurity]::new()
        $acl.SetSecurityDescriptorSddlForm($Sddl)
        $acl
    }
    $script:AclSddl = 'O:BAG:BAD:(A;;GA;;;S-1-5-21-1-2-3-1001)(A;;RP;;;S-1-5-21-1-2-3-1003)(A;ID;RP;;;S-1-5-21-1-2-3-1002)'
    $script:InheritedOnlySddl = 'O:BAG:BAD:(A;ID;RP;;;S-1-5-21-1-2-3-1002)'
}

Describe "Get-ObjectAccessRule" -Tag 'Unit', 'Private', 'Security' {

    BeforeEach {
        Mock Write-StructuredLog { }
        Mock Get-Acl { New-AclFromSddl -Sddl $script:AclSddl }
        Mock Get-ADObject { throw 'Get-ADObject should not be reached' }
    }

    Context "Strategy 1: Get-Acl" {
        It "Reads the ACL from the AD: drive path of the object and returns the explicit rules" {
            $result = @(Get-ObjectAccessRule -ADObject (New-TestObject))

            $result.Count | Should -Be 2
            @($result.IdentityReference.Value) | Should -Be @('S-1-5-21-1-2-3-1001', 'S-1-5-21-1-2-3-1003')
            Should -Invoke Get-Acl -Times 1 -Exactly -ParameterFilter { $Path -eq 'AD:\CN=TestUser,OU=Users,DC=domain,DC=com' }
            Should -Invoke Get-ADObject -Times 0 -Exactly
        }

        It "Returns SID references, without translating them to account names (#111)" {
            # SYSTEM translates on every machine; .Access would have returned it as NT AUTHORITY\SYSTEM
            Mock Get-Acl { New-AclFromSddl -Sddl 'O:BAG:BAD:(A;;GA;;;SY)' }

            $result = @(Get-ObjectAccessRule -ADObject (New-TestObject))

            $result.Count | Should -Be 1
            $result[0].IdentityReference | Should -BeOfType [System.Security.Principal.SecurityIdentifier]
            $result[0].IdentityReference.Value | Should -Be 'S-1-5-18'
        }

        It "Returns inherited rules too with -IncludeInherited" {
            $result = @(Get-ObjectAccessRule -ADObject (New-TestObject) -IncludeInherited)

            $result.Count | Should -Be 3
            $result[2].IsInherited | Should -Be $true
        }

        It "Passes the correlation ID to every log entry" {
            Get-ObjectAccessRule -ADObject (New-TestObject) -CorrelationId 'sd-1' | Out-Null

            Should -Invoke Write-StructuredLog -Times 0 -Exactly -ParameterFilter { $CorrelationId -ne 'sd-1' }
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Message -eq 'Successfully retrieved access rules using Get-Acl method for CN=TestUser,OU=Users,DC=domain,DC=com'
            }
        }

        It "Stops quietly, without a fallback query or a warning, when every entry is inherited (#48)" {
            Mock Get-Acl {
                New-AclFromSddl -Sddl $script:InheritedOnlySddl
            }
            # The binary strategy would read the object's own descriptor; give it one so a call shows
            $object = New-TestObject -Descriptor (New-TestDescriptor)

            $result = Get-ObjectAccessRule -ADObject $object

            $result | Should -BeNullOrEmpty
            Should -Invoke Get-ADObject -Times 0 -Exactly
            Should -Invoke Write-StructuredLog -Times 0 -Exactly -ParameterFilter { $Level -eq 'Warning' }
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Debug' -and $Message -eq 'No explicit access rules on CN=TestUser,OU=Users,DC=domain,DC=com (all 1 are inherited)'
            }
        }

        It "Still returns the inherited entries of such an object with -IncludeInherited" {
            Mock Get-Acl {
                New-AclFromSddl -Sddl $script:InheritedOnlySddl
            }

            @(Get-ObjectAccessRule -ADObject (New-TestObject) -IncludeInherited).Count | Should -Be 1
        }

        It "Processes each piped object with its own Get-Acl call" {
            $objects = @((New-TestObject -Dn 'CN=User1,DC=domain,DC=com'), (New-TestObject -Dn 'CN=User2,DC=domain,DC=com'))

            $results = @($objects | Get-ObjectAccessRule)

            $results.Count | Should -Be 4
            Should -Invoke Get-Acl -Times 1 -Exactly -ParameterFilter { $Path -eq 'AD:\CN=User1,DC=domain,DC=com' }
            Should -Invoke Get-Acl -Times 1 -Exactly -ParameterFilter { $Path -eq 'AD:\CN=User2,DC=domain,DC=com' }
        }
    }

    Context "Strategy 2: the object's own security descriptor" {
        BeforeEach {
            Mock Get-Acl { throw 'Access denied' }
        }

        It "Falls back to the descriptor on the object when Get-Acl throws" {
            Get-ObjectAccessRule -ADObject (New-TestObject -Descriptor $script:DescriptorBytes) | Out-Null

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter { $Message -like 'Get-Acl failed for*Access denied' }
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter { $Message -eq 'Processing byte array security descriptor' }
        }

        It "Reads the explicit rules from a deserialized descriptor" {
            $deserialized = [PSCustomObject]@{
                PSTypeName = 'Deserialized.System.DirectoryServices.ActiveDirectorySecurity'
                Access = @(
                    [PSCustomObject]@{ IdentityReference = 'S-1-5-21-1-2-3-1001'; IsInherited = $false }
                    [PSCustomObject]@{ IdentityReference = 'S-1-5-21-1-2-3-1002'; IsInherited = $true }
                )
            }

            $result = @(Get-ObjectAccessRule -ADObject (New-TestObject -Descriptor $deserialized))
            $inherited = @(Get-ObjectAccessRule -ADObject (New-TestObject -Descriptor $deserialized) -IncludeInherited)

            @($result.IdentityReference) | Should -Be @('S-1-5-21-1-2-3-1001')
            $inherited.Count | Should -Be 2
            Should -Invoke Get-ADObject -Times 0 -Exactly
        }

        It "Moves on to a fresh query when a deserialized descriptor has no Access entries" {
            Mock Get-ADObject { [PSCustomObject]@{ nTSecurityDescriptor = $null } }
            $deserialized = [PSCustomObject]@{ PSTypeName = 'Deserialized.System.DirectoryServices.ActiveDirectorySecurity'; Access = $null }

            Get-ObjectAccessRule -ADObject (New-TestObject -Descriptor $deserialized) | Should -BeNullOrEmpty

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter { $Message -like 'Deserialized security descriptor has no Access property*' }
            Should -Invoke Get-ADObject -Times 1 -Exactly
        }

        It "Routes a <Shape> descriptor to its converter" -ForEach @(
            @{ Shape = 'byte array'; Log = 'Processing byte array security descriptor' }
            @{ Shape = 'Base64 string'; Log = 'Processing Base64 string security descriptor' }
            @{ Shape = 'generic byte collection'; Log = 'Converting generic binary data to byte array' }
        ) {
            $descriptor = switch ($Shape) {
                'byte array' { , $script:DescriptorBytes }
                'Base64 string' { [Convert]::ToBase64String($script:DescriptorBytes) }
                'generic byte collection' { , [object[]]$script:DescriptorBytes }
            }

            Get-ObjectAccessRule -ADObject (New-TestObject -Descriptor $descriptor) | Out-Null

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter { $Message -eq $Log }
        }

        It "Returns the explicit rules from a <Shape> descriptor" -ForEach @(
            @{ Shape = 'byte array' }
            @{ Shape = 'Base64 string' }
            @{ Shape = 'ActiveDirectorySecurity object' }
        ) {
            $descriptor = switch ($Shape) {
                'byte array' { , $script:DescriptorBytes }
                'Base64 string' { [Convert]::ToBase64String($script:DescriptorBytes) }
                'ActiveDirectorySecurity object' { New-TestDescriptor }
            }

            $result = @(Get-ObjectAccessRule -ADObject (New-TestObject -Descriptor $descriptor))

            $result.Count | Should -Be 1
            $result[0].IdentityReference.Value | Should -Be 'NT AUTHORITY\SYSTEM'
            $result[0].IsInherited | Should -Be $false
            Should -Invoke Get-ADObject -Times 0 -Exactly
        }

        It "Returns the inherited rule as well with -IncludeInherited" {
            $result = @(Get-ObjectAccessRule -ADObject (New-TestObject -Descriptor $script:DescriptorBytes) -IncludeInherited)

            $result.Count | Should -Be 2
        }

        It "Warns about bytes that are not a security descriptor and falls back to a fresh query" {
            Mock Get-ADObject { [PSCustomObject]@{ nTSecurityDescriptor = $null } }

            Get-ObjectAccessRule -ADObject (New-TestObject -Descriptor ([byte[]](1, 0, 0x14, 0x80))) | Should -BeNullOrEmpty

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Warning' -and $Message -like 'Failed to convert binary security descriptor for CN=TestUser*'
            }
            Should -Invoke Get-ADObject -Times 1 -Exactly
        }
    }

    Context "Strategy 3: fresh query" {
        BeforeEach {
            Mock Get-Acl { $null }
        }

        It "Queries the object by DN for its nTSecurityDescriptor when the object carries none" {
            Mock Get-ADObject { [PSCustomObject]@{ nTSecurityDescriptor = , $script:DescriptorBytes } }

            Get-ObjectAccessRule -ADObject (New-TestObject) -CorrelationId 'sd-2' | Out-Null

            Should -Invoke Get-ADObject -Times 1 -Exactly -ParameterFilter {
                $Identity -eq 'CN=TestUser,OU=Users,DC=domain,DC=com' -and $Properties -eq 'nTSecurityDescriptor'
            }
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Message -eq 'No nTSecurityDescriptor property found for CN=TestUser,OU=Users,DC=domain,DC=com'
            }
        }

        It "Returns the explicit rules from the fresh <Shape>" -ForEach @(
            @{ Shape = 'byte array' }
            @{ Shape = 'ActiveDirectorySecurity object' }
            @{ Shape = 'generic byte collection' }
        ) {
            $descriptor = switch ($Shape) {
                'byte array' { , $script:DescriptorBytes }
                'ActiveDirectorySecurity object' { New-TestDescriptor }
                'generic byte collection' { , [object[]]$script:DescriptorBytes }
            }
            $script:freshDescriptor = $descriptor
            Mock Get-ADObject { [PSCustomObject]@{ nTSecurityDescriptor = $script:freshDescriptor } }

            $result = @(Get-ObjectAccessRule -ADObject (New-TestObject))

            $result.Count | Should -Be 1
            $result[0].IdentityReference.Value | Should -Be 'NT AUTHORITY\SYSTEM'
        }

        It "Warns and returns nothing when the fresh query has no descriptor" {
            Mock Get-ADObject { [PSCustomObject]@{ nTSecurityDescriptor = $null } }

            Get-ObjectAccessRule -ADObject (New-TestObject) | Should -BeNullOrEmpty

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Warning' -and $Message -like 'Fresh AD query returned no security descriptor*'
            }
        }

        It "Warns, and reports that every method failed, when the fresh query throws" {
            Mock Get-ADObject { throw 'Object not found' }

            Get-ObjectAccessRule -ADObject (New-TestObject) -CorrelationId 'sd-3' | Should -BeNullOrEmpty

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Warning' -and $Message -like 'Fresh AD query failed for CN=TestUser*Object not found'
            }
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Warning' -and $CorrelationId -eq 'sd-3' -and
                $Message -eq 'All security descriptor retrieval methods failed for CN=TestUser,OU=Users,DC=domain,DC=com'
            }
        }
    }
}
