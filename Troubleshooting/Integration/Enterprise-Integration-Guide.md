# Enterprise Integration Guide - OrphanedSid
## Overview

This guide covers running `Find-OrphanedSid`, `Remove-OrphanedSid` and `Restore-OrphanedSidBackup`
from schedulers, pipelines and monitoring systems, and the integration problems that follow from how
they behave:

- Each command writes its **results to the pipeline** as objects: one `OrphanedSIDResult` per
  orphaned or unverified entry, one `RemovalOperationResult` per object changed, one restore result per
  target. `-OutputPath` also writes them as CSV, and every run writes a log file.
- The log file starts with a plain-text header block. Regular entries are **plain text**, one line
  each: `[<yyyy-MM-ddTHH:mm:ss.fff>] [<Level>] [<Component>] [<CorrelationId>] <Message>`, ending
  with ` | Details: <json>` when there is extra data. Security audit entries are **one JSON object
  per line** with `Timestamp`, `Level`, `Component` (`SecurityAudit`), `CorrelationId`, `Message`
  and the event's context fields.
- The run's correlation ID is in every line but **never in the file name**
  (`<Command>_<yyyyMMdd_HHmmss>.log` by default).
- `-OutputPath` always produces **CSV**, whatever extension is given.
- There is no parallel mode, no throttle parameter and no `-Credential`; every command runs as the
  invoking account.
- `Remove-OrphanedSid` and `Restore-OrphanedSidBackup` have `ConfirmImpact = 'High'` and need
  `-Force` (or `-Confirm:$false`) to run unattended; without it the confirmation prompt fails in a
  non-interactive session and nothing changes.

## Integration Scenarios

### 1. SIEM Integration

Point `-LogPath` at a folder the forwarder watches and parse the bracketed fields. A path containing
`Program Files`, `Windows` or `system32` is refused and no entry reaches it, so use a dedicated
folder:

```powershell
$logPath = 'D:\SIEM\OrphanedSid\OrphanedSid.log'
Find-OrphanedSid -SearchBase 'DC=contoso,DC=com' -LogPath $logPath -LogLevel Information `
    -CorrelationId ([guid]::NewGuid().ToString())
```

Field extraction for the plain-text lines (regex for the SIEM):

```text
^\[(?<timestamp>[^\]]+)\] \[(?<level>[^\]]+)\] \[(?<component>[^\]]+)\] \[(?<correlationId>[^\]]+)\] (?<message>.*?)(?: \| Details: (?<details>\{.*\}))?$
```

Security audit entries are the lines that start with `{`; parse them as JSON. Their `Component` is
`SecurityAudit`, and `Security_Component` names the source (`ADOperations` or
`RemovalSecurityLogging`). They bypass the `-LogLevel` filter, so they are written even with
`-LogLevel Error`. Fields worth indexing: `level`, `component`, `correlationId`, and the
`Orphaned SIDs found: N` summary message.

**Common issues:**

- **Mixed formats**: one file holds a header, plain-text lines and JSON lines. Route lines starting
  with `{` to a JSON parser and the rest to the regex above.
- **Fixed log path**: each run recreates the file at `-LogPath` with a new header, so a fixed name
  keeps only the last run. Leave `-LogPath` unset (timestamped name) or put the date in it, and
  watch the folder, not a single file name.
- **Correlation ID format**: any string is accepted on all three commands, so a change or ticket
  number can be used directly and searched for in the SIEM.

### 2. Monitoring (SCOM, Event Log)

Count the result objects the command returns; the log and the CSV carry the same information.

```powershell
$id = [guid]::NewGuid().ToString()
$csv = "D:\Reports\sid-audit-$(Get-Date -Format 'yyyyMMdd').csv"
$found = @(Find-OrphanedSid -SearchBase 'DC=contoso,DC=com' -OutputPath $csv -CorrelationId $id -MaxMemoryUsageMB 2048).Count


if ($found -gt 100) {
    Write-EventLog -LogName Application -Source 'OrphanedSid' -EventId 1001 -EntryType Warning `
        -Message "High orphaned SID count detected: $found (CorrelationId $id)"
}
```

Register the event source once with `New-EventLog -LogName Application -Source 'OrphanedSid'`.
`Write-EventLog` and `New-EventLog` exist in Windows PowerShell 5.1 only; on PowerShell 7 use
`New-WinEvent` or load them through the `WindowsCompatibility` module. The CSV exists only when at
least one orphaned or unverified SID was found; `Test-Path $csv` is a valid zero-result check.

### 3. Desired State Configuration

The `Script` resource counts the result objects; the CSV feeds `GetScript`:

```powershell
Configuration ADSecurityMaintenance {
    param(
        [string]$SearchBase = 'DC=contoso,DC=com',
        [int]$MaxOrphanedSIDs = 50
    )

    Script OrphanedSIDCheck {
        TestScript = {
            Import-Module OrphanedSid
            $csv = Join-Path $env:TEMP 'dsc-sid-audit.csv'
            Remove-Item -Path $csv -ErrorAction SilentlyContinue
            $found = @(Find-OrphanedSid -SearchBase $using:SearchBase -OutputPath $csv -LogLevel Warning)
            return ($found.Count -le $using:MaxOrphanedSIDs)
        }
        SetScript = {
            throw 'Orphaned SID count exceeds threshold; review the audit CSV before running Remove-OrphanedSid'
        }
        GetScript = {
            $csv = Join-Path $env:TEMP 'dsc-sid-audit.csv'
            @{ Result = if (Test-Path $csv) { @(Import-Csv -Path $csv).Count } else { 0 } }
        }
    }
}
```

### 4. Azure Monitor / Log Analytics

Upload the result objects, or the CSV rows written by `-OutputPath`:

```powershell
$csv = '.\Reports\sid-audit.csv'
Find-OrphanedSid -SearchBase 'DC=contoso,DC=com' -OutputPath $csv
if (Test-Path $csv) {
    $body = Import-Csv -Path $csv | ConvertTo-Json -Depth 3
    # Send $body with the Log Analytics HTTP Data Collector API or a Logs Ingestion DCR endpoint
}
```

### 5. Scheduled Tasks

```powershell
$command = 'Import-Module OrphanedSid; Find-OrphanedSid -SearchBase ''DC=contoso,DC=com'' ' +
    '-OutputPath ''D:\Reports\sid-audit.csv'' -LogLevel Warning'
$action  = New-ScheduledTaskAction -Execute 'pwsh.exe' -Argument "-NoProfile -NonInteractive -Command `"$command`""
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At 02:00
# A group managed service account runs logged off without a stored password
$principal = New-ScheduledTaskPrincipal -UserId 'CONTOSO\svc-adsecurity$' -LogonType Password -RunLevel Highest
Register-ScheduledTask -TaskName 'OrphanedSid Audit' -Action $action -Trigger $trigger -Principal $principal
```

For an ordinary account, pass `-User` and `-Password` to `Register-ScheduledTask` instead. With
`-User` alone the task is registered with an interactive logon type and runs only while that
account is logged on.

The task's account needs Read permissions for discovery and Modify permissions for
`Remove-OrphanedSid`. Because the task is non-interactive, a `Remove-OrphanedSid` run must include
`-Force`; without it the command stops at the confirmation prompt the session cannot answer.

## Common Integration Issues

### 1. Authentication and Authorization

#### Issue: Access denied under the service account

**Symptoms:** `Failed to retrieve objects from search base '<DN>': ...` warnings, many
`All security descriptor retrieval methods failed for <DN>` warnings, or `Failed to retrieve ACL for
<DN>` during removal.

**Resolution:** grant the service account Read permissions on the search base for discovery and
Modify permissions for `Remove-OrphanedSid` and `Restore-OrphanedSidBackup`. Verify as that account:

```powershell
Get-ADObject -SearchBase 'DC=contoso,DC=com' -Filter * -ResultSetSize 1 -ErrorAction Stop
Get-Acl -Path 'AD:\CN=Users,DC=contoso,DC=com' | Select-Object -ExpandProperty Access | Measure-Object
```

#### Issue: Credential prompts

The commands never prompt for credentials and have no `-Credential` parameter. A prompt comes from
the environment (for example a `Get-Credential` in a wrapper). Run the task as the intended account
instead.

### 2. Performance and Scalability

#### Issue: Memory pressure on large domains

```powershell
Find-OrphanedSid -SearchBase 'DC=contoso,DC=com' -MaxMemoryUsageMB 4096 -LogLevel Warning
```

`-MaxMemoryUsageMB` accepts 100-16384 (default 1024); it sets the warning threshold, not a hard
cap. Splitting the domain by OU across several runs is the only way to shorten a run; see
`.\Troubleshooting\Performance\Performance-Tuning.md`.

#### Issue: Network timeouts

```powershell
Find-OrphanedSid -SearchBase 'DC=contoso,DC=com' -MaxRetries 5
```

`-MaxRetries` (1-10) controls the per-object retry loop: reading an object's ACL and SIDs is
retried up to that many times after an error; a removal is not retried. SID lookups and the ACL
steps of `Remove-OrphanedSid` are wrapped by `Invoke-ADOperationWithRetry` with fixed limits of 2 or
3 attempts for transient errors. Object discovery is not retried. There are no timeout settings in
the configuration file. When a lookup for a SID fails and no other lookup finds it, the SID is
reported with `VerificationStatus` `Unverified` and is never removed; re-run discovery once the
domain controller is reachable.

### 3. Logging and Monitoring

#### Issue: Log growth

```powershell
Find-OrphanedSid -SearchBase 'DC=contoso,DC=com' -LogLevel Warning -LogPath '\\fileserver\logs\ADSecurity\OrphanedSid.log'
```

`-LogLevel` filters file output only; console output is unaffected. The folder part of `-LogPath`
is created if missing (`Log directory initialization failed: <message>` on failure).

#### Issue: Correlating one run across systems

Generate the ID once and pass it everywhere:

```powershell
$id = [guid]::NewGuid().ToString()
Find-OrphanedSid -SearchBase 'DC=contoso,DC=com' -CorrelationId $id -OutputPath ".\Reports\$id.csv"
Select-String -Path .\Logs\Find-OrphanedSid_*.log -Pattern $id -SimpleMatch
```

Every row of the CSV carries the run's correlation ID in its `CorrelationId` column, so a CSV ties
back to its run's log through that value.

## Automation Framework Examples

### Jenkins

```groovy
pipeline {
    agent any
    parameters {
        string(name: 'SEARCH_BASE', defaultValue: 'DC=contoso,DC=com', description: 'AD search base')
        choice(name: 'OPERATION', choices: ['Discovery', 'Removal'], description: 'Operation')
    }
    stages {
        stage('AD Security Audit') {
            steps {
                powershell """
                    \$id = [guid]::NewGuid().ToString()
                    \$csv = "\$env:WORKSPACE\\sid-audit-${env.BUILD_NUMBER}.csv"
                    Import-Module OrphanedSid
                    if ('${params.OPERATION}' -eq 'Removal') {
                        Remove-OrphanedSid -Force -SearchBase '${params.SEARCH_BASE}' -BackupPath "\$env:WORKSPACE\\ACLBackups" -CorrelationId \$id -OutputPath \$csv
                    } else {
                        Find-OrphanedSid -SearchBase '${params.SEARCH_BASE}' -CorrelationId \$id -OutputPath \$csv
                    }
                """
                archiveArtifacts artifacts: 'sid-audit-*.csv, ACLBackups/**', allowEmptyArchive: true
            }
        }
    }
}
```

`-Force` is required for the removal branch because the agent is non-interactive. Archive the
backup folder with the results; it is the only way to undo a removal.

### Azure DevOps

```yaml
schedules:
- cron: "0 2 * * 1"
  displayName: Weekly AD Security Audit
  branches:
    include:
    - main

pool:
  vmImage: 'windows-latest'

steps:
- powershell: |
    $id = [guid]::NewGuid().ToString()
    Find-OrphanedSid -SearchBase "DC=contoso,DC=com" -CorrelationId $id `
        -OutputPath "$(Build.ArtifactStagingDirectory)\sid-audit-results.csv" `
        -LogPath "$(Build.ArtifactStagingDirectory)\OrphanedSid.log"
  displayName: 'Execute AD Security Audit'

- task: PublishBuildArtifacts@1
  inputs:
    PathtoPublish: '$(Build.ArtifactStagingDirectory)'
    ArtifactName: 'SID-Audit-Results'
```

## Configuration Management

`-ConfigPath` points at a JSON file. Only these top-level keys are read; nested objects and other
keys are ignored silently:

```json
{
  "BatchSize": 50,
  "MemoryCheckInterval": 50,
  "EnableDetailedLogging": false,
  "LogLevel": "Information",
  "LogFilePath": "\\\\fileserver\\logs\\ADSecurity\\OrphanedSid.log",
  "EnableLogFileRotation": true,
  "MaxLogFileSizeMB": 10,
  "ProtectedSIDs": ["S-1-5-32-544", "S-1-5-32-545", "S-1-5-32-546", "S-1-5-18", "S-1-5-19", "S-1-5-20"],
  "WellKnownSIDPatterns": ["^S-1-1-0$", "^S-1-5-11$", "^S-1-5-32-", "^S-1-3-[0-4]$", "^S-1-5-18$", "^S-1-5-19$", "^S-1-5-20$"]
}
```

`LogFilePath` in the file overrides `-LogPath`; unlike `-LogPath`, its folder is not created
automatically, so it must already exist or every entry fails with an `Add-Content` error
(`Could not find a part of the path '<path>'`). Search base, memory limit, retries, and output path
are parameters only and cannot be set in the file. Validate a file before deploying it:

```powershell
$known = 'WellKnownSIDPatterns', 'ProtectedSIDs', 'BatchSize', 'MemoryCheckInterval',
    'EnableDetailedLogging', 'LogLevel', 'LogFilePath', 'EnableLogFileRotation', 'MaxLogFileSizeMB'
(Get-Content -Path .\config.json -Raw | ConvertFrom-Json).PSObject.Properties.Name |
    Where-Object { $_ -notin $known } | ForEach-Object { "Ignored key: $_" }
```

## Monitoring and Alerting

```powershell
function Send-SecurityAlert {
    param(
        [string]$AlertType,
        [string]$Message,
        [string]$CorrelationId
    )
    $alert = @{
        AlertType     = $AlertType
        Message       = $Message
        CorrelationId = $CorrelationId
        Timestamp     = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Source        = 'OrphanedSid'
    }
    Invoke-RestMethod -Uri 'https://monitoring.contoso.com/api/alerts' -Method Post `
        -Body ($alert | ConvertTo-Json) -ContentType 'application/json'
}

$id  = [guid]::NewGuid().ToString()
$csv = ".\Reports\$id.csv"
Find-OrphanedSid -SearchBase 'DC=contoso,DC=com' -CorrelationId $id -OutputPath $csv
$count = if (Test-Path $csv) { @(Import-Csv -Path $csv).Count } else { 0 }
if ($count -gt 100) {
    Send-SecurityAlert -AlertType 'HighOrphanedSIDCount' -Message "Found $count orphaned SIDs" -CorrelationId $id
}
```

## Troubleshooting Integration Issues

### Diagnostic information

```powershell
function Get-IntegrationDiagnostics {
    param([string]$CorrelationId = [guid]::NewGuid().ToString())

    $dc = Get-ADDomainController
    @{
        CorrelationId   = $CorrelationId
        PowerShell      = $PSVersionTable.PSVersion.ToString()
        Edition         = $PSVersionTable.PSEdition
        RunningAs       = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        Interactive     = [Environment]::UserInteractive
        ADModule        = [bool](Get-Module -ListAvailable -Name ActiveDirectory)
        DomainController = $dc.HostName
        Ldap389         = (Test-NetConnection -ComputerName $dc.HostName -Port 389 -InformationLevel Quiet)
        DomainMode      = (Get-ADDomain).DomainMode
    }
}
```

`Interactive = False` means a `Remove-OrphanedSid` or `Restore-OrphanedSidBackup` run needs `-Force`.

### Common error patterns

| Error | Cause | Resolution |
| --- | --- | --- |
| A prompting error from `Remove-OrphanedSid` or `Restore-OrphanedSidBackup` | Non-interactive run without `-Force` | Add `-Force`, or `-WhatIf` for a preview |
| `The ActiveDirectory PowerShell module is not available. Install RSAT: ...` | RSAT AD module missing on the agent | Install RSAT-AD-PowerShell |
| `The RPC server is unavailable` inside AD lookups | DC connectivity | Check port 389/636 and DNS; raise `-MaxRetries` |
| `The folder for -OutputPath does not exist: <dir>` | Folder in `-OutputPath` does not exist | Create it first |
| CSV missing after a run | No orphaned or unverified SIDs found | Treat as a zero result; check `Orphaned SIDs found: 0` in the log |

### Batch processing for large environments

```powershell
$ous = Get-ADOrganizationalUnit -Filter * -SearchScope OneLevel | Select-Object -ExpandProperty DistinguishedName
$batchSize = 10
for ($i = 0; $i -lt $ous.Count; $i += $batchSize) {
    $batch = $ous[$i..([Math]::Min($i + $batchSize - 1, $ous.Count - 1))]
    $id = [guid]::NewGuid().ToString()
    Find-OrphanedSid -SearchBase $batch -CorrelationId $id -OutputPath ".\Reports\batch-$($i / $batchSize + 1)-$id.csv"
}
```

`-SearchBase` accepts an array, and distinguished names can also be piped
(`$ous | Find-OrphanedSid`).

## Related Documentation

- `.\Documentation\Automation.md`
- `.\Documentation\Security-Logging-Compliance.md`
- `.\Troubleshooting\Common\Common-Issues.md`
- `.\Troubleshooting\Common\Backup-Restore-Issues.md`
- `.\Troubleshooting\Performance\Performance-Tuning.md`
- `.\Troubleshooting\Security\Security-Logging-Issues.md`
