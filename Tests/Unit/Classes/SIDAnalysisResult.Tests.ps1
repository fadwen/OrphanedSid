#Requires -Version 5.1

BeforeAll {
    . "$PSScriptRoot\..\..\..\Classes\SIDAnalysisResult.ps1"
}

Describe "SIDAnalysisResult Class Tests" -Tag "Unit", "Classes", "SIDAnalysisResult" {

    Context "Constructor Tests" {
        It "Should set AnalyzedAt to the time of construction" {
            $beforeCreation = Get-Date
            $result = [SIDAnalysisResult]::new()
            $afterCreation = Get-Date

            $result.AnalyzedAt | Should -BeGreaterOrEqual $beforeCreation
            $result.AnalyzedAt | Should -BeLessOrEqual $afterCreation
        }

        It "Should initialize string properties as null" {
            $result = [SIDAnalysisResult]::new()

            $result.SID | Should -BeNullOrEmpty
            $result.LikelySource | Should -BeNullOrEmpty
            $result.Confidence | Should -BeNullOrEmpty
            $result.Notes | Should -BeNullOrEmpty
            $result.RiskLevel | Should -BeNullOrEmpty
            $result.DomainContext | Should -BeNullOrEmpty
        }
    }

    Context "Property Tests" {
        It "Should declare the property types consumers rely on" {
            $result = [SIDAnalysisResult]::new()
            foreach ($name in 'SID', 'LikelySource', 'Confidence', 'Notes', 'RiskLevel', 'DomainContext') {
                $result.$name = 'Test'
                $result.$name | Should -BeOfType [string]
            }

            $result.AnalyzedAt | Should -BeOfType [DateTime]
        }
    }
}
