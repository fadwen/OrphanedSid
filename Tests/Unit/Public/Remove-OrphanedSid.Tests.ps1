#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }

<#
.SYNOPSIS
    Unit tests for the Remove-OrphanedSid public command.

.DESCRIPTION
    Covers the confirmation gate, the backup folder convention, the pass-through to the processing
    engine with -Remove, the result emission and the session lifecycle. The engine is mocked.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\TestHelpers\ADCmdletStubs.ps1"
    Import-Module "$PSScriptRoot\..\..\..\OrphanedSid.psd1" -Force

    $script:fakeManager = [PSCustomObject]@{ TempDirectory = 'C:\Temp\fake' }
    $script:fakeManager | Add-Member -MemberType ScriptMethod -Name GetAllResults -Value { @() }
    $script:fakeRemovals = @(
        [PSCustomObject]@{ ObjectDN = 'CN=A,DC=contoso,DC=com'; Success = $true }
        [PSCustomObject]@{ ObjectDN = 'CN=B,DC=contoso,DC=com'; Success = $false }
    )

    # Stands in for an object from Get-ADOrganizationalUnit: the AD adapter answers any property
    # name, so 'SearchBase' comes back as an empty collection. By-property binding to a [string[]]
    # parameter found it before the DistinguishedName alias and the removal widened to the domain
    # root (#79).
    function New-ADLikeObject([string]$DistinguishedName) {
        [PSCustomObject]@{
            DistinguishedName = $DistinguishedName
            SearchBase        = [System.Collections.Generic.List[object]]::new()
        }
    }
}

Describe 'Remove-OrphanedSid' -Tag 'Unit', 'Public' {

    BeforeEach {
        Mock -ModuleName OrphanedSid Start-OrphanedSidSession { @{ CorrelationId = $CorrelationId } }
        Mock -ModuleName OrphanedSid Stop-OrphanedSidSession { }
        Mock -ModuleName OrphanedSid Write-ProcessingSummary { }
        Mock -ModuleName OrphanedSid Write-StructuredLog { }
        Mock -ModuleName OrphanedSid Invoke-MainProcessingLogic {
            @{ StreamingManager = $script:fakeManager; RemovalResults = $script:fakeRemovals }
        }
        Mock -ModuleName OrphanedSid Get-ADDomain { [PSCustomObject]@{ DistinguishedName = 'DC=contoso,DC=com' } }

        # Each test gets its own working directory so the default .\Backup lands under TestDrive
        $script:priorLocation = Get-Location
        Set-Location $TestDrive
    }

    AfterEach {
        Set-Location $script:priorLocation
    }

    Context 'Confirmation gate' {
        It 'Runs the engine with -Remove when -Force is given' {
            Remove-OrphanedSid -SearchBase 'OU=X,DC=contoso,DC=com' -Force | Out-Null

            Should -Invoke -ModuleName OrphanedSid Invoke-MainProcessingLogic -Times 1 -Exactly -ParameterFilter {
                $Remove -and $SearchBase -eq 'OU=X,DC=contoso,DC=com'
            }
        }

        It 'Runs the engine when confirmation is suppressed with -Confirm:$false' {
            Remove-OrphanedSid -SearchBase 'OU=X,DC=contoso,DC=com' -Confirm:$false | Out-Null

            Should -Invoke -ModuleName OrphanedSid Invoke-MainProcessingLogic -Times 1 -Exactly
        }

        It 'Under -WhatIf still runs discovery but creates no backup folder' {
            # TestDrive persists across the tests in this Describe, so use a root no other test writes to
            $root = Join-Path $TestDrive 'WhatIfRoot'
            New-Item -Path $root -ItemType Directory | Out-Null

            Remove-OrphanedSid -SearchBase 'OU=X,DC=contoso,DC=com' -WhatIf -BackupPath $root | Out-Null

            Should -Invoke -ModuleName OrphanedSid Invoke-MainProcessingLogic -Times 1 -Exactly -ParameterFilter { $Remove }
            @(Get-ChildItem $root -Directory).Count | Should -Be 0
        }
    }

    Context 'Search base handling' {
        It 'Removes only under a piped AD object, never the domain root (#79)' {
            New-ADLikeObject 'OU=Piped,DC=contoso,DC=com' |
                Remove-OrphanedSid -Force -WarningVariable warnings -WarningAction SilentlyContinue | Out-Null

            @($warnings).Count | Should -Be 0
            Should -Invoke -ModuleName OrphanedSid Get-ADDomain -Times 0 -Exactly
            Should -Invoke -ModuleName OrphanedSid Invoke-MainProcessingLogic -Times 1 -Exactly -ParameterFilter {
                $Remove -and $SearchBase.Count -eq 1 -and $SearchBase[0] -eq 'OU=Piped,DC=contoso,DC=com'
            }
        }

        It 'Reads Import-Csv rows and hashtables by their DistinguishedName' {
            [PSCustomObject]@{ DistinguishedName = 'OU=Row,DC=contoso,DC=com' }, @{ DistinguishedName = 'OU=Hash,DC=contoso,DC=com' } |
                Remove-OrphanedSid -Force | Out-Null

            Should -Invoke -ModuleName OrphanedSid Invoke-MainProcessingLogic -Times 1 -Exactly -ParameterFilter {
                $SearchBase.Count -eq 2 -and $SearchBase -contains 'OU=Row,DC=contoso,DC=com' -and $SearchBase -contains 'OU=Hash,DC=contoso,DC=com'
            }
        }

        It 'Refuses input with no usable DN and removes nothing (#79)' {
            { [PSCustomObject]@{ Name = 'NoDN' } | Remove-OrphanedSid -Force -ErrorAction SilentlyContinue } |
                Should -Throw '*No usable search base*'

            Should -Invoke -ModuleName OrphanedSid Get-ADDomain -Times 0 -Exactly
            Should -Invoke -ModuleName OrphanedSid Invoke-MainProcessingLogic -Times 0 -Exactly
        }

        It 'Still defaults to the domain root, with a warning, when -SearchBase is not given' {
            Remove-OrphanedSid -Force -WarningVariable warnings -WarningAction SilentlyContinue | Out-Null

            $warnings[0].Message | Should -Be 'No search base specified. Using the current domain root.'
            Should -Invoke -ModuleName OrphanedSid Invoke-MainProcessingLogic -Times 1 -Exactly -ParameterFilter {
                $SearchBase -eq 'DC=contoso,DC=com'
            }
        }
    }

    Context 'Backup folder' {
        It 'Creates a timestamped folder under .\Backup by default' {
            Remove-OrphanedSid -SearchBase 'OU=X,DC=contoso,DC=com' -Force | Out-Null

            $runFolders = @(Get-ChildItem (Join-Path $TestDrive 'Backup') -Directory)
            $runFolders.Count | Should -Be 1
            $runFolders[0].Name | Should -Match '^\d{8}_\d{6}$'
            Should -Invoke -ModuleName OrphanedSid Invoke-MainProcessingLogic -Times 1 -Exactly -ParameterFilter {
                $BackupPath -eq $runFolders[0].FullName
            }
        }

        It 'Creates the timestamped folder under an explicit -BackupPath' {
            $root = Join-Path $TestDrive 'MyBackups'
            New-Item -Path $root -ItemType Directory | Out-Null

            Remove-OrphanedSid -SearchBase 'OU=X,DC=contoso,DC=com' -Force -BackupPath $root | Out-Null

            $runFolders = @(Get-ChildItem $root -Directory)
            $runFolders.Count | Should -Be 1
            $runFolders[0].Name | Should -Match '^\d{8}_\d{6}$'
            Should -Invoke -ModuleName OrphanedSid Invoke-MainProcessingLogic -Times 1 -Exactly -ParameterFilter {
                $BackupPath -eq $runFolders[0].FullName
            }
        }

        It 'Rejects a -BackupPath whose parent folder does not exist' {
            { Remove-OrphanedSid -SearchBase 'OU=X,DC=contoso,DC=com' -Force -BackupPath 'C:\no\such\parent\Backup' } |
                Should -Throw '*parent folder*'
        }
    }

    Context 'Output and lifecycle' {
        It 'Writes every removal result to the pipeline' {
            $results = @(Remove-OrphanedSid -SearchBase 'OU=X,DC=contoso,DC=com' -Force)

            $results.Count | Should -Be 2
            $results.ObjectDN | Should -Be @('CN=A,DC=contoso,DC=com', 'CN=B,DC=contoso,DC=com')
            $results.Success | Should -Be @($true, $false)
            Should -Invoke -ModuleName OrphanedSid Write-ProcessingSummary -Times 1 -Exactly
        }

        It 'Starts the session under its own command name' {
            Remove-OrphanedSid -SearchBase 'OU=X,DC=contoso,DC=com' -Force | Out-Null

            Should -Invoke -ModuleName OrphanedSid Start-OrphanedSidSession -Times 1 -Exactly -ParameterFilter {
                $CommandName -eq 'Remove-OrphanedSid' -and $RequireActiveDirectory
            }
        }

        It 'Stops the session even when the engine throws' {
            Mock -ModuleName OrphanedSid Invoke-MainProcessingLogic { throw 'engine failed' }

            { Remove-OrphanedSid -SearchBase 'OU=X,DC=contoso,DC=com' -Force -CorrelationId 'rm-corr' } | Should -Throw '*engine failed*'

            Should -Invoke -ModuleName OrphanedSid Stop-OrphanedSidSession -Times 1 -Exactly -ParameterFilter { $CorrelationId -eq 'rm-corr' }
            Should -Invoke -ModuleName OrphanedSid Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Error' -and $Message -eq 'Removal failed: engine failed'
            }
        }
    }
}
