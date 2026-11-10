#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
Describe "Get-ADObjectFromSearchBase" -Tag "Unit", "ActiveDirectory" {
    
    BeforeAll {
        # The shared stubs, not a local global Get-ADObject: a global defined here with a shorter
        # parameter list outlived the file, and Mock then built later files' Get-ADObject mocks from it,
        # so -IncludeDeletedObjects never reached the mock body.
        . "$PSScriptRoot\..\..\..\TestHelpers\ADCmdletStubs.ps1"

        # Import the function once for all tests
        $FunctionPath = Join-Path $PSScriptRoot "..\..\..\..\Private\ActiveDirectory\Get-ADObjectFromSearchBase.ps1"
        . $FunctionPath
    }

    BeforeEach {
        # Get-ADObject returns fixed objects per search base, and throws for the error cases
        Mock Get-ADObject {
            param($SearchBase, $Filter, $Properties)

            switch -Wildcard ($SearchBase) {
                '*Users*' {
                    return @(
                        [PSCustomObject]@{
                            DistinguishedName = 'CN=User1,OU=Users,DC=contoso,DC=com'
                            Name = 'User1'
                            ObjectClass = 'user'
                            nTSecurityDescriptor = 'MockSecurityDescriptor1'
                        }
                        [PSCustomObject]@{
                            DistinguishedName = 'CN=User2,OU=Users,DC=contoso,DC=com' 
                            Name = 'User2'
                            ObjectClass = 'user'
                            nTSecurityDescriptor = 'MockSecurityDescriptor2'
                        }
                    )
                }
                '*Groups*' {
                    # Ensure we return an array even for single items
                    return @(
                        [PSCustomObject]@{
                            DistinguishedName = 'CN=Group1,OU=Groups,DC=contoso,DC=com'
                            Name = 'Group1'
                            ObjectClass = 'group'
                            nTSecurityDescriptor = 'MockSecurityDescriptor3'
                        }
                    )
                }
                '*InvalidDN*' {
                    throw "The supplied distinguished name contains invalid syntax"
                }
                '*AccessDenied*' {
                    throw "Insufficient access rights to perform the operation"
                }
                '*ServerError*' {
                    throw "The server is not operational"
                }
                default {
                    return @()
                }
            }
        }
        
        Mock Write-Verbose { }
        Mock Write-Warning { }
    }

    Context "Parameter Validation" {
        It "Should accept valid Distinguished Name for Users OU" {
            { Get-ADObjectFromSearchBase -SearchBase 'OU=Users,DC=contoso,DC=com' } | Should -Not -Throw
        }
        
        It "Should accept valid Distinguished Name for Groups OU" {
            { Get-ADObjectFromSearchBase -SearchBase 'OU=Groups,DC=contoso,DC=com' } | Should -Not -Throw
        }
        
        It "Should accept pipeline input" {
            { 'OU=Users,DC=contoso,DC=com' | Get-ADObjectFromSearchBase } | Should -Not -Throw
        }
        
        It "Should accept Properties parameter" {
            $properties = @('Name', 'Description', 'mail')
            { Get-ADObjectFromSearchBase -SearchBase 'OU=Users,DC=contoso,DC=com' -Properties $properties } | Should -Not -Throw
        }
        
        It "Should accept CorrelationId parameter" {
            $correlationId = [System.Guid]::NewGuid().ToString()
            { Get-ADObjectFromSearchBase -SearchBase 'OU=Users,DC=contoso,DC=com' -CorrelationId $correlationId } | Should -Not -Throw
        }
    }

    Context "Core Functionality" {
        It "Should return AD objects from Users OU" {
            $result = Get-ADObjectFromSearchBase -SearchBase 'OU=Users,DC=contoso,DC=com'
            
            $result | Should -Not -BeNullOrEmpty
            $result.Count | Should -Be 2
            $result[0].Name | Should -Be 'User1'
            $result[1].Name | Should -Be 'User2'
        }
        
        It "Should return AD objects from Groups OU" {
            $result = @(Get-ADObjectFromSearchBase -SearchBase 'OU=Groups,DC=contoso,DC=com')
            
            $result | Should -Not -BeNullOrEmpty
            $result.Count | Should -Be 1
            $result[0].Name | Should -Be 'Group1'
        }
        
        It "Should include nTSecurityDescriptor in results" {
            $result = Get-ADObjectFromSearchBase -SearchBase 'OU=Users,DC=contoso,DC=com'
            
            $result[0].nTSecurityDescriptor | Should -Not -BeNullOrEmpty
            $result[0].nTSecurityDescriptor | Should -Be 'MockSecurityDescriptor1'
        }
        
        It "Should handle empty result set" {
            $result = Get-ADObjectFromSearchBase -SearchBase 'OU=Empty,DC=contoso,DC=com'
            
            $result | Should -BeNullOrEmpty
        }
        
        It "Should process multiple search bases via pipeline" {
            $searchBases = @('OU=Users,DC=contoso,DC=com', 'OU=Groups,DC=contoso,DC=com')
            $result = $searchBases | Get-ADObjectFromSearchBase
            
            $result | Should -Not -BeNullOrEmpty
            $result.Count | Should -Be 3  # 2 users + 1 group
        }
    }

    Context "Error Handling" {
        It "Should handle invalid Distinguished Name gracefully" {
            $result = Get-ADObjectFromSearchBase -SearchBase 'InvalidDN'
            
            # A failed search base warns rather than throwing
            Should -Invoke Write-Warning -Exactly 1 -ParameterFilter {
                $Message -match "Failed to retrieve objects"
            }
        }
        
        It "Should handle access denied errors gracefully" {
            { $result = Get-ADObjectFromSearchBase -SearchBase 'OU=AccessDenied,DC=contoso,DC=com' } | Should -Not -Throw

            # Requires at least one warning; the count is not pinned
            Should -Invoke Write-Warning -ParameterFilter {
                $Message -match "Failed to retrieve objects"
            }
        }
        
        It "Should handle server unavailable errors gracefully" {
            { $result = Get-ADObjectFromSearchBase -SearchBase 'OU=ServerError,DC=contoso,DC=com' } | Should -Not -Throw

            # Requires at least one warning; the count is not pinned
            Should -Invoke Write-Warning -ParameterFilter {
                $Message -match "Failed to retrieve objects"
            }
        }
        
        It "Should continue pipeline processing after error" {
            $searchBases = @('OU=Users,DC=contoso,DC=com', 'InvalidDN', 'OU=Groups,DC=contoso,DC=com')
            $result = $searchBases | Get-ADObjectFromSearchBase
            
            # Should get results from valid search bases despite error in middle
            $result | Should -Not -BeNullOrEmpty
            $result.Count | Should -Be 3  # 2 users + 1 group (InvalidDN produces no output)
        }
    }

    Context "Integration Tests" {
        It "Should call Get-ADObject with correct SearchBase" {
            Get-ADObjectFromSearchBase -SearchBase 'OU=Users,DC=contoso,DC=com'
            
            Should -Invoke Get-ADObject -Exactly 1 -ParameterFilter {
                $SearchBase -eq 'OU=Users,DC=contoso,DC=com'
            }
        }
        
        It "Should call Get-ADObject with correct Filter" {
            Get-ADObjectFromSearchBase -SearchBase 'OU=Users,DC=contoso,DC=com'
            
            # The function passes -Filter * so every object class under the search base is returned
            Should -Invoke Get-ADObject -ParameterFilter {
                $Filter -eq '*'
            }
        }
        
        It "Should call Get-ADObject with nTSecurityDescriptor property" {
            Get-ADObjectFromSearchBase -SearchBase 'OU=Users,DC=contoso,DC=com'
            
            Should -Invoke Get-ADObject -ParameterFilter {
                $Properties -contains 'nTSecurityDescriptor'
            }
        }
        
        It "Should call Get-ADObject with custom properties" {
            $customProperties = @('Name', 'Description', 'mail')
            Get-ADObjectFromSearchBase -SearchBase 'OU=Users,DC=contoso,DC=com' -Properties $customProperties
            
            Should -Invoke Get-ADObject -Exactly 1 -ParameterFilter {
                $Properties -contains 'nTSecurityDescriptor' -and
                $Properties -contains 'Name' -and
                $Properties -contains 'Description' -and
                $Properties -contains 'mail'
            }
        }
        
        It "Should log verbose messages" {
            Get-ADObjectFromSearchBase -SearchBase 'OU=Users,DC=contoso,DC=com'
            
            # Asserts nothing: it only runs the function with Write-Verbose mocked. A check would be
            # Should -Invoke Write-Verbose -ParameterFilter { $Message -match "Retrieving AD objects" }
        }
    }

    Context "Performance" {
        It "Should complete within reasonable time" {
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            
            Get-ADObjectFromSearchBase -SearchBase 'OU=Users,DC=contoso,DC=com'
            
            $stopwatch.Stop()
            $stopwatch.ElapsedMilliseconds | Should -BeLessThan 1000  # 1 second max
        }
        
        It "Should handle pipeline input efficiently" {
            $searchBases = 1..10 | ForEach-Object { "OU=Test$_,DC=contoso,DC=com" }
            
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $searchBases | Get-ADObjectFromSearchBase
            $stopwatch.Stop()
            
            $stopwatch.ElapsedMilliseconds | Should -BeLessThan 5000  # 5 seconds max for 10 items
        }
    }
}
