#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }

<#
.SYNOPSIS
    Unit tests for the Find-OrphanedSid public command.

.DESCRIPTION
    Exercises the command's own responsibilities: parameter validation, collecting pipeline input,
    defaulting the search base, emitting the streamed results to the pipeline before cleanup, and
    always closing the session. The processing engine behind it is mocked; it has its own tests
    under Tests/Unit/Private/Core.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\TestHelpers\ADCmdletStubs.ps1"
    Import-Module "$PSScriptRoot\..\..\..\OrphanedSid.psd1" -Force

    # A stand-in for StreamingResultsManager: only GetAllResults() is read by the command
    $script:fakeResults = @(
        [PSCustomObject]@{ ObjectDN = 'CN=A,DC=contoso,DC=com'; OrphanedSID = 'S-1-5-21-1-2-3-1001' }
        [PSCustomObject]@{ ObjectDN = 'CN=B,DC=contoso,DC=com'; OrphanedSID = 'S-1-5-21-1-2-3-1002' }
    )
    $script:fakeManager = [PSCustomObject]@{ TempDirectory = 'C:\Temp\fake' }
    $script:fakeManager | Add-Member -MemberType ScriptMethod -Name GetAllResults -Value { $script:fakeResults }

    # Stands in for an object from Get-ADOrganizationalUnit: the AD adapter answers any property
    # name, so 'SearchBase' and 'TargetObjectDN' come back as empty collections. By-property
    # binding to a [string[]] parameter found those before the DistinguishedName alias (#79).
    function New-ADLikeObject([string]$DistinguishedName) {
        [PSCustomObject]@{
            DistinguishedName = $DistinguishedName
            SearchBase        = [System.Collections.Generic.List[object]]::new()
            TargetObjectDN    = [System.Collections.Generic.List[object]]::new()
        }
    }
}

Describe 'Find-OrphanedSid' -Tag 'Unit', 'Public' {

    BeforeEach {
        Mock -ModuleName OrphanedSid Start-OrphanedSidSession { @{ CorrelationId = $CorrelationId } }
        Mock -ModuleName OrphanedSid Stop-OrphanedSidSession { }
        Mock -ModuleName OrphanedSid Write-ProcessingSummary { }
        Mock -ModuleName OrphanedSid Write-StructuredLog { }
        Mock -ModuleName OrphanedSid Invoke-MainProcessingLogic {
            @{ StreamingManager = $script:fakeManager; RemovalResults = @(); OrphanedSIDsFound = 2 }
        }
        Mock -ModuleName OrphanedSid Get-ADDomain { [PSCustomObject]@{ DistinguishedName = 'DC=contoso,DC=com' } }
    }

    Context 'Parameter validation' {
        It 'Rejects an -OutputPath whose folder does not exist' {
            { Find-OrphanedSid -SearchBase 'DC=contoso,DC=com' -OutputPath 'C:\does\not\exist\out.csv' } |
                Should -Throw '*does not exist*'
        }

        It 'Rejects a -ConfigPath that is not a file' {
            { Find-OrphanedSid -SearchBase 'DC=contoso,DC=com' -ConfigPath 'C:\nope.json' } |
                Should -Throw '*Configuration file not found*'
        }

        It 'Rejects -MaxMemoryUsageMB outside 100-16384' {
            { Find-OrphanedSid -SearchBase 'DC=contoso,DC=com' -MaxMemoryUsageMB 50 } | Should -Throw '*MaxMemoryUsageMB*'
        }

        It 'Rejects an unknown -LogLevel' {
            { Find-OrphanedSid -SearchBase 'DC=contoso,DC=com' -LogLevel 'Chatty' } | Should -Throw '*LogLevel*'
        }
    }

    Context 'Search base handling' {
        It 'Passes every search base to the processing engine in one call' {
            Find-OrphanedSid -SearchBase 'OU=A,DC=contoso,DC=com', 'OU=B,DC=contoso,DC=com' | Out-Null

            Should -Invoke -ModuleName OrphanedSid Invoke-MainProcessingLogic -Times 1 -Exactly -ParameterFilter {
                $SearchBase.Count -eq 2 -and $SearchBase -contains 'OU=B,DC=contoso,DC=com'
            }
        }

        It 'Collects pipeline input by value' {
            'OU=A,DC=contoso,DC=com', ' OU=B,DC=contoso,DC=com ', '  ' | Find-OrphanedSid | Out-Null

            # Blank entries are dropped and the rest trimmed
            Should -Invoke -ModuleName OrphanedSid Invoke-MainProcessingLogic -Times 1 -Exactly -ParameterFilter {
                $SearchBase.Count -eq 2 -and $SearchBase[0] -eq 'OU=A,DC=contoso,DC=com' -and $SearchBase[1] -eq 'OU=B,DC=contoso,DC=com'
            }
        }

        It 'Collects pipeline input from a DistinguishedName property' {
            [PSCustomObject]@{ DistinguishedName = 'OU=Piped,DC=contoso,DC=com' } | Find-OrphanedSid | Out-Null

            Should -Invoke -ModuleName OrphanedSid Invoke-MainProcessingLogic -Times 1 -Exactly -ParameterFilter {
                $SearchBase -eq 'OU=Piped,DC=contoso,DC=com'
            }
        }

        It 'Reads the DN of piped AD objects instead of falling back to the domain root (#79)' {
            (New-ADLikeObject 'OU=A,DC=contoso,DC=com'), (New-ADLikeObject 'OU=B,DC=contoso,DC=com') |
                Find-OrphanedSid -WarningVariable warnings -WarningAction SilentlyContinue | Out-Null

            @($warnings).Count | Should -Be 0
            Should -Invoke -ModuleName OrphanedSid Get-ADDomain -Times 0 -Exactly
            Should -Invoke -ModuleName OrphanedSid Invoke-MainProcessingLogic -Times 1 -Exactly -ParameterFilter {
                $SearchBase.Count -eq 2 -and $SearchBase[0] -eq 'OU=A,DC=contoso,DC=com' -and $SearchBase[1] -eq 'OU=B,DC=contoso,DC=com'
            }
        }

        It 'Reads the DN of an AD object passed to -SearchBase' {
            Find-OrphanedSid -SearchBase (New-ADLikeObject 'OU=Named,DC=contoso,DC=com') | Out-Null

            Should -Invoke -ModuleName OrphanedSid Invoke-MainProcessingLogic -Times 1 -Exactly -ParameterFilter {
                $SearchBase -eq 'OU=Named,DC=contoso,DC=com'
            }
        }

        It 'Refuses input with no usable DN instead of scanning the domain root (#79)' {
            { [PSCustomObject]@{ Name = 'NoDN' } | Find-OrphanedSid -ErrorAction SilentlyContinue } |
                Should -Throw '*No usable search base*'

            Should -Invoke -ModuleName OrphanedSid Get-ADDomain -Times 0 -Exactly
            Should -Invoke -ModuleName OrphanedSid Invoke-MainProcessingLogic -Times 0 -Exactly
        }

        It 'Refuses a -SearchBase that is only blank' {
            { Find-OrphanedSid -SearchBase '  ' } | Should -Throw '*No usable search base*'

            Should -Invoke -ModuleName OrphanedSid Get-ADDomain -Times 0 -Exactly
        }

        It 'Defaults to the domain root when no search base is given' {
            Find-OrphanedSid -WarningVariable warnings -WarningAction SilentlyContinue | Out-Null

            @($warnings).Count | Should -Be 1
            $warnings[0].Message | Should -Be 'No search base specified. Using the current domain root.'
            Should -Invoke -ModuleName OrphanedSid Get-ADDomain -Times 1 -Exactly
            Should -Invoke -ModuleName OrphanedSid Invoke-MainProcessingLogic -Times 1 -Exactly -ParameterFilter {
                $SearchBase -eq 'DC=contoso,DC=com'
            }
        }

        It 'Forwards -IncludeInherited and -MaxRetries' {
            Find-OrphanedSid -SearchBase 'DC=contoso,DC=com' -IncludeInherited -MaxRetries 7 | Out-Null

            Should -Invoke -ModuleName OrphanedSid Invoke-MainProcessingLogic -Times 1 -Exactly -ParameterFilter {
                $IncludeInherited -and $MaxRetries -eq 7
            }
        }
    }

    Context 'Output' {
        It 'Writes every streamed result to the pipeline' {
            $results = @(Find-OrphanedSid -SearchBase 'DC=contoso,DC=com')

            $results.Count | Should -Be 2
            $results.OrphanedSID | Should -Be @('S-1-5-21-1-2-3-1001', 'S-1-5-21-1-2-3-1002')
        }

        It 'Writes nothing when the engine found nothing' {
            Mock -ModuleName OrphanedSid Invoke-MainProcessingLogic {
                $empty = [PSCustomObject]@{ TempDirectory = 'x' }
                $empty | Add-Member -MemberType ScriptMethod -Name GetAllResults -Value { @() }
                @{ StreamingManager = $empty; RemovalResults = @() }
            }

            @(Find-OrphanedSid -SearchBase 'DC=contoso,DC=com').Count | Should -Be 0
        }

        It 'Hands -OutputPath to the summary writer' {
            $csv = Join-Path $TestDrive 'out.csv'
            Find-OrphanedSid -SearchBase 'DC=contoso,DC=com' -OutputPath $csv | Out-Null

            Should -Invoke -ModuleName OrphanedSid Write-ProcessingSummary -Times 1 -Exactly -ParameterFilter {
                $OutputPath -eq $csv -and $ProcessingResults.OrphanedSIDsFound -eq 2
            }
        }
    }

    Context 'Session lifecycle' {
        It 'Starts the session with the command name and requires Active Directory' {
            Find-OrphanedSid -SearchBase 'DC=contoso,DC=com' -CorrelationId 'corr-1' | Out-Null

            Should -Invoke -ModuleName OrphanedSid Start-OrphanedSidSession -Times 1 -Exactly -ParameterFilter {
                $CommandName -eq 'Find-OrphanedSid' -and $RequireActiveDirectory -and $CorrelationId -eq 'corr-1'
            }
        }

        It 'Stops the session even when the engine throws' {
            Mock -ModuleName OrphanedSid Invoke-MainProcessingLogic { throw 'engine failed' }

            { Find-OrphanedSid -SearchBase 'DC=contoso,DC=com' -CorrelationId 'corr-2' } | Should -Throw '*engine failed*'

            Should -Invoke -ModuleName OrphanedSid Stop-OrphanedSidSession -Times 1 -Exactly -ParameterFilter { $CorrelationId -eq 'corr-2' }
            Should -Invoke -ModuleName OrphanedSid Write-ProcessingSummary -Times 0 -Exactly
            Should -Invoke -ModuleName OrphanedSid Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Error' -and $Message -eq 'Discovery failed: engine failed'
            }
        }

        It 'Passes -PreserveTempFiles through to the session stop' {
            Find-OrphanedSid -SearchBase 'DC=contoso,DC=com' -PreserveTempFiles | Out-Null

            Should -Invoke -ModuleName OrphanedSid Stop-OrphanedSidSession -Times 1 -Exactly -ParameterFilter {
                $PreserveTempFiles
            }
        }
    }
}
