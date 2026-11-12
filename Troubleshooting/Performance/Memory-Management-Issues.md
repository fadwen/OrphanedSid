# Memory Management Issues - Troubleshooting Guide

## Overview

This guide covers memory problems that can appear during large discovery or removal runs of
`Find-OrphanedSid`: memory that keeps growing, warnings that the configured threshold has been
exceeded, and out-of-memory failures. It describes the memory controls the module actually has and
how to read their output. The architecture itself is described in
[Memory-Management.md](./Memory-Management.md); the levers you can tune are in
[Performance-Tuning.md](./Performance-Tuning.md).

## What the module does with memory

| Component | File | Behaviour |
|---|---|---|
| `MemoryManager` class | `Classes\MemoryManager.ps1` | Counts operations; every `CheckInterval` operations it reads the process working set, tracks the peak, and if the value exceeds `MaxMemoryMB` runs `GC.Collect()` twice around `WaitForPendingFinalizers()`, adds and removes 50 MB of GC pressure, and re-measures. It never throws; it warns. |
| `Invoke-MemoryCheck` | `Private\System\Invoke-MemoryMonitoring.ps1` | Called once per AD object by `Invoke-MainProcessingLogic` with `-WhatIf:$false`; drives `MemoryManager.CheckMemoryUsage()` and returns a status object rating the process working set, the measure `CheckMemoryUsage()` compares, against the threshold: `Normal` up to 75 %, `High` to 90 %, `Critical` above. The managed heap (`GC.GetTotalMemory`) is reported beside it as `ManagedHeapMB`. The caller discards the object; the threshold warning a run logs comes from `CheckMemoryUsage()`. |
| `Invoke-Cleanup` | `Private\System\Invoke-GarbageCollection.ps1` | Called every 100 processed objects, with `-WhatIf:$false`. Adds 50 MB of GC pressure, runs three collect/finalize cycles 100 ms apart, removes the pressure, and returns `MemoryBeforeMB`, `MemoryAfterMB`, `MemoryFreedMB`. `-IncludeLOHCompaction` sets `GCLargeObjectHeapCompactionMode.CompactOnce` for that cleanup. |
| `StreamingResultsManager` | `Classes\StreamingResultsManager.ps1` | Holds at most `BatchSize` results (default 50) in memory before flushing them to a JSON batch file and calling `GC.Collect()`. |
| `Invoke-ResourceCleanup` | `Private\System\Invoke-ResourceDisposal.ps1` | Runs from `Stop-OrphanedSidSession` in each command's `finally` block, with `-WhatIf:$false`; disposes the streaming manager and the memory manager, then performs a final collection. |

The threshold is `-MaxMemoryUsageMB` (100-16384, default 1024). The check interval is the
`MemoryCheckInterval` key of a `-ConfigPath` JSON file (1-1000, default 50).

## Common Issues

### 1. "Memory usage threshold exceeded" warnings

**Symptoms**

Warnings of this form on the console (they are not written to the log file):

```text
Memory usage threshold exceeded: 1310.52 MB (Limit: 1024 MB) - CorrelationId: <guid>
Memory after garbage collection: 1288.1 MB (reduced by 22.42 MB) - CorrelationId: <guid>
Memory usage still exceeds limit after garbage collection: 1288.1 MB. Consider reducing batch size or increasing memory limit. - CorrelationId: <guid>
```

The second line is verbose output and appears only with `-Verbose`.

**What it means**

The working set of the PowerShell process is above `-MaxMemoryUsageMB`. The command keeps running;
the warning is advisory. Working set includes the .NET runtime, the ActiveDirectory module and any
other modules loaded in the session, so a 1024 MB limit is easy to exceed in a large session even
when the command itself is behaving.

**Resolution**

1. Measure the baseline before the run so the threshold is set relative to it:

   ```powershell
   $baselineMB = [Math]::Round((Get-Process -Id $PID).WorkingSet64 / 1MB, 0)
   "Baseline working set: $baselineMB MB"
   ```

2. Raise the threshold to something the host can afford. The parameter accepts up to 16384:

   ```powershell
   Find-OrphanedSid -SearchBase "DC=contoso,DC=com" -MaxMemoryUsageMB 4096
   ```

3. If the warning recurs after garbage collection, check more often so cleanup starts earlier. The
   interval is a configuration key, not a parameter:

   ```powershell
   @{ MemoryCheckInterval = 10 } | ConvertTo-Json | Set-Content .\config.json
   Find-OrphanedSid -SearchBase "DC=contoso,DC=com" -ConfigPath .\config.json
   ```

4. Reduce the scope of a single run by passing smaller search bases (see
   [Performance-Tuning.md](./Performance-Tuning.md#splitting-the-search-base)).

### 2. Memory grows steadily across a long run

**Symptoms**

- Working set climbs through the run and does not fall back after the per-100-object cleanup.
- `Peak memory usage` in the processing summary is far above the baseline.

**Where to look**

- The SID validation cache (`$script:SIDValidationCache` in `Private\SID\Test-OrphanedSID.ps1`)
  holds one small lookup result per distinct SID found orphaned or existing. It grows with the
  number of distinct SIDs, not with the number of objects, and lasts for the PowerShell session
  until the module is removed or re-imported. It is rarely the cause.
- Results are not held in memory during processing. Each `OrphanedSIDResult` is handed to
  `StreamingResultsManager.AddResult()` and flushed to disk after `BatchSize` results (default 50).
  At the end of the run `Find-OrphanedSid` reads every batch back once with `GetAllResults()` to
  emit the results, and the `-OutputPath` export reuses what that read returned.
- Access rules returned by `Get-ObjectAccessRule` are released after each object
  (`$accessRules = $null` in `Private\SID\Invoke-SIDProcessing.ps1`), and a collection runs after
  an object whose inspected access rules number a multiple of 100.

**Resolution**

Run with `-Verbose` and compare the `Memory usage at N objects: X MB (Freed: Y MB)` lines that
`Invoke-MainProcessingLogic` writes after every 100 objects. If `Freed` is consistently near zero
while `X` keeps rising, the growth is not reclaimable by collection; split the run across smaller
search bases so each process stays short-lived.

### 3. OutOfMemoryException

**Symptoms**

The run terminates with `OutOfMemoryException`, typically while reading a very large ACL or while
`GetAllResults()` reads the batch files back at the end of the run.

**Root causes**

- A 32-bit PowerShell host (2 GB address space). Check with `[IntPtr]::Size -eq 4`.
- System-wide memory pressure from other processes.
- A very large result set: at the end of the run every result is read back into memory, to be
  written to the pipeline and to `Export-Csv`, and held until the session ends.

**Resolution**

1. Run under 64-bit PowerShell.
2. Check free system memory before the run:

   ```powershell
   $os = Get-CimInstance Win32_OperatingSystem
   "Free: {0:N0} MB of {1:N0} MB" -f ($os.FreePhysicalMemory / 1KB), ($os.TotalVisibleMemorySize / 1KB)
   ```

3. For very large result sets, run one search base per invocation with its own `-OutputPath` so
   each export is bounded.
4. Keep the batch files for inspection with `-PreserveTempFiles`; they are JSON (an array, or a
   single object for a batch of one) under
   `$env:TEMP\OrphanedSid-<CorrelationId>\batch_N.json` and can be read with
   `Get-Content -Raw | ConvertFrom-Json` without running the export.

## Validation Commands

The memory helpers are private functions of the module, so each snippet runs inside the module
scope. Dot-sourcing the script block (`. (Get-Module OrphanedSid) { ... }`) keeps variables such as
`$manager` between snippets.

```powershell
Import-Module OrphanedSid
. (Get-Module OrphanedSid) { Initialize-LoggingSystem -LogLevel Information }
```

### Check current usage against a threshold

```powershell
. (Get-Module OrphanedSid) {
    Get-CurrentMemoryUsage                  # WorkingSetMB, PrivateMemoryMB, GC generation counts
    Test-MemoryThreshold -ThresholdMB 1024  # ThresholdExceeded, UtilizationPercent, RecommendedAction
}
```

### Exercise the memory manager

```powershell
. (Get-Module OrphanedSid) {
    $manager = Initialize-MemoryManager -MaxMemoryMB 1024 -CheckInterval 5
    1..5 | ForEach-Object { Invoke-MemoryCheck -MemoryManager $manager | Out-Null }   # 5th call checks
    Get-MemoryUsageReport -MemoryManager $manager -IncludeRecommendations
}
```

`PerformanceStatus` in the report is `Excellent` below 80 % of the threshold, `Good` below 90 %,
`Acceptable` below 100 % and `Concerning` at or above it.

### Measure what a cleanup recovers

```powershell
. (Get-Module OrphanedSid) {
    $result = Invoke-Cleanup -CorrelationId ([guid]::NewGuid().ToString()) -IncludeLOHCompaction
    "Before: $($result.MemoryBeforeMB) MB  After: $($result.MemoryAfterMB) MB  Freed: $($result.MemoryFreedMB) MB"
}
```

A `MemoryFreedMB` of zero on an idle session is normal; the figure is meaningful only after a run
has allocated something.

### Dispose cleanly

```powershell
. (Get-Module OrphanedSid) {
    Invoke-ResourceCleanup -MemoryManager $manager
    $manager.Disposed   # True
}
```

## Related Documentation

- [Memory Management](./Memory-Management.md)
- [Memory WhatIf Behavior](./Memory-WhatIf-Behavior.md)
- [Performance Tuning](./Performance-Tuning.md)
- [SID Processing Orchestration Issues](../Common/SID-Processing-Orchestration-Issues.md)
- [Security Descriptor Issues](../Security/Security-Descriptor-Issues.md)
