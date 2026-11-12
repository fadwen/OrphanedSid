#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
#Requires -Version 5.1

<#
.SYNOPSIS
    Scenario tests for Write-ProcessingSummary: discovery, removal and restore results, and CSV
    export.

.DESCRIPTION
    Write-ProcessingSummary.Tests.ps1 checks the parameters and that the summary logs something.
    These tests check what it logs for each shape of result the three public commands hand it, and
    where the CSV goes. Only Write-StructuredLog is mocked; the CSV export writes to TestDrive.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\..\Private\Reporting\Write-ProcessingSummary.ps1"

    function Write-StructuredLog { param($Message, $Level, $Component, $CorrelationId, $LogPath, $Data) }

    function New-DiscoveryResults {
        param([int]$Found = 2, [int]$Errors = 0, [int]$TotalResults = 2, [int]$Unverified = -1, [int]$Unexamined = -1, [switch]$AsHashtable)
        $manager = [PSCustomObject]@{ Summary = [PSCustomObject]@{ TotalResults = $TotalResults }; Exported = $null }
        $manager | Add-Member -MemberType ScriptMethod -Name ExportToCsv -Value { param($Path) $this.Exported = $Path; 'ObjectDN,OrphanedSID' | Set-Content $Path; $true }
        $results = [ordered]@{
            TotalObjectsProcessed = 37
            ProcessingDuration    = [TimeSpan]::FromSeconds(17.8)
            ObjectsPerSecond      = 2.079
            PeakMemoryUsageMB     = 141.5
            OrphanedSIDsFound     = $Found
            ProcessingErrors      = $Errors
            StreamingManager      = $manager
            RemovalResults        = @()
        }
        if ($Unverified -ge 0) {
            $results.UnverifiedSIDsFound = $Unverified
        }
        if ($Unexamined -ge 0) {
            $results.UnexaminedObjects = $Unexamined
        }
        # Invoke-MainProcessingLogic hands the summary a hashtable
        if ($AsHashtable) {
            return [hashtable]$results
        }
        [PSCustomObject]$results
    }

    function New-RestoreResults {
        param([int]$Failed = 0, [object[]]$Results)
        [PSCustomObject]@{
            TotalObjectsProcessed = $Results.Count
            ProcessingDuration    = [TimeSpan]::FromMilliseconds(312)
            SuccessfulRestores    = $Results.Count - $Failed
            FailedRestores        = $Failed
            BackupPath            = 'C:\OrphanedSidTest\Backup\20261108_133153'
            WhatIfMode            = $false
            RestoreResults        = $Results
        }
    }
}

Describe 'Write-ProcessingSummary' -Tag 'Unit', 'Reporting', 'Private' {

    BeforeEach {
        Mock Write-StructuredLog { }
        $script:csv = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.csv')
    }

    Context 'Discovery results' {
        It 'Logs the totals, rate, memory, errors and orphan count' {
            Write-ProcessingSummary -ProcessingResults (New-DiscoveryResults) -CorrelationId 'sum-1'

            foreach ($expected in 'Total objects processed: 37', 'Processing duration: 00:00:17.800', 'Processing rate: 2.08 objects/second',
                'Peak memory usage: 141.5 MB', 'Processing errors: 0', 'Orphaned SIDs found: 2', 'Processing summary completed') {
                Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Message -eq $expected -and $Component -eq 'Summary' -and $CorrelationId -eq 'sum-1' }
            }
            Should -Invoke Write-StructuredLog -Times 0 -ParameterFilter { $Message -like '*RESTORE*' }
        }

        It 'Logs the same totals for the hashtable Invoke-MainProcessingLogic returns' {
            Write-ProcessingSummary -ProcessingResults (New-DiscoveryResults -AsHashtable -Unverified 0) -CorrelationId 'sum-h'

            foreach ($expected in 'Processing rate: 2.08 objects/second', 'Peak memory usage: 141.5 MB', 'Processing errors: 0',
                'Orphaned SIDs found: 2', 'Unverified SIDs (lookup failed, not removed): 0') {
                Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Message -eq $expected -and $CorrelationId -eq 'sum-h' }
            }
        }

        It 'Counts unverified SIDs and warns that they were not removed' {
            Write-ProcessingSummary -ProcessingResults (New-DiscoveryResults -AsHashtable -Unverified 3)

            Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Message -eq 'Unverified SIDs (lookup failed, not removed): 3' }
            Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Level -eq 'Warning' -and $Message -like '3 SID(s) could not be verified*not removed*' }
        }

        It 'Does not warn when every SID was verified' {
            Write-ProcessingSummary -ProcessingResults (New-DiscoveryResults -AsHashtable -Unverified 0)

            Should -Invoke Write-StructuredLog -Times 0 -ParameterFilter { $Level -eq 'Warning' -and $Message -like '*could not be verified*' }
        }

        It 'Counts objects that could not be examined and warns that they were not checked (#47)' {
            Write-ProcessingSummary -ProcessingResults (New-DiscoveryResults -AsHashtable -Unexamined 2)

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter { $Message -eq 'Objects not examined (security descriptor not readable): 2' }
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'Warning' -and $Message -like '2 object(s) could not be examined*Re-run with an account that may read them.' }
        }

        It 'Does not warn when every object was examined' {
            Write-ProcessingSummary -ProcessingResults (New-DiscoveryResults -AsHashtable -Unexamined 0)

            Should -Invoke Write-StructuredLog -Times 0 -Exactly -ParameterFilter { $Level -eq 'Warning' -and $Message -like '*could not be examined*' }
        }

        It 'Exports the streamed results to the CSV path through the streaming manager' {
            $results = New-DiscoveryResults

            Write-ProcessingSummary -ProcessingResults $results -OutputPath $script:csv

            $results.StreamingManager.Exported | Should -Be $script:csv
            Test-Path $script:csv | Should -BeTrue
            Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Message -eq "Results exported to: $($script:csv)" }
        }

        It 'Says no file was written when the streaming manager is in WhatIf mode (#50)' {
            $results = New-DiscoveryResults
            $results.StreamingManager | Add-Member -NotePropertyName WhatIfMode -NotePropertyValue $true
            $results.StreamingManager | Add-Member -MemberType ScriptMethod -Name ExportToCsv -Value { param($Path) $this.Exported = $Path; $false } -Force

            Write-ProcessingSummary -ProcessingResults $results -OutputPath $script:csv

            Test-Path $script:csv | Should -BeFalse
            Should -Invoke Write-StructuredLog -Times 0 -ParameterFilter { $Message -like 'Results exported to:*' }
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Information' -and $Message -eq "WhatIf: results would be exported to $($script:csv); no file was written"
            }
        }

        It 'Warns, instead of claiming an export, when the manager wrote nothing outside WhatIf' {
            $results = New-DiscoveryResults
            $results.StreamingManager | Add-Member -MemberType ScriptMethod -Name ExportToCsv -Value { param($Path) $false } -Force

            Write-ProcessingSummary -ProcessingResults $results -OutputPath $script:csv

            Should -Invoke Write-StructuredLog -Times 0 -ParameterFilter { $Message -like 'Results exported to:*' }
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Warning' -and $Message -eq "No results were read back to export; $($script:csv) was not written"
            }
        }

        It 'Writes no CSV without an output path' {
            $results = New-DiscoveryResults

            Write-ProcessingSummary -ProcessingResults $results

            $results.StreamingManager.Exported | Should -BeNullOrEmpty
            Should -Invoke Write-StructuredLog -Times 0 -ParameterFilter { $Message -like 'Results exported to:*' }
        }

        It 'Says the directory is clean when nothing was found' {
            Write-ProcessingSummary -ProcessingResults (New-DiscoveryResults -Found 0 -TotalResults 0) -OutputPath $script:csv

            Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Message -like 'No orphaned SIDs found.*' }
            Test-Path $script:csv | Should -BeFalse
        }

        It 'Points at the error log when nothing was found but errors occurred' {
            Write-ProcessingSummary -ProcessingResults (New-DiscoveryResults -Found 0 -TotalResults 0 -Errors 3)

            Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Message -like 'Consider reviewing the error log*' }
        }

        It 'Logs the export failure at Error level and does not throw' {
            $results = New-DiscoveryResults
            $results.StreamingManager | Add-Member -MemberType ScriptMethod -Name ExportToCsv -Value { throw 'disk full' } -Force

            { Write-ProcessingSummary -ProcessingResults $results -OutputPath $script:csv } | Should -Not -Throw
            Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Level -eq 'Error' -and $Message -like 'Failed to export results to CSV:*disk full*' }
        }
    }

    Context 'Removal results' {
        It 'Counts successful and failed removals' {
            $results = New-DiscoveryResults
            $results.RemovalResults = @(
                [PSCustomObject]@{ ObjectDN = 'CN=A,DC=contoso,DC=com'; Success = $true }
                [PSCustomObject]@{ ObjectDN = 'CN=B,DC=contoso,DC=com'; Success = $true }
                [PSCustomObject]@{ ObjectDN = 'CN=C,DC=contoso,DC=com'; Success = $false }
            )

            Write-ProcessingSummary -ProcessingResults $results

            Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Message -eq '=== REMOVAL SUMMARY ===' }
            Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Message -eq 'Removal operations attempted: 3' }
            Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Message -eq 'Successful removals: 2' }
            Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Message -eq 'Failed removals: 1' }
        }
    }

    Context 'Restore results' {
        BeforeEach {
            $script:restores = @(
                [PSCustomObject]@{ ObjectDN = 'CN=Host 1,DC=contoso,DC=com'; Success = $true; EntriesRestored = 34; ErrorMessage = $null }
                [PSCustomObject]@{ ObjectDN = 'CN=Host 2,DC=contoso,DC=com'; Success = $false; EntriesRestored = 0; ErrorMessage = 'Access is denied' }
            )
        }

        It 'Logs the restore summary and one line per object, with the error for a failed one' {
            Write-ProcessingSummary -ProcessingResults (New-RestoreResults -Failed 1 -Results $script:restores)

            Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Message -eq '=== RESTORE SUMMARY ===' }
            Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Message -eq 'Successful restores: 1' }
            Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Message -eq 'Failed restores: 1' }
            Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Message -eq 'Backup source: C:\OrphanedSidTest\Backup\20261108_133153' }
            Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Message -eq '  [SUCCESS] CN=Host 1,DC=contoso,DC=com (34 entries)' }
            Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Message -eq '  [FAILED] CN=Host 2,DC=contoso,DC=com' }
            Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Message -eq '    Error: Access is denied' }
            Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Level -eq 'Warning' -and $Message -like 'Some restore operations failed.*' }
            Should -Invoke Write-StructuredLog -Times 0 -ParameterFilter { $Message -like '*PROCESSING ERRORS*' -or $Message -like 'Orphaned SIDs found*' }
        }

        It 'Celebrates when every restore succeeded' {
            $all = @([PSCustomObject]@{ ObjectDN = 'CN=Host 1,DC=contoso,DC=com'; Success = $true; EntriesRestored = 34 })

            Write-ProcessingSummary -ProcessingResults (New-RestoreResults -Results $all)

            Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Message -eq 'All restore operations completed successfully!' }
        }

        It 'Exports the restore results to CSV' {
            Write-ProcessingSummary -ProcessingResults (New-RestoreResults -Failed 1 -Results $script:restores) -OutputPath $script:csv

            $rows = @(Import-Csv $script:csv)
            $rows.Count | Should -Be 2
            $rows[1].ErrorMessage | Should -Be 'Access is denied'
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter { $Message -eq "Results exported to: $($script:csv)" }
        }

        It 'Writes no restore CSV under -WhatIf and says so (#50)' {
            $WhatIfPreference = $true

            Write-ProcessingSummary -ProcessingResults (New-RestoreResults -Failed 1 -Results $script:restores) -OutputPath $script:csv

            Test-Path $script:csv | Should -BeFalse
            Should -Invoke Write-StructuredLog -Times 0 -ParameterFilter { $Message -like 'Results exported to:*' }
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Message -eq "WhatIf: results would be exported to $($script:csv); no file was written"
            }
        }

        It 'Says so when no restore was performed' {
            Write-ProcessingSummary -ProcessingResults (New-RestoreResults -Results @())

            Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Message -eq 'No restore operations were performed.' }
        }
    }

    Context 'Failures' {
        It 'Logs at Error level and rethrows when the results cannot be summarised' {
            $broken = [PSCustomObject]@{ TotalObjectsProcessed = 1; ProcessingDuration = 'not a timespan' }

            { Write-ProcessingSummary -ProcessingResults $broken -CorrelationId 'sum-err' } | Should -Throw
            Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Level -eq 'Error' -and $Message -like 'Error generating processing summary:*' -and $CorrelationId -eq 'sum-err' }
        }
    }
}
