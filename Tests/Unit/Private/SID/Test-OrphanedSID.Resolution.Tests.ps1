#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
#Requires -Version 5.1

<#
.SYNOPSIS
    Tests for the resolution order inside Test-OrphanedSID and for its validation cache.

.DESCRIPTION
    Test-OrphanedSID.Tests.ps1 exercises the function with every directory lookup failing, where only
    local translation can answer. These tests mock the directory lookups so each step of the
    resolution order is reached: a live object, a deleted object, a local translation, the typed lookups, and the
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

    It 'Leaves a malformed SID unverified, warns, and makes no lookup' {
        $lookup = Test-OrphanedSID -SID 'not-a-sid'

        $lookup.Status | Should -Be 'Unverified'
        $lookup.IsOrphaned | Should -BeFalse
        $lookup.ErrorMessage | Should -BeLike '*not in a valid format*'
        Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Level -eq 'Warning' -and $Message -like 'SID format invalid*' }
        Should -Invoke Get-ADObject -Times 0 -Exactly
    }

    It 'Returns a SIDLookupResult' {
        $lookup = Test-OrphanedSID -SID $script:orphan

        $lookup.PSTypeNames | Should -Contain 'SIDLookupResult'
        $lookup.SID | Should -Be $script:orphan
    }

    It 'Exists when a live object carries the SID' {
        Mock Get-ADObject { if ($Filter -like "*$($script:live)*" -and -not $IncludeDeletedObjects) { [PSCustomObject]@{ DistinguishedName = 'CN=Live,DC=contoso,DC=com' } } }

        (Test-OrphanedSID -SID $script:live).Status | Should -Be 'Exists'
        $script:SIDValidationCache[$script:live].Status | Should -Be 'Exists'
        Should -Invoke Get-ADUser -Times 0 -Exactly
    }

    It 'Is orphaned when the SID is found only among deleted objects' {
        Mock Get-ADObject { if ($IncludeDeletedObjects) { [PSCustomObject]@{ DistinguishedName = 'CN=Gone\0ADEL:...,CN=Deleted Objects,DC=contoso,DC=com'; isDeleted = $true } } }

        $lookup = Test-OrphanedSID -SID $script:orphan

        $lookup.Status | Should -Be 'Orphaned'
        $lookup.IsOrphaned | Should -BeTrue
        $script:SIDValidationCache[$script:orphan].Status | Should -Be 'Orphaned'
        Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Message -like 'SID found in deleted objects:*' }
    }

    It 'Is orphaned when found among deleted objects even though the live lookup failed' {
        Mock Get-ADObject {
            if ($IncludeDeletedObjects) { [PSCustomObject]@{ DistinguishedName = 'CN=Gone\0ADEL:...,CN=Deleted Objects,DC=contoso,DC=com'; isDeleted = $true } }
            else { throw 'The operation returned because the timeout limit was exceeded' }
        }

        (Test-OrphanedSID -SID $script:orphan).Status | Should -Be 'Orphaned'
    }

    It 'Exists, not orphaned, when the live lookup failed and the deleted-objects lookup finds the live object (#39)' {
        # -IncludeDeletedObjects returns live objects too; a live one has no isDeleted value
        Mock Get-ADObject {
            if ($IncludeDeletedObjects) { [PSCustomObject]@{ DistinguishedName = 'CN=Live,DC=contoso,DC=com'; isDeleted = $null } }
            else { throw 'The operation returned because the timeout limit was exceeded' }
        }

        $lookup = Test-OrphanedSID -SID $script:live

        $lookup.Status | Should -Be 'Exists'
        $lookup.IsOrphaned | Should -BeFalse
        $script:SIDValidationCache[$script:live].Status | Should -Be 'Exists'
        Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
            $Message -eq 'SID found as a live object by the deleted-objects lookup: CN=Live,DC=contoso,DC=com'
        }
    }

    It 'Exists when the deleted-objects lookup returns both a tombstone and a live object' {
        Mock Get-ADObject {
            if ($IncludeDeletedObjects) {
                [PSCustomObject]@{ DistinguishedName = 'CN=Gone\0ADEL:...,CN=Deleted Objects,DC=contoso,DC=com'; isDeleted = $true }
                [PSCustomObject]@{ DistinguishedName = 'CN=Live,DC=contoso,DC=com'; isDeleted = $null }
            }
            else { throw 'The operation returned because the timeout limit was exceeded' }
        }

        (Test-OrphanedSID -SID $script:live).Status | Should -Be 'Exists'
    }

    It 'Asks the deleted-objects lookup for isDeleted' {
        Mock Get-ADObject { }

        $null = Test-OrphanedSID -SID $script:orphan

        Should -Invoke Get-ADObject -Times 1 -Exactly -ParameterFilter { $IncludeDeletedObjects -and @($Properties) -contains 'isDeleted' }
    }
    It 'Exists when the SID translates to an account locally' {
        # BUILTIN\Administrators resolves on any Windows machine without a domain
        (Test-OrphanedSID -SID 'S-1-5-32-544').Status | Should -Be 'Exists'
        Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Message -like 'SID successfully translated to account name:*Administrators' }
    }

    It 'Exists when a typed lookup finds the SID' {
        Mock Get-ADGroup { [PSCustomObject]@{ DistinguishedName = 'CN=Finance,OU=Groups,DC=contoso,DC=com' } }

        (Test-OrphanedSID -SID $script:live).Status | Should -Be 'Exists'
        Should -Invoke Get-ADUser -Times 1 -Exactly
        Should -Invoke Get-ADGroup -Times 1 -Exactly
        Should -Invoke Get-ADComputer -Times 0 -Exactly
        Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Message -like 'SID found via Get-ADGroup:*' }
    }

    It 'Is orphaned when every lookup completes and none finds it' {
        $lookup = Test-OrphanedSID -SID $script:orphan -CorrelationId 'orph-1'

        $lookup.Status | Should -Be 'Orphaned'
        $lookup.ErrorMessage | Should -BeNullOrEmpty
        $script:SIDValidationCache[$script:orphan].Status | Should -Be 'Orphaned'
        Should -Invoke Get-ADComputer -Times 1 -Exactly
        Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Message -eq "SID could not be resolved - marking as orphaned: $($script:orphan)" -and $CorrelationId -eq 'orph-1' }
    }

    It 'Is orphaned when every lookup throws not-found' {
        Mock Get-ADObject { throw [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException]::new('not found') }
        foreach ($cmdlet in 'Get-ADUser', 'Get-ADGroup', 'Get-ADComputer') {
            Mock $cmdlet { throw [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException]::new('not found') }
        }

        (Test-OrphanedSID -SID $script:orphan).Status | Should -Be 'Orphaned'
    }

    It 'Exists when one lookup throws and a later one finds the SID' {
        Mock Get-ADObject { throw 'The server is not operational' }
        Mock Get-ADUser { [PSCustomObject]@{ DistinguishedName = 'CN=Someone,OU=Users,DC=contoso,DC=com' } }

        (Test-OrphanedSID -SID $script:live).Status | Should -Be 'Exists'
        Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Message -like 'Get-ADObject lookup failed*not operational*' }
    }

    Context 'A lookup that fails for a reason other than not-found' {

        It 'Is unverified, not orphaned, when <Cmdlet> throws <Kind>' -ForEach @(
            @{ Cmdlet = 'Get-ADObject'; Kind = 'server down'; Failure = { [System.Exception]::new('Unable to contact the server. The server is not operational') } }
            @{ Cmdlet = 'Get-ADObject'; Kind = 'access denied'; Failure = { [System.UnauthorizedAccessException]::new('Access is denied') } }
            @{ Cmdlet = 'Get-ADUser'; Kind = 'server down'; Failure = { [System.Exception]::new('Unable to contact the server. The server is not operational') } }
            @{ Cmdlet = 'Get-ADGroup'; Kind = 'access denied'; Failure = { [System.UnauthorizedAccessException]::new('Access is denied') } }
            @{ Cmdlet = 'Get-ADComputer'; Kind = 'timeout'; Failure = { [System.TimeoutException]::new('The operation timed out') } }
        ) {
            $script:failure = & $Failure
            Mock $Cmdlet { throw $script:failure }

            $result = Test-OrphanedSID -SID $script:orphan

            $result.Status | Should -Be 'Unverified'
            $result.IsOrphaned | Should -BeFalse
            $result.ErrorMessage | Should -BeLike "*$($Cmdlet):*$($script:failure.Message)*"
            Should -Invoke Write-StructuredLog -ParameterFilter { $Level -eq 'Warning' -and $Message -like "SID could not be verified*$($script:orphan)*" }
        }

        It 'Is unverified when the deleted-objects lookup alone fails' {
            Mock Get-ADObject { if ($IncludeDeletedObjects) { throw [System.UnauthorizedAccessException]::new('Access is denied') } }

            (Test-OrphanedSID -SID $script:orphan).Status | Should -Be 'Unverified'
        }

        It 'Names every failed lookup in the error message' {
            Mock Get-ADObject { throw 'The server is not operational' }
            Mock Get-ADUser { throw 'The server is not operational' }

            $message = (Test-OrphanedSID -SID $script:orphan).ErrorMessage

            $message | Should -BeLike '*Get-ADObject:*'
            $message | Should -BeLike '*Get-ADObject -IncludeDeletedObjects:*'
            $message | Should -BeLike '*Get-ADUser:*'
        }

        It 'Is unverified when an unexpected error escapes the lookups' {
            Mock Test-SIDFormat { throw 'format check unavailable' }

            $lookup = Test-OrphanedSID -SID $script:orphan

            $lookup.Status | Should -Be 'Unverified'
            $lookup.ErrorMessage | Should -Be 'format check unavailable'
            $script:SIDValidationCache.ContainsKey($script:orphan) | Should -BeFalse
            Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Level -eq 'Error' }
        }

        It 'Does not cache the result, so the next call looks the SID up again' {
            Mock Get-ADObject { throw 'The server is not operational' }

            (Test-OrphanedSID -SID $script:orphan).Status | Should -Be 'Unverified'
            $script:SIDValidationCache.ContainsKey($script:orphan) | Should -BeFalse

            # The error clears: the second call repeats the lookups and reaches a verdict
            Mock Get-ADObject { $null }

            (Test-OrphanedSID -SID $script:orphan).Status | Should -Be 'Orphaned'
            $script:SIDValidationCacheHits | Should -Be 0
            Should -Invoke Get-ADUser -Times 2 -Exactly
        }
    }

    It 'Answers from the cache on a repeat and counts the hit' {
        Mock Get-ADObject { if (-not $IncludeDeletedObjects) { [PSCustomObject]@{ DistinguishedName = 'CN=Live,DC=contoso,DC=com' } } }

        (Test-OrphanedSID -SID $script:live).Status | Should -Be 'Exists'
        (Test-OrphanedSID -SID $script:live).Status | Should -Be 'Exists'

        Should -Invoke Get-ADObject -Times 1 -Exactly
        $script:SIDValidationCacheLookups | Should -Be 2
        $script:SIDValidationCacheHits | Should -Be 1
        Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter { $Message -eq "SID validation cache hit for $($script:live)" }
    }

    It 'Processes SIDs from the pipeline' {
        $results = @($script:orphan, 'S-1-5-32-544' | Test-OrphanedSID)

        @($results.Status) | Should -Be @('Orphaned', 'Exists')
    }
}

Describe 'SID validation cache' -Tag 'Unit', 'SID', 'Private' {

    BeforeEach {
        Mock Write-StructuredLog { }
    }

    It 'Reports the entries, the split between orphaned and valid, and the hit ratio' {
        $script:SIDValidationCache = @{
            'S-1-5-21-1-2-3-9001' = New-SIDLookupResult -SID 'S-1-5-21-1-2-3-9001' -Status 'Orphaned'
            'S-1-5-21-1-2-3-9002' = New-SIDLookupResult -SID 'S-1-5-21-1-2-3-9002' -Status 'Orphaned'
            'S-1-5-21-1-2-3-1105' = New-SIDLookupResult -SID 'S-1-5-21-1-2-3-1105' -Status 'Exists'
        }
        $script:SIDValidationCacheLookups = 8
        $script:SIDValidationCacheHits = 5

        $stats = Get-SIDValidationCacheStat

        $stats.PSTypeNames | Should -Contain 'SIDValidationCacheStats'
        $stats.TotalEntries | Should -Be 3
        $stats.OrphanedSIDs | Should -Be 2
        $stats.ValidSIDs | Should -Be 1
        $stats.CacheHitRatio | Should -Be 62.5
    }

    It 'Creates a lookup result whose IsOrphaned follows the status' -ForEach @(
        @{ Status = 'Orphaned'; Expected = $true }
        @{ Status = 'Exists'; Expected = $false }
        @{ Status = 'Unverified'; Expected = $false }
    ) {
        $result = New-SIDLookupResult -SID 'S-1-5-21-1-2-3-9001' -Status $Status -ErrorMessage 'x'

        $result.Status | Should -Be $Status
        $result.IsOrphaned | Should -Be $Expected
        $result.ErrorMessage | Should -Be 'x'
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
