#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
#Requires -Version 5.1

<#
.SYNOPSIS
    Tests for the resolution order inside Test-OrphanedSID and for its validation cache.

.DESCRIPTION
    Test-OrphanedSID.Tests.ps1 exercises the function end to end without a domain, where every SID
    comes back orphaned. These tests mock the directory lookups so each step of the resolution order
    is reached: a live object, a deleted object, a local translation, the typed lookups, and the
    cache that remembers the answer.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\TestHelpers\ADCmdletStubs.ps1"
    . "$PSScriptRoot\..\..\..\..\Private\SID\Test-OrphanedSID.ps1"

    function Write-StructuredLog { param($Message, $Level, $Component, $CorrelationId, $LogPath, $Data) }
    function Test-SIDFormat { param($SID, $CorrelationId) }
    function Invoke-ADOperationWithRetry { param([scriptblock]$ScriptBlock, $MaxRetries, $OperationName, $ObjectContext, $CorrelationId) }
    foreach ($name in 'Get-ADGroup', 'Get-ADComputer') {
        if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
            Set-Item -Path "function:global:$name" -Value { param($Filter, $Identity, $Properties, $Server, $ErrorAction) }
        }
    }

    $script:orphan = 'S-1-5-21-111-222-333-9001'
    $script:live = 'S-1-5-21-111-222-333-1105'
}

Describe 'Test-OrphanedSID resolution order' -Tag 'Unit', 'SID', 'Private' {

    BeforeEach {
        Mock Write-StructuredLog { }
        Mock Test-SIDFormat { $SID -match '^S-1-\d+(-\d+)+$' }
        Mock Invoke-ADOperationWithRetry { & $ScriptBlock }
        Mock Get-ADObject { $null }
        Mock Get-ADUser { $null }
        Mock Get-ADGroup { $null }
        Mock Get-ADComputer { $null }
        $script:SIDValidationCache = @{}
        $script:SIDValidationCacheLookups = 0
        $script:SIDValidationCacheHits = 0
    }

    It 'Treats a malformed SID as orphaned and warns' {
        Test-OrphanedSID -SID 'not-a-sid' | Should -BeTrue
        Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Level -eq 'Warning' -and $Message -like 'SID format invalid*' }
        Should -Invoke Get-ADObject -Times 0 -Exactly
    }

    It 'Is not orphaned when a live object carries the SID' {
        Mock Get-ADObject { if ($Filter -like "*$($script:live)*" -and -not $IncludeDeletedObjects) { [PSCustomObject]@{ DistinguishedName = 'CN=Live,DC=contoso,DC=com' } } }

        Test-OrphanedSID -SID $script:live | Should -BeFalse
        $script:SIDValidationCache[$script:live] | Should -BeFalse
        Should -Invoke Get-ADUser -Times 0 -Exactly
    }

    It 'Is orphaned when the SID is found only among deleted objects' {
        Mock Get-ADObject { if ($IncludeDeletedObjects) { [PSCustomObject]@{ DistinguishedName = 'CN=Gone\0ADEL:...,CN=Deleted Objects,DC=contoso,DC=com' } } }

        Test-OrphanedSID -SID $script:orphan | Should -BeTrue
        $script:SIDValidationCache[$script:orphan] | Should -BeTrue
        Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Message -like 'SID found in deleted objects:*' }
    }

    It 'Is not orphaned when the SID translates to an account locally' {
        # BUILTIN\Administrators resolves on any Windows machine without a domain
        Test-OrphanedSID -SID 'S-1-5-32-544' | Should -BeFalse
        Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Message -like 'SID successfully translated to account name:*Administrators' }
    }

    It 'Is not orphaned when a typed lookup finds the SID' {
        Mock Get-ADGroup { [PSCustomObject]@{ DistinguishedName = 'CN=Finance,OU=Groups,DC=contoso,DC=com' } }

        Test-OrphanedSID -SID $script:live | Should -BeFalse
        Should -Invoke Get-ADUser -Times 1 -Exactly
        Should -Invoke Get-ADGroup -Times 1 -Exactly
        Should -Invoke Get-ADComputer -Times 0 -Exactly
        Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Message -like 'SID found via Get-ADGroup:*' }
    }

    It 'Is orphaned when nothing resolves it' {
        Test-OrphanedSID -SID $script:orphan -CorrelationId 'orph-1' | Should -BeTrue

        $script:SIDValidationCache[$script:orphan] | Should -BeTrue
        Should -Invoke Get-ADComputer -Times 1 -Exactly
        Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Message -eq "SID could not be resolved - marking as orphaned: $($script:orphan)" -and $CorrelationId -eq 'orph-1' }
    }

    It 'Carries on to the next lookup when one of them throws' {
        Mock Get-ADObject { throw 'The server is not operational' }
        Mock Get-ADUser { [PSCustomObject]@{ DistinguishedName = 'CN=Someone,OU=Users,DC=contoso,DC=com' } }

        Test-OrphanedSID -SID $script:live | Should -BeFalse
        Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Message -like 'Get-ADObject lookup failed*not operational*' }
    }

    It 'Answers from the cache on a repeat and counts the hit' {
        Mock Get-ADObject { if (-not $IncludeDeletedObjects) { [PSCustomObject]@{ DistinguishedName = 'CN=Live,DC=contoso,DC=com' } } }

        Test-OrphanedSID -SID $script:live | Should -BeFalse
        Test-OrphanedSID -SID $script:live | Should -BeFalse

        Should -Invoke Get-ADObject -Times 1 -Exactly
        $script:SIDValidationCacheLookups | Should -Be 2
        $script:SIDValidationCacheHits | Should -Be 1
        Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Message -eq "SID validation cache hit for $($script:live)" }
    }

    It 'Processes SIDs from the pipeline' {
        $results = @($script:orphan, 'S-1-5-32-544' | Test-OrphanedSID)

        $results | Should -Be @($true, $false)
    }
}

Describe 'SID validation cache' -Tag 'Unit', 'SID', 'Private' {

    BeforeEach {
        Mock Write-StructuredLog { }
    }

    It 'Reports the entries, the split between orphaned and valid, and the hit ratio' {
        $script:SIDValidationCache = @{ 'S-1-5-21-1-2-3-9001' = $true; 'S-1-5-21-1-2-3-9002' = $true; 'S-1-5-21-1-2-3-1105' = $false }
        $script:SIDValidationCacheLookups = 8
        $script:SIDValidationCacheHits = 5

        $stats = Get-SIDValidationCacheStat

        $stats.PSTypeNames | Should -Contain 'SIDValidationCacheStats'
        $stats.TotalEntries | Should -Be 3
        $stats.OrphanedSIDs | Should -Be 2
        $stats.ValidSIDs | Should -Be 1
        $stats.CacheHitRatio | Should -Be 62.5
    }

    It 'Reports zeros when the cache is empty' {
        $script:SIDValidationCache = $null

        $stats = Get-SIDValidationCacheStat

        $stats.TotalEntries | Should -Be 0
        $stats.CacheHitRatio | Should -Be 0
    }

    It 'Clears the entries and the counters, and says how many it dropped' {
        $script:SIDValidationCache = @{ 'S-1-5-21-1-2-3-9001' = $true; 'S-1-5-21-1-2-3-1105' = $false }
        $script:SIDValidationCacheLookups = 4
        $script:SIDValidationCacheHits = 2

        Clear-SIDValidationCache -CorrelationId 'cache-1'

        $script:SIDValidationCache.Count | Should -Be 0
        $script:SIDValidationCacheLookups | Should -Be 0
        $script:SIDValidationCacheHits | Should -Be 0
        Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Message -eq 'Cleared SID validation cache (2 entries)' -and $Level -eq 'Information' -and $CorrelationId -eq 'cache-1' }
    }

    It 'Says so when there was nothing to clear' {
        $script:SIDValidationCache = $null

        Clear-SIDValidationCache

        Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Message -eq 'SID validation cache was already empty' }
    }
}
