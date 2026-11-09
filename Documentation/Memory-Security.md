# OrphanedSid Memory Management and Security Troubleshooting

## Memory Management

### How Memory Is Managed

`Find-OrphanedSid` and `Remove-OrphanedSid` create one `MemoryManager` (`Classes/MemoryManager.ps1`)
per run with the `-MaxMemoryUsageMB` threshold (100 to 16384 MB, default 1024). Every
`MemoryCheckInterval` objects (configuration key, default 50) it reads the process working set,
records the peak, and when the working set exceeds the threshold it writes

```text
WARNING: Memory usage threshold exceeded: <n> MB (Limit: <max> MB) - CorrelationId: <id>
```

and forces a full garbage collection. If the working set is still above the threshold afterwards
it adds `Memory usage still exceeds limit after garbage collection: <n> MB. Consider reducing batch
size or increasing memory limit.` The threshold is advisory: it triggers cleanup, it does not stop
the run or cap the process.

Discovery results are not held in memory. `StreamingResultsManager`
(`Classes/StreamingResultsManager.ps1`) writes them in batches of `BatchSize` objects (configuration
key, default 50) to `$env:TEMP\OrphanedSid-<CorrelationId>\batch_<n>.json` and reads them back at
the end of the run, to write them to the pipeline and, with `-OutputPath`, to the CSV. The folder is
removed at the end of the run unless `-PreserveTempFiles` is given. Under `-WhatIf` the folder is
not created.

The peak working set is written to the log in the processing summary as `Peak memory usage: <n> MB`.

### High Memory Usage

**Symptoms**

- The threshold warning above appears repeatedly in the log
- The process working set grows well past `-MaxMemoryUsageMB`

**Solutions**

1. Lower the threshold so garbage collection runs earlier: `-MaxMemoryUsageMB 512`
2. Check more often and flush smaller batches through a configuration file:

   ```json
   { "BatchSize": 25, "MemoryCheckInterval": 10 }
   ```

   ```powershell
   Find-OrphanedSid -SearchBase "DC=contoso,DC=com" -ConfigPath ".\low-memory.json"
   ```

3. Scan one OU at a time by passing several `-SearchBase` values across separate runs rather than
   the domain root in one run.
4. Lower `-LogLevel` (for example `Warning`) so the log file stays small on long runs.

### Temporary Files Left Behind

The streaming folder is deleted by `Dispose()` when the command's `finally` block runs
`Stop-OrphanedSidSession`. It remains on disk when `-PreserveTempFiles` was given (the path is
logged) or when the process was terminated before that block ran. In either case it is safe to
delete `$env:TEMP\OrphanedSid-<CorrelationId>`.

See [Memory-Management.md](../Troubleshooting/Performance/Memory-Management.md),
[Memory-Management-Issues.md](../Troubleshooting/Performance/Memory-Management-Issues.md) and
[Memory-WhatIf-Behavior.md](../Troubleshooting/Performance/Memory-WhatIf-Behavior.md).

## Security Validation

### What Is Checked Before Removal

During a `Remove-OrphanedSid` run that is not a `-WhatIf` preview, every orphaned SID on an object
passes through `Invoke-SecurityValidation` (`Private/Security/Invoke-SecurityValidation.ps1`),
which calls `Test-SIDSecurity` (`Private/SID/Test-SIDSecurity.ps1`) at the `Standard` level for
each SID. A SID is blocked when any of these applies:

| Check | Source of the rule | Issue text in the log |
|-------|--------------------|-----------------------|
| Listed as protected | `ProtectedSIDs` configuration key | `SID is in protected SIDs list - removal blocked by security policy` |
| Matches a well-known pattern | `WellKnownSIDPatterns` configuration key | `Well-known SID detected - removal may impact system security` |
| Malformed or malicious-looking input | Built-in pattern checks | `Critical security risk detected - potentially malicious input pattern: <pattern>` |
| Rated Critical risk by SID analysis | `Get-SIDAnalysis` risk level | `Critical security risk detected - potentially malicious input` |

Two further findings are recorded but do not block at the `Standard` level: a SID rated High risk
by `Get-SIDAnalysis` (`High-risk SID requires elevated confirmation for removal`, reported by
`Invoke-SecurityValidation` as `High-risk SID detected: <sid>`), and an object whose DN matches a
`CriticalObjectPatterns` entry (defaults: Domain Admins, Enterprise Admins, Schema Admins, BUILTIN,
`CN=Users,DC=*`, `CN=Computers,DC=*`; issue text `SID is on critical object: <DN>`). Both set the
validation's `RiskLevel` to `High` and appear in the `SecurityValidation` property of the
`RemovalOperationResult`; the entry is still removed.

If any SID on an object is blocked, the removal workflow skips that object entirely and logs
`SECURITY BLOCK: Security validation failed: <issues>` at `Error` level. The blocked SIDs are also
written as security audit entries (`"Component":"SecurityAudit"`, `DataValidation` events with
outcome `Failure`), which are always logged regardless of `-LogLevel`.

There is no parameter that overrides a block. The only adjustable inputs are `ProtectedSIDs` and
`WellKnownSIDPatterns` in the `-ConfigPath` file; `CriticalObjectPatterns` and the risk rating are
fixed in code.

Security validation runs only when an entry is actually being removed. A `-WhatIf` run lists the
entries that would be removed but does not evaluate these checks.

### Protected or Well-Known SID Blocked

**Symptoms**

- `SECURITY BLOCK: Security validation failed: SID is in protected SIDs list ...` in the log
- The object is counted as a failed removal and its ACL is unchanged

**Solutions**

1. Confirm the SID really is orphaned; a protected or well-known SID is almost never a candidate
   for removal.
2. If a SID in the default `ProtectedSIDs` list is genuinely orphaned in this forest, supply a
   configuration file with a `ProtectedSIDs` array that omits it, and keep that file under change
   control.
3. Review the security audit entries for the run before re-running with the changed
   configuration.

### Critical Object Findings

**Symptoms**

- `SID is on critical object: <DN>` in the `SecurityValidation.Issues` of a result, or
  `High-risk SID detected: <sid>` for objects under `CN=Users` or `CN=Computers`, or admin groups
- The result's `SecurityValidation.RiskLevel` is `High`

**Solutions**

1. These findings do not stop the removal. Review the affected objects in the results before
   relying on the run, and restore from the run's backup folder if an entry should not have gone.
2. Test in a non-production forest before touching the same objects in production; the patterns
   cannot be changed through configuration.

### Backup Integrity Failures

**Symptoms**

- `Failed to create ACL backup for <DN> : <message>` during `Remove-OrphanedSid`
- `Backup validation failed: SDDL integrity check failed: Hash mismatch ...` during
  `Restore-OrphanedSidBackup`

**Solutions**

1. Check that the account can write to `-BackupPath` and that its parent folder exists.
2. Do not edit backup `.xml` files; the stored `SDDLHash` must equal the SHA256 of the stored
   `SDDL`.
3. Restore from a different backup of the same object if one exists.

See [Security-Validation-Guide.md](../Troubleshooting/Security/Security-Validation-Guide.md) and
[Backup-Restore-Issues.md](../Troubleshooting/Common/Backup-Restore-Issues.md).

## Best Practices

### Memory

- Set `-MaxMemoryUsageMB` for the host the command runs on, not for the dataset.
- Use a configuration file with a smaller `BatchSize` and `MemoryCheckInterval` for large domains.
- Keep `-PreserveTempFiles` for troubleshooting only.

### Security Validation

- Run `Remove-OrphanedSid -WhatIf` first to see which entries would be removed, then read the
  `SECURITY BLOCK` lines and the `BlockedSIDs` of each result after the real run.
- Keep the default `ProtectedSIDs` unless a reviewed configuration file says otherwise.
- Keep the backup folders from every removal run until the change has been verified.

### Error Recovery

- Record the run's correlation ID; it is on every log line and inside every backup file.
- Rehearse `Restore-OrphanedSidBackup -WhatIf` against a real backup folder before relying on it.
