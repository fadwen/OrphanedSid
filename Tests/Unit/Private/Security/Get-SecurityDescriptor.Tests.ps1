#Requires -Version 5.1

<#
.SYNOPSIS
    Pester tests for Get-ObjectAccessRule function

.DESCRIPTION
    Security descriptor analysis function testing - tests AD security descriptor retrieval 
    with multiple strategies, access control evaluation, and security validation.

.NOTES
    Author: Jeffrey Stuhr
#>

BeforeAll {
    function Write-StructuredLog {
        param($Message, $Level = 'Information', $CorrelationId, $Data)
        # For testing - track calls
        $script:LogCalls += @{
            Level = $Level
            Message = $Message  
            CorrelationId = $CorrelationId
            Data = $Data
        }
    }

    # Pester can only mock a command that exists, so Get-ADObject is stubbed when RSAT is absent.
    # The shared stubs, not a local global Get-ADObject: a global defined here with a shorter
    # parameter list outlived the file, and Mock then built later files' Get-ADObject mocks from it,
    # so -IncludeDeletedObjects never reached the mock body.
    . "$PSScriptRoot\..\..\..\TestHelpers\ADCmdletStubs.ps1"

    . "$PSScriptRoot\..\..\..\..\Private\Security\Get-SecurityDescriptor.ps1"
}

Describe "Get-ObjectAccessRule Tests" {
    
    BeforeEach {
        $script:TestCorrelationId = [System.Guid]::NewGuid().ToString()
        $script:LogCalls = @()
        
        # Get-Acl returns two non-inherited rules for any AD: path
        Mock Get-Acl {
            param($Path)
            if ($Path -like "AD:\*") {
                return [PSCustomObject]@{
                    Owner = "DOMAIN\Administrator"
                    Group = "DOMAIN\Domain Admins"
                    Access = @(
                        [PSCustomObject]@{
                            IdentityReference = "S-1-5-21-123456789-123456789-123456789-1001"
                            AccessControlType = "Allow"
                            ActiveDirectoryRights = "GenericAll"
                            IsInherited = $false
                        },
                        [PSCustomObject]@{
                            IdentityReference = "DOMAIN\TestUser"
                            AccessControlType = "Allow"
                            ActiveDirectoryRights = "ReadProperty"
                            IsInherited = $false
                        }
                    )
                }
            }
            return $null
        }
        
        Mock Get-ADObject {
            param($Identity, $Properties)
            return [PSCustomObject]@{
                DistinguishedName = $Identity
                nTSecurityDescriptor = @(0x01, 0x00, 0x14, 0x80)
            }
        }
    }
    
    Context "Parameter Validation" {
        
        It "Should accept valid ADObject parameter" {
            $testObject = [PSCustomObject]@{
                DistinguishedName = "CN=TestUser,OU=Users,DC=domain,DC=com"
                nTSecurityDescriptor = @(0x01, 0x00, 0x14, 0x80)
            }
            
            { Get-ObjectAccessRule -ADObject $testObject } | Should -Not -Throw
        }
        
        It "Should accept valid AD object input" {
            $testObject = [PSCustomObject]@{
                DistinguishedName = "CN=TestUser,OU=Users,DC=domain,DC=com"
                nTSecurityDescriptor = @(0x01, 0x00, 0x14, 0x80)
            }
            
            { Get-ObjectAccessRule -ADObject $testObject } | Should -Not -Throw
        }
        
        It "Should accept IncludeInherited switch" {
            $testObject = [PSCustomObject]@{
                DistinguishedName = "CN=TestUser,OU=Users,DC=domain,DC=com"
                nTSecurityDescriptor = @(0x01, 0x00, 0x14, 0x80)
            }
            
            { Get-ObjectAccessRule -ADObject $testObject -IncludeInherited } | Should -Not -Throw
        }
        
        It "Should accept custom CorrelationId" {
            $testObject = [PSCustomObject]@{
                DistinguishedName = "CN=TestUser,OU=Users,DC=domain,DC=com"
                nTSecurityDescriptor = @(0x01, 0x00, 0x14, 0x80)
            }
            
            { Get-ObjectAccessRule -ADObject $testObject -CorrelationId $script:TestCorrelationId } | Should -Not -Throw
        }
    }
    
    Context "Access Rule Retrieval" {
        
        It "Should return access rules from Get-Acl method" {
            $testObject = [PSCustomObject]@{
                DistinguishedName = "CN=TestUser,OU=Users,DC=domain,DC=com"
                nTSecurityDescriptor = @(0x01, 0x00, 0x14, 0x80)
            }
            
            $result = Get-ObjectAccessRule -ADObject $testObject
            $result | Should -Not -BeNullOrEmpty
            $result.Count | Should -Be 2
            
            Should -Invoke Get-Acl -Times 1
        }
        
        It "Should filter inherited rules when IncludeInherited is false" {
            $testObject = [PSCustomObject]@{
                DistinguishedName = "CN=TestUser,OU=Users,DC=domain,DC=com"
                nTSecurityDescriptor = @(0x01, 0x00, 0x14, 0x80)
            }

            # The Get-Acl mock returns no inherited rules, so this checks only that the two
            # non-inherited rules survive the filter, not that an inherited rule is removed

            $result = Get-ObjectAccessRule -ADObject $testObject -IncludeInherited:$false

            $result.Count | Should -Be 2
            $result[0].IsInherited | Should -Be $false
            $result[1].IsInherited | Should -Be $false
        }
        
        It "Should include inherited rules when IncludeInherited is true" {
            $testObject = [PSCustomObject]@{
                DistinguishedName = "CN=TestUser,OU=Users,DC=domain,DC=com"
                nTSecurityDescriptor = @(0x01, 0x00, 0x14, 0x80)
            }
            
            $result = Get-ObjectAccessRule -ADObject $testObject -IncludeInherited
            $result | Should -Not -BeNullOrEmpty
            $result.Count | Should -Be 2
        }
    }
    
    Context "Get-Acl Method Processing" {
        
        It "Should use Get-Acl as primary retrieval method" {
            $testObject = [PSCustomObject]@{
                DistinguishedName = "CN=TestUser,OU=Users,DC=domain,DC=com"
                nTSecurityDescriptor = @(0x01, 0x00, 0x14, 0x80)
            }
            
            $result = Get-ObjectAccessRule -ADObject $testObject
            Should -Invoke Get-Acl -Exactly 1
        }
        
        It "Should handle Get-Acl failures gracefully" {
            Mock Get-Acl { throw "Access denied" }
            
            $testObject = [PSCustomObject]@{
                DistinguishedName = "CN=TestUser,OU=Users,DC=domain,DC=com"
                nTSecurityDescriptor = @(0x01, 0x00, 0x14, 0x80)
            }
            
            { Get-ObjectAccessRule -ADObject $testObject } | Should -Not -Throw
        }
    }
    
    Context "Fresh AD Query Fallback" {
        
        It "Should use fresh AD query when other methods fail" {
            Mock Get-Acl { return $null }
            
            $testObject = [PSCustomObject]@{
                DistinguishedName = "CN=TestUser,OU=Users,DC=domain,DC=com"
                nTSecurityDescriptor = $null
            }
            
            $result = Get-ObjectAccessRule -ADObject $testObject
            Should -Invoke Get-ADObject -Exactly 1
        }
        
        It "Should handle fresh AD query failures gracefully" {
            Mock Get-Acl { return $null }
            Mock Get-ADObject { throw "Object not found" }
            
            $testObject = [PSCustomObject]@{
                DistinguishedName = "CN=TestUser,OU=Users,DC=domain,DC=com"
                nTSecurityDescriptor = $null
            }
            
            $result = Get-ObjectAccessRule -ADObject $testObject
            $result | Should -BeNullOrEmpty
        }
    }
    
    Context "Error Handling and Logging" {
        
        It "Should log retrieval attempts" {
            $testObject = [PSCustomObject]@{
                DistinguishedName = "CN=TestUser,OU=Users,DC=domain,DC=com"
                nTSecurityDescriptor = @(0x01, 0x00, 0x14, 0x80)
            }
            
            $result = Get-ObjectAccessRule -ADObject $testObject -CorrelationId $script:TestCorrelationId
            
            $script:LogCalls | Should -Not -BeNullOrEmpty
            $script:LogCalls | Where-Object { $_.CorrelationId -eq $script:TestCorrelationId } | Should -Not -BeNullOrEmpty
        }
        
        It "Should handle objects without DistinguishedName gracefully" {
            $testObject = [PSCustomObject]@{
                Name = "TestObject"
                nTSecurityDescriptor = @(0x01, 0x00, 0x14, 0x80)
            }
            
            { Get-ObjectAccessRule -ADObject $testObject } | Should -Not -Throw
        }
        
        It "Should return null when all methods fail" {
            Mock Get-Acl { return $null }
            Mock Get-ADObject { throw "Access denied" }
            
            $testObject = [PSCustomObject]@{
                DistinguishedName = "CN=TestUser,OU=Users,DC=domain,DC=com"
                nTSecurityDescriptor = $null
            }
            
            $result = Get-ObjectAccessRule -ADObject $testObject
            $result | Should -BeNullOrEmpty
        }
    }
    
    Context "Pipeline Support" {
        
        BeforeEach {
            # Replaces the Get-Acl mock for this context
            Mock Get-Acl {
                param($Path)
                if ($Path -like "AD:\*") {
                    return [PSCustomObject]@{
                        Owner = "DOMAIN\Administrator"
                        Access = @(
                            [PSCustomObject]@{
                                IdentityReference = "S-1-5-21-123456789-123456789-123456789-1001"
                                AccessControlType = "Allow"
                                ActiveDirectoryRights = "GenericAll"
                                IsInherited = $false
                            }
                        )
                    }
                }
                return $null
            }
        }
        
        It "Should support pipeline input" {
            $testObjects = @(
                [PSCustomObject]@{
                    DistinguishedName = "CN=User1,OU=Users,DC=domain,DC=com"
                    nTSecurityDescriptor = @(0x01, 0x00, 0x14, 0x80)
                },
                [PSCustomObject]@{
                    DistinguishedName = "CN=User2,OU=Users,DC=domain,DC=com"
                    nTSecurityDescriptor = @(0x01, 0x00, 0x14, 0x80)
                }
            )
            
            $results = $testObjects | Get-ObjectAccessRule
            $results | Should -Not -BeNullOrEmpty
        }
        
        It "Should process each pipeline object independently" {
            $testObjects = @(
                [PSCustomObject]@{
                    DistinguishedName = "CN=User1,OU=Users,DC=domain,DC=com"
                    nTSecurityDescriptor = @(0x01, 0x00, 0x14, 0x80)
                },
                [PSCustomObject]@{
                    DistinguishedName = "CN=User2,OU=Users,DC=domain,DC=com"
                    nTSecurityDescriptor = @(0x01, 0x00, 0x14, 0x80)
                }
            )
            
            $results = $testObjects | Get-ObjectAccessRule
            
            # One access rule comes back per piped object
            $results.Count | Should -Be 2

            # Requires at least one Get-Acl call; the count is not pinned
            Should -Invoke Get-Acl
        }
    }
}
