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

        # The retry wrapper is mocked to run the read once, so these tests see Get-ADObject directly;
        # the retry loop itself is tested in Invoke-OperationWithRetry.Tests.ps1
        function Invoke-ADOperationWithRetry { param([scriptblock]$ScriptBlock, $MaxRetries, $OperationName, $ObjectContext, $CorrelationId) }
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
        Mock Invoke-ADOperationWithRetry { & $ScriptBlock }
    }

    Context "Parameter Validation" {
        It "Rejects an empty SearchBase" {
            { Get-ADObjectFromSearchBase -SearchBase '' } | Should -Throw -ExpectedMessage "*SearchBase*"
            Should -Invoke Get-ADObject -Times 0 -Exactly
        }

        It "Binds a piped string to SearchBase" {
            $result = @('OU=Groups,DC=contoso,DC=com' | Get-ADObjectFromSearchBase)

            $result.Count | Should -Be 1
            Should -Invoke Get-ADObject -Times 1 -Exactly -ParameterFilter {
                $SearchBase -eq 'OU=Groups,DC=contoso,DC=com'
            }
        }

        It "Writes the CorrelationId into the start-of-search verbose message" {
            $correlationId = [System.Guid]::NewGuid().ToString()
            Get-ADObjectFromSearchBase -SearchBase 'OU=Users,DC=contoso,DC=com' -CorrelationId $correlationId

            Should -Invoke Write-Verbose -Times 1 -Exactly -ParameterFilter {
                $Message -like "Retrieving AD objects from search base: OU=Users,DC=contoso,DC=com*" -and
                $Message -like "*CorrelationId: $correlationId"
            }
        }
    }

    Context "Core Functionality" {
        It "Should return AD objects from Users OU" {
            $result = Get-ADObjectFromSearchBase -SearchBase 'OU=Users,DC=contoso,DC=com'

            $result.Count | Should -Be 2
            $result[0].Name | Should -Be 'User1'
            $result[1].Name | Should -Be 'User2'
        }

        It "Should return a single AD object from Groups OU" {
            $result = @(Get-ADObjectFromSearchBase -SearchBase 'OU=Groups,DC=contoso,DC=com')

            $result.Count | Should -Be 1
            $result[0].Name | Should -Be 'Group1'
        }

        It "Should include nTSecurityDescriptor in results" {
            $result = Get-ADObjectFromSearchBase -SearchBase 'OU=Users,DC=contoso,DC=com'

            $result[0].nTSecurityDescriptor | Should -Be 'MockSecurityDescriptor1'
        }

        It "Should return nothing and warn nothing for an empty result set" {
            $result = Get-ADObjectFromSearchBase -SearchBase 'OU=Empty,DC=contoso,DC=com'

            $result | Should -BeNullOrEmpty
            Should -Invoke Write-Warning -Times 0 -Exactly
            Should -Invoke Write-Verbose -Times 1 -Exactly -ParameterFilter {
                $Message -eq 'Retrieved 0 objects from search base: OU=Empty,DC=contoso,DC=com'
            }
        }

        It "Should report the retrieved object count in a verbose message" {
            Get-ADObjectFromSearchBase -SearchBase 'OU=Users,DC=contoso,DC=com'

            Should -Invoke Write-Verbose -Times 1 -Exactly -ParameterFilter {
                $Message -eq 'Retrieved 2 objects from search base: OU=Users,DC=contoso,DC=com'
            }
        }

        It "Should process multiple search bases via pipeline" {
            $searchBases = @('OU=Users,DC=contoso,DC=com', 'OU=Groups,DC=contoso,DC=com')
            $result = $searchBases | Get-ADObjectFromSearchBase

            $result.Count | Should -Be 3  # 2 users + 1 group
            $result.Name | Should -Be @('User1', 'User2', 'Group1')
            Should -Invoke Get-ADObject -Times 2 -Exactly
        }
    }

    Context "Error Handling" {
        It "Throws a read that still fails, for its caller to count and report: <Case> (#89)" -ForEach @(
            @{ Case = 'invalid DN'; Base = 'InvalidDN'; Expected = 'The supplied distinguished name contains invalid syntax' }
            @{ Case = 'access denied'; Base = 'OU=AccessDenied,DC=contoso,DC=com'; Expected = 'Insufficient access rights to perform the operation' }
            @{ Case = 'server unavailable'; Base = 'OU=ServerError,DC=contoso,DC=com'; Expected = 'The server is not operational' }
        ) {
            # Swallowing the error here made Get-ADObjectsSequential count the base as successful
            { Get-ADObjectFromSearchBase -SearchBase $Base } | Should -Throw -ExpectedMessage $Expected
            Should -Invoke Write-Warning -Times 0 -Exactly
        }
    }

    Context "Retries (#89)" {
        It "Reads through the retry wrapper with -MaxRetries plus the first attempt" {
            Get-ADObjectFromSearchBase -SearchBase 'OU=Users,DC=contoso,DC=com' -MaxRetries 5 -CorrelationId 'r-1'

            Should -Invoke Invoke-ADOperationWithRetry -Times 1 -Exactly -ParameterFilter {
                $MaxRetries -eq 6 -and $OperationName -eq 'Get-ADObject-SearchBase' -and
                $ObjectContext -eq 'OU=Users,DC=contoso,DC=com' -and $CorrelationId -eq 'r-1'
            }
        }

        It "Allows four attempts by default" {
            Get-ADObjectFromSearchBase -SearchBase 'OU=Users,DC=contoso,DC=com'

            Should -Invoke Invoke-ADOperationWithRetry -Times 1 -Exactly -ParameterFilter { $MaxRetries -eq 4 }
        }

        It "Rejects -MaxRetries outside 0-10" {
            { Get-ADObjectFromSearchBase -SearchBase 'OU=Users,DC=contoso,DC=com' -MaxRetries 11 } | Should -Throw -ExpectedMessage '*MaxRetries*'
        }
    }

    Context "Get-ADObject call" {
        It "Should call Get-ADObject with the SearchBase, Filter * and ErrorAction Stop" {
            Get-ADObjectFromSearchBase -SearchBase 'OU=Users,DC=contoso,DC=com'

            Should -Invoke Get-ADObject -Times 1 -Exactly -ParameterFilter {
                $SearchBase -eq 'OU=Users,DC=contoso,DC=com' -and
                $Filter -eq '*' -and
                $ErrorAction -eq 'Stop'
            }
        }

        It "Should request only nTSecurityDescriptor by default" {
            Get-ADObjectFromSearchBase -SearchBase 'OU=Users,DC=contoso,DC=com'

            Should -Invoke Get-ADObject -Times 1 -Exactly -ParameterFilter {
                @($Properties).Count -eq 1 -and @($Properties)[0] -eq 'nTSecurityDescriptor'
            }
        }

        It "Should add nTSecurityDescriptor to custom properties" {
            $customProperties = @('Name', 'Description', 'mail')
            Get-ADObjectFromSearchBase -SearchBase 'OU=Users,DC=contoso,DC=com' -Properties $customProperties

            Should -Invoke Get-ADObject -Times 1 -Exactly -ParameterFilter {
                @($Properties).Count -eq 4 -and
                $Properties -contains 'nTSecurityDescriptor' -and
                $Properties -contains 'Name' -and
                $Properties -contains 'Description' -and
                $Properties -contains 'mail'
            }
        }

        It "Should not request nTSecurityDescriptor twice when the caller names it" {
            Get-ADObjectFromSearchBase -SearchBase 'OU=Users,DC=contoso,DC=com' -Properties @('nTSecurityDescriptor', 'Name')

            Should -Invoke Get-ADObject -Times 1 -Exactly -ParameterFilter {
                @($Properties | Where-Object { $_ -eq 'nTSecurityDescriptor' }).Count -eq 1 -and
                @($Properties).Count -eq 2
            }
        }
    }
}
