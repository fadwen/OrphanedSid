#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
BeforeAll {
    $ModuleRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path

    . "$ModuleRoot\Classes\RemovalOperationResult.ps1"
}

Describe "RemovalOperationResult Class Tests" -Tag "Unit", "Classes", "RemovalOperationResult" {
    Context "Constructor Tests" {
        It "Should generate a GUID CorrelationId unique to each instance" {
            $result1 = [RemovalOperationResult]::new()
            $result2 = [RemovalOperationResult]::new()

            $result1.CorrelationId | Should -Match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
            $result1.CorrelationId | Should -Not -Be $result2.CorrelationId
        }

        It "Should initialize the SID lists as empty string arrays" {
            $result = [RemovalOperationResult]::new()

            foreach ($name in 'RemovedSIDs', 'FailedSIDs', 'BlockedSIDs') {
                $result.$name.GetType().Name | Should -Be 'String[]' -Because "$name is a string array"
                $result.$name.Count | Should -Be 0 -Because "$name starts empty"
            }
        }

        It "Should initialize counters to zero" {
            $result = [RemovalOperationResult]::new()

            $result.IntendedRemovals | Should -BeOfType [int]
            $result.IntendedRemovals | Should -Be 0
            $result.ActualRemovals | Should -Be 0
            $result.FailedRemovals | Should -Be 0
        }

        It "Should initialize Success to false" {
            $result = [RemovalOperationResult]::new()
            $result.Success | Should -Be $false
        }

        It "Should initialize ProcessingTime to zero" {
            $result = [RemovalOperationResult]::new()
            $result.ProcessingTime | Should -Be ([System.TimeSpan]::Zero)
        }

        It "Should initialize optional properties to null" {
            $result = [RemovalOperationResult]::new()

            $result.ObjectDN | Should -BeNullOrEmpty
            $result.ErrorMessage | Should -BeNullOrEmpty
            $result.SecurityValidation | Should -BeNullOrEmpty
        }
    }

    Context "Property Tests" {
        It "Should declare the property types consumers rely on" {
            $result = [RemovalOperationResult]::new()
            $result.ObjectDN = "Test"
            $result.ErrorMessage = "Test"
            $result.SecurityValidation = @{ Test = "Value" }

            $result.ObjectDN | Should -BeOfType [string]
            $result.ActualRemovals | Should -BeOfType [int]
            $result.FailedRemovals | Should -BeOfType [int]
            $result.Success | Should -BeOfType [bool]
            $result.ErrorMessage | Should -BeOfType [string]
            $result.ProcessingTime | Should -BeOfType [System.TimeSpan]
            $result.CorrelationId | Should -BeOfType [string]
            # SecurityValidation is [object], so it keeps whatever shape the validator returned
            $result.SecurityValidation | Should -BeOfType [hashtable]
        }

        It "Should store a single SID assigned to a list as a one-element array" {
            $result = [RemovalOperationResult]::new()

            $result.RemovedSIDs = 'S-1-5-21-1-1-1-500'

            $result.RemovedSIDs.GetType().Name | Should -Be 'String[]'
            $result.RemovedSIDs.Count | Should -Be 1
            $result.RemovedSIDs[0] | Should -Be 'S-1-5-21-1-1-1-500'
        }
    }
}
