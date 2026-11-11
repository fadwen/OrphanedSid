#Requires -Version 5.1

BeforeAll {
    $ModuleRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path

    . "$ModuleRoot\Classes\OrphanedSIDResult.ps1"
    . "$ModuleRoot\Classes\StreamingResultsManager.ps1"

    function New-TestDirectoryPath {
        Join-Path $TestDrive "StreamingResults_$([guid]::NewGuid().ToString('N'))"
    }

    function New-TestResult {
        param([int]$Number, [string]$Status = 'Orphaned')

        [PSCustomObject]@{
            ObjectDN           = "CN=Object$Number,DC=contoso,DC=com"
            OrphanedSID        = "S-1-5-21-1-2-3-$Number"
            VerificationStatus = $Status
        }
    }
}

Describe "StreamingResultsManager Tests" -Tag "Unit", "Classes", "StreamingResultsManager" {
    Context "Construction" {
        It "Should record settings and leave the directory uncreated in WhatIf mode" {
            $testDir = New-TestDirectoryPath
            $manager = [StreamingResultsManager]::new($testDir, 100, $true)

            $manager.TempDirectory | Should -Be $testDir
            $manager.BatchSize | Should -Be 100
            $manager.WhatIfMode | Should -Be $true
            $manager.CurrentBatch | Should -Be 0
            $manager.Disposed | Should -Be $false
            $manager.Summary.TotalResults | Should -Be 0
            $manager.Summary.BatchFiles.Count | Should -Be 0
            Test-Path $testDir | Should -Be $false
        }

        It "Should create the directory and an initial summary file outside WhatIf mode" {
            $testDir = New-TestDirectoryPath
            $manager = [StreamingResultsManager]::new($testDir, 10, $false)

            Test-Path $testDir -PathType Container | Should -Be $true
            Split-Path $manager.SummaryFile -Parent | Should -Be $testDir
            Split-Path $manager.ResultsFile -Parent | Should -Be $testDir
            (Get-Content $manager.SummaryFile -Raw | ConvertFrom-Json).initialized | Should -Be $true

            $manager.Dispose()
        }

        It "Should defer directory creation in the two-argument constructor until ConfigureWhatIfMode" {
            $testDir = New-TestDirectoryPath
            $manager = [StreamingResultsManager]::new($testDir, 10)

            $manager.WhatIfMode | Should -Be $false
            $manager.Summary.TotalResults | Should -Be 0
            Test-Path $testDir | Should -Be $false

            $manager.ConfigureWhatIfMode($false)

            Test-Path $testDir -PathType Container | Should -Be $true
            $manager.Dispose()
        }

        It "Should not create the directory when ConfigureWhatIfMode turns WhatIf on" {
            $testDir = New-TestDirectoryPath
            $manager = [StreamingResultsManager]::new($testDir, 10)

            $manager.ConfigureWhatIfMode($true)

            $manager.WhatIfMode | Should -Be $true
            Test-Path $testDir | Should -Be $false
        }

        It "Should throw naming the directory when it cannot be created" {
            # A directory cannot be created beneath a file
            $blocker = Join-Path $TestDrive "blocker_$([guid]::NewGuid().ToString('N')).txt"
            Set-Content -Path $blocker -Value 'not a directory'
            $testDir = Join-Path $blocker 'results'

            { [StreamingResultsManager]::new($testDir, 10, $false) } |
                Should -Throw -ExpectedMessage "StreamingResultsManager initialization failed - cannot create temporary directory '$testDir'*"
        }
    }

    Context "AddResult" {
        It "Should count every result and add it to the current batch" {
            $manager = [StreamingResultsManager]::new((New-TestDirectoryPath), 50, $true)

            $manager.AddResult([PSCustomObject]@{ Name = "Test"; Value = 123 })

            $manager.CurrentResults.Count | Should -Be 1
            $manager.Summary.TotalResults | Should -Be 1
            $manager.Summary.ObjectsProcessed | Should -Be 1
            # A result with no OrphanedSID or VerificationStatus is not counted as a finding
            $manager.Summary.OrphanedSIDsFound | Should -Be 0
            $manager.Summary.UnverifiedSIDsFound | Should -Be 0
        }

        It "Should count unverified results apart from orphaned ones" {
            $manager = [StreamingResultsManager]::new((New-TestDirectoryPath), 50, $true)

            $manager.AddResult([PSCustomObject]@{ OrphanedSID = 'S-1-5-21-1-2-3-1001'; VerificationStatus = 'Orphaned' })
            $manager.AddResult([PSCustomObject]@{ OrphanedSID = 'S-1-5-21-1-2-3-1002'; VerificationStatus = 'Unverified' })
            $manager.AddResult([PSCustomObject]@{ OrphanedSID = 'S-1-5-21-1-2-3-1003' })

            $manager.Summary.TotalResults | Should -Be 3
            $manager.Summary.OrphanedSIDsFound | Should -Be 2
            $manager.Summary.UnverifiedSIDsFound | Should -Be 1
        }

        It "Should write a batch file when the batch is full" {
            $manager = [StreamingResultsManager]::new((New-TestDirectoryPath), 2, $false)

            $manager.AddResult((New-TestResult -Number 1))
            $manager.CurrentBatch | Should -Be 0

            $manager.AddResult((New-TestResult -Number 2))

            $manager.CurrentBatch | Should -Be 1
            $manager.CurrentResults.Count | Should -Be 0
            $manager.Summary.BatchFiles.Count | Should -Be 1
            $batch = @(Get-Content $manager.Summary.BatchFiles[0] -Raw | ConvertFrom-Json)
            $batch.OrphanedSID | Should -Be @('S-1-5-21-1-2-3-1', 'S-1-5-21-1-2-3-2')

            $manager.Dispose()
        }

        It "Should record batch names without writing files in WhatIf mode" {
            $testDir = New-TestDirectoryPath
            $manager = [StreamingResultsManager]::new($testDir, 2, $true)

            1..2 | ForEach-Object { $manager.AddResult((New-TestResult -Number $_)) }

            $manager.Summary.BatchFiles | Should -Be @((Join-Path $testDir 'batch_1.json'))
            $manager.CurrentResults.Count | Should -Be 0
            Test-Path $testDir | Should -Be $false
        }

        It "Should throw once the manager is disposed" {
            $manager = [StreamingResultsManager]::new((New-TestDirectoryPath), 50, $true)
            $manager.Dispose()

            { $manager.AddResult((New-TestResult -Number 1)) } | Should -Throw -ExpectedMessage 'StreamingResultsManager has been disposed'
        }
    }

    Context "FlushBatch" {
        It "Should do nothing when there are no pending results" {
            $manager = [StreamingResultsManager]::new((New-TestDirectoryPath), 10, $false)

            $manager.FlushBatch()

            $manager.CurrentBatch | Should -Be 0
            $manager.Summary.BatchFiles.Count | Should -Be 0
            $manager.Dispose()
        }

        It "Should recreate a temp directory removed underneath it, with a warning" {
            $testDir = New-TestDirectoryPath
            $manager = [StreamingResultsManager]::new($testDir, 10, $false)
            $manager.AddResult((New-TestResult -Number 1))
            Remove-Item -Path $testDir -Recurse -Force

            $warnings = @(& { $manager.FlushBatch() } 3>&1)

            $warnings[0].Message | Should -Be "Temporary directory no longer exists, recreating: $testDir"
            Test-Path (Join-Path $testDir 'batch_1.json') | Should -Be $true
            $manager.Dispose()
        }
    }

    Context "GetAllResults" {
        It "Should return the results from every batch file and the unflushed remainder, in order" {
            $manager = [StreamingResultsManager]::new((New-TestDirectoryPath), 2, $false)
            1..5 | ForEach-Object { $manager.AddResult((New-TestResult -Number $_)) }

            $results = @($manager.GetAllResults())

            $results.Count | Should -Be 5
            $results.OrphanedSID | Should -Be @(1..5 | ForEach-Object { "S-1-5-21-1-2-3-$_" })
            $manager.Summary.BatchFiles.Count | Should -Be 3
            $manager.Dispose()
        }

        It "Should give back an OrphanedSIDResult with its enum names, local timestamp and note properties (#41)" {
            $original = [OrphanedSIDResult]::new()
            $original.ObjectDN = 'CN=Object1,DC=contoso,DC=com'
            $original.OrphanedSID = 'S-1-5-21-1-2-3-1'
            $original.AccessControlType = 'Deny'
            $original.ActiveDirectoryRights = 'ReadProperty, WriteProperty'
            $original.InheritanceType = 'ContainerInherit'
            $original.ObjectType = [guid]'bf967aba-0de6-11d0-a285-00aa003049e2'
            $original.Timestamp = [datetime]::new(2026, 3, 4, 5, 6, 7, [DateTimeKind]::Local)
            $original | Add-Member -NotePropertyName ProcessingContext -NotePropertyValue @{ Source = 'test' }
            $manager = [StreamingResultsManager]::new((New-TestDirectoryPath), 1, $false)
            $manager.AddResult($original)

            $result = @($manager.GetAllResults())[0]

            $result.GetType().Name | Should -Be 'OrphanedSIDResult'
            $result.AccessControlType | Should -Be ([System.Security.AccessControl.AccessControlType]::Deny)
            "$($result.ActiveDirectoryRights)" | Should -Be 'ReadProperty, WriteProperty'
            "$($result.InheritanceType)" | Should -Be 'ContainerInherit'
            $result.ObjectType | Should -Be ([guid]'bf967aba-0de6-11d0-a285-00aa003049e2')
            $result.Timestamp.Kind | Should -Not -Be ([DateTimeKind]::Utc)
            $result.Timestamp.ToString('yyyy-MM-dd HH:mm:ss') | Should -Be '2026-03-04 05:06:07'
            $result.ProcessingContext.Source | Should -Be 'test'
            $manager.Dispose()
        }

        It "Should give back any other object as it was read" {
            $manager = [StreamingResultsManager]::new((New-TestDirectoryPath), 1, $false)
            $manager.AddResult([PSCustomObject]@{ Name = 'not a result'; Count = 3 })

            $result = @($manager.GetAllResults())[0]

            $result | Should -BeOfType [System.Management.Automation.PSCustomObject]
            $result.Name | Should -Be 'not a result'
            $manager.Dispose()
        }

        It "Should warn and skip a batch file it cannot parse" {
            $manager = [StreamingResultsManager]::new((New-TestDirectoryPath), 1, $false)
            $manager.AddResult((New-TestResult -Number 1))
            $manager.AddResult((New-TestResult -Number 2))
            Set-Content -Path $manager.Summary.BatchFiles[0] -Value '{ not json'

            $output = @(& { $manager.GetAllResults() } 3>&1)
            $warnings = @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
            $results = @($output | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })

            $warnings.Count | Should -Be 1
            $warnings[0].Message | Should -BeLike "Failed to read batch file $($manager.Summary.BatchFiles[0]) :*"
            $results.OrphanedSID | Should -Be @('S-1-5-21-1-2-3-2')
            $manager.Dispose()
        }

        It "Should return every added result in order in WhatIf mode, across flushed batches" {
            $directory = New-TestDirectoryPath
            $manager = [StreamingResultsManager]::new($directory, 2, $true)
            1..3 | ForEach-Object { $manager.AddResult((New-TestResult -Number $_)) }

            $results = @($manager.GetAllResults())

            $results.OrphanedSID | Should -Be @('S-1-5-21-1-2-3-1', 'S-1-5-21-1-2-3-2', 'S-1-5-21-1-2-3-3')
            Test-Path -Path $directory | Should -BeFalse
        }
    }

    Context "Summary and export" {
        It "Should write the current counts to the summary file when GetSummary is called" {
            $manager = [StreamingResultsManager]::new((New-TestDirectoryPath), 10, $false)
            $manager.AddResult((New-TestResult -Number 1))
            $manager.AddResult((New-TestResult -Number 2 -Status 'Unverified'))

            $summary = $manager.GetSummary()

            $summary.TotalResults | Should -Be 2
            $written = Get-Content $manager.SummaryFile -Raw | ConvertFrom-Json
            $written.TotalResults | Should -Be 2
            $written.OrphanedSIDsFound | Should -Be 1
            $written.UnverifiedSIDsFound | Should -Be 1
            $manager.Dispose()
        }

        It "Should export every result to CSV" {
            $manager = [StreamingResultsManager]::new((New-TestDirectoryPath), 2, $false)
            1..3 | ForEach-Object { $manager.AddResult((New-TestResult -Number $_)) }
            $csv = Join-Path $TestDrive "export_$([guid]::NewGuid().ToString('N')).csv"

            $manager.ExportToCsv($csv) | Should -Be $true

            $rows = @(Import-Csv -Path $csv)
            $rows.Count | Should -Be 3
            $rows.ObjectDN | Should -Be @('CN=Object1,DC=contoso,DC=com', 'CN=Object2,DC=contoso,DC=com', 'CN=Object3,DC=contoso,DC=com')
            $manager.Dispose()
        }

        It "Should not create a CSV when there are no results" {
            $manager = [StreamingResultsManager]::new((New-TestDirectoryPath), 2, $false)
            $csv = Join-Path $TestDrive "empty_$([guid]::NewGuid().ToString('N')).csv"

            $manager.ExportToCsv($csv) | Should -Be $false

            Test-Path $csv | Should -Be $false
            $manager.Dispose()
        }

        It "Should write nothing in WhatIf mode and say so (#50)" {
            $manager = [StreamingResultsManager]::new((New-TestDirectoryPath), 2, $true)
            1..2 | ForEach-Object { $manager.AddResult((New-TestResult -Number $_)) }
            $csv = Join-Path $TestDrive "whatif_$([guid]::NewGuid().ToString('N')).csv"

            $manager.ExportToCsv($csv) | Should -Be $false

            Test-Path $csv | Should -Be $false
            $manager.Dispose()
        }

        It "Should report the process working set in MB" {
            $manager = [StreamingResultsManager]::new((New-TestDirectoryPath), 2, $true)

            $manager.GetCurrentMemoryUsage() | Should -BeGreaterThan 0
        }
    }

    Context "Dispose" {
        It "Should remove the temp directory and its batch files" {
            $testDir = New-TestDirectoryPath
            $manager = [StreamingResultsManager]::new($testDir, 1, $false)
            $manager.AddResult((New-TestResult -Number 1))
            Test-Path (Join-Path $testDir 'batch_1.json') | Should -Be $true

            $manager.Dispose()

            $manager.Disposed | Should -Be $true
            $manager.CurrentResults | Should -BeNullOrEmpty
            Test-Path $testDir | Should -Be $false
        }

        It "Should flush pending results and keep the files when PreserveFiles is set" {
            $testDir = New-TestDirectoryPath
            $manager = [StreamingResultsManager]::new($testDir, 10, $false)
            $manager.PreserveFiles = $true
            $manager.AddResult((New-TestResult -Number 1))

            $manager.Dispose()

            $batch = @(Get-Content (Join-Path $testDir 'batch_1.json') -Raw | ConvertFrom-Json)
            $batch.OrphanedSID | Should -Be @('S-1-5-21-1-2-3-1')
            (Get-Content $manager.SummaryFile -Raw | ConvertFrom-Json).TotalResults | Should -Be 1
        }

        It "Should be safe to call twice" {
            $manager = [StreamingResultsManager]::new((New-TestDirectoryPath), 10, $true)

            $manager.Dispose()
            { $manager.Dispose() } | Should -Not -Throw

            $manager.Disposed | Should -Be $true
        }
    }
}
