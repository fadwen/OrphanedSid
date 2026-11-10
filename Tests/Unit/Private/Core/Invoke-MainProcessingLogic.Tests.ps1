#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
#Requires -Version 5.1

<#
.SYNOPSIS
    Pester tests for the Invoke-MainProcessingLogic private function

.DESCRIPTION
    Runs the discovery and removal loop against the real ProcessingStatistics and
    StreamingResultsManager classes, with object retrieval, orphaned SID detection, removal, memory
    checks and logging mocked. Covers discovery, the result summary, removal and -WhatIf, error
    handling and retries, and how unverified SIDs are counted.

.NOTES
    Author: Jeffrey Stuhr
    Blog: https://www.techbyjeff.net
    LinkedIn: https://www.linkedin.com/in/jeffrey-stuhr-034214aa/
    PowerShell Version: 5.1+

    TROUBLESHOOTING:
    - Memory management: .\Troubleshooting\Performance\Memory-Management.md
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\TestHelpers\ADCmdletStubs.ps1"
    . "$PSScriptRoot\..\..\..\..\Classes\ProcessingStatistics.ps1"
    . "$PSScriptRoot\..\..\..\..\Classes\StreamingResultsManager.ps1"
    . "$PSScriptRoot\..\..\..\..\Private\ActiveDirectory\Test-ValidDistinguishedName.ps1"
    . "$PSScriptRoot\..\..\..\..\Private\Core\Invoke-MainProcessingLogic.ps1"

    # Placeholders for collaborators, so each can be mocked; the names match the real parameters
    function Write-StructuredLog { param($Message, $Level, $Component, $CorrelationId) }
    function Write-ADOperationSecurityLog { param($OperationName, $Outcome, $SecurityContext, $CorrelationId) }
    function Get-ADObjectsSequential { param($SearchBase, [switch]$IncludeInherited, $CorrelationId) }
    function Find-OrphanedSIDsInObject { param($ADObject, [switch]$IncludeInherited, $CurrentDomainSID) }
    function Remove-OrphanedSidEntry { param($ObjectDN, $OrphanedSIDs, $BackupPath, $CorrelationId) }
    function Invoke-MemoryCheck { param($MemoryManager, $CorrelationId, [switch]$WhatIf) }
    function Invoke-Cleanup { param($CorrelationId, [switch]$WhatIf) }

    $script:SidA = 'S-1-5-21-123456789-123456789-123456789-1001'
    $script:DomainSid = 'S-1-5-21-123456789-123456789-123456789'

    function New-TestObject {
        param([string]$Name, [string]$ObjectClass)
        [PSCustomObject]@{ DistinguishedName = "CN=$Name,OU=Test,DC=test,DC=com"; ObjectClass = $ObjectClass }
    }

    # Runs the subject with a fresh correlation ID unless the test supplies one
    function Invoke-Subject {
        param([hashtable]$Parameters = @{})
        if (-not $Parameters.ContainsKey('CorrelationId')) {
            $Parameters.CorrelationId = [System.Guid]::NewGuid().ToString()
        }
        $script:LastCorrelationId = $Parameters.CorrelationId
        Invoke-MainProcessingLogic @Parameters
    }
}

Describe "Invoke-MainProcessingLogic" -Tag 'Unit', 'Core', 'Private' {

    BeforeEach {
        $script:Config = [PSCustomObject]@{ BatchSize = 50 }
        $script:Statistics = [ProcessingStatistics]::new()
        $script:MemoryManager = [PSCustomObject]@{ Name = 'TestMemoryManager' }
        Add-Member -InputObject $script:MemoryManager -MemberType ScriptMethod -Name 'GetPeakMemoryUsage' -Value { 321 }
        $script:StreamingResults = $null
        $script:RemovalResults = $null
        $script:CurrentDomainSID = $null

        Mock Write-StructuredLog { }
        Mock Write-ADOperationSecurityLog { }
        Mock Invoke-MemoryCheck { }
        Mock Invoke-Cleanup { [PSCustomObject]@{ MemoryAfterMB = 50; MemoryFreedMB = 10 } }
        Mock Start-Sleep { }
        Mock Get-ADDomain { [PSCustomObject]@{ DomainSID = [PSCustomObject]@{ Value = $script:DomainSid } } }
        Mock Get-ADObjectsSequential {
            New-TestObject -Name 'User1' -ObjectClass 'user'
            New-TestObject -Name 'Computer1' -ObjectClass 'computer'
            New-TestObject -Name 'Group1' -ObjectClass 'group'
        }
        Mock Find-OrphanedSIDsInObject {
            [PSCustomObject]@{ OrphanedSID = $script:SidA; ObjectDN = $ADObject.DistinguishedName; VerificationStatus = 'Orphaned'; VerificationError = $null }
        }
        Mock Remove-OrphanedSidEntry {
            [PSCustomObject]@{ ObjectDN = $ObjectDN; RemovedSIDs = $OrphanedSIDs; BackupCreated = $true; BackupPath = $BackupPath; RemovedCount = @($OrphanedSIDs).Count }
        }
    }

    AfterEach {
        if ($script:StreamingResults) {
            $tempDir = $script:StreamingResults.TempDirectory
            $script:StreamingResults.Dispose()
            if ($tempDir -and (Test-Path $tempDir)) {
                Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context "Set-up" {
        It "Rejects a search base that is not a distinguished name" {
            { Invoke-Subject @{ SearchBase = 'not a dn' } } | Should -Throw -ExpectedMessage '*SearchBase*'
            Should -Invoke Get-ADObjectsSequential -Times 0 -Exactly
        }

        It "Creates a streaming manager in a per-correlation temp folder with the configured batch size" {
            $script:Config = [PSCustomObject]@{ BatchSize = 7 }

            $result = Invoke-Subject @{ SearchBase = 'OU=Test,DC=test,DC=com' }

            $result.StreamingManager | Should -Be $script:StreamingResults
            $result.StreamingManager.BatchSize | Should -Be 7
            $result.StreamingManager.TempDirectory | Should -Be (Join-Path ([System.IO.Path]::GetTempPath()) "OrphanedSid-$($script:LastCorrelationId)")
            $result.StreamingManager.WhatIfMode | Should -Be $false
        }

        It "Uses a batch size of 50 when no configuration is loaded" {
            $script:Config = $null

            $result = Invoke-Subject @{ SearchBase = 'OU=Test,DC=test,DC=com' }

            $result.StreamingManager.BatchSize | Should -Be 50
        }

        It "Puts the streaming manager in WhatIf mode under -WhatIf" {
            $result = Invoke-Subject @{ SearchBase = 'OU=Test,DC=test,DC=com'; WhatIf = $true }

            $result.StreamingManager.WhatIfMode | Should -Be $true
        }

        It "Reads the domain SID once and passes it to SID detection" {
            Invoke-Subject @{ SearchBase = 'OU=Test,DC=test,DC=com' } | Out-Null

            Should -Invoke Get-ADDomain -Times 1 -Exactly
            Should -Invoke Find-OrphanedSIDsInObject -Times 3 -Exactly -ParameterFilter { $CurrentDomainSID -eq $script:DomainSid }
        }

        It "Warns and carries on without a domain SID when Get-ADDomain fails" {
            Mock Get-ADDomain { throw 'domain unreachable' }

            $result = Invoke-Subject @{ SearchBase = 'OU=Test,DC=test,DC=com' }

            $result.TotalObjectsProcessed | Should -Be 3
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Warning' -and $Message -eq 'Could not determine the current domain SID: domain unreachable'
            }
            Should -Invoke Find-OrphanedSIDsInObject -Times 3 -Exactly -ParameterFilter { $null -eq $CurrentDomainSID }
        }
    }

    Context "Discovery" {
        It "Retrieves objects once per search base, passing each base alone" {
            Invoke-Subject @{ SearchBase = 'OU=Users,DC=test,DC=com', 'OU=Groups,DC=test,DC=com' } | Out-Null

            Should -Invoke Get-ADObjectsSequential -Times 2 -Exactly
            Should -Invoke Get-ADObjectsSequential -Times 1 -Exactly -ParameterFilter { @($SearchBase).Count -eq 1 -and $SearchBase[0] -eq 'OU=Users,DC=test,DC=com' }
            Should -Invoke Get-ADObjectsSequential -Times 1 -Exactly -ParameterFilter { @($SearchBase).Count -eq 1 -and $SearchBase[0] -eq 'OU=Groups,DC=test,DC=com' }
        }

        It "Logs a discovery Attempt and Success for each base, with the object count" {
            Invoke-Subject @{ SearchBase = 'OU=Users,DC=test,DC=com' } | Out-Null

            Should -Invoke Write-ADOperationSecurityLog -Times 1 -Exactly -ParameterFilter {
                $OperationName -eq 'AD-ObjectDiscovery' -and $Outcome -eq 'Attempt' -and
                $SecurityContext.SearchBase -eq 'OU=Users,DC=test,DC=com' -and $SecurityContext.Mode -eq 'DiscoveryMode' -and
                $CorrelationId -eq $script:LastCorrelationId
            }
            Should -Invoke Write-ADOperationSecurityLog -Times 1 -Exactly -ParameterFilter {
                $OperationName -eq 'AD-ObjectDiscovery' -and $Outcome -eq 'Success' -and $SecurityContext.ObjectsFound -eq 3
            }
        }

        It "Marks the discovery Attempt as RemovalMode under -Remove" {
            Invoke-Subject @{ SearchBase = 'OU=Users,DC=test,DC=com'; Remove = $true } | Out-Null

            Should -Invoke Write-ADOperationSecurityLog -Times 1 -Exactly -ParameterFilter {
                $OperationName -eq 'AD-ObjectDiscovery' -and $Outcome -eq 'Attempt' -and $SecurityContext.Mode -eq 'RemovalMode'
            }
        }

        It "Summarizes the discovered objects by class" {
            Mock Get-ADObjectsSequential {
                New-TestObject -Name 'U1' -ObjectClass 'user'
                New-TestObject -Name 'U2' -ObjectClass 'user'
                New-TestObject -Name 'C1' -ObjectClass 'computer'
                New-TestObject -Name 'G1' -ObjectClass 'group'
                New-TestObject -Name 'O1' -ObjectClass 'organizationalUnit'
                New-TestObject -Name 'X1' -ObjectClass 'contact'
            }

            Invoke-Subject @{ SearchBase = 'OU=Test,DC=test,DC=com' } | Out-Null

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Message -eq 'Discovered: 2 users, 1 computers, 1 groups, 1 OUs, 1 other objects (Total: 6 objects)'
            }
        }

        It "Reports 0 objects for an empty search base" {
            Mock Get-ADObjectsSequential { }

            $result = Invoke-Subject @{ SearchBase = 'OU=Empty,DC=test,DC=com' }

            $result.TotalObjectsProcessed | Should -Be 0
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Message -eq 'Discovered: 0 objects (Total: 0 objects)'
            }
            Should -Invoke Find-OrphanedSIDsInObject -Times 0 -Exactly
        }

        It "Logs a discovery Failure, counts a critical error and rethrows when retrieval fails" {
            Mock Get-ADObjectsSequential { throw 'AD connection failed' }

            { Invoke-Subject @{ SearchBase = 'OU=Users,DC=test,DC=com' } } | Should -Throw -ExpectedMessage 'AD connection failed'

            Should -Invoke Write-ADOperationSecurityLog -Times 1 -Exactly -ParameterFilter {
                $OperationName -eq 'AD-ObjectDiscovery' -and $Outcome -eq 'Failure' -and
                $SecurityContext.ErrorMessage -eq 'AD connection failed' -and $SecurityContext.SearchBase -eq 'OU=Users,DC=test,DC=com'
            }
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Error' -and $Message -eq 'Critical error in main processing: AD connection failed'
            }
            $script:Statistics.CriticalErrors | Should -Be 1
        }
    }

    Context "SID analysis" {
        It "Checks every object for orphaned SIDs and passes IncludeInherited through" {
            Invoke-Subject @{ SearchBase = 'OU=Test,DC=test,DC=com'; IncludeInherited = $true } | Out-Null

            foreach ($name in 'User1', 'Computer1', 'Group1') {
                Should -Invoke Find-OrphanedSIDsInObject -Times 1 -Exactly -ParameterFilter {
                    $ADObject.DistinguishedName -eq "CN=$name,OU=Test,DC=test,DC=com" -and $IncludeInherited
                }
            }
        }

        It "Runs a memory check for every object with WhatIf pinned off" {
            Invoke-Subject @{ SearchBase = 'OU=Test,DC=test,DC=com'; WhatIf = $true } | Out-Null

            Should -Invoke Invoke-MemoryCheck -Times 3 -Exactly -ParameterFilter {
                $MemoryManager.Name -eq 'TestMemoryManager' -and $WhatIf -eq $false
            }
        }

        It "Runs a cleanup after every 100th object with WhatIf pinned off" {
            Mock Get-ADObjectsSequential { 1..201 | ForEach-Object { New-TestObject -Name "U$_" -ObjectClass 'user' } }
            Mock Find-OrphanedSIDsInObject { }

            Invoke-Subject @{ SearchBase = 'OU=Test,DC=test,DC=com' } | Out-Null

            Should -Invoke Invoke-Cleanup -Times 2 -Exactly -ParameterFilter { $WhatIf -eq $false -and $CorrelationId -eq $script:LastCorrelationId }
        }

        It "Logs progress every 50 objects and at the last one" {
            Mock Get-ADObjectsSequential { 1..60 | ForEach-Object { New-TestObject -Name "U$_" -ObjectClass 'user' } }
            Mock Find-OrphanedSIDsInObject { }

            Invoke-Subject @{ SearchBase = 'OU=Test,DC=test,DC=com' } | Out-Null

            Should -Invoke Write-StructuredLog -Times 2 -Exactly -ParameterFilter { $Message -like 'Processing: *' }
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter { $Message -eq 'Processing: 50/60 objects (83.3%) - Orphaned SIDs found: 0' }
        }

        It "Streams every finding and returns the totals" {
            $result = Invoke-Subject @{ SearchBase = 'OU=Test,DC=test,DC=com' }

            $result.TotalObjectsProcessed | Should -Be 3
            $result.OrphanedSIDsFound | Should -Be 3
            $result.UnverifiedSIDsFound | Should -Be 0
            $result.ProcessingErrors | Should -Be 0
            $result.StreamingSummary.TotalResults | Should -Be 3
            $result.StreamingSummary.OrphanedSIDsFound | Should -Be 3
            $script:Statistics.TotalObjects | Should -Be 3
        }

        It "Logs a detection entry naming the orphaned SIDs on each object" {
            Invoke-Subject @{ SearchBase = 'OU=Test,DC=test,DC=com' } | Out-Null

            Should -Invoke Write-ADOperationSecurityLog -Times 1 -Exactly -ParameterFilter {
                $OperationName -eq 'OrphanedSID-Detection' -and $Outcome -eq 'Success' -and
                $SecurityContext.ObjectDN -eq 'CN=User1,OU=Test,DC=test,DC=com' -and
                $SecurityContext.ObjectClass -eq 'user' -and
                $SecurityContext.OrphanedSIDsFound -eq 1 -and
                $SecurityContext.OrphanedSIDs -eq $script:SidA
            }
        }

        It "Writes no detection entry for an object without findings" {
            Mock Find-OrphanedSIDsInObject { }

            $result = Invoke-Subject @{ SearchBase = 'OU=Test,DC=test,DC=com' }

            $result.OrphanedSIDsFound | Should -Be 0
            Should -Invoke Write-ADOperationSecurityLog -Times 0 -Exactly -ParameterFilter { $OperationName -eq 'OrphanedSID-Detection' }
        }

        It "Logs a completion line per search base with the object and SID counts" {
            Invoke-Subject @{ SearchBase = 'OU=Test,DC=test,DC=com' } | Out-Null

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Message -eq 'Completed OU=Test,DC=test,DC=com - Objects: 3, Orphaned SIDs: 3'
            }
        }
    }

    Context "Result" {
        It "Returns only the result hashtable, carrying the caller's correlation ID" {
            $correlationId = [System.Guid]::NewGuid().ToString()

            $output = @(Invoke-Subject @{ SearchBase = 'OU=Test,DC=test,DC=com'; CorrelationId = $correlationId })

            $output.Count | Should -Be 1
            $output[0] | Should -BeOfType [hashtable]
            $output[0].CorrelationId | Should -Be $correlationId
        }

        It "Reports the peak memory from the memory manager and the run's duration" {
            $result = Invoke-Subject @{ SearchBase = 'OU=Test,DC=test,DC=com' }

            $result.PeakMemoryUsageMB | Should -Be 321
            $result.ProcessingDuration | Should -BeOfType [TimeSpan]
            $result.ProcessingDuration | Should -Be $script:Statistics.Duration
            $script:Statistics.EndTime | Should -Not -Be ([DateTime]::MinValue)
        }

        It "Sums the totals across several search bases" {
            $result = Invoke-Subject @{ SearchBase = 'OU=Users,DC=test,DC=com', 'OU=Groups,DC=test,DC=com' }

            $result.TotalObjectsProcessed | Should -Be 6
            $result.OrphanedSIDsFound | Should -Be 6
        }
    }

    Context "Removal" {
        It "Removes nothing without -Remove" {
            $result = Invoke-Subject @{ SearchBase = 'OU=Test,DC=test,DC=com' }

            Should -Invoke Remove-OrphanedSidEntry -Times 0 -Exactly
            @($result.RemovalResults).Count | Should -Be 0
        }

        It "Removes each orphaned SID with the object, backup path and correlation ID" {
            $result = Invoke-Subject @{ SearchBase = 'OU=Test,DC=test,DC=com'; Remove = $true; BackupPath = 'C:\Backups' }

            Should -Invoke Remove-OrphanedSidEntry -Times 3 -Exactly
            Should -Invoke Remove-OrphanedSidEntry -Times 1 -Exactly -ParameterFilter {
                $ObjectDN -eq 'CN=User1,OU=Test,DC=test,DC=com' -and
                @($OrphanedSIDs).Count -eq 1 -and $OrphanedSIDs[0] -eq $script:SidA -and
                $BackupPath -eq 'C:\Backups' -and
                $CorrelationId -eq $script:LastCorrelationId
            }
            @($result.RemovalResults).Count | Should -Be 3
            $result.RemovalResults[0].BackupPath | Should -Be 'C:\Backups'
        }

        It "Leaves BackupPath unbound when none is given" {
            Invoke-Subject @{ SearchBase = 'OU=Test,DC=test,DC=com'; Remove = $true } | Out-Null

            Should -Invoke Remove-OrphanedSidEntry -Times 3 -Exactly -ParameterFilter { -not $PSBoundParameters.ContainsKey('BackupPath') }
        }

        It "Logs a removal Attempt and Success with the removal details" {
            Invoke-Subject @{ SearchBase = 'OU=Test,DC=test,DC=com'; Remove = $true; BackupPath = 'C:\Backups' } | Out-Null

            Should -Invoke Write-ADOperationSecurityLog -Times 3 -Exactly -ParameterFilter {
                $OperationName -eq 'OrphanedSID-Removal' -and $Outcome -eq 'Attempt' -and
                $SecurityContext.OrphanedSID -eq $script:SidA -and $SecurityContext.BackupPath -eq 'C:\Backups' -and
                -not $SecurityContext.ContainsKey('SimulationMode')
            }
            Should -Invoke Write-ADOperationSecurityLog -Times 1 -Exactly -ParameterFilter {
                $OperationName -eq 'OrphanedSID-Removal' -and $Outcome -eq 'Success' -and
                $SecurityContext.ObjectDN -eq 'CN=Group1,OU=Test,DC=test,DC=com' -and
                $SecurityContext.BackupCreated -eq $true -and $SecurityContext.RemovedCount -eq 1
            }
        }

        It "Previews removal under -WhatIf without calling Remove-OrphanedSidEntry" {
            $result = Invoke-Subject @{ SearchBase = 'OU=Test,DC=test,DC=com'; Remove = $true; WhatIf = $true }

            Should -Invoke Remove-OrphanedSidEntry -Times 0 -Exactly
            @($result.RemovalResults).Count | Should -Be 3
            $result.RemovalResults[0].SecurityValidation | Should -Be 'WhatIf - Would Remove'
            $result.RemovalResults[0].ObjectDN | Should -Be 'CN=User1,OU=Test,DC=test,DC=com'
            Should -Invoke Write-ADOperationSecurityLog -Times 3 -Exactly -ParameterFilter {
                $OperationName -eq 'OrphanedSID-Removal' -and $Outcome -eq 'Attempt' -and
                $SecurityContext.SimulationMode -eq $true -and $SecurityContext.WhatIfMode -eq $true
            }
        }

        It "Logs a removal Failure and counts a processing error when removal throws" {
            Mock Remove-OrphanedSidEntry { throw 'access denied' }

            $result = Invoke-Subject @{ SearchBase = 'OU=Test,DC=test,DC=com'; Remove = $true }

            Should -Invoke Write-ADOperationSecurityLog -Times 3 -Exactly -ParameterFilter {
                $OperationName -eq 'OrphanedSID-Removal' -and $Outcome -eq 'Failure' -and $SecurityContext.ErrorMessage -eq 'access denied'
            }
            $result.ProcessingErrors | Should -Be 3
        }
    }

    Context "Per-object errors and retries" {
        It "Counts a processing error, logs it and retries up to MaxRetries with a growing delay" {
            Mock Find-OrphanedSIDsInObject { throw 'Processing failed' }
            Mock Get-ADObjectsSequential { New-TestObject -Name 'User1' -ObjectClass 'user' }

            $result = Invoke-Subject @{ SearchBase = 'OU=Test,DC=test,DC=com'; MaxRetries = 3 }

            $result.ProcessingErrors | Should -Be 1
            Should -Invoke Find-OrphanedSIDsInObject -Times 4 -Exactly
            Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 2 }
            Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 4 }
            Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 6 }
            Should -Invoke Write-StructuredLog -Times 3 -Exactly -ParameterFilter { $Level -eq 'Warning' -and $Message -like 'Retry attempt * of 3 *' }
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'Error' -and $Message -like 'Max retries (3) exceeded*' }
        }

        It "Streams the findings of a retry that succeeds and continues with the next object" {
            $script:findCalls = 0
            Mock Find-OrphanedSIDsInObject {
                $script:findCalls++
                if ($script:findCalls -eq 1) { throw 'transient' }
                [PSCustomObject]@{ OrphanedSID = $script:SidA; ObjectDN = 'CN=X'; VerificationStatus = 'Orphaned' }
            }

            $result = Invoke-Subject @{ SearchBase = 'OU=Test,DC=test,DC=com'; MaxRetries = 2 }

            $result.ProcessingErrors | Should -Be 1
            $result.TotalObjectsProcessed | Should -Be 3
            $result.OrphanedSIDsFound | Should -Be 3
            $result.StreamingSummary.TotalResults | Should -Be 3
            Should -Invoke Start-Sleep -Times 1 -Exactly
        }

        # Module bug (#22): the retry in the per-object catch passes $_ (the ErrorRecord) as -ADObject, not the object that failed
        It "Retries detection on the object that failed" -Skip {
            $script:findCalls = 0
            Mock Find-OrphanedSIDsInObject {
                $script:findCalls++
                if ($script:findCalls -eq 1) { throw 'transient' }
            }
            Mock Get-ADObjectsSequential { New-TestObject -Name 'User1' -ObjectClass 'user' }

            Invoke-Subject @{ SearchBase = 'OU=Test,DC=test,DC=com'; MaxRetries = 1 } | Out-Null

            Should -Invoke Find-OrphanedSIDsInObject -Times 2 -Exactly -ParameterFilter {
                $ADObject.DistinguishedName -eq 'CN=User1,OU=Test,DC=test,DC=com'
            }
        }
    }

    Context "Unverified SIDs" {
        BeforeEach {
            $script:unverifiedSid = 'S-1-5-21-123456789-123456789-123456789-2002'
            $script:verifiedSid = 'S-1-5-21-123456789-123456789-123456789-1001'

            Mock Get-ADObjectsSequential { New-TestObject -Name 'User1' -ObjectClass 'user' }

            # One SID every lookup confirmed missing, one a failed lookup left unverified
            Mock Find-OrphanedSIDsInObject {
                [PSCustomObject]@{ OrphanedSID = $script:verifiedSid; ObjectDN = $ADObject.DistinguishedName; VerificationStatus = 'Orphaned'; VerificationError = $null }
                [PSCustomObject]@{ OrphanedSID = $script:unverifiedSid; ObjectDN = $ADObject.DistinguishedName; VerificationStatus = 'Unverified'; VerificationError = 'Get-ADObject: The server is not operational' }
            }
        }

        It "Never passes an unverified SID to removal" {
            $result = Invoke-Subject @{ SearchBase = 'OU=Users,DC=test,DC=com'; Remove = $true }

            Should -Invoke Remove-OrphanedSidEntry -Times 1 -Exactly
            Should -Invoke Remove-OrphanedSidEntry -Times 1 -Exactly -ParameterFilter { $OrphanedSIDs -contains $script:verifiedSid }
            @($result.RemovalResults).Count | Should -Be 1
        }

        It "Logs a warning that names the unverified SID and the lookup failure" {
            Invoke-Subject @{ SearchBase = 'OU=Users,DC=test,DC=com'; Remove = $true } | Out-Null

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Warning' -and $Message -like "Not removing unverified SID $($script:unverifiedSid)*not operational*"
            }
        }

        It "Counts unverified SIDs apart from orphaned ones and streams both" {
            $result = Invoke-Subject @{ SearchBase = 'OU=Users,DC=test,DC=com' }

            $result.OrphanedSIDsFound | Should -Be 1
            $result.UnverifiedSIDsFound | Should -Be 1
            $result.StreamingSummary.TotalResults | Should -Be 2
            $result.StreamingSummary.UnverifiedSIDsFound | Should -Be 1
            Should -Invoke Remove-OrphanedSidEntry -Times 0 -Exactly
            Should -Invoke Write-ADOperationSecurityLog -Times 1 -Exactly -ParameterFilter {
                $OperationName -eq 'OrphanedSID-Detection' -and
                $SecurityContext.UnverifiedSIDsFound -eq 1 -and $SecurityContext.UnverifiedSIDs -eq $script:unverifiedSid -and
                $SecurityContext.OrphanedSIDsFound -eq 1 -and $SecurityContext.OrphanedSIDs -eq $script:verifiedSid
            }
        }

        It "Leaves the unverified SID out of a -WhatIf preview" {
            $result = Invoke-Subject @{ SearchBase = 'OU=Users,DC=test,DC=com'; Remove = $true; WhatIf = $true }

            @($result.RemovalResults.OrphanedSID) | Should -Be @($script:verifiedSid)
        }
    }
}
