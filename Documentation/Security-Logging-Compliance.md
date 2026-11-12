# Security Logging

## Overview

OrphanedSid keeps two logging paths. Ordinary entries go through `Write-StructuredLog` /
`Write-StructuredLogEntry`, and their file output honours `-LogLevel`. Security audit entries go
through `Write-SecurityStructuredLogEntry`, which writes to the log file regardless of `-LogLevel`,
so an operator who lowers the file verbosity to `Error` still gets the recorded Active Directory
operations and every SID that was blocked or removed.

## Regular Logging and -LogLevel

`Write-StructuredLogEntry` (`Private/Logging/Write-StructuredLogEntry.ps1`) formats each entry as

```text
[<timestamp>] [<Level>] [<Component>] [<CorrelationId>] <Message>
```

appending ` | Details: {...}` when structured data is attached. It always writes the entry to the
console (unless `-SuppressConsoleOutput` was given) and writes it to the file only when
`Test-LogLevel` accepts the level. Levels are ordered `Critical` (0), `Error` (1), `Warning` (2),
`Information` (3), `Debug` (4), `Verbose` (5); an entry is written when its number is less than or
equal to the configured level's number. `-LogLevel Warning` therefore keeps `Critical`, `Error` and
`Warning` in the file and drops the rest.

The level is held in module state, `$script:LogLevel`, declared in
`Private/Logging/Initialize-LoggingConfiguration.ps1` and set when each command starts.

## Security Logging Path

### Write-SecurityStructuredLogEntry

`Private/Logging/Write-SecurityStructuredLogEntry.ps1` accepts `-Message`, `-Level` (`Critical`,
`Error`, `Warning` or `Information`; `Debug` and `Verbose` are not allowed for security entries),
`-Component` (default `SecurityAudit`), `-Data` and `-CorrelationId`. For each entry it:

1. Formats the message with `Format-LogMessage`.
2. Writes it to the console with a `[SECURITY]` prefix, except that `Information`-level security
   entries are file-only to keep the console readable. `Critical` is shown via `Write-Host` in red
   on yellow, `Error` via `Write-Error`, `Warning` via `Write-Warning`. `-SuppressConsoleOutput`
   suppresses all of this.
3. Appends the entry to the log file with `Add-Content`, without consulting `Test-LogLevel`.

If the log file is not initialised or the write fails, the entry is retried directly against the
configured log path and then written to `%TEMP%\OrphanedSid-Security-<yyyyMMdd>.log` with a
warning naming that file; when that fails too, it writes the error
`CRITICAL: Cannot write security log entry anywhere: <message>`. If formatting itself fails, a
plain-text line goes through the same direct write, and `%TEMP%\OrphanedSid-Security-Emergency.log`
is used only when that direct write throws.

### Write-SecurityLog

`Private/Logging/Write-SecurityLog.ps1` is the entry point the rest of the code uses:

```powershell
Write-SecurityLog -SecurityEventType <string> -Message <string> -Outcome Attempt|Success|Failure
                  [-SecurityContext <hashtable>] [-CorrelationId <string>]
```

It builds a data block (timestamp, event type, outcome, `UserContext` as `user@computer`, process
ID, correlation ID, plus every `SecurityContext` key prefixed `Security_`), maps the outcome to a
level (`Attempt` and `Success` to `Information`, `Failure` to `Warning`), and calls
`Write-SecurityStructuredLogEntry` with the component `SecurityAudit` and the message
`[<SecurityEventType>] [<Outcome>] <Message>`, which is the `Message` value in the written JSON.
If that call throws, the line is appended to `%TEMP%\OrphanedSid-Security-Fallback.log`.

### Write-ADOperationSecurityLog

`Private/Logging/Write-ADOperationSecurityLog.ps1` wraps `Write-SecurityLog` for Active Directory
access:

```powershell
Write-ADOperationSecurityLog -OperationName <string> -Outcome Attempt|Success|Failure
                             [-SecurityContext <hashtable>] [-CorrelationId <string>]
```

It emits an `ObjectAccess` event with the message `Attempting Active Directory operation: <name>`,
`Successfully completed Active Directory operation: <name>` or
`Failed Active Directory operation: <name>`.

### Where Security Entries Come From

- `Private/ActiveDirectory/Get-ADObjectsSequential.ps1`: the start and end of object discovery
- `Private/ActiveDirectory/Invoke-ADOperationWithRetry.ps1`: attempt and outcome of each operation
  it wraps (SID lookups, and the ACL reads and writes of a removal). The discovery query itself,
  `Get-Acl` during detection and `Get-ADDomain` are not wrapped and leave no security entry
- `Private/Core/Invoke-MainProcessingLogic.ps1`: workflow-level access events
- `Private/SID/Test-SIDSecurity.ps1`: `DataValidation` events for every SID checked before removal,
  including the reason a SID was blocked, and a `SecurityViolation` event for a malicious input
  pattern
- `Private/Operations/Invoke-RemovalWorkflow.ps1` via `Write-RemovalSecurityLog`
  (`Private/Logging/Write-RemovalSecurityLog.ps1`): `PrivilegeUse` events around each ACL
  modification, forwarded to `Write-SecurityLog`

### Load Order

`OrphanedSid.psm1` dot-sources `Private/Logging/` before every other `Private/` folder, so the
logging functions, including the security writer, exist before any function that calls them is
defined. `Private/Logging/Initialize-LoggingConfiguration.ps1` is the one file that does work at
load time: it creates the shared logging state (`$script:LogLevel`, `$script:LogLevels`, the
metrics tables) when the root module dot-sources it. Elsewhere, load-time code only sets initial
module-scope values (`Initialize-MemoryManager.ps1`, `Test-OrphanedSID.ps1`) or defines guarded
fallback functions (`Invoke-GarbageCollection.ps1`); it writes no log entries.
`Start-OrphanedSidSession` configures the logging state per run.

## What This Provides

- **Audit trail at any -LogLevel.** The AD operations listed above, SID validation outcomes and
  ACL changes reach the file even with `-LogLevel Error` or `Critical`.
- **Correlation.** Security entries carry the run's correlation ID, the same value that is on
  regular log lines and inside each backup file.
- **Fallback locations.** A security event that cannot reach the log file lands in `%TEMP%` under
  one of the three names above rather than being lost.
- **Separation from operational noise.** Security entries are identifiable by the `SecurityAudit`
  component in the file and the `[SECURITY]` prefix on the console.

What it does not provide: log integrity protection or tamper evidence. The log file is plain
UTF-8 text that anyone with write access can edit; protect the log folder with file-system ACLs
and forward the file to a central log store if the audit trail must survive the host.

## Usage

```powershell
# Only Error and Critical operational entries reach the file; all security entries still do
Find-OrphanedSid -SearchBase "DC=contoso,DC=com" -LogLevel Error

# Read back the security entries for a run
Select-String -Path ".\Logs\Find-OrphanedSid_*.log" -Pattern '"Component":"SecurityAudit"' |
    Where-Object { $_.Line -match "12345678-1234-1234-1234-123456789012" }
```

From inside a function that already has the logging system loaded:

```powershell
Write-SecurityLog -SecurityEventType 'ObjectAccess' -Message 'Reading ACL' -Outcome 'Attempt' -CorrelationId $CorrelationId
Write-ADOperationSecurityLog -OperationName 'Get-Acl' -Outcome 'Success' -CorrelationId $CorrelationId
```

## Troubleshooting

- **Security entries appear in the file but not on the console**: expected for `Information`
  outcomes (`Attempt`, `Success`); only `Warning`, `Error` and `Critical` are echoed.
- **"Security log written to emergency location: ..."**: the main log file could not be written;
  check `-LogPath` permissions and collect the named `%TEMP%` file.
- **No `"Component":"SecurityAudit"` lines at all**: the logging system failed to initialise before the first
  security event; look for `Initialize-LoggingSystem` errors at the top of the console output.

See [Security-Logging-Issues.md](../Troubleshooting/Security/Security-Logging-Issues.md).
