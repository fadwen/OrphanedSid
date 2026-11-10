#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
BeforeAll {
    $ModuleRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path

    $ClassesPath = Join-Path $ModuleRoot "Classes"

    . (Join-Path $ClassesPath "RestoreOperationResult.ps1")
}

Describe "RestoreOperationResult Class Tests" -Tag "Unit", "Classes", "RestoreOperationResult" {
    Context "Constructor Tests" {
        It "Should set RestorationDate to the time of construction" {
            $beforeCreate = Get-Date
            $result = [RestoreOperationResult]::new()
            $afterCreate = Get-Date

            $result.RestorationDate | Should -BeGreaterOrEqual $beforeCreate
            $result.RestorationDate | Should -BeLessOrEqual $afterCreate
        }

        It "Should generate a GUID CorrelationId unique to each instance" {
            $result1 = [RestoreOperationResult]::new()
            $result2 = [RestoreOperationResult]::new()

            $result1.CorrelationId | Should -Match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
            $result1.CorrelationId | Should -Not -Be $result2.CorrelationId
        }

        It "Should initialize Success to false" {
            $result = [RestoreOperationResult]::new()

            $result.Success | Should -Be $false
        }

        It "Should initialize BackupValidation to false" {
            $result = [RestoreOperationResult]::new()

            $result.BackupValidation | Should -Be $false
        }

        It "Should initialize EntriesRestored to zero" {
            $result = [RestoreOperationResult]::new()

            $result.EntriesRestored | Should -Be 0
        }

        It "Should initialize WhatIfMode to false" {
            $result = [RestoreOperationResult]::new()

            $result.WhatIfMode | Should -Be $false
        }

        It "Should initialize ProcessingTime to zero" {
            $result = [RestoreOperationResult]::new()

            $result.ProcessingTime | Should -Be ([TimeSpan]::Zero)
        }

        It "Should leave ObjectDN, BackupFile, ErrorMessage and BackupDate unset" {
            $result = [RestoreOperationResult]::new()

            $result.ObjectDN | Should -BeNullOrEmpty
            $result.BackupFile | Should -BeNullOrEmpty
            $result.ErrorMessage | Should -BeNullOrEmpty
            $result.BackupDate | Should -Be ([DateTime]::MinValue)
        }
    }

    Context "Property Tests" {
        It "Should declare the property types consumers rely on" {
            $result = [RestoreOperationResult]::new()
            # String properties are null until set, so set them to test their declared type
            $result.ObjectDN = "TestDN"
            $result.BackupFile = "TestFile"
            $result.ErrorMessage = "TestError"

            $result.ObjectDN.GetType().Name | Should -Be "String"
            $result.CorrelationId.GetType().Name | Should -Be "String"
            $result.BackupFile.GetType().Name | Should -Be "String"
            $result.BackupDate.GetType().Name | Should -Be "DateTime"
            $result.RestorationDate.GetType().Name | Should -Be "DateTime"
            $result.Success.GetType().Name | Should -Be "Boolean"
            $result.ErrorMessage.GetType().Name | Should -Be "String"
            $result.ProcessingTime.GetType().Name | Should -Be "TimeSpan"
            $result.BackupValidation.GetType().Name | Should -Be "Boolean"
            $result.EntriesRestored.GetType().Name | Should -Be "Int32"
            $result.WhatIfMode.GetType().Name | Should -Be "Boolean"
        }
    }
}
