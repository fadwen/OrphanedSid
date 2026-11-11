# OrphanedSid Automation Guide

This guide covers running the OrphanedSid commands from a scheduled task, a CI/CD job or any other
session where nobody can answer a prompt, and how such a job reads the results.

## Errors and Results

The commands have no exit codes. Each one writes its results to the pipeline and reports failure
through PowerShell's error stream:

| Outcome | How it surfaces |
|---------|-----------------|
| The run completed | The command returns normally. Individual objects may still have failed; check the result objects, the log and the CSV. |
| A critical error ended the run | The command logs `Discovery failed: ...`, `Removal failed: ...` or `Restore failed: ...` at `Error` level and raises a terminating error. |

A failed object, a blocked SID or a failed backup does not end the run; those outcomes are recorded
in the log and in the per-object results. Wrap the call in `try`/`catch`, or pass
`-ErrorAction Stop`, so that a terminating error fails the job step.

### Pipeline Output

| Command | Writes to the pipeline |
|---------|------------------------|
| `Find-OrphanedSid` | One result per orphaned or unverified access control entry, with the `OrphanedSIDResult` properties; `VerificationStatus` is `Orphaned` or `Unverified` |
| `Remove-OrphanedSid` | One `RemovalOperationResult` per object with verified orphaned entries, covering all of them; under `-WhatIf`, one `RemovalOperationResult` per such object with `ActualRemovals = 0`, the SIDs that would be removed in `RemovedSIDs`, and `SecurityValidation = 'WhatIf - Would Remove'` |
| `Restore-OrphanedSidBackup` | One `RestoreWorkflowResult` per `-TargetObjectDN` value, with `Success`, `TargetObjectDN`, `EntriesRestored`, `ErrorMessage` and `CorrelationId` |

`$found = @(Find-OrphanedSid ...)` captures the findings directly. `-OutputPath` writes the same
data to CSV in addition.

## Parameters for Unattended Runs

| Parameter | Commands | Purpose in automation |
|-----------|----------|----------------------|
| `-SearchBase <string[]>` | Find, Remove | OU or object DNs to scan; accepts pipeline input. Omitted: the current domain root, with a warning. |
| `-TargetObjectDN <string[]>` | Restore | Object or container DNs to restore. Mandatory; accepts pipeline input; aliases `DistinguishedName` and `SearchBase`. |
| `-BackupPath <path>` | Remove, Restore | Remove: folder that receives the per-run `<yyyyMMdd_HHmmss>` subfolder, default `.\Backup` under the current directory; its parent must exist. Restore: mandatory, the timestamped run folder that holds the `.xml` files. |
| `-OutputPath <path>` | all | CSV file for the results. The parent folder must exist. |
| `-LogPath <path>` | all | Log file. Default `.\Logs\<Command>_<yyyyMMdd_HHmmss>.log` under the current directory. Pass an absolute path: a relative value is resolved against the module folder. An existing file is overwritten at the start of the run. |
| `-LogLevel <level>` | all | Minimum level written to the log file: `Critical`, `Error`, `Warning`, `Information` (default), `Debug`, `Verbose`. Security audit entries are written regardless. |
| `-SuppressConsoleOutput` | all | Suppresses console log output. File logging is unaffected. |
| `-CorrelationId <string>` | all | Identifier stamped on every log line of the run, on every result and CSV row, and on every backup. Supply one from the orchestrator to correlate across systems; default is a new GUID. |
| `-Force` | Remove, Restore | Required for an unattended run. Sets `$ConfirmPreference` to `None` for the command; `-Confirm:$false` has the same effect. See [Confirmation](#confirmation-in-non-interactive-sessions). |
| `-WhatIf` | Remove, Restore | Previews without changing anything and never prompts. |
| `-ConfigPath <path>` | Find, Remove | JSON configuration file. See [Configuration File](#configuration-file). |
| `-MaxMemoryUsageMB <int>` | Find, Remove | Memory threshold in MB, 100 to 16384, default 1024. |
| `-MaxRetries <int>` | Find, Remove | Retries of an object's ACL and SID detection after an error, 1 to 10, default 3. A removal is not retried. |
| `-IncludeInherited` | Find, Remove | Also report inherited access control entries. `Remove-OrphanedSid` logs a warning for an inherited orphaned entry and leaves it; it is removed where it is set, on the parent. |
| `-PreserveTempFiles` | Find, Remove | Keep the per-run streaming results folder after the run. |

There is no `-Credential` parameter; every command runs as the calling account.

## Confirmation in Non-Interactive Sessions

`Remove-OrphanedSid` and `Restore-OrphanedSidBackup` declare `ConfirmImpact = 'High'` and call
`ShouldProcess` once per run, so they ask for confirmation unless `-Force`, `-Confirm:$false` or
`-WhatIf` is given. A session that cannot show a prompt (scheduled task, CI agent, no host UI)
cannot answer it: the prompt fails with PowerShell's own host error, the command logs
`Removal failed: ...` or `Restore failed: ...` at `Error` level and raises a terminating error.
Nothing has been changed at that point.

An operator who answers No in a console gets `Removal declined at the confirmation prompt for:
<targets>` (or `Restore declined ...`) at `Warning` level, and the command returns without output.

`Find-OrphanedSid` never prompts.

```powershell
# Discovery, unattended
Find-OrphanedSid -SearchBase "DC=contoso,DC=com" -OutputPath "C:\Reports\orphaned-sids.csv" -SuppressConsoleOutput

# Removal preview, unattended
Remove-OrphanedSid -SearchBase "OU=Users,DC=contoso,DC=com" -WhatIf -SuppressConsoleOutput

# Removal, unattended
Remove-OrphanedSid -SearchBase "OU=Users,DC=contoso,DC=com" -BackupPath "C:\Backups" -Force -SuppressConsoleOutput
```

## CI/CD Integration

The module does not detect CI environments and has no automation-specific mode; a pipeline step
is an ordinary unattended run on a Windows agent that has the RSAT ActiveDirectory module. Pass a
correlation ID from the pipeline so the log can be tied back to the job. A terminating error from
the command fails the step; the result objects are the pipeline's data.

### Azure DevOps Pipeline

```yaml
- task: PowerShell@2
  displayName: 'Scan for orphaned SIDs'
  inputs:
    targetType: inline
    pwsh: true
    script: |
      Install-PSResource -Name OrphanedSid -Scope CurrentUser -TrustRepository
      $found = @(Find-OrphanedSid -SearchBase 'DC=contoso,DC=com' `
          -OutputPath "$(Build.ArtifactStagingDirectory)/orphaned-sids.csv" `
          -LogPath "$(Build.ArtifactStagingDirectory)/OrphanedSid.log" `
          -CorrelationId "$(Build.BuildId)" -SuppressConsoleOutput)
      Write-Host "##vso[task.setvariable variable=OrphanedSidCount]$($found.Count)"
```

### GitHub Actions

```yaml
- name: Scan for orphaned SIDs
  shell: pwsh
  run: |
    Install-PSResource -Name OrphanedSid -Scope CurrentUser -TrustRepository
    $found = @(Find-OrphanedSid -SearchBase 'DC=contoso,DC=com' `
        -OutputPath "$env:RUNNER_TEMP/orphaned-sids.csv" `
        -LogPath "$env:RUNNER_TEMP/OrphanedSid.log" `
        -CorrelationId "$env:GITHUB_RUN_ID" -SuppressConsoleOutput)
    "found=$($found.Count)" >> $env:GITHUB_OUTPUT
```

### Scheduled Task

```powershell
$command = 'Import-Module OrphanedSid; Find-OrphanedSid -SearchBase ''DC=contoso,DC=com'' ' +
    '-OutputPath ''C:\Reports\orphaned-sids.csv'' -LogPath ''C:\Logs\OrphanedSid.log'' -SuppressConsoleOutput'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -Command `"$command`""
```

A scheduled `Remove-OrphanedSid` must pass `-Force`; without it the command fails at the
confirmation prompt, which a non-interactive session cannot answer.

## Reading the Results

### CSV Output

With `-OutputPath`, `Find-OrphanedSid` and `Remove-OrphanedSid` export the orphaned entries found
with `Export-Csv -NoTypeInformation` (UTF-8). One row per orphaned or unverified access control
entry, with these columns:

`ObjectDN`, `ObjectClass`, `OrphanedSID`, `LikelySource`, `Confidence`, `AnalysisNotes`,
`AccessControlType`, `ActiveDirectoryRights`, `InheritanceType`, `ObjectType`,
`InheritedObjectType`, `IsInherited`, `ProcessingMethod`, `ActionTaken`, `VerificationStatus`,
`VerificationError`, `CorrelationId`, `Timestamp`, `ProcessingContext`, `ProcessingStatistics`.

`AccessControlType`, `ActiveDirectoryRights` and `InheritanceType` hold the enum names (for
example `Allow` and `ReadProperty, WriteProperty`), and the last two columns hold flattened
hashtables.

No CSV is written when nothing was found, or under `-WhatIf`.

`Restore-OrphanedSidBackup` exports one row per target with `Success`, `TargetObjectDN`,
`EntriesRestored`, `ErrorMessage` and `CorrelationId`, whenever it produced at least one result.

```powershell
$results = Import-Csv "C:\Reports\orphaned-sids.csv"
$results | Group-Object ObjectDN | Sort-Object Count -Descending | Select-Object -First 10
```

### Log File

Each operational log line has the form:

```text
[2025-01-27T14:30:22.123] [Information] [Main] [12345678-1234-1234-1234-123456789012] Starting discovery
```

Entries with structured details append ` | Details: {...}` as compact JSON. Security audit
entries are written as one compact JSON object per line, with `"Component":"SecurityAudit"`,
`"SecurityEventType"`, `"Outcome"`, `"Message"` and `"CorrelationId"` keys; they are written at
every `-LogLevel`. The correlation ID appears in both forms, so it isolates one run's lines when
several runs append to the same file through the `LogFilePath` configuration key:

```powershell
Select-String -Path "C:\Logs\OrphanedSid.log" -Pattern "12345678-1234-1234-1234-123456789012" |
    Where-Object { $_.Line -match '\[(Error|Warning)\]' }
```

`-LogLevel` filters what reaches the file: `Warning` keeps `Critical`, `Error` and `Warning`
lines and drops `Information`, `Debug` and `Verbose`. Security audit entries bypass the filter.

### Temporary Files

Discovery results are streamed in batches to `$env:TEMP\OrphanedSid-<CorrelationId>\` as
`batch_<n>.json`, alongside a `summary_<timestamp>.json`. The folder is deleted when the run ends
unless `-PreserveTempFiles` is given, in which case its path is logged. Under `-WhatIf` the folder
is not created.

## Configuration File

`-ConfigPath` points at a JSON file. Only these keys are read; anything else is ignored.

| Key | Type | Default | Notes |
|-----|------|---------|-------|
| `WellKnownSIDPatterns` | string[] | Built-in list of regexes for well-known SIDs | Each value must compile as a .NET regex |
| `ProtectedSIDs` | string[] | `S-1-5-32-544`, `S-1-5-32-545`, `S-1-5-32-546`, `S-1-5-18`, `S-1-5-19`, `S-1-5-20` | Each value must match `^S-1-\d+(-\d+)*$` |
| `BatchSize` | int | 50 | 1 to 1000; results per streaming batch file |
| `MemoryCheckInterval` | int | 50 | 1 to 1000; objects processed between memory checks |
| `EnableDetailedLogging` | bool | false | Read; no command acts on it |
| `LogLevel` | string | `Information` | Must be one of the `-LogLevel` values; no command acts on it, so use `-LogLevel` |
| `LogFilePath` | string | none | When set, entries written after configuration load go to this file instead of `-LogPath`; its folder must exist. Startup entries are already in `-LogPath`. Runs append to this file |
| `EnableLogFileRotation` | bool | true | At startup, rename the `LogFilePath` file with a timestamp suffix when it is larger than `MaxLogFileSizeMB`. A `-LogPath` file is recreated each run, so rotation only matters for `LogFilePath` |
| `MaxLogFileSizeMB` | int | 10 | |

`CriticalObjectPatterns` is part of the default configuration but cannot be set from the file.

```json
{
  "BatchSize": 200,
  "MemoryCheckInterval": 25,
  "LogLevel": "Warning",
  "ProtectedSIDs": ["S-1-5-32-544", "S-1-5-32-548"]
}
```

## Best Practices

1. Run `Remove-OrphanedSid -WhatIf` in a new environment before the first removal.
2. Always pass `-OutputPath` and `-LogPath` to known locations and collect both as job artifacts.
3. Pass the job identifier as `-CorrelationId`; it is stamped on the run's log lines, removal and
   restore results and every backup file.
4. Treat a command that returned as "the run finished", not as "nothing failed"; inspect the
   result objects and the `[Error]` and `[Warning]` lines before acting on the output.
5. Keep `-Force` out of discovery runs; only `Remove-OrphanedSid` and `Restore-OrphanedSidBackup`
   have it.
