#Requires -Version 5.1

BeforeAll {
    . "$PSScriptRoot\..\..\..\Classes\SecurityValidationResult.ps1"
}

Describe "SecurityValidationResult Class Tests" -Tag "Unit", "Classes", "SecurityValidationResult" {
    Context "Constructor Tests" {
        It "Should set ValidatedAt to the time of construction" {
            $beforeCreate = Get-Date
            $result = [SecurityValidationResult]::new()
            $afterCreate = Get-Date

            $result.ValidatedAt | Should -BeGreaterOrEqual $beforeCreate
            $result.ValidatedAt | Should -BeLessOrEqual $afterCreate
        }

        It "Should set ValidatorVersion to default value" {
            $result = [SecurityValidationResult]::new()
            $result.ValidatorVersion | Should -Be "2.0.0"
        }

        It "Should initialize <Name> as an empty string array rather than null" -ForEach @(
            @{ Name = 'Issues' }
            @{ Name = 'BlockedSIDs' }
            @{ Name = 'AllowedSIDs' }
        ) {
            $result = [SecurityValidationResult]::new()

            # Piping an empty array to Should unrolls it, so compare against $null directly
            ($null -eq $result.$Name) | Should -Be $false
            $result.$Name.GetType().Name | Should -Be 'String[]'
            $result.$Name.Count | Should -Be 0
        }

        It "Should start as a valid, low-risk result needing no elevated confirmation" {
            $result = [SecurityValidationResult]::new()

            $result.IsValid | Should -Be $true
            $result.RiskLevel | Should -Be "Low"
            $result.RequiresElevatedConfirmation | Should -Be $false
        }
    }

    Context "Array Property Tests" {
        It "Should keep a string array type when a validator appends to <Name>" -ForEach @(
            @{ Name = 'Issues'; Value = 'Protected SID targeted' }
            @{ Name = 'BlockedSIDs'; Value = 'S-1-5-32-544' }
            @{ Name = 'AllowedSIDs'; Value = 'S-1-5-21-1234567890-1234567890-1234567890-500' }
        ) {
            $result = [SecurityValidationResult]::new()

            $result.$Name += $Value

            $result.$Name.GetType().Name | Should -Be 'String[]'
            $result.$Name.Count | Should -Be 1
            $result.$Name[0] | Should -Be $Value
        }
    }
}
