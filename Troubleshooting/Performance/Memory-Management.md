# Memory Management Troubleshooting

## Overview

`Find-OrphanedSid` keeps memory flat on large Active Directory scans by streaming results to
disk in small batches and by monitoring the process working set against a configurable threshold.
This document describes those two mechanisms as implemented, the log messages they produce, and
how to diagnose them.

## Architecture Components

### 1. StreamingResultsManager

Defined in `Classes\StreamingResultsManager.ps1`, created once per run by
`Private\Core\Invoke-MainProcessingLogic.ps1`.

- **Purpose**: results are not accumulated in memory during processing. Each `OrphanedSIDResult`
  is passed to `AddResult()`; when `BatchSize` are held the batch is written to disk and the list
  is cleared. At the end `Find-OrphanedSid` reads them all back with `GetAllResults()` to emit them.
- **Batch size**: the `BatchSize` configuration key (1-1000, default 50), read from `-ConfigPath`
  and passed to the constructor by `Invoke-MainProcessingLogic`.
- **Storage**: `<TEMP>\OrphanedSid-<CorrelationId>\`, where `<TEMP>` is
  `[System.IO.Path]::GetTempPath()`. Batches are `batch_1.json`, `batch_2.json`, ... (compressed
  JSON, an array or a single object for a batch of one); a `summary_<yyyyMMdd_HHmmss>.json`
  records totals and the batch file list.
- **Garbage collection**: `GC.Collect()` after every flush.
- **Export**: `ExportToCsv($path)` takes the results from `GetAllResults()`, which reads only the
  batch files an earlier call has not, and calls `Export-Csv`. `Write-ProcessingSummary` calls it when `-OutputPath` is given.
- **Cleanup**: `Dispose()` flushes, updates the summary and removes the temp directory unless the
  `PreserveFiles` property is set. `Stop-OrphanedSidSession` sets that property when `-PreserveTempFiles` is
  passed, and logs `Temporary result files preserved in: <path>`.
- **WhatIf**: under `-WhatIf` no directory or files are created; flushes are simulated and logged
  as `WhatIf: Would flush batch N with M results to <file>`.

### 2. MemoryManager Class

Defined in `Classes\MemoryManager.ps1`, created by `Initialize-MemoryManager` during
`Initialize-ScriptExecution`.

- **Threshold**: `-MaxMemoryUsageMB` (100-16384, default 1024), compared against the process
  working set.
- **Check frequency**: every `MemoryCheckInterval` operations. The value comes from the
  configuration object (`Classes\ScriptConfiguration.ps1`), default 50, overridable through a
  `-ConfigPath` JSON file with a value from 1 to 1000.
- **On exceeding the threshold**: two `GC.Collect()` calls around `WaitForPendingFinalizers()`,
  `AddMemoryPressure(50MB)` followed immediately by `RemoveMemoryPressure(50MB)`, then a second
  measurement. If still above the limit a warning is written; processing continues.
- **Peak tracking**: `GetPeakMemoryUsage()` is reported as `Peak memory usage: N MB` in the
  processing summary.

### 3. Processing Loop

In `Invoke-MainProcessingLogic`:

- `Invoke-MemoryCheck -MemoryManager $script:MemoryManager` runs before every object.
- Every 100 objects, `Invoke-Cleanup` runs three collect/finalize cycles with 50 MB of GC pressure
  applied, and the result is written as a verbose line:
  `Memory usage at 100 objects: 412.3 MB (Freed: 18.6 MB)`.
- In `Private\SID\Invoke-SIDProcessing.ps1`, access-rule references are nulled after each object
  and a collection runs after an object whose inspected access rules number a multiple of 100.
- In each command's `finally` block, `Stop-OrphanedSidSession` calls `Invoke-ResourceCleanup`, which disposes the streaming manager and the
  memory manager and runs a final collection.

## Memory Usage Patterns

### Expected behaviour

Working set rises during module import and the first few hundred objects, then stays roughly flat.
`Get-MemoryUsageReport` (in `Private\System\Get-MemoryStatistics.ps1`) rates the current working
set against the threshold:

| PerformanceStatus | Working set |
|---|---|
| Excellent | below 80 % of `-MaxMemoryUsageMB` |
| Good | 80 % to 90 % |
| Acceptable | 90 % to 100 % |
| Concerning | at or above 100 % |

The default 1024 MB threshold leaves wide headroom: on a domain controller, a Windows PowerShell
5.1 session with the ActiveDirectory module and OrphanedSid loaded measured about 105 MB, and about
120 MB after a small discovery run.

## Common Memory Issues

### Issue: Threshold warnings during a large run

**Symptoms**: `Memory usage threshold exceeded: N MB (Limit: M MB)` warnings; processing continues.

**Resolution**: raise `-MaxMemoryUsageMB`, lower `MemoryCheckInterval` so cleanup starts earlier,
or split the run. Details in [Memory-Management-Issues.md](./Memory-Management-Issues.md).

### Issue: Memory not released after the run

**Symptoms**: the PowerShell process stays large after the command returns.

**Resolution**: `Invoke-ResourceCleanup` already runs a full collection at exit. Remaining working
set belongs to the session (loaded modules, the AD provider drive). Start large runs in a fresh
process:

```powershell
powershell.exe -NoProfile -Command "Find-OrphanedSid -SearchBase 'DC=contoso,DC=com' -MaxMemoryUsageMB 2048"
```

### Issue: Temporary file accumulation

**Symptoms**: `OrphanedSid-<guid>` folders left under the temp directory.

**Cause**: a run ended before `Dispose()` could execute (process killed, host crash), or runs were
made with `-PreserveTempFiles`.

**Resolution**:

```powershell
# List leftover streaming folders with their size
Get-ChildItem ([System.IO.Path]::GetTempPath()) -Filter 'OrphanedSid-*' -Directory | ForEach-Object {
    $sizeMB = (Get-ChildItem $_.FullName -Recurse -File | Measure-Object -Property Length -Sum).Sum / 1MB
    "{0}: {1:N2} MB" -f $_.Name, $sizeMB
}

# Remove them (drop -WhatIf to execute)
Get-ChildItem ([System.IO.Path]::GetTempPath()) -Filter 'OrphanedSid-*' -Directory |
    Remove-Item -Recurse -Force -WhatIf
```

The batch files contain object DNs and SIDs; treat them as sensitive and do not leave them on a
shared host.

## Monitoring and Diagnostics

### Memory monitoring during a run

```powershell
# From a second console while the command runs
Get-Process -Name powershell, pwsh -ErrorAction SilentlyContinue |
    Select-Object Id, ProcessName, @{ Name = 'WorkingSetMB'; Expression = { [Math]::Round($_.WorkingSet64 / 1MB, 1) } }
```

### Log messages to search for

Regular log entries are written as `[timestamp] [Level] [Component] [CorrelationId] Message`.
Memory events use the `MemoryManagement` component. Debug-level lines reach the file only with
`-LogLevel Debug` or `Verbose` (or `-Debug`/`-Verbose` when `-LogLevel` is not given).

```powershell
$log = Get-ChildItem .\Logs\Find-OrphanedSid_*.log | Sort-Object LastWriteTime | Select-Object -Last 1
Select-String -Path $log.FullName -Pattern 'MemoryManagement|Peak memory usage'
```

Messages written at Information level and above:

- `Initializing memory manager with threshold N MB`
- `Memory manager initialized successfully`
- `Starting memory cleanup operation...` and `Memory after cleanup: N MB (Freed: M MB)`
- `Memory manager disposed successfully`
- `Peak memory usage: N MB` (processing summary)

`Memory usage threshold exceeded: ...` (warning stream) and `Memory usage at N objects: ...`
(verbose stream) come from `Write-Warning` and `Write-Verbose`, so they reach the console, not the
log file.

### Streaming diagnostics

```powershell
# Keep the batch files and inspect them afterwards
Find-OrphanedSid -SearchBase "OU=Users,DC=contoso,DC=com" -PreserveTempFiles -CorrelationId 'mem-check-01'

$dir = Join-Path ([System.IO.Path]::GetTempPath()) 'OrphanedSid-mem-check-01'
Get-ChildItem $dir
(Get-Content (Join-Path $dir 'batch_1.json') -Raw | ConvertFrom-Json).Count   # 50 for a full batch
Get-Content (Get-ChildItem $dir -Filter 'summary_*.json').FullName -Raw | ConvertFrom-Json
```

## Configuration

```powershell
# Threshold is a parameter
Find-OrphanedSid -SearchBase "DC=contoso,DC=com" -MaxMemoryUsageMB 2048

# Check interval is a configuration key (1-1000)
@{ MemoryCheckInterval = 25 } | ConvertTo-Json | Set-Content .\config.json
Find-OrphanedSid -SearchBase "DC=contoso,DC=com" -ConfigPath .\config.json

# Keep streaming files for analysis
Find-OrphanedSid -SearchBase "DC=contoso,DC=com" -PreserveTempFiles
```

Suggested thresholds by object count; adjust to the host's free memory:

| Objects in scope | `-MaxMemoryUsageMB` |
|---|---|
| under 1,000 | 1024 |
| 1,000 to 10,000 | 2048 |
| 10,000 to 50,000 | 4096 |
| more than 50,000 | 8192, or split the search base |

## Implementation Details

### StreamingResultsManager key members

- `AddResult($result)`: adds to the current batch and flushes when `BatchSize` are held
- `FlushBatch()`: writes `batch_N.json`, clears the list, collects
- `GetSummary()`: returns totals and batch file list, updating the summary file
- `GetAllResults()`: flushes, reads the batch files no earlier call has read, and returns every result read so far
- `ExportToCsv($path)`: `GetAllResults()` piped to `Export-Csv`
- `Dispose()`: flush, summary update, `Cleanup()` unless `PreserveFiles`, final collection
- `Cleanup()`: removes the temp directory

### Integration points

- Results added via `$script:StreamingResults.AddResult()` in `Invoke-MainProcessingLogic`
- CSV export via `$ProcessingResults.StreamingManager.ExportToCsv($OutputPath)` in
  `Private\Reporting\Write-ProcessingSummary.ps1`
- Disposal via `Invoke-ResourceCleanup -AdditionalResources @($script:StreamingResults)` from
  `Stop-OrphanedSidSession`, in each command's `finally` block

## Related Documentation

- [Memory Management Issues](./Memory-Management-Issues.md)
- [Memory WhatIf Behavior](./Memory-WhatIf-Behavior.md)
- [Performance Tuning](./Performance-Tuning.md)
- [Security Validation Guide](../Security/Security-Validation-Guide.md)
- [Enterprise Integration Guide](../Integration/Enterprise-Integration-Guide.md)
- [Common Issues](../Common/Common-Issues.md)
