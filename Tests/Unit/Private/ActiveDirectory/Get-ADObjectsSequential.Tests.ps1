#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
BeforeAll {
    $privateRoot = Join-Path $PSScriptRoot '..\..\..\..\Private'

    # The real collaborators are dot-sourced so each mock carries the real parameter block: a call
    # that would not bind to the real Get-ADObjectFromSearchBase does not bind to its mock either.
    . (Join-Path $privateRoot 'Logging\Write-ADOperationSecurityLog.ps1')
    . (Join-Path $privateRoot 'ActiveDirectory\Get-ADObjectFromSearchBase.ps1')
    . (Join-Path $privateRoot 'ActiveDirectory\Get-ADObjectsSequential.ps1')

    function New-TestADObject {
        param([string]$Name, [string]$ObjectClass, [string]$Container)
        [PSCustomObject]@{
            DistinguishedName = "CN=$Name,$Container"
            Name = $Name
            ObjectClass = $ObjectClass
            nTSecurityDescriptor = "SD-$Name"
        }
    }

    $script:Users = 'OU=Users,DC=contoso,DC=com'
    $script:Groups = 'OU=Groups,DC=contoso,DC=com'
    $script:Computers = 'OU=Computers,DC=contoso,DC=com'
    $script:Empty = 'OU=Empty,DC=contoso,DC=com'
    $script:Invalid1 = 'OU=Invalid1,DC=contoso,DC=com'
    $script:Invalid2 = 'OU=Invalid2,DC=contoso,DC=com'

    $script:ObjectsByBase = @{
        $script:Users = @(
            New-TestADObject -Name 'User1' -ObjectClass 'user' -Container $script:Users
            New-TestADObject -Name 'User2' -ObjectClass 'user' -Container $script:Users
            New-TestADObject -Name 'User3' -ObjectClass 'user' -Container $script:Users
        )
        $script:Groups = @(New-TestADObject -Name 'Group1' -ObjectClass 'group' -Container $script:Groups)
        $script:Computers = @(New-TestADObject -Name 'Computer1$' -ObjectClass 'computer' -Container $script:Computers)
    }
}

Describe "Get-ADObjectsSequential" -Tag 'Unit' {

    BeforeEach {
        Mock Write-ADOperationSecurityLog { }
        Mock Write-Verbose { }
        Mock Write-Warning { }
        Mock Get-ADObjectFromSearchBase {
            if ($SearchBase -like '*Invalid*') {
                throw 'The specified domain either does not exist or could not be contacted.'
            }
            if ($script:ObjectsByBase.ContainsKey($SearchBase)) {
                $script:ObjectsByBase[$SearchBase]
            }
        }
    }

    Context "Parameter validation" {
        It "Rejects a null SearchBase" {
            { Get-ADObjectsSequential -SearchBase $null } | Should -Throw -ExpectedMessage '*SearchBase*'
            Should -Invoke Get-ADObjectFromSearchBase -Times 0 -Exactly
        }

        It "Rejects an empty SearchBase array" {
            { Get-ADObjectsSequential -SearchBase @() } | Should -Throw -ExpectedMessage '*SearchBase*'
            Should -Invoke Get-ADObjectFromSearchBase -Times 0 -Exactly
        }
    }

    Context "Sequential processing" {
        It "Returns the objects from every search base in search-base order" {
            $results = Get-ADObjectsSequential -SearchBase $script:Users, $script:Groups, $script:Computers

            $results.Name | Should -Be @('User1', 'User2', 'User3', 'Group1', 'Computer1$')
        }

        It "Calls Get-ADObjectFromSearchBase once per search base, each with a single string" {
            # A loop variable named like the [string[]] parameter in another letter case is the same
            # variable, so each element arrived as a one-element array and did not bind to [string].
            # The mock carries the real [string] parameter, so such a call would fail and log a Failure.
            Get-ADObjectsSequential -SearchBase $script:Users, $script:Groups, $script:Computers | Out-Null

            Should -Invoke Get-ADObjectFromSearchBase -Times 3 -Exactly
            foreach ($base in $script:Users, $script:Groups, $script:Computers) {
                Should -Invoke Get-ADObjectFromSearchBase -Times 1 -Exactly -ParameterFilter { $SearchBase -eq $base }
            }
            Should -Invoke Write-ADOperationSecurityLog -Times 0 -Exactly -ParameterFilter { $Outcome -eq 'Failure' }
        }

        It "Accepts a single search base string" {
            $results = Get-ADObjectsSequential -SearchBase $script:Groups

            @($results).Count | Should -Be 1
            $results.Name | Should -Be 'Group1'
        }

        It "Passes IncludeInherited and CorrelationId to Get-ADObjectFromSearchBase" {
            $correlationId = [System.Guid]::NewGuid().ToString()

            Get-ADObjectsSequential -SearchBase $script:Users -IncludeInherited -CorrelationId $correlationId | Out-Null

            Should -Invoke Get-ADObjectFromSearchBase -Times 1 -Exactly -ParameterFilter {
                $IncludeInherited -eq $true -and $CorrelationId -eq $correlationId
            }
        }

        It "Passes IncludeInherited as false when the switch is omitted" {
            Get-ADObjectsSequential -SearchBase $script:Users | Out-Null

            Should -Invoke Get-ADObjectFromSearchBase -Times 1 -Exactly -ParameterFilter { -not $IncludeInherited }
        }

        It "Treats a search base with no objects as successful" {
            $results = Get-ADObjectsSequential -SearchBase $script:Empty, $script:Groups

            @($results).Count | Should -Be 1
            Should -Invoke Write-Verbose -Times 1 -Exactly -ParameterFilter {
                $Message -eq "No objects found in $($script:Empty) (not an error)"
            }
            Should -Invoke Write-ADOperationSecurityLog -Times 1 -Exactly -ParameterFilter {
                $Outcome -eq 'Success' -and $SecurityContext.SuccessfulBases -eq 2 -and $SecurityContext.FailedBases -eq 0
            }
        }
    }

    Context "Security logging" {
        It "Logs an Attempt with the search base count, IncludeInherited and correlation ID" {
            $correlationId = [System.Guid]::NewGuid().ToString()

            Get-ADObjectsSequential -SearchBase $script:Users, $script:Groups -IncludeInherited -CorrelationId $correlationId | Out-Null

            Should -Invoke Write-ADOperationSecurityLog -Times 1 -Exactly -ParameterFilter {
                $OperationName -eq 'Get-ADObjectsSequential' -and
                $Outcome -eq 'Attempt' -and
                $CorrelationId -eq $correlationId -and
                $SecurityContext.SearchBaseCount -eq 2 -and
                $SecurityContext.IncludeInherited -eq $true -and
                $SecurityContext.ProcessingType -eq 'Sequential' -and
                $SecurityContext.ADAccessType -eq 'BulkRetrieval'
            }
        }

        It "Logs Success with the base and object counts and a result summary" {
            $correlationId = [System.Guid]::NewGuid().ToString()

            Get-ADObjectsSequential -SearchBase $script:Users, $script:Groups -CorrelationId $correlationId | Out-Null

            Should -Invoke Write-ADOperationSecurityLog -Times 1 -Exactly -ParameterFilter {
                $Outcome -eq 'Success' -and
                $CorrelationId -eq $correlationId -and
                $SecurityContext.SearchBaseCount -eq 2 -and
                $SecurityContext.SuccessfulBases -eq 2 -and
                $SecurityContext.FailedBases -eq 0 -and
                $SecurityContext.TotalObjectsRetrieved -eq 4 -and
                $SecurityContext.IncludeInherited -eq $false -and
                $SecurityContext.ResultSummary -eq 'Retrieved 4 objects from 2/2 search bases'
            }
        }

        It "Counts a single search base string as one base" {
            Get-ADObjectsSequential -SearchBase $script:Users | Out-Null

            Should -Invoke Write-ADOperationSecurityLog -Times 1 -Exactly -ParameterFilter {
                $Outcome -eq 'Attempt' -and $SecurityContext.SearchBaseCount -eq 1
            }
        }
    }

    Context "Error handling" {
        It "Continues past a failing search base and returns the others' objects" {
            $results = Get-ADObjectsSequential -SearchBase $script:Users, $script:Invalid1, $script:Groups

            $results.Name | Should -Be @('User1', 'User2', 'User3', 'Group1')
            Should -Invoke Get-ADObjectFromSearchBase -Times 3 -Exactly
        }

        It "Warns and logs a Failure naming the failed search base and error" {
            $correlationId = [System.Guid]::NewGuid().ToString()

            Get-ADObjectsSequential -SearchBase $script:Users, $script:Invalid1 -CorrelationId $correlationId | Out-Null

            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
                $Message -eq "Failed to process search base $($script:Invalid1) : The specified domain either does not exist or could not be contacted."
            }
            Should -Invoke Write-ADOperationSecurityLog -Times 1 -Exactly -ParameterFilter {
                $Outcome -eq 'Failure' -and
                $CorrelationId -eq $correlationId -and
                $SecurityContext.FailedSearchBase -eq $script:Invalid1 -and
                $SecurityContext.ErrorMessage -eq 'The specified domain either does not exist or could not be contacted.' -and
                $SecurityContext.ContinueProcessing -eq $true
            }
        }

        It "Logs one Failure per failing base and reports them in the Success summary" {
            $results = Get-ADObjectsSequential -SearchBase $script:Invalid1, $script:Invalid2

            $results | Should -BeNullOrEmpty
            Should -Invoke Write-ADOperationSecurityLog -Times 2 -Exactly -ParameterFilter { $Outcome -eq 'Failure' }
            Should -Invoke Write-ADOperationSecurityLog -Times 1 -Exactly -ParameterFilter {
                $Outcome -eq 'Success' -and
                $SecurityContext.SuccessfulBases -eq 0 -and
                $SecurityContext.FailedBases -eq 2 -and
                $SecurityContext.TotalObjectsRetrieved -eq 0
            }
        }
    }

    Context "Verbose progress" {
        It "Reports the number of search bases at the start" {
            Get-ADObjectsSequential -SearchBase $script:Users, $script:Groups, $script:Computers | Out-Null

            Should -Invoke Write-Verbose -Times 1 -Exactly -ParameterFilter {
                $Message -eq 'Starting sequential AD object retrieval from 3 search bases'
            }
        }

        It "Reports the totals at the end" {
            Get-ADObjectsSequential -SearchBase $script:Users, $script:Invalid1 | Out-Null

            Should -Invoke Write-Verbose -Times 1 -Exactly -ParameterFilter {
                $Message -eq 'Sequential processing completed: 3 objects from 1/2 search bases'
            }
        }
    }
}
