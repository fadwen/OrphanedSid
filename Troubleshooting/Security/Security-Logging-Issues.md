# Security Logging Troubleshooting Guide

## Overview

`Find-OrphanedSid` writes two kinds of entries to the same log file
(`.\Logs\<Command>_<yyyyMMdd_HHmmss>.log` by default, or `-LogPath`):

| Kind | Written by | File format | Filtered by `-LogLevel`? |
|---|---|---|---|
| Regular | `Write-StructuredLog` -> `Write-StructuredLogEntry` | `[timestamp] [Level] [Component] [CorrelationId] Message` | Yes (file only; console is not filtered) |
| Security audit | `Write-SecurityLog`, `Write-ADOperationSecurityLog`, `Write-RemovalSecurityLog` -> `Write-SecurityStructuredLogEntry` | One compressed JSON object per line, `Component` is `SecurityAudit` | No; always written |

A security entry looks like:

```json
{"Level":"Information","ProcessId":4321,"Outcome":"Success","SecurityEventType":"ObjectAccess","UserContext":"user@HOST","Message":"Successfully completed Active Directory operation: AD-ObjectDiscovery","Component":"SecurityAudit","CorrelationId":"<guid>","Security_OperationName":"AD-ObjectDiscovery","Security_SearchBase":"OU=Users,DC=contoso,DC=com","Timestamp":"2025-07-02T14:30:52.1181234+02:00", ...}
```

Property order varies. `Message` is the event text alone; `SecurityEventType` and `Outcome` are
separate properties. `Outcome` `Attempt` and `Success` are written at `Information`, `Failure` at
`Warning`. On the console only `Warning`, `Error` and
`Critical` security entries appear, prefixed `[SECURITY]`; `Information` security entries go to the
file only.

The logging functions live in `Private\Logging\`, the first folder `OrphanedSid.psm1` loads after
`Classes\`. They are private: the samples below run them through the module scope.

## Reading Security Entries

Because security entries are JSON lines, filter them by parsing rather than by bracket matching:

```powershell
function Get-SecurityLogEntry {
    param([Parameter(Mandatory)][string]$LogPath)
    Get-Content -Path $LogPath |
        Where-Object { $_.StartsWith('{') } |
        ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } |
        Where-Object { $_.Component -eq 'SecurityAudit' }
}

$log = Get-ChildItem .\Logs\<Command>_*.log | Sort-Object LastWriteTime | Select-Object -Last 1
$security = Get-SecurityLogEntry -LogPath $log.FullName
$security | Group-Object SecurityEventType, Outcome | Select-Object Name, Count
$security | Where-Object Outcome -eq 'Failure' | Select-Object Timestamp, Message
```

Regular entries are the lines that do not start with `{`:

```powershell
$regular = Get-Content $log.FullName | Where-Object { -not $_.StartsWith('{') }
$regular | Where-Object { $_ -match '^\[[^\]]+\] \[Information\]' } | Measure-Object
```

## Common Issues

### Issue 1: Security entries missing from the file

**Symptoms**

- `[SECURITY]` warnings on the console but no JSON lines in the log file.
- Warnings `Security log written to emergency file: ...` or
  `Security log written to emergency location: ...`.

**Diagnosis**

```powershell
# In a session where OrphanedSid is imported
$osid = Get-Module OrphanedSid
& $osid { Get-Command Write-SecurityStructuredLogEntry -ErrorAction SilentlyContinue }

$state = & $osid { Get-LoggingSystemState }
"Log path: $($state.LogPath)"
"Initialized: $($state.LogFileInitialized)"
```

`Write-SecurityFileEntry` writes to `$state.LogPath` only when `LogFileInitialized` is true;
otherwise it falls back to `Write-SecurityFileEntryDirect`.

**Solutions**

1. Load the logging system from its real location when working interactively:

   ```powershell
   Import-Module OrphanedSid
   & (Get-Module OrphanedSid) {
       Initialize-LoggingSystem -CorrelationId ([guid]::NewGuid().ToString()) -LogLevel Information
       # A relative path resolves against the current directory
       $null = Initialize-LogDirectory -LogPath 'Logs\manual-test.log'
   }
   ```

2. Check that the log directory is writable:

   ```powershell
   $logDir = Split-Path $state.LogPath -Parent
   Test-Path $logDir -PathType Container
   [IO.File]::OpenWrite((Join-Path $logDir 'write-test.tmp')).Dispose(); Remove-Item (Join-Path $logDir 'write-test.tmp')
   ```

3. Look for emergency files; see Issue 4.

### Issue 2: Security entries thought to be filtered by -LogLevel

**Symptoms**

- A run with `-LogLevel Warning` or `Error` shows no `Information` security entries.

**Root cause**

Normally this is a reading problem, not a filtering one: `Information` security entries are in the
file as JSON lines and are invisible to a search for `[Information]`. Use the parsing approach
above. Only entries routed through `Write-StructuredLogEntry` are filtered, so a component that
logs security-relevant text with `Write-StructuredLog` instead of a security function will be
filtered.

**Verification**

```powershell
Import-Module OrphanedSid
$logPath = & (Get-Module OrphanedSid) {
    Initialize-LoggingSystem -CorrelationId ([guid]::NewGuid().ToString()) -LogLevel Error
    $null = Initialize-LogDirectory -LogPath (Join-Path $PWD 'Logs\filter-test.log')

    Write-SecurityLog -SecurityEventType 'ObjectAccess' -Message 'Compliance test entry' -Outcome 'Success'
    Write-StructuredLogEntry -Message 'Regular test entry' -Level Information -Component 'Test'

    (Get-LoggingSystemState).LogPath
}
$lines = Get-Content $logPath
"Security entries (expect 1): " + @($lines | Where-Object { $_.StartsWith('{') -and $_ -match '"Component":"SecurityAudit"' }).Count
"Regular Information entries (expect 0): " + @($lines | Where-Object { $_ -match '\[Information\] \[Test\]' }).Count
```

### Issue 3: Security logging overhead

**Symptoms**

- Slower runs when many objects contain orphaned SIDs.

**Diagnosis**

```powershell
$metrics = & (Get-Module OrphanedSid) { $script:SecurityLoggingMetrics }
"Total security entries: $($metrics.TotalSecurityEntries)"
"By level: $($metrics.SecurityEntriesByLevel | ConvertTo-Json -Compress)"
"Last entry: $($metrics.LastSecurityLogTime)"
```

**What is logged**

`Invoke-MainProcessingLogic` writes an `AD-ObjectDiscovery` attempt/success pair per search base,
an `OrphanedSID-Detection` entry per object with findings, and an `OrphanedSID-Removal`
attempt/success (or failure) pair per object changed. The second entry of the pair carries
`ActualRemovals`, `FailedRemovals`, `BackupCreated` and `BackupFile`, the backup written before the
change; it is a failure, with `ErrorMessage`, when the removal did not succeed. `Invoke-ADOperationWithRetry` writes an
`ObjectAccess` attempt and success (or failure) for every directory call it makes, which includes
each lookup `Test-OrphanedSID` performs for a SID not yet in the cache. During removal
`Test-SIDSecurity` writes `DataValidation` entries for each SID it validates. The volume therefore
grows with the number of distinct SIDs looked up, not only with findings. The entries cannot be
suppressed; they are the audit trail.

### Issue 4: Emergency security logs in the temp directory

**Symptoms**

- Files matching `$env:TEMP\OrphanedSid-Security-*.log`:
  - `OrphanedSid-Security-Emergency.log`: written when formatting or the direct write threw.
  - `OrphanedSid-Security-<yyyyMMdd>.log`: written when the main log path was unavailable.
  - `OrphanedSid-Security-Fallback.log`: written by `Write-SecurityLog` when
    `Write-SecurityStructuredLogEntry` itself failed.

**Root cause**

The main log file could not be written: directory missing, permissions, disk full, or the logging
system not initialised when the security function ran.

**Diagnosis**

```powershell
$state = & (Get-Module OrphanedSid) { Get-LoggingSystemState }
"Main log path: $($state.LogPath)"
"File exists: $(Test-Path $state.LogPath)"
Get-ChildItem "$env:TEMP\OrphanedSid-Security-*.log" -ErrorAction SilentlyContinue | Select-Object Name, Length, LastWriteTime
```

**Solutions**

```powershell
# Recreate the log directory
$logDir = Split-Path $state.LogPath -Parent
if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }

# Merge emergency entries into the main log and remove them
Get-ChildItem "$env:TEMP\OrphanedSid-Security-*.log" -ErrorAction SilentlyContinue | ForEach-Object {
    Add-Content -Path $state.LogPath -Value (Get-Content $_.FullName) -Encoding UTF8
    Remove-Item $_.FullName
}
```

Entries in `OrphanedSid-Security-Emergency.log`
(`<timestamp> [SECURITY-EMERGENCY] [<Level>] <message> (CorrelationId: <id>)`) and
`OrphanedSid-Security-Fallback.log` (`<timestamp> [SecurityAudit] [<Level>] <message> ...`) are
plain text, so after merging they will not parse as JSON; the dated file usually holds the normal
JSON lines.

### Issue 5: Entries without a correlation ID or context

**Symptoms**

- Security entries whose `CorrelationId` differs from the run's.

**Root cause**

`Write-SecurityLog` generates a new GUID when none is passed. Every call site in the module passes
the run's ID, so a mismatch indicates a manual call or a helper invoked outside a command.

**Solution**

Always pass the ID and a context hashtable:

```powershell
$correlationId = [guid]::NewGuid().ToString()
& (Get-Module OrphanedSid) {
    Write-SecurityLog -SecurityEventType 'ObjectAccess' -Message 'Manual check' -Outcome 'Success' -CorrelationId $correlationId -SecurityContext @{
        OperationType = 'ManualReview'
        SearchBase    = 'OU=Users,DC=contoso,DC=com'
    }
}
```

Context keys are stored in the JSON object prefixed `Security_`.

## Validation Procedures

### Confirm security entries survive a restrictive log level

```powershell
Find-OrphanedSid -SearchBase "OU=Users,DC=contoso,DC=com" -LogLevel Error

$log = Get-ChildItem .\Logs\<Command>_*.log | Sort-Object LastWriteTime | Select-Object -Last 1
$security = Get-Content $log.FullName | Where-Object { $_.StartsWith('{') -and $_ -match '"Component":"SecurityAudit"' }
if ($security.Count -gt 0) {
    "Security logging verified: $($security.Count) entries"
} else {
    Write-Warning "No security entries found in $($log.FullName)"
}
```

### Monitor for emergency logging

```powershell
function Test-EmergencySecurityLogs {
    $files = Get-ChildItem "$env:TEMP\OrphanedSid-Security-*.log" -ErrorAction SilentlyContinue
    if ($files) {
        Write-Warning "Emergency security logs present - the main log was unavailable at some point"
        $files | Select-Object FullName, Length, LastWriteTime
        return $false
    }
    return $true
}
```

### Check recent security activity in a log

```powershell
function Test-SecurityLoggingHealth {
    param([Parameter(Mandatory)][string]$LogPath, [int]$WithinMinutes = 60)
    $since = (Get-Date).AddMinutes(-$WithinMinutes)
    $recent = Get-SecurityLogEntry -LogPath $LogPath | Where-Object { [datetime]$_.Timestamp -gt $since }
    if (-not $recent) {
        Write-Warning "No security entries in the last $WithinMinutes minutes"
        return $false
    }
    return $true
}
```

## Related Documentation

- [Security Validation Guide](./Security-Validation-Guide.md)
- [Common Issues](../Common/Common-Issues.md)
- [Enterprise Integration Guide](../Integration/Enterprise-Integration-Guide.md)
