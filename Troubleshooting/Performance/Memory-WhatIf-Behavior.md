# Memory Management WhatIf Behavior

## Overview

`-WhatIf` previews the changes a run would make to Active Directory. A preview of a 50,000 object
domain allocates as much as a real run, so the memory manager, the per-object check, the periodic
cleanup and the final disposal all execute regardless.

**Under a command.** `Remove-OrphanedSid -WhatIf` and `Restore-OrphanedSidBackup -WhatIf` pass the
preference on to everything they call, so the commands pin the housekeeping calls with
`-WhatIf:$false`: `Initialize-ScriptExecution` creates the memory manager, `Invoke-MainProcessingLogic`
calls `Invoke-MemoryCheck` and `Invoke-Cleanup`, and `Stop-OrphanedSidSession` calls
`Invoke-ResourceCleanup`, all pinned. A command run under `-WhatIf` therefore logs the normal memory
lines and prints no `What if:` line for memory work; `-WhatIf` reaches only the ACL change, the backup
folder, the streaming manager's temp files and the `-OutputPath` CSV. `Find-OrphanedSid` has no
`-WhatIf`.

**Called directly.** The sections below describe the functions when they are called on their own
with `-WhatIf`, as in a diagnostic session. There `ShouldProcess` guards their log statements, not
the operation.

## Design Principle

In `Private\System\*.ps1`, `ShouldProcess` guards the log statements, not the operation:

```powershell
if ($PSCmdlet.ShouldProcess("Memory", "Perform cleanup")) {
    Write-StructuredLog "Starting memory cleanup operation..." -Level Information ...
} else {
    Write-Verbose "WhatIf: Would perform memory cleanup"
}

# Executes in both modes
[System.GC]::AddMemoryPressure(50MB)
...
```

- **Always execute**: memory manager creation, memory checks, `Invoke-Cleanup` garbage
  collection, resource disposal, final collection.
- **Respect -WhatIf**: Information and Debug log lines, which are replaced by `WhatIf: Would ...`
  verbose lines.

## Functions Affected

### `Initialize-MemoryManager`

```powershell
Initialize-MemoryManager -MaxMemoryMB 1024 -CheckInterval 25 -WhatIf
```

Creates and returns the `MemoryManager` instance. Under `-WhatIf` it logs
`WhatIf: Would initialize memory manager with threshold 1024 MB` (verbose) and
`Memory manager created for WhatIf simulation` (debug) instead of the normal initialisation lines.

### `Invoke-MemoryCheck`

```powershell
Invoke-MemoryCheck -MemoryManager $manager -WhatIf
```

Calls `$MemoryManager.CheckMemoryUsage()` and returns the status object in both modes. The
returned object's `WhatIfMode` property reflects `$WhatIfPreference`. The check itself only
measures when the manager's internal counter reaches `CheckInterval`; pass `-Force` to measure on
this call.

### `Invoke-Cleanup`

```powershell
Invoke-Cleanup -CorrelationId $id -WhatIf
```

Runs the full three-cycle collection with memory pressure in both modes and returns a
`MemoryCleanupResult` whose `WhatIfMode` is `$true` under `-WhatIf`. Under `-WhatIf` the log shows
`WhatIf: Would perform memory cleanup` (verbose) and
`WhatIf simulation: memory cleanup would be performed` (debug) in place of
`Starting memory cleanup operation...` and `Memory after cleanup: N MB (Freed: M MB)`.

### `Invoke-ResourceCleanup`

```powershell
Invoke-ResourceCleanup -MemoryManager $manager -WhatIf
```

Disposes `AdditionalResources`, disposes the memory manager and runs the final collection in both
modes. Under `-WhatIf` the log shows `WhatIf: Would dispose and cleanup resources` (verbose) and
`WhatIf simulation: resource disposal would be performed` (debug).

### Functions that do honour -WhatIf

- `Invoke-GarbageCollection` (same file as `Invoke-Cleanup`) is a targeted helper that no command
  calls. Under `-WhatIf` it skips the collection, logs
  `WhatIf: Would perform garbage collection`, and returns `MemoryAfter` equal to `MemoryBefore`
  with `WhatIfMode = $true`.
- `StreamingResultsManager` in WhatIf mode creates no temp directory and writes no batch files; it
  keeps each flushed batch in memory (`WhatIfResults`) so `GetAllResults()` can return it, so a
  preview holds every result in memory where a real run holds at most one batch.

## Verification

The helpers are private, so run this inside the module scope (see
[Memory-Management-Issues.md](./Memory-Management-Issues.md#validation-commands)):

```powershell
Import-Module OrphanedSid
. (Get-Module OrphanedSid) {
    Initialize-LoggingSystem -LogLevel Information

    # Manager is created despite -WhatIf
    $manager = Initialize-MemoryManager -MaxMemoryMB 1024 -CheckInterval 10 -WhatIf
    $null -ne $manager                  # True

    # Cleanup runs despite -WhatIf
    $result = Invoke-Cleanup -WhatIf -Verbose
    $result.WhatIfMode                  # True
    $result.GCCycles                    # 3

    # Disposal runs despite -WhatIf
    Invoke-ResourceCleanup -MemoryManager $manager -WhatIf
    $manager.Disposed                   # True
}
```

Comparing `[System.GC]::GetTotalMemory($false)` before and after `Invoke-Cleanup -WhatIf` on an
idle session proves little, because there may be nothing to reclaim; the `Disposed` flag and the
`GCCycles` count are the reliable indicators.

## Log Analysis

Lines that prove the operations executed in a command run, with or without `-WhatIf`, because the
memory functions are pinned (Debug lines need `-LogLevel Debug` or `Verbose`). A direct call
with `-WhatIf` does not write them:

```text
Garbage collection completed (3 cycles)
Memory manager disposed successfully
Final garbage collection completed
```

Lines that appear only under `-WhatIf` (verbose stream, so pass `-Verbose`). From a command run,
only the streaming manager's lines appear, because the memory functions are pinned:

```text
WhatIf: Would create temporary directory: <TEMP>\OrphanedSid-<CorrelationId>
WhatIf: Would flush batch 1 with 50 results to <TEMP>\OrphanedSid-<CorrelationId>\batch_1.json
```

When the memory functions are called directly with `-WhatIf`, these appear as well:

```text
WhatIf: Would initialize memory manager with threshold 1024 MB
WhatIf: Would check memory usage and cleanup if needed
WhatIf: Would perform memory cleanup
WhatIf: Would dispose and cleanup resources
```

## Troubleshooting

**Memory still climbs with -WhatIf.** Expected: the preview performs the full discovery, including
every `Get-Acl` and every SID lookup, and only skips the ACL writes. Tune `-MaxMemoryUsageMB` and
the search base as for a real run.

**Output is noisy under -WhatIf.** When the memory functions are called directly, each guarded log
statement prints a `What if:` line, and some add a `WhatIf: Would ...` verbose line. Dropping
`-Verbose` silences only the verbose lines; the operations still run. A command run produces
neither.

**Disposal errors under -WhatIf.** Resource disposal is real in both modes, so a disposal error
points at an actual resource problem (for example a temp directory removed by another process), not
at the simulation.

## Related Documentation

- [Memory Management](./Memory-Management.md)
- [Memory Management Issues](./Memory-Management-Issues.md)
- [Performance Tuning](./Performance-Tuning.md)
