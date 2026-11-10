# Test-OrphanedSID.Tests.ps1
# Tests for Test-OrphanedSID with the real Test-SIDFormat and a directory that cannot be reached.
# Test-OrphanedSID.Resolution.Tests.ps1 mocks each directory lookup to walk the resolution order;
# this file checks what the function concludes when every directory lookup fails and only the
# local SecurityIdentifier translation can answer.

BeforeAll {
    # Pester can only mock a command that exists; define placeholder AD cmdlets when RSAT is absent.
    # The helper also supplies the ADIdentityNotFoundException type the function's catch clauses name.
    . "$PSScriptRoot\..\..\..\TestHelpers\ADCmdletStubs.ps1"

    function Write-StructuredLog { param($Message, $Level, $CorrelationId, $Component, $Data) }
    function Invoke-ADOperationWithRetry { param([scriptblock]$ScriptBlock, $MaxRetries, $OperationName, $ObjectContext, $CorrelationId) }

    . (Join-Path $PSScriptRoot '..\..\..\..\Private\SID\Test-SIDFormat.ps1')
    . (Join-Path $PSScriptRoot '..\..\..\..\Private\SID\Test-OrphanedSID.ps1')

    $script:Config = $null
    $script:domainSID = 'S-1-5-21-1234567890-1234567890-1234567890-1001'
}

Describe "Test-OrphanedSID without a reachable directory" -Tag 'Unit', 'SID', 'Private' {

    BeforeEach {
        Mock Write-StructuredLog { }
        # Every directory lookup fails the way an unreachable domain controller does
        Mock Invoke-ADOperationWithRetry { throw 'Unable to contact the server' }
        Clear-SIDValidationCache
    }

    It "Rejects a null or empty SID" {
        { Test-OrphanedSID -SID $null } | Should -Throw
        { Test-OrphanedSID -SID '' } | Should -Throw
    }

    It "Finds the well-known SID <_> by local translation and caches it" -ForEach @(
        'S-1-5-32-544', 'S-1-5-32-545', 'S-1-1-0', 'S-1-5-18', 'S-1-5-19', 'S-1-5-20'
    ) {
        $result = Test-OrphanedSID -SID $_

        $result.PSTypeNames | Should -Contain 'SIDLookupResult'
        $result.Status | Should -Be 'Exists'
        $result.IsOrphaned | Should -BeFalse
        $script:SIDValidationCache[$_].Status | Should -Be 'Exists'
    }

    It "Leaves a domain SID Unverified, naming every failed lookup, and does not cache it" {
        $result = Test-OrphanedSID -SID $script:domainSID

        $result.Status | Should -Be 'Unverified'
        $result.IsOrphaned | Should -BeFalse
        foreach ($lookup in 'Get-ADObject', 'Get-ADObject -IncludeDeletedObjects', 'Get-ADUser', 'Get-ADGroup', 'Get-ADComputer') {
            $result.ErrorMessage | Should -BeLike "*$($lookup): Unable to contact the server*"
        }
        $script:SIDValidationCache.ContainsKey($script:domainSID) | Should -BeFalse
    }

    It "Passes its correlation ID to every directory lookup" {
        Test-OrphanedSID -SID $script:domainSID -CorrelationId 'orph-e2e' | Out-Null

        Should -Invoke Invoke-ADOperationWithRetry -Times 5 -Exactly -ParameterFilter {
            $CorrelationId -eq 'orph-e2e' -and $ObjectContext -eq $script:domainSID
        }
    }

    It "Leaves '<_>' Unverified without any lookup because its format is invalid" -ForEach @(
        'invalid-sid', 'S-1-5', 'not-a-sid-at-all', '123456789'
    ) {
        $result = Test-OrphanedSID -SID $_

        $result.Status | Should -Be 'Unverified'
        $result.ErrorMessage | Should -Be 'The SID is not in a valid format, so no lookup was made'
        Should -Invoke Invoke-ADOperationWithRetry -Times 0 -Exactly
    }

    It "Returns one result per piped SID, in order" {
        $results = @('S-1-5-32-544', 'invalid-sid', $script:domainSID | Test-OrphanedSID)

        @($results.SID) | Should -Be @('S-1-5-32-544', 'invalid-sid', $script:domainSID)
        @($results.Status) | Should -Be @('Exists', 'Unverified', 'Unverified')
    }

    It "Reflects real lookups in the cache statistics" {
        Test-OrphanedSID -SID 'S-1-5-32-544' | Out-Null
        Test-OrphanedSID -SID 'S-1-5-18' | Out-Null
        Test-OrphanedSID -SID 'S-1-5-32-544' | Out-Null
        Test-OrphanedSID -SID $script:domainSID | Out-Null

        $stats = Get-SIDValidationCacheStat

        $stats.TotalEntries | Should -Be 2
        $stats.ValidSIDs | Should -Be 2
        $stats.OrphanedSIDs | Should -Be 0
        $stats.CacheHitRatio | Should -Be 25
    }
}
