# OrphanedSid Common Issues Troubleshooting Guide

## Overview

This guide covers the issues most often reported when running `Find-OrphanedSid`,
`Remove-OrphanedSid` and `Restore-OrphanedSidBackup`, with the exact messages they emit and fixes
that use their real parameters.

`Find-OrphanedSid` and `Remove-OrphanedSid` accept `-SearchBase` (string array, also from the
pipeline, alias `DistinguishedName`), `-OutputPath`, `-IncludeInherited`, `-MaxRetries` (1-10,
default 3), `-ConfigPath`, `-MaxMemoryUsageMB` (100-16384, default 1024), `-PreserveTempFiles`,
`-LogPath`, `-CorrelationId`, `-LogLevel` (`Critical`, `Error`, `Warning`, `Information`, `Debug`,
`Verbose`; default `Information`) and `-SuppressConsoleOutput`. `Remove-OrphanedSid` adds
`-BackupPath` and `-Force`. `Restore-OrphanedSidBackup` takes `-TargetObjectDN`, a mandatory
`-BackupPath`, `-Force`, `-OutputPath`, `-LogPath`, `-CorrelationId`, `-LogLevel` and
`-SuppressConsoleOutput`. The two commands that change Active Directory also take `-WhatIf` and
`-Confirm`. There is no `-Credential`; every command runs as the current user.

Each command writes its results to the pipeline as objects: one `OrphanedSIDResult` per orphaned
entry, one `RemovalOperationResult` per object changed, one restore result per target.
`-OutputPath` also writes them as CSV, and every run writes a log file.

## Critical Issues (Immediate Resolution Required)

### 1. A Command Fails to Start

#### Issue: "ActiveDirectory PowerShell module is not available"

**Symptoms:**

- The command stops before any object is processed.
- The error is `The ActiveDirectory PowerShell module is not available. Install RSAT: Active
  Directory PowerShell (...) and run the command again.`, raised by `Start-OrphanedSidSession`.

**Root Cause:** the `ActiveDirectory` module is not installed, or is not visible to the PowerShell
edition in use.

**Resolution:**

```powershell
# Windows 10 (1809 and later) and 11
Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0

# Windows Server
Install-WindowsFeature RSAT-AD-PowerShell

# Verify from the same PowerShell edition that will run the command
Get-Module -ListAvailable -Name ActiveDirectory
```

#### Issue: Import-Module fails or a command "is not recognized"

**Symptoms:**

- `Import-Module OrphanedSid` reports a parse error naming a file under `Classes\` or `Private\`.
- A command runs but fails with `The term '<function>' is not recognized`.

**Root Cause:** an incomplete or edited copy of the module. `OrphanedSid.psm1` dot-sources every
file under `Classes\` and `Private\<Area>\` in a fixed order; a missing or broken file either fails
the import or leaves a dependent function undefined, which surfaces when it is first called.

**Resolution:** reinstall from the Gallery, or redeploy the whole module folder from source
control. Verify with:

```powershell
Get-ChildItem -Path .\Private -Recurse -Filter *.ps1 | Measure-Object
```

### 2. Authentication and Authorization Failures

#### Issue: "Access denied" during AD operations

**Symptoms:**

- `WARNING: Failed to retrieve objects from search base '<DN>': Insufficient access rights ...`
  during discovery.
- Objects quietly missing from the results: an object whose security descriptor the account cannot
  read is skipped with the Debug-level `No security descriptor found for <DN>` (see
  `.\Troubleshooting\Common\Security-Descriptor-Warnings.md`).
- From `Remove-OrphanedSid`: `Failed to retrieve ACL for <DN>` or Set-Acl access-denied errors.

**Required permissions:**

| Command | Permission on target objects |
| --- | --- |
| `Find-OrphanedSid` | Read all properties and Read permissions |
| `Remove-OrphanedSid` | Modify permissions (and the backup folder must be writable) |
| `Restore-OrphanedSidBackup` | Modify permissions |

**Resolution:**

```powershell
# Confirm the account running the command
whoami
whoami /groups | findstr /i "Domain Admins Account Operators"

# Read test on the search base
Get-ADObject -SearchBase 'OU=Test,DC=contoso,DC=com' -Filter * -ResultSetSize 1 -ErrorAction Stop

# Permission read test on one object
Get-Acl -Path 'AD:\CN=User1,OU=Test,DC=contoso,DC=com' | Select-Object -ExpandProperty Access | Measure-Object
```

#### Issue: "The RPC server is unavailable"

**Symptoms:** intermittent failures on `Get-ADObject` or `Get-Acl`, usually in large runs.

**Resolution:**

```powershell
$dc = (Get-ADDomainController).HostName
Test-NetConnection -ComputerName $dc -Port 389 -InformationLevel Detailed
Resolve-DnsName -Name $dc -Type A

# Raise the per-object detection retry count (default 3, maximum 10)
Find-OrphanedSid -SearchBase 'OU=Test,DC=contoso,DC=com' -MaxRetries 5
```

`-MaxRetries` governs the per-object retry loop in `Invoke-MainProcessingLogic`: when detection
on an object throws, detection is retried up to that many times with a 2, 4, 6... second back-off
(`Retry attempt N of M for object <DN>`); removal is never retried. SID lookups and the ACL steps
of `Remove-OrphanedSid` go through
`Invoke-ADOperationWithRetry`, which has its own fixed default of 3 attempts and retries only
errors matching `timeout|network|connection|busy|unavailable|server not operational|replication|domain controller`.
Object discovery (`Get-ADObject -SearchBase`) and the security-descriptor read during detection are
not retried.

### 3. Remove or Restore Stops at the Confirmation Prompt

#### Issue: a scheduled or remote run fails before changing anything

**Symptoms:** `Remove-OrphanedSid` or `Restore-OrphanedSidBackup` stops immediately with a PowerShell
error about prompting in a non-interactive session, or, when the prompt was answered No, logs one of:

```text
Removal declined at the confirmation prompt for: <search bases>
Restore declined at the confirmation prompt for: <targets>
```

**Root Cause:** both commands declare `ConfirmImpact = 'High'` and call `ShouldProcess` once per run
(`Remove orphaned SIDs from ACLs (a backup of each ACL is written first)` and
`Restore ACLs from backup folder <path>`). In an interactive console PowerShell asks once. A host
that cannot prompt - a scheduled task, CI agent, or remote session - fails the prompt instead.

**Resolution:**

```powershell
# Preview without any prompt or change
Remove-OrphanedSid -SearchBase 'OU=Test,DC=contoso,DC=com' -WhatIf

# Unattended run - skips the confirmation
Remove-OrphanedSid -SearchBase 'OU=Test,DC=contoso,DC=com' -Force
```

`-WhatIf` never prompts. `-Force` (or `-Confirm:$false`) only affects this confirmation; it does not
change what is removed or restored.

## High Priority Issues

### 4. Performance and Memory Issues

#### Issue: Memory warnings or "Out of memory" during processing

**Symptoms:**

- Memory threshold warnings from the memory manager in the log.
- The host process working set grows beyond `-MaxMemoryUsageMB`.

**Resolution:**

```powershell
# Raise the ceiling (100-16384 MB; default 1024)
Find-OrphanedSid -SearchBase 'DC=contoso,DC=com' -MaxMemoryUsageMB 4096

# Watch the process while it runs (pwsh or powershell depending on host)
Get-Process -Id $PID | Select-Object ProcessName, @{ n = 'WorkingSetMB'; e = { [math]::Round($_.WorkingSet64 / 1MB) } }

# Split a large domain into several runs
$ous = Get-ADOrganizationalUnit -Filter * -SearchScope OneLevel | Select-Object -ExpandProperty DistinguishedName
foreach ($ou in $ous) {
    Find-OrphanedSid -SearchBase $ou -OutputPath ".\Reports\$($ou.Split(',')[0].Substring(3)).csv"
}
```

Objects are processed one at a time; there is no parallel mode and no throttle parameter. Results
are streamed to batch files under `OrphanedSid-<CorrelationId>\` in `[IO.Path]::GetTempPath()`,
so result count does not drive memory use. See `.\Troubleshooting\Performance\Memory-Management-Issues.md` and
`.\Troubleshooting\Performance\Performance-Tuning.md`.

#### Issue: A run appears to hang

**Symptoms:** no progress line for a long time. Progress is logged every 50 objects as
`Processing: <n>/<total> objects (<pct>%) - Orphaned SIDs found: <k>`.

**Root Cause:** most often a slow domain controller during SID lookups. Each unknown SID can cost
up to five AD queries (`Get-ADObject` by `objectSid`, deleted-objects query, `Get-ADUser`,
`Get-ADGroup`, `Get-ADComputer`), each retried up to 3 times by `Invoke-ADOperationWithRetry`
when the error looks transient.

**Resolution:**

```powershell
# See each lookup as it happens
Find-OrphanedSid -SearchBase 'OU=Test,DC=contoso,DC=com' -LogLevel Debug

# Bound the run from a wrapper
$job = Start-Job -ScriptBlock { Find-OrphanedSid -SearchBase 'OU=Test,DC=contoso,DC=com' }
if (-not (Wait-Job -Job $job -Timeout 1800)) {
    Stop-Job -Job $job
    Write-Warning 'Find-OrphanedSid did not finish within 30 minutes'
}
Receive-Job -Job $job
```

Lookup results are cached per SID for the PowerShell session, so repeated SIDs cost one lookup set;
an `Unverified` result (a lookup failed) is not cached.

### 5. Configuration and Parameter Issues

#### Issue: "Configuration file not found" or JSON parsing errors

**Symptoms:**

- `Cannot validate argument on parameter 'ConfigPath'. Configuration file not found: <path>`.
- `Failed to load configuration from <path> : <message>`, logged as `Script initialization failed: ...`.
- Settings in the file appear to be ignored.

**Root Cause:** the path is wrong, the JSON is malformed, or the file uses keys the loader does not
read. `ScriptConfiguration.LoadFromFile` reads only these top-level keys:

| Key | Type | Default | Accepted |
| --- | --- | --- | --- |
| `WellKnownSIDPatterns` | string[] of regex | built-in list | each must compile |
| `ProtectedSIDs` | string[] | built-in list | `^S-1-\d+(-\d+)*$` |
| `BatchSize` | int | 50 | 1-1000; results per streaming batch file |
| `MemoryCheckInterval` | int | 50 | 1-1000; objects between memory checks |
| `EnableDetailedLogging` | bool | false | read but has no effect |
| `LogLevel` | string | Information | Critical, Error, Warning, Information, Debug, Verbose; validated but has no effect, use `-LogLevel` |
| `LogFilePath` | string | null | overrides `-LogPath` for entries after the configuration loads; its folder must exist |
| `EnableLogFileRotation` | bool | true | |
| `MaxLogFileSizeMB` | int | 10 | |

Any other key, and any nested object, is ignored without a warning.

**Resolution:**

```powershell
$configPath = '.\config.json'
if (Test-Path $configPath) {
    try {
        $config = Get-Content -Path $configPath -Raw | ConvertFrom-Json
        'Configuration file parses'
        $known = 'WellKnownSIDPatterns', 'ProtectedSIDs', 'BatchSize', 'MemoryCheckInterval',
            'EnableDetailedLogging', 'LogLevel', 'LogFilePath', 'EnableLogFileRotation', 'MaxLogFileSizeMB'
        $config.PSObject.Properties.Name | Where-Object { $_ -notin $known } |
            ForEach-Object { "Ignored key: $_" }
    } catch {
        "Configuration file invalid: $($_.Exception.Message)"
    }
} else {
    "Configuration file not found: $configPath"
}

# Minimal valid file
@{
    BatchSize           = 50
    MemoryCheckInterval = 50
    LogLevel            = 'Information'
    MaxLogFileSizeMB    = 10
} | ConvertTo-Json | Set-Content -Path .\config.json -Encoding UTF8
```

## Medium Priority Issues

### 6. Output and Reporting Issues

#### Issue: No CSV is produced, or the CSV is empty

**Symptoms:**

- `The folder for -OutputPath does not exist: <dir>` from parameter validation.
- The summary ends with `No orphaned SIDs found. Active Directory ACLs appear to be clean.` and no
  file is written.
- `Failed to export results to CSV: <message>` in the summary section.

**Root Cause:** the export runs only when at least one orphaned SID was found, and under
`Remove-OrphanedSid -WhatIf` no file is written although `Results exported to:` is still logged.
The file is always CSV (`StreamingResultsManager.ExportToCsv`), whatever extension `-OutputPath` carries. The folder
must already exist. The same results are written to the pipeline whether or not `-OutputPath` is
given.

**Resolution:**

```powershell
New-Item -Path .\Reports -ItemType Directory -Force | Out-Null
Find-OrphanedSid -SearchBase 'OU=Test,DC=contoso,DC=com' -OutputPath '.\Reports\orphaned-sids.csv'

# Confirm from the log
Select-String -Path (Get-ChildItem .\Logs\<Command>_*.log | Sort-Object LastWriteTime | Select-Object -Last 1).FullName -Pattern 'Orphaned SIDs found:|Results exported to:'
```

Columns follow the `OrphanedSIDResult` class: `ObjectDN`, `ObjectClass`, `OrphanedSID`,
`LikelySource`, `Confidence`, `AnalysisNotes`, `AccessControlType`, `ActiveDirectoryRights`,
`InheritanceType`, `ObjectType`, `InheritedObjectType`, `IsInherited`, `ProcessingMethod`,
`ActionTaken`, `VerificationStatus`, `VerificationError`, `CorrelationId`, `Timestamp`, then the
note properties `ProcessingContext` and `ProcessingStatistics` as text. Enum columns hold numbers.

#### Issue: Correlation ID cannot be found in the logs

**Symptoms:** `Select-String` for the ID returns nothing, or returns lines from several runs.

**Root Cause:** the correlation ID is written in every log line as the fourth bracketed field,
`[<timestamp>] [<Level>] [<Component>] [<CorrelationId>] <Message>`. It is never part of the log
file name, which is `<Command>_<yyyyMMdd_HHmmss>.log` by default. When `-CorrelationId` is
not given a new GUID is generated per run.

**Resolution:**

```powershell
$correlationId = [guid]::NewGuid().ToString()
Find-OrphanedSid -SearchBase 'OU=Test,DC=contoso,DC=com' -CorrelationId $correlationId
Select-String -Path .\Logs\<Command>_*.log -Pattern "\[$correlationId\]" | Select-Object -First 20
```

Any string is accepted for `-CorrelationId` on all three commands, so a change or ticket number
can be used directly.

### 7. Backup Issues During Removal

#### Issue: Removal aborts with a backup error

**Symptoms:**

- `Failed to create ACL backup for <DN> : <message>` followed by
  `SID removal workflow failed for <DN> : <message>` for that object.

**Root Cause:** every removal first writes `<sanitized DN>_<yyyyMMdd_HHmmss>.xml` (Export-Clixml)
to `<BackupPath>\<yyyyMMdd_HHmmss>\`. When `-BackupPath` is omitted it is `.\Backup` under the
current directory. A failed backup aborts that object's removal; other objects continue.

**Resolution:**

```powershell
$backupRoot = 'D:\ACLBackups'
New-Item -Path $backupRoot -ItemType Directory -Force | Out-Null
$drive = Get-PSDrive -Name $backupRoot.Substring(0, 1)
"Free space: $([math]::Round($drive.Free / 1GB, 2)) GB"

Remove-OrphanedSid -SearchBase 'OU=Test,DC=contoso,DC=com' -BackupPath $backupRoot -WhatIf
```

The parent of `-BackupPath` must exist (`The parent folder for -BackupPath does not exist: <dir>`
otherwise). Full backup and restore guidance is in
`.\Troubleshooting\Common\Backup-Restore-Issues.md`.

## Low Priority Issues

### 8. Logging Issues

#### Issue: Log files grow too large

**Resolution:**

```powershell
# Write only Warning and above to the file; console output is unaffected
Find-OrphanedSid -SearchBase 'DC=contoso,DC=com' -LogLevel Warning

# Remove logs older than 30 days
Get-ChildItem -Path .\Logs -Filter '<Command>_*.log' |
    Where-Object LastWriteTime -lt (Get-Date).AddDays(-30) |
    Remove-Item -Force
```

Each run starts its log file afresh: a file already at `-LogPath` is overwritten, not appended to
or rotated. Rotation to `<name>_<yyyyMMdd_HHmmss>.log` (`EnableLogFileRotation`, over
`MaxLogFileSizeMB`) applies only to an existing file named by the config key `LogFilePath`.
Security events bypass the `-LogLevel` filter and are always written.

#### Issue: `-Verbose` or `-Debug` changes the log level unexpectedly

When `-LogLevel` is not given, `-Verbose` sets the file level to `Verbose` and `-Debug` sets it to
`Debug`. Pass `-LogLevel` explicitly to keep a fixed level while using the common parameters.

## Diagnostic Commands

### Quick health check

```powershell
function Test-OrphanedSidHealth {
    "PowerShell: $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"

    if (Get-Module -ListAvailable -Name ActiveDirectory) { 'ActiveDirectory module: available' }
    else { 'ActiveDirectory module: MISSING' }

    $module = Get-Module -ListAvailable -Name OrphanedSid | Sort-Object Version -Descending | Select-Object -First 1
    if ($module) { "OrphanedSid $($module.Version) at $($module.ModuleBase)" } else { 'OrphanedSid module: MISSING' }

    Import-Module OrphanedSid -ErrorAction Stop
    $exported = (Get-Module OrphanedSid).ExportedFunctions.Keys -join ', '
    "Exported commands: $exported"

    try {
        $domain = Get-ADDomain -ErrorAction Stop
        "AD connectivity: $($domain.DNSRoot)"
    } catch {
        "AD connectivity failed: $($_.Exception.Message)"
    }
}
```

### Collect diagnostics for a support request

```powershell
$diag = ".\Diagnostics\$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -Path $diag -ItemType Directory -Force | Out-Null
$PSVersionTable | Out-File "$diag\powershell-version.txt"
Get-ADDomain | Out-File "$diag\ad-domain.txt"
if (Test-Path .\config.json) { Copy-Item .\config.json "$diag\config.json" }
Get-ChildItem .\Logs -Filter '<Command>_*.log' | Sort-Object LastWriteTime -Descending |
    Select-Object -First 3 | Copy-Item -Destination $diag
"Diagnostic package: $diag"
```

Include the correlation ID of the failed run, the exact error text, and the domain size.

## Related Documentation

- `.\Troubleshooting\Common\Backup-Restore-Issues.md`
- `.\Troubleshooting\Common\Security-Descriptor-Warnings.md`
- `.\Troubleshooting\Common\SID-Processing-Orchestration-Issues.md`
- `.\Troubleshooting\Performance\Memory-Management-Issues.md`
- `.\Troubleshooting\Security\Orphaned-SID-Issues.md`
- `.\Documentation\Automation.md`
