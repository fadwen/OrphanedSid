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
    # As OrphanedSid.psm1 does: in the module the code under test runs under strict mode
    Set-StrictMode -Version Latest

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
        # A case that finds the server down suspends the directory lookups for 60 seconds (#82);
        # without this the cases that run after it would attempt none
        $script:DirectoryUnreachableSince = $null
        $script:DirectoryRetryAt = $null
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

    Context 'An unreachable directory server (#82)' {

        BeforeAll {
            $script:downMessage = 'Unable to contact the server. This may be because this server does not exist, it is currently down, or it does not have the Active Directory Web Services running.'
        }

        It 'Skips the remaining directory lookups once the first finds the server down' {
            Mock Get-ADObject { throw [Microsoft.ActiveDirectory.Management.ADServerDownException]::new($script:downMessage) }

            $lookup = Test-OrphanedSID -SID $script:orphan

            $lookup.Status | Should -Be 'Unverified'
            $lookup.IsOrphaned | Should -BeFalse
            Should -Invoke Get-ADObject -Times 1 -Exactly
            Should -Invoke Get-ADUser -Times 0 -Exactly
            Should -Invoke Get-ADGroup -Times 0 -Exactly
            Should -Invoke Get-ADComputer -Times 0 -Exactly
            $lookup.ErrorMessage | Should -BeLike "Get-ADObject: $($script:downMessage)*"
            $lookup.ErrorMessage | Should -BeLike '*Not attempted because the directory server could not be contacted: Get-ADObject -IncludeDeletedObjects, Get-ADUser, Get-ADGroup, Get-ADComputer'
            $script:SIDValidationCache.ContainsKey($script:orphan) | Should -BeFalse
            # The count says what happened: one lookup failed, four were not tried
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Warning' -and $Message -like "SID could not be verified - 1 lookup(s) failed, 4 not attempted: $($script:orphan) (*"
            }
        }

        It 'Still asks the local name lookup, which can prove the SID exists' {
            # BUILTIN\Administrators resolves through LSA without the directory
            Mock Get-ADObject { throw [Microsoft.ActiveDirectory.Management.ADServerDownException]::new($script:downMessage) }

            (Test-OrphanedSID -SID 'S-1-5-32-544').Status | Should -Be 'Exists'
            Should -Invoke Get-ADUser -Times 0 -Exactly
        }

        It 'Skips the typed lookups when the deleted-objects lookup finds the server down' {
            Mock Get-ADObject { if ($IncludeDeletedObjects) { throw [Microsoft.ActiveDirectory.Management.ADServerDownException]::new($script:downMessage) } }

            $lookup = Test-OrphanedSID -SID $script:orphan

            $lookup.Status | Should -Be 'Unverified'
            Should -Invoke Get-ADObject -Times 2 -Exactly
            Should -Invoke Get-ADUser -Times 0 -Exactly
            $lookup.ErrorMessage | Should -BeLike '*Not attempted because the directory server could not be contacted: Get-ADUser, Get-ADGroup, Get-ADComputer'
        }

        It 'Skips the later typed lookups when an earlier one finds the server down' {
            Mock Get-ADUser { throw [Microsoft.ActiveDirectory.Management.ADServerDownException]::new($script:downMessage) }

            $lookup = Test-OrphanedSID -SID $script:orphan

            $lookup.Status | Should -Be 'Unverified'
            Should -Invoke Get-ADUser -Times 1 -Exactly
            Should -Invoke Get-ADGroup -Times 0 -Exactly
            Should -Invoke Get-ADComputer -Times 0 -Exactly
            $lookup.ErrorMessage | Should -BeLike '*Not attempted because the directory server could not be contacted: Get-ADGroup, Get-ADComputer'
        }

        It 'Recognises the server-down exception inside another one' {
            Mock Get-ADObject {
                $inner = [Microsoft.ActiveDirectory.Management.ADServerDownException]::new($script:downMessage)
                throw [System.InvalidOperationException]::new('Lookup failed', $inner)
            }

            $null = Test-OrphanedSID -SID $script:orphan

            Should -Invoke Get-ADUser -Times 0 -Exactly
        }

        It 'Keeps trying every lookup after a failure that is not server-down' {
            Mock Get-ADObject { throw [System.TimeoutException]::new('The operation timed out') }

            $lookup = Test-OrphanedSID -SID $script:orphan

            $lookup.Status | Should -Be 'Unverified'
            Should -Invoke Get-ADObject -Times 2 -Exactly
            Should -Invoke Get-ADComputer -Times 1 -Exactly
            $lookup.ErrorMessage | Should -Not -BeLike '*Not attempted*'
        }

        It 'Does not suspend the lookups of the next SID after a failure that is not server-down' {
            Mock Get-ADObject { throw [System.TimeoutException]::new('The operation timed out') }
            $null = Test-OrphanedSID -SID $script:orphan

            Mock Get-ADObject { $null }
            (Test-OrphanedSID -SID 'S-1-5-21-111-222-333-9002').Status | Should -Be 'Orphaned'
            Should -Invoke Get-ADObject -Times 2 -Exactly -ParameterFilter { $Filter -like '*-9002*' }
            Should -Invoke Get-ADComputer -Times 1 -Exactly -ParameterFilter { $Filter -like '*-9002*' }
            $script:DirectoryRetryAt | Should -BeNullOrEmpty
        }
    }

    Context 'The SIDs that follow while the server cannot be contacted (#82)' {

        BeforeAll {
            $script:downMessage = 'Unable to contact the server. This may be because this server does not exist, it is currently down, or it does not have the Active Directory Web Services running.'
            $script:next = 'S-1-5-21-111-222-333-9002'
            $script:allLookups = 'Get-ADObject, Get-ADObject -IncludeDeletedObjects, Get-ADUser, Get-ADGroup, Get-ADComputer'
        }

        BeforeEach {
            # The clock of the function, which a case moves forward
            $script:clock = [datetime]::new(2026, 11, 20, 10, 0, 0)
            Mock Get-Date { $script:clock }
            # The first SID finds the server down, at 10:00:00
            Mock Get-ADObject { throw [Microsoft.ActiveDirectory.Management.ADServerDownException]::new($script:downMessage) }
            $null = Test-OrphanedSID -SID $script:orphan
        }

        It 'Attempts no directory lookup for the next SID, and reports it Unverified without caching it' {
            $script:clock = $script:clock.AddSeconds(59)

            $lookup = Test-OrphanedSID -SID $script:next

            $lookup.Status | Should -Be 'Unverified'
            $lookup.IsOrphaned | Should -BeFalse
            $lookup.ErrorMessage | Should -Be "Not attempted because the directory server could not be contacted: $($script:allLookups)"
            Should -Invoke Get-ADObject -Times 0 -Exactly -ParameterFilter { $Filter -like '*-9002*' }
            Should -Invoke Get-ADUser -Times 0 -Exactly
            Should -Invoke Get-ADGroup -Times 0 -Exactly
            Should -Invoke Get-ADComputer -Times 0 -Exactly
            $script:SIDValidationCache.ContainsKey($script:next) | Should -BeFalse
        }

        It 'Still asks the local name lookup in that time, which can prove that a SID exists' {
            $lookup = Test-OrphanedSID -SID 'S-1-5-32-544'

            $lookup.Status | Should -Be 'Exists'
            Should -Invoke Get-ADObject -Times 0 -Exactly -ParameterFilter { $Filter -like '*S-1-5-32-544*' }
        }

        It 'Writes one warning that the server cannot be contacted, however many SIDs follow' {
            foreach ($rid in 9002..9006) {
                $null = Test-OrphanedSID -SID "S-1-5-21-111-222-333-$rid"
            }

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Warning' -and $Message -eq ('The directory server cannot be contacted. No directory lookup is ' +
                    'attempted for the next 60 seconds: a SID that needs one is reported as Unverified and is not removed. ' +
                    'The server is tried again after that.')
            }
            # The SID that found the server down has its two warnings; the five after it have none
            Should -Invoke Write-StructuredLog -Times 3 -Exactly -ParameterFilter { $Level -eq 'Warning' }
            Should -Invoke Write-StructuredLog -Times 5 -Exactly -ParameterFilter {
                $Level -eq 'Debug' -and $Message -like 'SID could not be verified - 0 lookup(s) failed, 5 not attempted: *'
            }
        }

        It 'Tries the directory again for the first SID after 60 seconds, and goes on as usual when it answers' {
            $script:clock = $script:clock.AddSeconds(60)
            Mock Get-ADObject { $null }

            (Test-OrphanedSID -SID $script:next).Status | Should -Be 'Orphaned'
            (Test-OrphanedSID -SID 'S-1-5-21-111-222-333-9003').Status | Should -Be 'Orphaned'

            Should -Invoke Get-ADObject -Times 2 -Exactly -ParameterFilter { $Filter -like '*-9002*' }
            Should -Invoke Get-ADComputer -Times 1 -Exactly -ParameterFilter { $Filter -like '*-9003*' }
            $script:DirectoryUnreachableSince | Should -BeNullOrEmpty
            $script:DirectoryRetryAt | Should -BeNullOrEmpty
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Information' -and $Message -eq ('The directory server answers again, 60 seconds after it ' +
                    'could not be contacted. Directory lookups are attempted again.')
            }
        }

        It 'Takes not-found from the lookup that tries again as an answer' {
            $script:clock = $script:clock.AddSeconds(61)
            Mock Get-ADObject { throw [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException]::new('not found') }

            (Test-OrphanedSID -SID $script:next).Status | Should -Be 'Orphaned'

            $script:DirectoryRetryAt | Should -BeNullOrEmpty
            Should -Invoke Get-ADComputer -Times 1 -Exactly
        }

        It 'Begins another 60 seconds when the lookup that tries again finds the server down as well' {
            $script:clock = $script:clock.AddSeconds(75)

            $probe = Test-OrphanedSID -SID $script:next
            $script:clock = $script:clock.AddSeconds(59)
            $after = Test-OrphanedSID -SID 'S-1-5-21-111-222-333-9003'

            # The SID that tried again made one lookup; the one after it made none
            $probe.ErrorMessage | Should -BeLike "Get-ADObject: $($script:downMessage)*"
            Should -Invoke Get-ADObject -Times 1 -Exactly -ParameterFilter { $Filter -like '*-9002*' }
            Should -Invoke Get-ADObject -Times 0 -Exactly -ParameterFilter { $Filter -like '*-9003*' }
            $after.ErrorMessage | Should -Be "Not attempted because the directory server could not be contacted: $($script:allLookups)"
            # Since the first failure, and again from the second
            $script:DirectoryUnreachableSince | Should -Be ([datetime]::new(2026, 11, 20, 10, 0, 0))
            $script:DirectoryRetryAt | Should -Be ([datetime]::new(2026, 11, 20, 10, 2, 15))
            # Still the one warning about the server
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Warning' -and $Message -like 'The directory server cannot be contacted.*'
            }
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Debug' -and $Message -eq 'The directory server still cannot be contacted. It is tried again in 60 seconds.'
            }
        }

        It 'Suspends the lookups also when the SID that found the server down has a local name' {
            # A SID that the local name lookup finds returns before the end of the function
            $script:DirectoryUnreachableSince = $null
            $script:DirectoryRetryAt = $null
            (Test-OrphanedSID -SID 'S-1-5-32-545').Status | Should -Be 'Exists'

            $null = Test-OrphanedSID -SID $script:next

            Should -Invoke Get-ADObject -Times 1 -Exactly -ParameterFilter { $Filter -like '*S-1-5-32-545*' }
            Should -Invoke Get-ADObject -Times 0 -Exactly -ParameterFilter { $Filter -like '*-9002*' }
        }

        It 'Suspends the lookups also when <Lookup> is the one that finds the server down' -ForEach @(
            @{ Lookup = 'the deleted-objects lookup'; DownAt = 'Deleted' }
            @{ Lookup = 'a typed lookup'; DownAt = 'Typed' }
        ) {
            $script:DirectoryUnreachableSince = $null
            $script:DirectoryRetryAt = $null
            Mock Get-ADObject {
                if ($IncludeDeletedObjects -and $DownAt -eq 'Deleted') {
                    throw [Microsoft.ActiveDirectory.Management.ADServerDownException]::new($script:downMessage)
                }
            }
            Mock Get-ADGroup {
                if ($DownAt -eq 'Typed') {
                    throw [Microsoft.ActiveDirectory.Management.ADServerDownException]::new($script:downMessage)
                }
            }
            $null = Test-OrphanedSID -SID 'S-1-5-21-111-222-333-9004'

            $null = Test-OrphanedSID -SID $script:next

            Should -Invoke Get-ADObject -Times 0 -Exactly -ParameterFilter { $Filter -like '*-9002*' }
            $script:DirectoryRetryAt | Should -Be $script:clock.AddSeconds(60)
        }
    }

    Context 'Register-DirectoryLookupOutcome' {

        BeforeEach {
            $script:clock = [datetime]::new(2026, 11, 20, 10, 0, 0)
            Mock Get-Date { $script:clock }
        }

        It 'Records the time and suspends lookups for 60 seconds the first time the server is unreachable' {
            Register-DirectoryLookupOutcome -Outcome Unreachable -CorrelationId 'reg-1'

            $script:DirectoryUnreachableSince | Should -Be $script:clock
            $script:DirectoryRetryAt | Should -Be $script:clock.AddSeconds(60)
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Warning' -and $CorrelationId -eq 'reg-1' -and $Component -eq 'SIDDetection'
            }
        }

        It 'Keeps the first time and moves the time to try again when the server is unreachable once more' {
            Register-DirectoryLookupOutcome -Outcome Unreachable
            $first = $script:clock
            $script:clock = $script:clock.AddSeconds(100)

            Register-DirectoryLookupOutcome -Outcome Unreachable

            $script:DirectoryUnreachableSince | Should -Be $first
            $script:DirectoryRetryAt | Should -Be $first.AddSeconds(160)
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'Warning' }
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'Debug' }
        }

        It 'Clears both times and says for how long the server was unreachable when it answers' {
            Register-DirectoryLookupOutcome -Outcome Unreachable
            $script:clock = $script:clock.AddSeconds(145)

            Register-DirectoryLookupOutcome -Outcome Answered -CorrelationId 'reg-2'

            $script:DirectoryUnreachableSince | Should -BeNullOrEmpty
            $script:DirectoryRetryAt | Should -BeNullOrEmpty
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Information' -and $CorrelationId -eq 'reg-2' -and
                $Message -like 'The directory server answers again, 145 seconds after*'
            }
        }

        It 'Does and writes nothing for an answer when the server was not recorded as unreachable' {
            Register-DirectoryLookupOutcome -Outcome Answered

            $script:DirectoryRetryAt | Should -BeNullOrEmpty
            Should -Invoke Write-StructuredLog -Times 0 -Exactly
        }

        It 'Writes nothing to the pipeline' {
            @(Register-DirectoryLookupOutcome -Outcome Unreachable).Count | Should -Be 0
            @(Register-DirectoryLookupOutcome -Outcome Answered).Count | Should -Be 0
        }

        It 'Rejects an outcome other than Answered and Unreachable' {
            { Register-DirectoryLookupOutcome -Outcome 'Slow' } | Should -Throw "*parameter 'Outcome'*"
        }
    }

    Context 'Retries for a transient lookup failure (#89)' {
        It 'Gives every directory lookup -MaxRetries plus the first attempt' {
            $null = Test-OrphanedSID -SID $script:orphan -MaxRetries 5

            Should -Invoke Invoke-ADOperationWithRetry -Times 5 -Exactly
            Should -Invoke Invoke-ADOperationWithRetry -Times 5 -Exactly -ParameterFilter { $MaxRetries -eq 6 }
        }

        It 'Allows four attempts per lookup by default' {
            $null = Test-OrphanedSID -SID $script:orphan

            Should -Invoke Invoke-ADOperationWithRetry -Times 5 -Exactly -ParameterFilter { $MaxRetries -eq 4 }
        }

        It 'Makes one attempt per lookup with -MaxRetries 0' {
            $null = Test-OrphanedSID -SID $script:orphan -MaxRetries 0

            Should -Invoke Invoke-ADOperationWithRetry -Times 5 -Exactly -ParameterFilter { $MaxRetries -eq 1 }
        }

        It 'Rejects -MaxRetries outside 0-10' {
            { Test-OrphanedSID -SID $script:orphan -MaxRetries 11 } | Should -Throw -ExpectedMessage '*MaxRetries*'
        }
    }

    Context 'Test-ADServerDownError' {
        It 'Is true for ADServerDownException' {
            $record = [System.Management.Automation.ErrorRecord]::new([Microsoft.ActiveDirectory.Management.ADServerDownException]::new('down'), 'id', 'ConnectionError', $null)
            Test-ADServerDownError -ErrorRecord $record | Should -BeTrue
        }

        It 'Is true when ADServerDownException is an inner exception' {
            $inner = [Microsoft.ActiveDirectory.Management.ADServerDownException]::new('down')
            $record = [System.Management.Automation.ErrorRecord]::new([System.Exception]::new('outer', $inner), 'id', 'ConnectionError', $null)
            Test-ADServerDownError -ErrorRecord $record | Should -BeTrue
        }

        It 'Is false for <Kind>' -ForEach @(
            @{ Kind = 'a timeout'; Make = { [System.TimeoutException]::new('timed out') } }
            @{ Kind = 'access denied'; Make = { [System.UnauthorizedAccessException]::new('Access is denied') } }
            @{ Kind = 'a server-down message on another type'; Make = { [System.Exception]::new('Unable to contact the server') } }
        ) {
            $record = [System.Management.Automation.ErrorRecord]::new((& $Make), 'id', 'NotSpecified', $null)
            Test-ADServerDownError -ErrorRecord $record | Should -BeFalse
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
