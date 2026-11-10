#Requires -Version 5.1

BeforeAll {
    $ModuleRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path

    . "$ModuleRoot\Classes\StreamingResultsManager.ps1"
}

Describe "StreamingResultsManager Tests" {
    Context "Basic Tests" {
        It "Should create instance with 3-argument constructor" {
            # $env:TEMP is an 8.3 short path (RUNNER~1) on the GitHub runners; Get-Item expands it so the
            # paths the functions return, which are long, compare equal to the ones built here
            $testDir = Join-Path (Get-Item -LiteralPath $env:TEMP).FullName "StreamingResultsManagerTest_$(Get-Random)"
            $manager = [StreamingResultsManager]::new($testDir, 100, $true)

            $manager | Should -Not -BeNullOrEmpty
            $manager.TempDirectory | Should -Be $testDir
            $manager.BatchSize | Should -Be 100
            $manager.WhatIfMode | Should -Be $true
            $manager.CurrentBatch | Should -Be 0
            $manager.Disposed | Should -Be $false
        }

        It "Should add result successfully" {
            $testDir = Join-Path (Get-Item -LiteralPath $env:TEMP).FullName "StreamingResultsManagerTest_$(Get-Random)"
            $manager = [StreamingResultsManager]::new($testDir, 50, $true)
            $result = [PSCustomObject]@{ Name = "Test"; Value = 123 }

            $manager.AddResult($result)

            $manager.CurrentResults.Count | Should -Be 1
            $manager.Summary.TotalResults | Should -Be 1
        }

        It "Should count unverified results apart from orphaned ones" {
            $testDir = Join-Path (Get-Item -LiteralPath $env:TEMP).FullName "StreamingResultsManagerTest_$(Get-Random)"
            $manager = [StreamingResultsManager]::new($testDir, 50, $true)

            $manager.AddResult([PSCustomObject]@{ OrphanedSID = 'S-1-5-21-1-2-3-1001'; VerificationStatus = 'Orphaned' })
            $manager.AddResult([PSCustomObject]@{ OrphanedSID = 'S-1-5-21-1-2-3-1002'; VerificationStatus = 'Unverified' })
            $manager.AddResult([PSCustomObject]@{ OrphanedSID = 'S-1-5-21-1-2-3-1003' })

            $manager.Summary.TotalResults | Should -Be 3
            $manager.Summary.OrphanedSIDsFound | Should -Be 2
            $manager.Summary.UnverifiedSIDsFound | Should -Be 1
        }

        It "Should dispose properly" {
            $testDir = Join-Path (Get-Item -LiteralPath $env:TEMP).FullName "StreamingResultsManagerTest_$(Get-Random)"
            $manager = [StreamingResultsManager]::new($testDir, 50, $true)

            $manager.Dispose()

            $manager.Disposed | Should -Be $true
        }
    }
}
