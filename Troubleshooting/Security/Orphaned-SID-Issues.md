# Orphaned SID Detection Troubleshooting Guide

## Overview

This guide covers `Private\SID\Test-OrphanedSID.ps1`, which decides whether a SID still exists in
Active Directory and caches the answer for the rest of the run.

`Test-OrphanedSID -SID <sid>` returns a `SIDLookupResult` with `SID`, `Status`, `IsOrphaned` and
`ErrorMessage`. `Status` is one of:

| Status | Meaning | Reported | Removed |
|---|---|---|---|
| `Exists` | A lookup found a live principal | No | No |
| `Orphaned` | Every lookup completed and none found the SID, or it was found only among deleted objects | Yes, `VerificationStatus = Orphaned` | Yes |
| `Unverified` | No lookup found the SID, but at least one failed for a reason other than "not found" | Yes, `VerificationStatus = Unverified` | Never |

It works through these steps and stops at the first that decides:

1. `Test-SIDFormat`; an invalid format is `Unverified`, because no lookup was made (Warning
   `SID format invalid - cannot be verified: <SID>`).
2. Cache lookup in `$script:SIDValidationCache` (Debug `SID validation cache hit for <SID>`).
3. `Get-ADObject -Filter "objectSid -eq '<SID>'"`; found means `Exists`.
4. The same query with `-IncludeDeletedObjects -Properties isDeleted`. That query returns live
   objects too, so a match with `isDeleted` true is a tombstone and means `Orphaned` (the account
   is gone and the ACE should be cleaned), even when step 3 failed; a live match means `Exists`.
5. `SecurityIdentifier.Translate([NTAccount])`; a resolved name that is not itself a SID means
   `Exists`.
6. `Get-ADUser`, `Get-ADGroup`, `Get-ADComputer` with `SID -eq '<SID>'`.
7. If any step from 3 to 6 threw anything other than a not-found error
   (`ADIdentityNotFoundException`, or `IdentityNotMappedException` for the translation), the SID is
   `Unverified` and `ErrorMessage` names each failed step (Warning
   `SID could not be verified - N lookup(s) failed: <SID> (<errors>)`).
8. Otherwise `Orphaned` (Debug `SID could not be resolved - marking as orphaned: <SID>`).

Directory calls go through `Invoke-ADOperationWithRetry`, so transient failures are retried before
a step is considered to have failed. An unexpected exception anywhere in the function also gives
`Unverified` (Error `Error testing SID for orphaned status <SID> : ...`). In 1.0.1 and earlier every
one of these failures reported the SID as orphaned, and `Remove-OrphanedSid` removed it.

Only `Exists` and `Orphaned` are cached. An `Unverified` result is not, so the next object that
carries the same SID performs the lookups again, and a transient failure does not decide the answer
for the rest of the run.

The functions and the cache are private; the samples below run them through the module scope
(`$osid = Get-Module OrphanedSid`), as shown in
[Identity-Resolution-Issues.md](./Identity-Resolution-Issues.md#loading-the-functions-in-a-session).

## Common Issues

### 1. False positives: valid SIDs marked as orphaned

**Symptoms**

- Existing accounts or groups appear in the results CSV.
- Recently created accounts are reported.
- Service accounts or accounts from a trusted domain are reported.

**Causes**

- Replication lag: the object exists on one domain controller but not on the one answering.
- The SID belongs to a trusted domain that answered "not found" for it; see
  [SIDs from a trusted domain](#6-sids-from-a-trusted-domain).
- A cached `Orphaned` result from an earlier lookup in the same session.

A lookup that fails with an unreachable server or a broken trust no longer causes this: the SID is
reported `Unverified` instead (see [Unverified SIDs](#5-unverified-sids)).

**Solutions**

```powershell
# Clear the cache and retry one SID
$testSID = "S-1-5-21-1234567890-1234567890-1234567890-1001"
& $osid { Clear-SIDValidationCache; Test-OrphanedSID -SID $testSID -Verbose }

# Test 1: direct AD lookup
try {
    $adObject = Get-ADObject -Filter "objectSid -eq '$testSID'" -ErrorAction Stop
    "Found AD object: $($adObject.DistinguishedName)"
} catch {
    "AD object not found: $($_.Exception.Message)"
}

# Test 2: SecurityIdentifier translation
try {
    $account = [System.Security.Principal.SecurityIdentifier]::new($testSID).Translate([System.Security.Principal.NTAccount])
    "Account name: $($account.Value)"
} catch {
    "Translation failed: $($_.Exception.Message)"
}

# Test 3: typed lookups
foreach ($cmdlet in 'Get-ADUser', 'Get-ADGroup', 'Get-ADComputer') {
    try {
        $result = & $cmdlet -Filter "SID -eq '$testSID'" -ErrorAction Stop
        if ($result) { "$cmdlet found: $($result.DistinguishedName)" }
    } catch {
        "$cmdlet failed: $($_.Exception.Message)"
    }
}
```

For a foreign SID, resolve it against its own domain:

```powershell
Get-ADObject -Server trusted.example.com -Filter "objectSid -eq '$testSID'"
```

**Prevention**

- Run as an account with read access to every object in scope.
- Check replication (`repadmin /replsummary`) before a large run.
- Always run `Remove-OrphanedSid -WhatIf` and review the results before the real run.

### 2. False negatives: orphaned SIDs marked as valid

**Symptoms**

- A SID known to be deleted is not reported.

**Causes**

- A cached `Exists` result from an earlier lookup in the same session (the cache does not expire).
- The SID resolves through a trust, so `Translate` succeeds although no local object exists.

Deleted objects are not a cause: an object found in the Deleted Objects container is treated as
orphaned.

**Solutions**

```powershell
& $osid { Clear-SIDValidationCache }

$testSID = "S-1-5-21-1234567890-1234567890-1234567890-1001"
try {
    # -IncludeDeletedObjects also returns live objects; isDeleted marks a tombstone
    Get-ADObject -Filter "objectSid -eq '$testSID'" -IncludeDeletedObjects -Properties isDeleted -ErrorAction Stop |
        ForEach-Object { if ($_.isDeleted) { "In deleted objects: $($_.DistinguishedName)" } else { "Live: $($_.DistinguishedName)" } }
} catch {
    "Not in deleted objects: $($_.Exception.Message)"
}

# Which method is accepting the SID?
try {
    [System.Security.Principal.SecurityIdentifier]::new($testSID).Translate([System.Security.Principal.NTAccount]).Value
} catch {
    "Translate failed: $($_.Exception.Message)"
}
```

Disabled accounts are not orphaned; only SIDs with no object are reported.

### 3. Performance problems

**Symptoms**

- Slow progress once discovery has finished.
- Many `Retry attempt` warnings.

**Causes**

- Each distinct SID costs up to six directory operations when it is orphaned.
- Domain controller latency or load.
- Retries after transient errors (see `-MaxRetries` in
  [Performance-Tuning.md](../Performance/Performance-Tuning.md)).

**Solutions**

```powershell
# Cache effectiveness for the current session
$stats = & $osid { Get-SIDValidationCacheStat }
"Entries: $($stats.TotalEntries)  Orphaned: $($stats.OrphanedSIDs)  Valid: $($stats.ValidSIDs)  Hit ratio: $($stats.CacheHitRatio)%"

# Time cached versus uncached lookups
$testSIDs = 1000..1099 | ForEach-Object { "S-1-5-21-1234567890-1234567890-1234567890-$_" }
& $osid { Clear-SIDValidationCache }
(Measure-Command { & $osid { $testSIDs | Test-OrphanedSID } }).TotalSeconds   # uncached
(Measure-Command { & $osid { $testSIDs | Test-OrphanedSID } }).TotalSeconds   # cached
```

`CacheHitRatio` is cache hits divided by lookups, as a percentage, since the cache was last
cleared. During a real run the ratio rises with the number of objects that share principals; a
ratio near zero on a large OU means almost every ACE names a different SID and the run is bound by
directory latency.

### 4. Active Directory connection problems

**Symptoms**

- `Unable to contact the server` or authentication errors.
- Every SID reported with `VerificationStatus = Unverified`.

**Solutions**

```powershell
try {
    $domain = Get-ADDomain -Current LocalComputer
    "Connected to $($domain.DNSRoot); PDC: $($domain.PDCEmulator)"
} catch {
    "AD connection failed: $($_.Exception.Message)"
}

$dc = (Get-ADDomain).PDCEmulator
Test-NetConnection -ComputerName $dc -Port 389    # LDAP
Test-NetConnection -ComputerName $dc -Port 636    # LDAPS
Test-NetConnection -ComputerName $dc -Port 3268   # Global Catalog
```

A run that cannot reach the directory removes nothing: every SID it cannot check is `Unverified`.
It also finds nothing useful, so fix connectivity before running it.

### 5. Unverified SIDs

**Symptoms**

- Results with `VerificationStatus = Unverified`, `Confidence = Low` and a `VerificationError`.
- The summary line `Unverified SIDs (lookup failed, not removed): N`, with a warning when N is above
  zero.
- During `Remove-OrphanedSid`, a warning
  `Not removing unverified SID <SID> from <DN>: a directory lookup failed, so it may belong to a live principal (<errors>)`.

**Causes**

`VerificationError` names each lookup that failed and its error, for example
`Get-ADObject: Unable to contact the server` or `Get-ADUser: Access is denied`:

- The domain controller was unreachable, busy, or timed out after the retries.
- The SID belongs to a trusted domain whose domain controllers cannot be reached, or the trust is
  broken (`The trust relationship between the primary domain and the trusted domain failed`).
- A directory call failed with an error such as access denied. Lack of read permission alone
  usually does not do this; see [Running without read access](#7-running-without-read-access).

**Solutions**

```powershell
# List what could not be checked, and why
$results = Find-OrphanedSid -SearchBase 'OU=Servers,DC=contoso,DC=com'
$results | Where-Object VerificationStatus -eq 'Unverified' |
    Select-Object ObjectDN, OrphanedSID, VerificationError

# Keep only confirmed orphans for review
$results | Where-Object VerificationStatus -eq 'Orphaned'
```

Fix the cause the error names, then run the command again. Unverified results are never cached, so
the new run looks every such SID up afresh.

**When the domain controller is down.** A directory lookup against a server that does not answer
waits for the AD Web Services connect timeout, about 42 seconds, and fails with `Unable to contact
the server`. After the first such failure for a SID, its remaining directory lookups are not tried,
because they would wait and fail the same way. `VerificationError` then ends with `Not attempted
because the directory server could not be contacted: <lookups>`. The local name lookup still runs.
Each SID that needs the directory still costs one timeout, so a run against an unreachable domain
controller slows by about 42 seconds per distinct SID. Every object that carries the same SID pays
it again, because unverified answers are not cached. Check the domain controller before re-running:

```powershell
Get-ADDomainController -Discover -Service ADWS   # which DC the AD cmdlets will use
Test-NetConnection <dc> -Port 9389               # AD Web Services
```

### 6. SIDs from a trusted domain

The local `Get-ADObject` and typed lookups search the local domain only. They find a SID from
another domain only when it has a foreign security principal object here, which Active Directory
creates when that principal is made a member of a local group; the SID is then reported as existing,
even after its own domain has deleted it. Otherwise the answer comes from
`SecurityIdentifier.Translate`, which Windows routes through the trust to the domain that issued the
SID. What is reported depends on what that domain says:

| Trusted domain | Reported as | `VerificationError` / `LikelySource` |
|---|---|---|
| Reachable, principal exists | Not reported | |
| Reachable, principal deleted | `Orphaned` | `LikelySource = Foreign Domain/Trust` |
| Domain controllers unreachable, trust broken or timing out | `Unverified` | `SecurityIdentifier.Translate: ... The trust relationship between the primary domain and the trusted domain failed.` |

Only the domain that issued a SID can say whether it still exists. When that domain answers "not
found", the SID is reported orphaned. When it cannot be reached, nothing is decided and the SID is
left in place.

An unreachable-trust lookup can wait for the trust to time out, about 40 seconds per distinct SID
in testing. Once Windows has marked the trust broken (`nltest` below reports
`ERROR_NO_LOGON_SERVERS`), each lookup fails in a few seconds instead; 4 seconds in testing. An
unverified answer is not cached, so every ACE that names such a SID pays the cost again.
A run that slows down sharply on objects with foreign entries is usually waiting on a trust:

```powershell
nltest /sc_verify:<trusted domain DNS name>   # NERR_Success means the secure channel works
```

Review `Foreign Domain/Trust` rows before a removal: they are the entries whose owner lives outside
the domain you are cleaning, and someone in that domain may want to know before the access goes.

### 7. Running without read access

An account that is not allowed to read a principal does not get an error from Active Directory. The
search returns nothing, exactly as it would for a SID that does not exist, so missing read
permission on its own does not make a SID `Unverified`. The name translation step still resolves a
live principal in that case, because Windows performs it with the domain controller's own access
and not the caller's, so the principal is not reported. Run discovery and removal as an account that
can read every object in scope all the same: it is the only setup in which every lookup step
answers for itself.

## Cache Management

The cache is `$script:SIDValidationCache`, a hashtable of SID to `SIDLookupResult`. Only `Exists`
and `Orphaned` results are stored. It lives for the PowerShell session or process, grows by one
entry per distinct SID resolved, and is cleared only by `Clear-SIDValidationCache`, which also
resets the hit and lookup counters.

```powershell
& $osid {
    $stats = Get-SIDValidationCacheStat
    if ($stats.TotalEntries -gt 10000) {
        Clear-SIDValidationCache
    }

    # Direct inspection
    $script:SIDValidationCache.Count
    @($script:SIDValidationCache.Values | Where-Object Status -eq 'Orphaned').Count   # orphaned
    @($script:SIDValidationCache.Values | Where-Object Status -eq 'Exists').Count     # valid
}
```

Entries have no timestamp; clear the cache if the directory changed during a long interactive
session. The cache lives in the module's scope, so it lasts as long as the module stays imported;
`Import-Module OrphanedSid -Force` or a new process starts with an empty one.

## Error Messages

| Message | Level | Meaning |
|---|---|---|
| `SID format invalid - cannot be verified: <SID>` | Warning | Failed `Test-SIDFormat`; `Unverified` |
| `SID validation cache hit for <SID>` | Debug | Answer returned from cache |
| `SID found in AD via Get-ADObject: <DN>` | Debug | `Exists` |
| `SID found in deleted objects: <DN> - treating as orphaned` | Debug | Tombstoned object; `Orphaned` |
| `SID could not be translated - likely orphaned: <SID>` | Debug | Translation reported not-found; later steps still run |
| `Get-ADObject lookup failed for SID <SID> : <error>`, `Deleted objects lookup failed for SID <SID> : <error>`, `SecurityIdentifier translation failed for <SID> : <error>`, `<cmdlet> lookup failed for <SID> : <error>` | Warning | A step threw something other than not-found; later steps still run |
| `SID could not be verified - N lookup(s) failed: <SID> (<errors>)` | Warning | Nothing found the SID and a step failed; `Unverified` |
| `SID could not be resolved - marking as orphaned: <SID>` | Debug | Every step completed and none found it; `Orphaned` |
| `Error testing SID for orphaned status <SID> : <error>` | Error | Unexpected exception; `Unverified` |
| `UNVERIFIED SID: <SID> on <DN> could not be checked - <errors>` | Warning | Discovery listed the entry as unverified |
| `Not removing unverified SID <SID> from <DN>: ...` | Warning | `Remove-OrphanedSid` skipped it |
| `Cleared SID validation cache (N entries)` | Information | `Clear-SIDValidationCache` ran |

Debug lines appear in the log file only with `-LogLevel Debug` or `Verbose`.

## Diagnostics

```powershell
# Trace one SID with its own correlation ID
$correlationId = [guid]::NewGuid().ToString()
& $osid { Test-OrphanedSID -SID "S-1-5-21-1234567890-1234567890-1234567890-1001" -CorrelationId $correlationId -Verbose }

# Then search the log for that ID
$log = Get-ChildItem .\Logs\<Command>_*.log | Sort-Object LastWriteTime | Select-Object -Last 1
Select-String -Path $log.FullName -Pattern $correlationId
```

## Best Practices

- Review `-WhatIf` output before any `Remove-OrphanedSid` run. Check the `VerificationStatus` column
  of the CSV: `Unverified` rows are SIDs a failed lookup could not check, and are not removed.
- Run from a host close to a domain controller; per-SID latency dominates run time.
- In an interactive session, clear the cache between runs against different domains.
- Use correlation IDs to tie a reported SID back to the exact lookup sequence in the log.

## Related Documentation

- [Identity Resolution Issues](./Identity-Resolution-Issues.md)
- [SID Format Issues](./SID-Format-Issues.md)
- [SID Analysis Issues](./SID-Analysis-Issues.md)
- [Performance Tuning](../Performance/Performance-Tuning.md)
- [Common Issues](../Common/Common-Issues.md)
