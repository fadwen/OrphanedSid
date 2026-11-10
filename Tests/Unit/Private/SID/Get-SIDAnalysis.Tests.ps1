# Get-SIDAnalysis.Tests.ps1
# Tests for the Get-SIDAnalysis private function, run against the real Test-SIDFormat and
# Test-WellKnownSID unless a test mocks one of them

BeforeAll {
    function Write-StructuredLog { param($Message, $Level, $CorrelationId, $Component, $Data) }

    . (Join-Path $PSScriptRoot '..\..\..\..\Classes\SIDAnalysisResult.ps1')
    . (Join-Path $PSScriptRoot '..\..\..\..\Private\SID\Test-SIDFormat.ps1')
    . (Join-Path $PSScriptRoot '..\..\..\..\Private\SID\Get-SIDAnalysis.ps1')

    Mock Write-StructuredLog { }

    $script:Config = $null
    $script:currentDomainSID = 'S-1-5-21-1234567890-1234567890-1234567890'
}

Describe "Get-SIDAnalysis" -Tag 'Unit', 'SID', 'Private' {

    Context "Parameter validation" {
        It "Rejects a null or empty SID" {
            { Get-SIDAnalysis -SIDString $null } | Should -Throw
            { Get-SIDAnalysis -SIDString '' } | Should -Throw
        }
    }

    Context "Invalid input" {
        It "Rates '<SID>' Invalid and High risk without analysing it further" -ForEach @(
            @{ SID = 'S-1-5-21-123; Invoke-Expression "Get-Process"' }
            @{ SID = 'S-1-5-21-123 & net user hacker /add' }
            @{ SID = 'S-1-5-21-123$(Get-Process)' }
            @{ SID = 'InvalidSID' }
            @{ SID = 'S-1-5-INVALID' }
            @{ SID = 'S-1-5-21-abc-def-ghi-123' }
        ) {
            $result = Get-SIDAnalysis -SIDString $SID

            $result.LikelySource | Should -Be 'Invalid'
            $result.RiskLevel | Should -Be 'High'
            $result.Confidence | Should -Be 'High'
            $result.Notes | Should -Be 'Invalid SID format - does not match standard SID structure'
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Warning' -and $Message -eq "SID format validation failed for: $SID"
            }
        }

        It "Rates a SID with more sub-authorities than Windows allows as Invalid" {
            $longSID = 'S-1-5-21-' + ('1234567890-' * 100) + '1001'

            (Get-SIDAnalysis -SIDString $longSID).LikelySource | Should -Be 'Invalid'
        }

        It "Rates a SID with fewer than four components as Invalid structure" {
            Mock Test-SIDFormat { $true }

            $result = Get-SIDAnalysis -SIDString 'S-1-5'

            $result.LikelySource | Should -Be 'Invalid'
            $result.Notes | Should -Be 'Invalid SID structure - insufficient components'
        }

        It "Rates a RID too large for an Int32 as an invalid RID" {
            $result = Get-SIDAnalysis -SIDString "$($script:currentDomainSID)-4294967295" -CurrentDomainSID $script:currentDomainSID

            $result.LikelySource | Should -Be 'Invalid'
            $result.RiskLevel | Should -Be 'High'
            $result.Notes | Should -Be 'Invalid RID format - must be numeric'
        }
    }

    Context "Well-known SIDs" {
        It "Rates the well-known SID <_> Low risk in the System context" -ForEach @('S-1-5-32-544', 'S-1-5-18', 'S-1-5-19') {
            $result = Get-SIDAnalysis -SIDString $_ -CurrentDomainSID $script:currentDomainSID

            $result.LikelySource | Should -Be 'Well-Known SID'
            $result.RiskLevel | Should -Be 'Low'
            $result.DomainContext | Should -Be 'System'
            $result.Confidence | Should -Be 'High'
        }
    }

    Context "Local domain SIDs" {
        It "Classifies local RID <Rid> as <Source> with <Risk> risk" -ForEach @(
            @{ Rid = 400; Source = 'Domain Object'; Risk = 'Low'; Notes = 'Standard domain object' }
            @{ Rid = 500; Source = 'Built-in Administrator'; Risk = 'Medium'; Notes = 'Built-in Administrator account - verify if account was properly deleted' }
            @{ Rid = 501; Source = 'Built-in Guest'; Risk = 'Low'; Notes = 'Built-in Guest account*' }
            @{ Rid = 502; Source = 'KRBTGT Account'; Risk = 'High'; Notes = 'KRBTGT account - critical service account, investigate if orphaned' }
            @{ Rid = 503; Source = 'Built-in Account'; Risk = 'Medium'; Notes = 'Built-in account range*' }
            @{ Rid = 999; Source = 'Built-in Account'; Risk = 'Medium'; Notes = 'Built-in account range*' }
            @{ Rid = 1000; Source = 'Standard User/Group'; Risk = 'Low'; Notes = 'Standard user/group range - likely deleted user or group account' }
            @{ Rid = 4999; Source = 'Standard User/Group'; Risk = 'Low'; Notes = 'Standard user/group range*' }
            @{ Rid = 5000; Source = 'Extended Range Object'; Risk = 'Medium'; Notes = 'Extended range*' }
            @{ Rid = 10000; Source = 'Bulk Import/Migration'; Risk = 'Medium'; Notes = 'High RID value*' }
            @{ Rid = 99999; Source = 'Bulk Import/Migration'; Risk = 'Medium'; Notes = 'High RID value*' }
            @{ Rid = 100000; Source = 'High-Volume Import'; Risk = 'High'; Notes = 'Very high RID value*' }
        ) {
            $sid = "$($script:currentDomainSID)-$Rid"

            $result = Get-SIDAnalysis -SIDString $sid -CurrentDomainSID $script:currentDomainSID

            $result.SID | Should -Be $sid
            $result.LikelySource | Should -Be $Source
            $result.RiskLevel | Should -Be $Risk
            $result.Notes | Should -BeLike $Notes
            $result.Confidence | Should -Be 'High'
            $result.DomainContext | Should -Be 'Local'
        }
    }

    Context "Foreign and unknown domain SIDs" {
        It "Rates a SID from another domain as Foreign Domain/Trust" {
            $result = Get-SIDAnalysis -SIDString 'S-1-5-21-9876543210-9876543210-9876543210-1001' -CurrentDomainSID $script:currentDomainSID

            $result.LikelySource | Should -Be 'Foreign Domain/Trust'
            $result.DomainContext | Should -Be 'Foreign'
            $result.Confidence | Should -Be 'Medium'
            $result.RiskLevel | Should -Be 'High'
            $result.Notes | Should -Match 'verify trust relationships.*Broken trust.*Migrated.*Deleted external account$'
        }

        It "Notes a low foreign RID as a likely built-in or administrative account" {
            $result = Get-SIDAnalysis -SIDString 'S-1-5-21-9876543210-9876543210-9876543210-500' -CurrentDomainSID $script:currentDomainSID

            $result.Notes | Should -BeLike '*. Low RID suggests built-in or administrative account from external domain.'
        }

        It "Rates a domain SID as Unknown Domain when no current domain SID is given" {
            $result = Get-SIDAnalysis -SIDString "$($script:currentDomainSID)-1001"

            $result.LikelySource | Should -Be 'Unknown Domain'
            $result.Confidence | Should -Be 'Low'
            $result.RiskLevel | Should -Be 'High'
            $result.DomainContext | Should -Be 'Unknown'
            $result.Notes | Should -BeLike 'Cannot determine domain context - investigate source.*'
        }
    }

    Context "Logging, pipeline and errors" {
        It "Passes the correlation ID to the format checks and the log" {
            Mock Test-SIDFormat { $true }
            Mock Test-WellKnownSID { $false }

            Get-SIDAnalysis -SIDString "$($script:currentDomainSID)-1001" -CorrelationId 'ana-1' | Out-Null

            Should -Invoke Test-SIDFormat -Times 1 -Exactly -ParameterFilter { $CorrelationId -eq 'ana-1' }
            Should -Invoke Test-WellKnownSID -Times 1 -Exactly -ParameterFilter { $CorrelationId -eq 'ana-1' }
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $CorrelationId -eq 'ana-1' -and $Component -eq 'SIDAnalysis' -and
                $Message -eq "SID analysis completed for $($script:currentDomainSID)-1001 - Source: Unknown Domain, Risk: High"
            }
        }

        It "Analyses each SID piped to it" {
            $results = @("$($script:currentDomainSID)-502", 'S-1-5-32-544', 'NotASid' |
                Get-SIDAnalysis -CurrentDomainSID $script:currentDomainSID)

            $results.LikelySource | Should -Be @('KRBTGT Account', 'Well-Known SID', 'Invalid')
        }

        It "Returns an Analysis Error result, and logs it, when a check throws" {
            Mock Test-WellKnownSID { throw 'well-known list unavailable' }
            $sid = "$($script:currentDomainSID)-1001"

            $result = Get-SIDAnalysis -SIDString $sid -CorrelationId 'ana-2'

            $result.SID | Should -Be $sid
            $result.LikelySource | Should -Be 'Analysis Error'
            $result.Confidence | Should -Be 'Low'
            $result.RiskLevel | Should -Be 'High'
            $result.Notes | Should -Be 'Error during analysis: well-known list unavailable'
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Error' -and $CorrelationId -eq 'ana-2' -and $Message -like '*well-known list unavailable*'
            }
        }
    }
}
