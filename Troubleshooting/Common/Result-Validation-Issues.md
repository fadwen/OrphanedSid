# Result Validation Issues - Troubleshooting Guide

## Overview

Result objects are instances of the `OrphanedSIDResult` class and are created only by
`New-OrphanedSIDResult`. The class and its members are documented in
`.\Troubleshooting\Common\Result-Creation-Issues.md`; the metadata attached to each result is
documented in `.\Troubleshooting\Common\Metadata-Population-Issues.md`. This page covers how to
check a set of results after a run.

## What to Validate

`Find-OrphanedSid` writes one result object per orphaned entry to the pipeline, and the same rows to
the CSV named by `-OutputPath` (always CSV, whatever the extension).
The columns are the class members: `ObjectDN`, `ObjectClass`, `OrphanedSID`, `LikelySource`,
`Confidence`, `AnalysisNotes`, `AccessControlType`, `ActiveDirectoryRights`, `InheritanceType`,
`ObjectType`, `InheritedObjectType`, `IsInherited`, `ProcessingMethod`, `ActionTaken`,
`VerificationStatus`, `VerificationError`, `CorrelationId`, `Timestamp`, followed by the
`ProcessingContext` and `ProcessingStatistics` note properties as text. Enum columns hold numbers.

```powershell
$rows = Import-Csv -Path .\Reports\orphaned-sids.csv

# 1. Identifying fields present
$rows | Where-Object { [string]::IsNullOrWhiteSpace($_.ObjectDN) -or [string]::IsNullOrWhiteSpace($_.OrphanedSID) }

# 2. SIDs well formed and not well-known
$rows | Where-Object { $_.OrphanedSID -notmatch '^S-1-\d+(-\d+)+$' }
$rows | Where-Object { $_.OrphanedSID -match '^S-1-5-(18|19|20|32-\d+)$|^S-1-1-0$|^S-1-5-11$' }

# 3. DNs resolvable (objects deleted since the run are expected to fail)
$rows.ObjectDN | Sort-Object -Unique | ForEach-Object {
    try { $null = Get-ADObject -Identity $_ -ErrorAction Stop }
    catch { "Not found: $_" }
}

# 4. Timestamps inside the run window and ActionTaken as expected
$rows | ForEach-Object { [datetime]::Parse($_.Timestamp) } | Measure-Object -Minimum -Maximum
$rows | Where-Object ActionTaken -ne 'Detected'

# 5. Counts agree with the log summary lines "Orphaned SIDs found: N" (Orphaned rows) and
#    "Unverified SIDs (lookup failed, not removed): N" (Unverified rows)
$rows | Group-Object VerificationStatus -NoElement
```

A SID in the well-known ranges should never appear: `Test-WellKnownSID` filters them before a
result is created. The SIDs check 2 matches are in a list built into that function, so no
`-ConfigPath` setting lets them through.

## Common Findings and Their Meaning

| Finding | Meaning |
| --- | --- |
| Many rows share one `CorrelationId` | Expected: results from the same object share the ID generated for that object |
| `ActiveDirectoryRights = 131220` (GenericRead), `AccessControlType = 0` (Allow) on every row | Access rules lacked those properties and defaults were applied; see Result-Creation-Issues.md |
| `LikelySource = Unknown Domain` | `Get-SIDAnalysis` had no domain SID to compare against; see `.\Troubleshooting\Security\SID-Analysis-Issues.md` |
| `Timestamp` is local time (UTC on Windows PowerShell 5.1) | See Metadata-Population-Issues.md; convert on export when UTC is required |
| Row count lower than `ORPHANED ACCOUNT DETECTED` log entries suggest | Name-form identities that fail translation are logged but produce no result; see Result-Creation-Issues.md |
| A SID that does resolve today | `Test-OrphanedSID` marks a SID orphaned only when every lookup completed and none found it; a failed lookup gives `VerificationStatus = Unverified`. Re-run and compare |

## Validating Live Objects

Results emitted by `Find-OrphanedSid` are read back from JSON batch files, so they are
`PSCustomObject`s, not class instances. For results from `Find-OrphanedSIDsInObject` run in the
module scope (as shown in Metadata-Population-Issues.md), type checks replace property-name checks:

```powershell
& (Get-Module OrphanedSid) { param($r) $r | Where-Object { $_ -isnot [OrphanedSIDResult] } } $results
$results | Where-Object { -not $_.PSObject.Properties['ProcessingStatistics'] }   # attached by Find-OrphanedSIDsInObject
```

Counts by source, confidence, verification status and object class are the quickest way to spot
skew:

```powershell
"Results: $(@($results).Count); objects: $(@($results.ObjectDN | Sort-Object -Unique).Count); " +
    "SIDs: $(@($results.OrphanedSID | Sort-Object -Unique).Count)"
foreach ($property in 'LikelySource', 'Confidence', 'VerificationStatus', 'ObjectClass') {
    $results | Group-Object -Property $property -NoElement | Sort-Object Count -Descending |
        Select-Object @{ Name = $property; Expression = { $_.Name } }, Count
}
```

## Related Documentation

- `.\Troubleshooting\Common\Result-Creation-Issues.md`
- `.\Troubleshooting\Common\Metadata-Population-Issues.md`
- `.\Troubleshooting\Common\SID-Processing-Orchestration-Issues.md`
- `.\Troubleshooting\Security\Orphaned-SID-Issues.md`

## Support Information

- **Module**: `Private\SID\New-SIDResult.ps1`
- **Class**: `Classes\OrphanedSIDResult.ps1`
