# SID Processing Orchestration Issues - Troubleshooting Guide

## Overview

`Find-OrphanedSIDsInObject` in `Private\SID\Invoke-SIDProcessing.ps1` is the per-object workflow.
`Invoke-MainProcessingLogic` calls it once for every object returned by `Get-ADObjectsSequential`,
and it returns an array of `OrphanedSIDResult` objects (possibly empty). This guide describes the
components it coordinates, the messages each emits, and the failure modes between them.

## The Workflow

```text
Invoke-MainProcessingLogic                      (Private\Core)
  for each object:
    Find-OrphanedSIDsInObject -ADObject $obj [-IncludeInherited]
      Get-ObjectAccessRule                      (Private\Security\Get-SecurityDescriptor.ps1)
        -> ActiveDirectoryAccessRule[] or $null
      for each rule:
        Test-AccessRuleForOrphanedSID           (Private\SID\Resolve-SIDIdentity.ps1)
          SecurityIdentifier.Value, or for any other reference type:
          Resolve-IdentityReference             -> SID string, or $null
            Convert-NTAccountToSID              (for NTAccount identities)
          Test-SIDValidityAndType               -> Test-SIDFormat, Test-WellKnownSID
                                                   (once per SID per run; the answer is cached)
          Test-OrphanedSID                      (Private\SID\Test-OrphanedSID.ps1) -> Status
          Get-SIDAnalysis -SIDString -CurrentDomainSID (Private\SID\Get-SIDAnalysis.ps1; Orphaned only)
          New-OrphanedSIDResult                 (Private\SID\New-SIDResult.ps1; Orphaned or Unverified)
      attach ProcessingStatistics to each result
    StreamingResultsManager.AddResult(...)      (batch files under <temp>\OrphanedSid-<CorrelationId>)
    under Remove-OrphanedSid: Remove-OrphanedSidEntry once per object, for its Orphaned,
      non-inherited SIDs (Unverified and inherited entries are reported, not removed)
```

Objects are processed sequentially; there is no parallel path.

### Component contracts

| Component | Input | Output |
| --- | --- | --- |
| `Get-ObjectAccessRule -ADObject <PSObject> [-IncludeInherited]` | AD object with `DistinguishedName` (and usually `nTSecurityDescriptor`) | `ActiveDirectoryAccessRule[]`, with `SecurityIdentifier` references when read through `Get-Acl`; `$null` when every strategy fails, or when every entry is inherited and `-IncludeInherited` is off |
| `Resolve-IdentityReference -IdentityReference <PSObject>` | `SecurityIdentifier`, `NTAccount`, or a deserialized identity | SID string; `ORPHANED_ACCOUNT:<name>` for an untranslatable `NTAccount`; `$null` otherwise |
| `Test-SIDValidityAndType -SIDString <string>` | SID string | `$true` only for a well-formed, non-well-known SID |
| `Test-OrphanedSID -SID <string>` | SID string | object with `Status` `Orphaned`, `Exists` or `Unverified` and `ErrorMessage`; `Orphaned` and `Exists` cached per SID for the session |
| `Get-SIDAnalysis -SIDString <string> [-CurrentDomainSID <string>]` | SID string | `SIDAnalysisResult` (`LikelySource`, `Confidence`, `Notes`, `RiskLevel`) |
| `New-OrphanedSIDResult` | see Result-Creation-Issues.md | `OrphanedSIDResult` |

## Common Issues

### 1. Objects Skipped Without Results

Each skip is logged at Debug level by `Find-OrphanedSIDsInObject`; run with `-LogLevel Debug` to
see them.

| Debug message | Cause |
| --- | --- |
| `Skipping error object: <message>` | Input object carries `IsError = $true`; no module function emits one |
| `Object missing DistinguishedName property, skipping` | Malformed pipeline input |
| `No security descriptor found for <DN>` | Object arrived without `nTSecurityDescriptor` when `Find-OrphanedSIDsInObject` is called directly; a command run skips such an object earlier with the Warning `Not examined: ...` and counts it under `Objects not examined` |
| `No access rules retrieved for <DN>` | `Get-ObjectAccessRule` returned nothing: either every entry is inherited (Debug `No explicit access rules on <DN> (all N are inherited)` precedes it; use `-IncludeInherited` to examine them), or a Warning `All security descriptor retrieval methods failed for <DN>` precedes it (see `.\Troubleshooting\Common\Security-Descriptor-Warnings.md`) |

Skips are not errors. `Processing errors` in the summary counts exceptions caught by the per-object
loop in `Invoke-MainProcessingLogic`,
not skipped objects.

### 2. Rules Evaluated but No Result Created

Per-rule outcomes are also Debug level in `Test-AccessRuleForOrphanedSID` and its helpers:

| Debug message | Cause |
| --- | --- |
| `Skipping access rule with missing or null IdentityReference for <DN>` | Rule has no identity |
| `Failed to resolve identity reference to SID for <DN>` | `Resolve-IdentityReference` returned `$null` |
| `Extracted string is not a valid SID format: <value> (Type: <type>) for <DN>` | Deserialized identity whose string form is not a SID |
| `Skipping well-known SID: <sid>` | Filtered by `Test-WellKnownSID` (`ScriptConfiguration.WellKnownSIDPatterns` and `ProtectedSIDs`, plus a built-in list) |
| `SID validation failed or well-known SID detected: <sid>` | `Test-SIDValidityAndType` returned `$false` |
| `SID <sid> is valid (found in AD)` | `Test-OrphanedSID` resolved the SID |

One case is logged at Information level and is easy to miss:
`ORPHANED ACCOUNT DETECTED: Failed to translate NTAccount '<name>' to SID - likely orphaned: <message>`.
`Convert-NTAccountToSID` returns `ORPHANED_ACCOUNT:<name>`, which `Test-SIDFormat` rejects, so the
rule is skipped and no result is created. Count these when the CSV looks short:

```powershell
Select-String -Path .\Logs\<Command>_*.log -Pattern 'ORPHANED ACCOUNT DETECTED' | Measure-Object
```

### 3. Unverified Results When the Domain Controller Is Unreachable

`Test-OrphanedSID` tries, in order: `Get-ADObject -Filter "objectSid -eq '<sid>'"`, the same
with `-IncludeDeletedObjects`, `SecurityIdentifier.Translate`, then `Get-ADUser`, `Get-ADGroup`
and `Get-ADComputer`. Each AD call goes through `Invoke-ADOperationWithRetry`, which retries
transient errors up to its own default of 3 attempts (the commands' `-MaxRetries` does not reach
it). Only when every lookup completes and none finds the SID is it marked orphaned
(`SID could not be resolved - marking as orphaned: <sid>` at Debug) and cached for the session.
When a lookup fails instead, the SID is `Unverified` (`SID could not be verified - N lookup(s)
failed: <sid> (<failures>)` at Warning), is not cached, and `Remove-OrphanedSid` does not remove it
(`Not removing unverified SID ...`). When the directory server cannot be contacted, the first
lookup waits out a connect timeout of about 42 seconds and the remaining directory lookups for that
SID are skipped: the Warning reads `N lookup(s) failed, M not attempted`, and `VerificationError`
ends with `Not attempted because the directory server could not be contacted: <lookups>`. An
exception in the function itself also gives `Unverified` (`Error testing SID for orphaned status <sid> : <message>` at Error level).

Check before acting on results:

```powershell
# Look for lookup failures in the log
Select-String -Path .\Logs\<Command>_*.log -Pattern 'SID could not be verified|Error testing SID for orphaned status' | Measure-Object

# Re-test a reported SID directly
$sid = 'S-1-5-21-1234567890-1234567890-1234567890-1001'
Get-ADObject -Filter "objectSid -eq '$sid'" -IncludeDeletedObjects
([System.Security.Principal.SecurityIdentifier]$sid).Translate([System.Security.Principal.NTAccount])
```

Never run `Remove-OrphanedSid` against a scope whose discovery log shows lookup failures.

### 4. Errors Inside the Workflow

| Message | Level | Where | Effect |
| --- | --- | --- | --- |
| `Error processing access rule for <DN> : <message>` | Warning | `Find-OrphanedSIDsInObject` | That rule is skipped; `ErrorsEncountered` incremented; other rules continue |
| `Error testing access rule for orphaned SID on <DN> : <message>` | Warning | `Test-AccessRuleForOrphanedSID` | Rule skipped |
| `Error in orchestrated processing for object <DN> : <message>` | Error | `Find-OrphanedSIDsInObject` | Results collected so far for that object are returned |
| `Unexpected error retrieving access rules for <DN>: <message>` | Error | `Get-ObjectAccessRule` | Object skipped |
| `Retry attempt N of M for object <DN>: <message>`, then `Max retries (M) exceeded for object <DN>` and `Error processing object <DN>: <message>` | Warning / Error | `Invoke-MainProcessingLogic` | Detection retried up to `-MaxRetries` times with 2s, 4s, 6s... back-off; the object is then counted as an error and skipped |

Errors never abort the run; the next object is processed. `Processing errors: N` in the summary is
the count of exceptions caught in the per-object loop.

### 5. Resource Clean-up

Results are streamed to `OrphanedSid-<CorrelationId>\batch_<n>.json` under
`[IO.Path]::GetTempPath()` by
`StreamingResultsManager` (`BatchSize` results per file, default 50) and the folder is removed when
`Stop-OrphanedSidSession` disposes it in the command's `finally` block. Pass `-PreserveTempFiles` to
keep the folder for inspection; the log then shows `Temporary result files preserved in: <folder>`.
Every 100 objects `Invoke-MainProcessingLogic` calls `Invoke-Cleanup` and writes the freed memory
to the Verbose stream
(`Memory usage at N objects: X MB (Freed: Y MB)`).

```powershell
Find-OrphanedSid -SearchBase 'OU=Test,DC=contoso,DC=com' -PreserveTempFiles -CorrelationId ($id = [guid]::NewGuid().ToString())
Get-ChildItem -Path (Join-Path ([IO.Path]::GetTempPath()) "OrphanedSid-$id")
```

If a run was killed before `finally` ran, delete leftover `OrphanedSid-*` folders under
`[IO.Path]::GetTempPath()` by hand. See
`.\Troubleshooting\Performance\Memory-Management-Issues.md` for the memory manager and `.\Troubleshooting\Performance\Memory-WhatIf-Behavior.md` for `-WhatIf` runs.

### 6. SID Lookup Cache

`Test-OrphanedSID` caches each `Orphaned` or `Exists` verdict in `$script:SIDValidationCache` for
the session; `Unverified` is never cached. `Get-SIDValidationCacheStat` returns `TotalEntries`,
`OrphanedSIDs`, `ValidSIDs`, `CacheHitRatio` (cache hits / lookups * 100) and `LastUpdated`;
`Clear-SIDValidationCache` empties the cache and resets the counters. Both live in
`Private\SID\Test-OrphanedSID.ps1` and are reached through `& (Get-Module OrphanedSid) { ... }`.
In a long session, clear the cache after a principal is restored or created, otherwise its cached
`Orphaned` verdict persists.

## Running the Workflow by Hand

```powershell
Import-Module ActiveDirectory
Import-Module OrphanedSid
# Private functions are reached through the module scope: & (Get-Module OrphanedSid) { <command> }

$object = Get-ADObject -Identity 'CN=User1,OU=Test,DC=contoso,DC=com' -Properties nTSecurityDescriptor, ObjectClass
& (Get-Module OrphanedSid) {
    param($ADObject)
    $rules   = Get-ObjectAccessRule -ADObject $ADObject -IncludeInherited
    "Access rules: $(@($rules).Count)"
    $results = @(Find-OrphanedSIDsInObject -ADObject $ADObject -IncludeInherited)
    "Orphaned SIDs: $($results.Count)"
    $results | Select-Object ObjectDN, OrphanedSID, LikelySource, Confidence, VerificationStatus, IsInherited
    # One statistics table per object, shared by all of that object's results
    $results | Select-Object -First 1 -ExpandProperty ProcessingStatistics
    Get-SIDValidationCacheStat
} $object
```

## Related Documentation

- `.\Troubleshooting\Common\Security-Descriptor-Warnings.md`
- `.\Troubleshooting\Common\Result-Creation-Issues.md`
- `.\Troubleshooting\Security\Security-Descriptor-Issues.md`
- `.\Troubleshooting\Security\Identity-Resolution-Issues.md`
- `.\Troubleshooting\Security\Orphaned-SID-Issues.md`
- `.\Troubleshooting\Performance\Memory-Management-Issues.md`

## Support Information

- **Module**: `Private\SID\Invoke-SIDProcessing.ps1`
- **Functions**: `Find-OrphanedSIDsInObject`
- **Correlation ID**: include the run's `-CorrelationId` in support requests
