# Metadata Population Issues - Troubleshooting Guide

## Overview

Every orphaned SID `Find-OrphanedSid` or `Remove-OrphanedSid` finds becomes one `OrphanedSIDResult` object
(`Classes\OrphanedSIDResult.ps1`). `New-OrphanedSIDResult` (`Private\SID\New-SIDResult.ps1`) fills
it in three steps:

1. Core identification: `ObjectDN`, `ObjectClass`, `OrphanedSID`, `LikelySource`, `Confidence`,
   `AnalysisNotes`.
2. `Add-ProcessingMetadata`: `ProcessingMethod`, `ActionTaken` (always `Detected`),
   `CorrelationId`, `Timestamp`, plus a `ProcessingContext` note property.
3. `Set-ACLMetadata`: `AccessControlType`, `ActiveDirectoryRights`, `InheritanceType`,
   `ObjectType`, `InheritedObjectType`, `IsInherited`, read from the access rule.

`Find-OrphanedSIDsInObject` then attaches a `ProcessingStatistics` note property to each result for
the object it came from. This guide covers the metadata that can look wrong and why.

## Common Issues

### 1. Timestamps

#### Issue: Timestamps are local time, not UTC

`Timestamp` is set with `Get-Date` in the class constructor and again in `Add-ProcessingMetadata`,
so it carries the local time of the machine running the command with `Kind = Local`, on Windows
PowerShell 5.1 and PowerShell 7 alike. The CSV written by `-OutputPath` serialises the value in the
local culture's format. Convert on the way out when a downstream system needs UTC:

```powershell
Import-Csv -Path .\Reports\orphaned-sids.csv | ForEach-Object {
    $_.Timestamp = ([datetime]::Parse($_.Timestamp)).ToUniversalTime().ToString('o')
    $_
} | Export-Csv -Path .\Reports\orphaned-sids-utc.csv -NoTypeInformation
```

Backup files use a different field: `BackupDate` is written as `yyyy-MM-ddTHH:mm:ss.fffZ` text
(local time with a literal `Z`). Treat it as local when comparing with `Timestamp`.

#### Issue: Timestamps appear out of order or far apart in one run

Results are created when each access rule is evaluated, so the `Timestamp` spread equals the
run's duration. A gap of minutes between consecutive objects usually reflects slow SID lookups or
detection being retried (`Retry attempt N of M for object <DN>` in the log). Check the system
clock only when timestamps are in the future relative to the log file's own timestamps.

### 2. Processing Metrics

#### Issue: Per-object duration looks wrong

There is no per-result `ProcessingTime` property. Timing lives in the `ProcessingStatistics` note
property that `Find-OrphanedSIDsInObject` attaches to every result from one object:

| Key | Meaning |
| --- | --- |
| `ObjectDN` | Object the statistics belong to |
| `StartTime`, `EndTime` | `Get-Date` at start and end of that object |
| `Duration` | Milliseconds between them |
| `AccessRulesRetrieved` | Rules returned by `Get-ObjectAccessRule` |
| `ProcessedSIDs` | Rules evaluated, including well-known and resolved ones |
| `SkippedSIDs` | Rules whose evaluation threw an error |
| `WellKnownSIDsSkipped` | Never incremented; always `0` |
| `OrphanedSIDsFound` | Orphaned results created |
| `UnverifiedSIDsFound` | Unverified results created |
| `ErrorsEncountered` | Exceptions caught for that object |
| `ProcessingMethod` | `Orchestrated-Workflow` |

`Duration` is the `TotalMilliseconds` of a `Get-Date` difference, a fractional number. The CSV
holds `ProcessingStatistics` only as text (`@{...}`). To see it as a table, run the per-object
function directly in a diagnostic session:

```powershell
Import-Module ActiveDirectory
Import-Module OrphanedSid
# Private functions are reached through the module scope: & (Get-Module OrphanedSid) { <command> }

$object = Get-ADObject -Identity 'CN=User1,OU=Test,DC=contoso,DC=com' -Properties nTSecurityDescriptor, ObjectClass
$results = & (Get-Module OrphanedSid) {
    param($ADObject) Find-OrphanedSIDsInObject -ADObject $ADObject -IncludeInherited
} $object
$results | Select-Object -First 1 -ExpandProperty ProcessingStatistics
```

Every result from one object shares the same `ProcessingStatistics` table, so read it from one
result per object, from live results rather than a result read back with `Import-Csv`.

#### Issue: Memory figures missing from the summary

`Peak memory usage: N MB` in the summary comes from `MemoryManager.GetPeakMemoryUsage()`. Current
process figures come from `Get-CurrentMemoryUsage` (`Private\System\Get-MemoryStatistics.ps1`),
which returns `WorkingSetMB`, `PrivateMemoryMB`, `VirtualMemoryMB` and `GCTotalMemoryMB`; a failure
is reported as `Failed to retrieve memory usage: <message>`. These read the current process only;
no WMI query is involved. See `.\Troubleshooting\Performance\Memory-Management-Issues.md`.

### 3. Correlation IDs

#### Issue: Many results share one correlation ID

Expected. Every result of a run carries the run's `-CorrelationId`: `Invoke-MainProcessingLogic`
passes it to `Find-OrphanedSIDsInObject`, which passes it on to `Test-AccessRuleForOrphanedSID` and
`New-OrphanedSIDResult`. The GUID the class constructor assigns is always overwritten by
`Add-ProcessingMetadata`. Uniqueness per result is not a goal; traceability from result to log
lines is.

To find the log lines for one result, filter the run's log by its `ObjectDN`:

```powershell
$dn = 'CN=User1,OU=Test,DC=contoso,DC=com'
Select-String -Path .\Logs\Find-OrphanedSid_*.log -Pattern ([regex]::Escape($dn)) | Select-Object -First 10
```

#### Issue: Correlation ID format

Generated IDs are GUID strings (`[System.Guid]::NewGuid().ToString()`). `-CorrelationId` accepts
any string on all three commands, so a change or ticket number works as well as a GUID:

```powershell
$id = [guid]::NewGuid().ToString()
Find-OrphanedSid -SearchBase 'OU=Test,DC=contoso,DC=com' -CorrelationId $id
```

### 4. Processing Context

Each result also carries a `ProcessingContext` note property (hashtable) with `MachineName`,
`UserName`, `ProcessId`, `PowerShellVersion` and `ModuleVersion` (always `1.0.0`). Like
`ProcessingStatistics` it is not a class member; the CSV holds it only as text.

### 5. ACL Metadata Defaults

When the access rule lacks a property, `Set-ACLMetadata` substitutes a default and logs it at
Debug level:

| Property | Default when absent | Debug message |
| --- | --- | --- |
| `AccessControlType` | `Allow` | `AccessControlType property missing, set to Allow` |
| `ActiveDirectoryRights` | `GenericRead` (after trying a `Rights` property) | `ActiveDirectoryRights property missing, set to GenericRead` |
| `InheritanceType` | `None` | `InheritanceFlags property missing, set to None` |
| `ObjectType`, `InheritedObjectType` | `Guid.Empty` | `GUID property <name> missing or null, set to Empty` |
| `IsInherited` | `$false` | `IsInherited property missing, set to false` |

Defaults appear mainly on deserialized access rules. If many results show `GenericRead` and
`Allow`, run with `-LogLevel Debug` and look for these messages to confirm.

## Validation Commands

```powershell
# After a run with -OutputPath
$rows = Import-Csv -Path .\Reports\orphaned-sids.csv

# Every row has the identifying fields
$rows | Where-Object { -not $_.ObjectDN -or -not $_.OrphanedSID -or -not $_.CorrelationId }

# Timestamps fall inside the run window recorded in the log
$rows | ForEach-Object { [datetime]::Parse($_.Timestamp) } | Measure-Object -Minimum -Maximum

# SIDs are well formed
$rows | Where-Object { $_.OrphanedSID -notmatch '^S-1-\d+(-\d+)+$' }
```

## Related Documentation

- `.\Troubleshooting\Common\Result-Creation-Issues.md`
- `.\Troubleshooting\Common\Result-Validation-Issues.md`
- `.\Troubleshooting\Common\SID-Processing-Orchestration-Issues.md`
- `.\Troubleshooting\Performance\Memory-Management-Issues.md`

## Support Information

- **Module**: `Private\SID\New-SIDResult.ps1`
- **Functions**: `New-OrphanedSIDResult`, `Add-ProcessingMetadata`, `Set-ACLMetadata`,
  `Get-SafeGuidProperty`
- **Correlation ID**: include the run's `-CorrelationId` in support requests
