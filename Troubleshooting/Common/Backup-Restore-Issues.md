# Backup and Restore Issues Troubleshooting Guide

## Overview

`Remove-OrphanedSid` backs up every ACL it is about to modify, and
`Restore-OrphanedSidBackup` re-applies those backups. This guide describes the backup format,
the messages each phase emits, and how to diagnose failures.

## How Backups Are Stored

Each backup is one `Export-Clixml` file written by `New-ACLBackup`
(`Private\Backup\New-ACLBackup.ps1`):

- **Folder**: `<BackupPath>\<yyyyMMdd_HHmmss>\`. The timestamped subfolder is created once per run
  by `Remove-OrphanedSid` before discovery starts (`Created backup folder: <path>` in the log).
  When `-BackupPath` is omitted it is `.\Backup` under the current directory. The parent of
  `-BackupPath` must already exist. Under `-WhatIf` no folder is created.
- **File name**: `<sanitized DN>_<yyyyMMdd_HHmmss>.xml`, where the DN has `\ / : * ? " < > | , =`
  and whitespace replaced by `_` and is cut at 200 characters (`_truncated` appended).
- **Content**: a single object with these properties.

| Property | Meaning |
| --- | --- |
| `ObjectDN` | Distinguished name the ACL belongs to |
| `BackupDate` | ISO 8601 timestamp |
| `CorrelationId` | Correlation ID of the removal run |
| `SDDL` | Full security descriptor in SDDL form |
| `SDDLHash` | Base64 SHA256 of the SDDL string |
| `BackupVersion` | `2.1` |
| `ValidationSignature` | `PSSecurityBackup_v2.1` |
| `ACLEntryCount` | Number of access rules at backup time |
| `BackupMethod` | `New-ACLBackup` |
| `UserContext`, `ComputerName`, `DomainContext` | Who and where |
| `PowerShellVersion`, `Platform`, `PSEdition`, `ScriptVersion` | Environment |

Read a backup with `Import-Clixml`, not `ConvertFrom-Json`:

```powershell
$backup = Import-Clixml -Path 'D:\ACLBackups\20250702_103631\CN_User1_OU_Test_DC_contoso_DC_com_20250702_103632.xml'
$backup | Select-Object ObjectDN, BackupDate, ACLEntryCount, BackupVersion, ValidationSignature
```

Immediately after writing, `New-ACLBackup` re-imports the file and compares `SDDLHash` and
`ObjectDN`; a mismatch deletes the file and throws
`Backup integrity check failed - SHA256 hash mismatch detected` or
`Backup integrity check failed - ObjectDN mismatch detected`.

## Backup Process Flow (`Remove-OrphanedSid`)

1. `Get-ACLForRemoval` reads the current ACL (`Failed to retrieve ACL for <DN>` on failure).
2. `Invoke-SecurityValidation` checks the SIDs to be removed.
3. `New-ACLBackup` writes and verifies the backup file
   (`Successfully backed up ACL to: <file> (Size: N bytes, Entries: N, Hash: xxxxxxxx...)`).
4. If the backup failed: `Failed to create ACL backup - aborting removal operation`; that object is
   left untouched and the run continues with the next one.
5. `Invoke-SIDRemoval` and `Set-ModifiedACL` apply the change, then `Invoke-RemovalVerification`
   confirms the SIDs are gone.

Under `-WhatIf`, `Invoke-MainProcessingLogic` prints `What if: Performing the operation "Remove
Orphaned SID" on target "<DN> - SID: <sid>"` per orphaned entry, logs
`WhatIf: Would remove orphaned SID: <sid> from <DN>` at Verbose level, and never calls the removal
workflow, so no backup folder or file is written. `Backup creation was cancelled by
user` (Warning) appears only when `New-ACLBackup`'s own confirmation is declined, for example with
`-Confirm` answered No.

## Restore Process Flow (`Restore-OrphanedSidBackup`)

`-BackupPath` is mandatory and must be an existing folder; parameter validation rejects anything
else before the command starts. Each `-TargetObjectDN` value (aliases `DistinguishedName` and
`SearchBase`, also accepted from the pipeline) is passed to
`Start-OrchestrationWorkflow -OperationType Restore` and on to `Invoke-RestoreWorkflow`
(`Private\Backup\Invoke-RestoreWorkflow.ps1`), which:

1. **Validates input**: the DN must start with `CN=`, `OU=` or `DC=`
   (`Invalid target object DN format`).
2. **Discovers backups** in `-BackupPath` (top level only, `*.xml`):
   - `No backup files found in directory: <path>` when the folder holds no `.xml` files.
   - Every file is read with `Import-Clixml` for the `ObjectDN` it records; a file that cannot be
     read is skipped with `Failed to process backup file '<path>': <message>`. File names are not
     used to pick a backup.
   - **Bulk mode** when the target starts with `OU=` or `DC=`: every backup whose `ObjectDN` is the
     target or ends with `,<target>` is restored. `OU=Sales` takes in `OU=East,OU=Sales` but not
     `OU=PreSales`.
   - **Single mode** otherwise: only backups whose `ObjectDN` equals the target, ignoring case.
     `No backup files found for object <DN> in path <path>` when none does.
   - In both modes an object with several backups in the folder is restored once, from the one with
     the latest `LastWriteTime`.
3. **Validates each backup** with `Test-BackupIntegrity -BackupData` at `Standard` level
   (`Backup validation failed: <issues>` on failure).
4. **Validates the target** with `Get-RestorationTarget -CheckPermissions`
   (`Target validation failed: <issues>`).
5. **Applies the SDDL** with `Set-ObjectACL`, which calls `Set-Acl -Path "AD:<DN>"`
   (`ACL application failed: <message>`).
6. **Verifies** with `Confirm-RestorationSuccess`. Its findings are written to the Verbose stream
   only and never mark a restore as failed (details below).

`Restore-OrphanedSidBackup` then logs a summary:

```text
=== RESTORE OPERATION SUMMARY ===
Total restore operations: 2
Successful restores: 1
Failed restores: 1
Total ACL entries restored: 34
Backup source: D:\ACLBackups\20250702_103631
```

The summary has no per-object lines. Each target's outcome is the result object the command writes
to the pipeline (`Success`, `TargetObjectDN`, `EntriesRestored`, `ErrorMessage`, and for a container
`IndividualResults`); the CSV written by `-OutputPath` has the first five columns:

```powershell
$results = @(Restore-OrphanedSidBackup -TargetObjectDN 'OU=Test,DC=contoso,DC=com' -BackupPath 'D:\ACLBackups\20250702_103631' -Force)
$results.IndividualResults | Where-Object { -not $_.Success } | Select-Object TargetObjectDN, ErrorMessage
```

`Restore-OrphanedSidBackup` has `ConfirmImpact = 'High'`: it prompts once
(`Restore ACLs from backup folder <path>`) in an interactive console, and a non-interactive run needs
`-Force` or `-Confirm:$false`; without either, PowerShell's own prompt fails. A declined prompt logs
`Restore declined at the confirmation prompt for: <targets>`. `-WhatIf` runs the discovery and
validation steps and prints `What if: Performing the operation "Apply ACL from backup" on target
"<DN>"` per object without changing anything.

Note that `Restore-OrphanedSidBackup -BackupPath` names the **timestamped subfolder**
(`D:\ACLBackups\20250702_103631`), not the root given to `Remove-OrphanedSid`; discovery does not
recurse.

## Critical Backup Issues

### 1. Backup Creation Failures

#### Issue: `Failed to create ACL backup for <DN> : <message>`

**Symptoms:**

- The message above at Error level, followed by
  `Failed to create ACL backup - aborting removal operation` and the object listed under
  `Failed removals` in the summary.
- `Cleaned up partial backup file: <file>` at Debug level when a half-written file was removed.

**Root Cause:**

- The backup folder is not writable, or its parent does not exist
  (`Parent directory does not exist for backup path: <dir>` fails parameter validation up front).
- Path length: the sanitized DN plus timestamp is capped at about 220 characters, but a deep
  `-BackupPath` can still exceed the 260-character limit on systems without long-path support.
- Disk full, or antivirus holding the new file during the immediate re-import check.

**Resolution:**

```powershell
$backupRoot = 'D:\ACLBackups'
New-Item -Path $backupRoot -ItemType Directory -Force | Out-Null

# Write test
$probe = Join-Path $backupRoot "probe-$(Get-Date -Format 'HHmmss').tmp"
New-Item -Path $probe -ItemType File -Force | Out-Null
Remove-Item -Path $probe -Force
'Backup folder is writable'

# Space
$drive = Get-PSDrive -Name $backupRoot.Substring(0, 1)
"Free: $([math]::Round($drive.Free / 1GB, 2)) GB"

# Keep paths short
Remove-OrphanedSid -SearchBase 'OU=Test,DC=contoso,DC=com' -BackupPath $backupRoot -WhatIf
```

#### Issue: `ACL object contains no access entries to backup for <DN>`

A Warning, not an error. The ACL read back had zero access rules; the backup is still written so
the empty state can be restored. Usually seen with `-IncludeInherited` absent on objects whose ACL
is entirely inherited.

### 2. Backup File Corruption

#### Issue: "Backup validation failed: ..." during restore

**Symptoms:** a restore result with `ErrorMessage` beginning `Backup validation failed:` and one
or more of these issues, joined by a semicolon and a space:

| Issue text | Meaning |
| --- | --- |
| `Missing required property: <name>` | One of `ObjectDN`, `BackupDate`, `SDDL`, `SDDLHash`, `ValidationSignature` is absent |
| `Invalid backup signature: <value>. Expected: PSSecurityBackup_v1.0, PSSecurityBackup_v2.0, PSSecurityBackup_v2.1` | Not a file written by `New-ACLBackup` |
| `ObjectDN mismatch: Expected '<target>', found '<backup>'` | The file belongs to a different object |
| `SDDL integrity check failed: Hash mismatch (expected: ..., calculated: ...)` | The SDDL text changed after the backup was written |
| `Invalid SDDL format: <message>` | `SetSecurityDescriptorSddlForm` rejected the SDDL |

**Root Cause:** the file was edited or truncated after creation, copied through a tool that altered
encoding, or is not an OrphanedSid backup at all.

**Resolution:** inspect each file with the check the restore itself runs, `Test-BackupIntegrity`
(`Private\Backup\Test-BackupValidation.ps1`). It takes the imported backup, so a file that cannot
be imported at all is reported as unreadable:

```powershell
Import-Module OrphanedSid
# Private functions are reached through the module scope: & (Get-Module OrphanedSid) { <command> }

Get-ChildItem -Path 'D:\ACLBackups\20250702_103631' -Filter *.xml | ForEach-Object {
    $check = try {
        $data = Import-Clixml -Path $_.FullName -ErrorAction Stop
        & (Get-Module OrphanedSid) { param($Data) Test-BackupIntegrity -BackupData $Data } $data
    } catch {
        [PSCustomObject]@{ IsValid = $false; Issues = @("Cannot read the file: $($_.Exception.Message)") }
    }
    [PSCustomObject]@{
        File    = $_.Name
        IsValid = $check.IsValid
        Issues  = $check.Issues -join '; '
    }
} | Format-Table -AutoSize
```

`Test-BackupIntegrity` checks the required properties, the signature, and at the default
`Standard` level the SHA256 hash and that the SDDL parses.

For an inventory of a backup folder with filtering:

```powershell
& (Get-Module OrphanedSid) {
    Find-BackupFile -BackupPath 'D:\ACLBackups\20250702_103631' -ObjectDN '*OU=Test,DC=contoso,DC=com'
} | Select-Object FileName, ObjectDN, BackupDate, ACLEntryCount, BackupVersion
```

`Find-BackupFile` is private and no command calls it; it recurses, so it can be pointed at the backup root. A corrupt file cannot be
repaired; restore from a different backup set or rebuild the ACL by hand (see Recovery Procedures).

## Critical Restore Issues

### 3. Restore Operation Failures

#### Issue: "Target validation failed: Target object not found or inaccessible: ..."

**Symptoms:** the object's result has `Success = False` and that `ErrorMessage`.

**Root Cause:** the object was deleted or moved since the backup; the backup's `ObjectDN` no longer
resolves. In bulk mode the DN comes from the backup file, not from `-TargetObjectDN`.

**Resolution:**

```powershell
# Which backups point at objects that no longer exist?
Get-ChildItem -Path 'D:\ACLBackups\20250702_103631' -Filter *.xml | ForEach-Object {
    $dn = (Import-Clixml -Path $_.FullName).ObjectDN
    try {
        $null = Get-ADObject -Identity $dn -ErrorAction Stop
        [PSCustomObject]@{ ObjectDN = $dn; Status = 'Found' }
    } catch {
        [PSCustomObject]@{ ObjectDN = $dn; Status = 'Missing' }
    }
}

# Look for a moved object by its leaf name
$name = 'User1'
Get-ADObject -Filter "Name -eq '$name'" | Select-Object DistinguishedName
```

A moved object has a new DN, so `Restore-OrphanedSidBackup` cannot apply its backup. Apply the SDDL manually
if needed:

```powershell
$backup = Import-Clixml -Path '<backup file>'
$sd = [System.DirectoryServices.ActiveDirectorySecurity]::new()
$sd.SetSecurityDescriptorSddlForm($backup.SDDL)
Set-Acl -Path "AD:$newDn" -AclObject $sd -WhatIf
```

#### Issue: "Target validation failed: Insufficient permissions to modify ACL: ..." or "ACL application failed: ..."

**Symptoms:** a result with `Success = False` and one of those errors; `Cannot read current ACL: <message>` may also
appear in the issues list.

**Root Cause:** the running account lacks Modify Permissions on the object, or the object is
protected (AdminSDHolder-governed objects reset their ACL within an hour; system containers).

**Resolution:**

```powershell
$dn = 'CN=User1,OU=Test,DC=contoso,DC=com'
Get-Acl -Path "AD:$dn" | Select-Object -ExpandProperty Access | Measure-Object        # read
Get-ADObject -Identity $dn -Properties adminCount, ProtectedFromAccidentalDeletion |
    Select-Object adminCount, ProtectedFromAccidentalDeletion                           # protection
```

Run as an account with Modify Permissions. For `adminCount = 1` objects, expect AdminSDHolder to
overwrite the restored ACL on the next SDProp cycle.

#### Issue: Restore verification differences

**Symptoms:** with `-Verbose`, lines such as:

```text
VERBOSE: Verification differences detected (this is often normal): Verification failed with Standard tolerance; Expected 49 entries, found 50, matched 48 - CorrelationId: ...
```

**What it means:** after `Set-Acl`, `Confirm-RestorationSuccess` splits the backup SDDL and the
current SDDL into ACE strings and counts exact matches. At the `Standard` tolerance the restore
workflow uses, 80 percent of the backed-up ACEs must be present for `IsVerified` to be true. A difference of
one or two entries is normal: inherited entries re-evaluated against the parent, entries added by
SDProp, or permissions granted after the backup. `Significant entry count difference detected` is
added when the backup has more than three ACEs that the current ACL lacks.

These lines are informational. They go to the Verbose stream only, do not appear in the log file,
and never change a result's `Success` to `False`. The `EntriesRestored` count in the summary
is the number of ACEs in the applied SDDL, not the number verified.

**When to investigate:** `Significant entry count difference detected`, or a `matched` count far
below `Expected`, on an object that is not AdminSDHolder-protected. Compare directly:

```powershell
$backup = Import-Clixml -Path '<backup file>'
$current = (Get-Acl -Path "AD:$($backup.ObjectDN)").GetSecurityDescriptorSddlForm('All')
$expectedAces = $backup.SDDL -split '\(' | Where-Object { $_ -like '*;*' }
$actualAces   = $current     -split '\(' | Where-Object { $_ -like '*;*' }
"Backup ACEs: $($expectedAces.Count)  Current ACEs: $($actualAces.Count)"
'Missing from current:'; $expectedAces | Where-Object { $_ -notin $actualAces }
'Added since backup:';   $actualAces   | Where-Object { $_ -notin $expectedAces }
```

### 4. Partial Restore Scenarios

Mixed successful and failed results in one run are expected when some objects were deleted,
moved, or are protected. Each failed result carries its own `ErrorMessage`; address them
individually. A per-object failure does not raise an error from the command; read the result
objects or the CSV.

## Performance Issues

### 5. Slow Backup or Restore

Backups cost one `Get-Acl`, one SDDL hash, one `Export-Clixml` and one `Import-Clixml` per object
and are rarely the bottleneck; SID resolution during discovery is (see
`.\Troubleshooting\Performance\Performance-Tuning.md`). Restores cost one `Import-Clixml`, one
`Get-ADObject`, one `Get-Acl` and one `Set-Acl` per object.

To keep runs bounded, split large OUs across several `Remove-OrphanedSid` runs, each producing its own
timestamped backup subfolder, and restore each subfolder separately:

```powershell
$ous = Get-ADOrganizationalUnit -Filter * -SearchBase 'OU=Departments,DC=contoso,DC=com' -SearchScope OneLevel |
    Select-Object -ExpandProperty DistinguishedName
foreach ($ou in $ous) {
    Remove-OrphanedSid -SearchBase $ou -BackupPath 'D:\ACLBackups' -Force
}
```

Monitor progress from the backup root:

```powershell
Get-ChildItem -Path 'D:\ACLBackups' -Directory | Sort-Object Name -Descending | Select-Object -First 1 |
    Get-ChildItem -Filter *.xml | Measure-Object
```

## Recovery Procedures

### 6. Salvaging a Damaged Backup Set

Copy every file that still passes validation into a new folder, then restore from that folder:

```powershell
Import-Module OrphanedSid
# Private functions are reached through the module scope: & (Get-Module OrphanedSid) { <command> }

$source   = 'D:\ACLBackups\20250702_103631'
$recovery = 'D:\ACLBackups\Recovered_20250702_103631'
New-Item -Path $recovery -ItemType Directory -Force | Out-Null

function Test-BackupFileUsable {
    param([string]$Path)
    try {
        $data = Import-Clixml -Path $Path -ErrorAction Stop
        (& (Get-Module OrphanedSid) { param($Data) Test-BackupIntegrity -BackupData $Data } $data).IsValid
    } catch {
        $false
    }
}

Get-ChildItem -Path $source -Filter *.xml | ForEach-Object {
    if (Test-BackupFileUsable -Path $_.FullName) {
        Copy-Item -Path $_.FullName -Destination $recovery
        "Salvaged: $($_.Name)"
    } else {
        "Unusable: $($_.Name)"
    }
}

Restore-OrphanedSidBackup -TargetObjectDN 'OU=Test,DC=contoso,DC=com' -BackupPath $recovery -WhatIf
```

### 7. Manual ACL Clean-up Without a Backup

When no usable backup exists, unresolvable SIDs can be removed by hand. Back up first with
`Export-Clixml` so the step is reversible:

```powershell
$dn = 'CN=User1,OU=Test,DC=contoso,DC=com'
$acl = Get-Acl -Path "AD:$dn"
[PSCustomObject]@{ ObjectDN = $dn; SDDL = $acl.GetSecurityDescriptorSddlForm('All'); BackupDate = Get-Date } |
    Export-Clixml -Path ".\manual-backup-$(Get-Date -Format 'yyyyMMdd_HHmmss').xml"

$removed = 0
foreach ($ace in @($acl.Access | Where-Object { -not $_.IsInherited })) {
    try {
        $null = ([System.Security.Principal.SecurityIdentifier]$ace.IdentityReference.Value).Translate([System.Security.Principal.NTAccount])
    } catch {
        $null = $acl.RemoveAccessRule($ace)
        $removed++
        "Removed: $($ace.IdentityReference)"
    }
}
if ($removed -gt 0) { Set-Acl -Path "AD:$dn" -AclObject $acl -WhatIf }
```

Only SID-form identities are tested here; the module's own detection (`Test-OrphanedSID`) also
checks deleted objects and performs AD lookups, so prefer `Remove-OrphanedSid` whenever it can
run.

## Preventive Measures

### 8. Validate Recent Backup Sets Automatically

```powershell
Import-Module OrphanedSid
# Private functions are reached through the module scope: & (Get-Module OrphanedSid) { <command> }

$root = 'D:\ACLBackups'
Get-ChildItem -Path $root -Directory | Where-Object CreationTime -gt (Get-Date).AddHours(-24) | ForEach-Object {
    $files = Get-ChildItem -Path $_.FullName -Filter *.xml
    # Test-BackupFileUsable is defined in the salvage example above
    $valid = @($files | Where-Object { Test-BackupFileUsable -Path $_.FullName }).Count
    [PSCustomObject]@{ BackupSet = $_.Name; Files = $files.Count; Valid = $valid }
} | Format-Table -AutoSize
```

Keep backup sets for at least as long as the change-review window; the module never deletes them.

## Support Information

When reporting a backup or restore problem, provide:

1. The correlation ID of the run (fourth bracketed field in every log line).
2. The `-BackupPath` used and a listing of the timestamped subfolder.
3. The `ErrorMessage` of each failed result, or the CSV from `-OutputPath`.
4. Whether the run used `-WhatIf`, `-Force`, or an interactive confirmation.

## Related Documentation

- `.\Documentation\Backup-and-Restore-Guide.md`
- `.\Troubleshooting\Common\Common-Issues.md`
- `.\Troubleshooting\Security\Security-Validation-Guide.md`
