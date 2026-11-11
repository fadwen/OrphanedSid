# ACL Backup and Restore Operations

## Overview

OrphanedSid backs up the full security descriptor of every Active Directory object it modifies
and can apply those backups again later. `Remove-OrphanedSid` writes the backup before any access
control entry is removed, and abandons the removal for an object whose backup could not be
written. `Restore-OrphanedSidBackup` reads the backups back. This document describes where
backups land, what they contain, and how the restore selects and validates them.

## Backup Operations

### Automatic Backup Creation

Every `Remove-OrphanedSid` run that is not a `-WhatIf` preview creates a backup for each object
before touching its ACL. `-BackupPath` is optional:

```powershell
# Backups written under C:\Backups\<yyyyMMdd_HHmmss>\
Remove-OrphanedSid -SearchBase "OU=Users,DC=contoso,DC=com" -BackupPath "C:\Backups"

# No -BackupPath: backups written under .\Backup\<yyyyMMdd_HHmmss>\ in the current directory
Remove-OrphanedSid -SearchBase "OU=Users,DC=contoso,DC=com"
```

The parent of `-BackupPath` must already exist; the folder itself and the per-run timestamped
subfolder are created on demand, and the log records `Created backup folder: <path>`. Each run
gets its own subfolder, so repeated runs never overwrite one another.

Under `-WhatIf` no backup folder or file is written, because no ACL is changed.

### Backup Function

Backups are produced by `New-ACLBackup` in `Private/Backup/New-ACLBackup.ps1`. It takes
`-ObjectDN`, `-ACL` (the `System.DirectoryServices.ActiveDirectorySecurity` object read from the
`AD:` drive), `-BackupPath` and an optional `-CorrelationId`. It returns `$true` when the file was
written and verified, `$false` when its own confirmation was declined, and throws when the write
or the verification fails. It is a private function and is not exported; `Remove-OrphanedSid` is
the supported way to create backups.

### Backup File Format

Each backup is one file written with `Export-Clixml`, so it is a CliXML document that
`Import-Clixml` reads back as a `PSCustomObject`.

- **Location**: `<BackupPath>\<yyyyMMdd_HHmmss>\` (the run timestamp)
- **File name**: `<SafeObjectName>_<yyyyMMdd_HHmmss>.xml`, where `SafeObjectName` is the object's
  distinguished name with every `\ / : * ? " < > | , =` character and every run of whitespace
  replaced by `_`. The name is limited to 200 characters, and less when the folder path is long
  enough that the full path would pass 259 characters; a longer name is cut and ends with
  `_<first 8 hex digits of the SHA256 of the DN>_truncated`, so two long DNs never share a name.
  The budget keeps room for a counter: a second backup of the same object in the same second is
  written as `..._<yyyyMMdd_HHmmss>_2.xml` rather than overwriting the first. A removal backs each
  object up once, before any of its entries is removed. The DN itself is recorded inside the file. For example `CN=User1,CN=Users,DC=contoso,DC=com`
  becomes `CN_User1_CN_Users_DC_contoso_DC_com_20250127_143022.xml`.
- **Integrity**: a SHA256 hash of the UTF-8 SDDL string, stored Base64-encoded in `SDDLHash`. The
  file is re-read immediately after writing and the hash and `ObjectDN` compared; a mismatch
  deletes the file and fails the backup.

### Backup File Contents

| Property | Value |
|----------|-------|
| `ObjectDN` | Distinguished name of the backed-up object |
| `BackupDate` | UTC time in `yyyy-MM-ddTHH:mm:ss.fffZ` format. Backups written by 1.0.1 and earlier hold local time with a literal `Z` |
| `CorrelationId` | Correlation ID of the run that created the backup |
| `SDDL` | Full security descriptor in SDDL form (all sections) |
| `SDDLHash` | Base64 SHA256 of the SDDL string |
| `BackupVersion` | `2.1` |
| `PowerShellVersion` | `$PSVersionTable.PSVersion` of the creating session |
| `UserContext` | `$env:USERNAME` |
| `ComputerName` | `$env:COMPUTERNAME` |
| `DomainContext` | `$env:USERDOMAIN` |
| `ScriptVersion` | Version of the OrphanedSid module that wrote the file. Backups written by 1.0.1 and earlier hold `2.1.0` |
| `ValidationSignature` | `PSSecurityBackup_v2.1` |
| `BackupMethod` | `New-ACLBackup` |
| `ACLEntryCount` | Number of access rules in the backed-up ACL |
| `Platform` | `$PSVersionTable.Platform`, or `Windows` when that is empty |
| `PSEdition` | `$PSVersionTable.PSEdition` |

## Restore Operations

### Using Restore-OrphanedSidBackup

`-BackupPath` is mandatory and must be the folder that directly contains the `.xml` files,
normally one of the timestamped subfolders; the search is not recursive. `-TargetObjectDN`
(aliases `DistinguishedName` and `SearchBase`, pipeline input accepted) names the object or
objects to restore.

```powershell
# Restore one object from the backups in a specific run folder
Restore-OrphanedSidBackup -TargetObjectDN "CN=User1,CN=Users,DC=contoso,DC=com" -BackupPath "C:\Backups\20250127_143022"

# Preview the restore without changing anything
Restore-OrphanedSidBackup -TargetObjectDN "CN=User1,CN=Users,DC=contoso,DC=com" -BackupPath "C:\Backups\20250127_143022" -WhatIf

# Restore several objects in one run
Restore-OrphanedSidBackup -TargetObjectDN @("CN=User1,CN=Users,DC=contoso,DC=com", "CN=User2,CN=Users,DC=contoso,DC=com") -BackupPath "C:\Backups\20250127_143022"

# Restore every backed-up object under an OU
Restore-OrphanedSidBackup -TargetObjectDN "OU=Users,DC=contoso,DC=com" -BackupPath "C:\Backups\20250127_143022"
```

The command processes each `-TargetObjectDN` value in turn and selects backup files as follows:

- **Bulk mode**: the value starts with `OU=` or `DC=`. Every object whose recorded `ObjectDN` is
  the target DN or ends with `,<target DN>` is restored.
- **Single mode**: any other value. Only files whose recorded `ObjectDN` equals the target DN
  (ignoring case) are candidates. No candidate is an error for that target; the run continues with
  the next one.

Selection reads the `ObjectDN` inside each file, not the file name. When the folder holds several
backups of one object, only the most recently modified file is used.

Under `-WhatIf` each selected backup is still read and validated, and one line
`What if: Performing the operation "Apply ACL from backup" on target "<DN>".` is printed per
object.

### Confirmation and -Force

`Remove-OrphanedSid` and `Restore-OrphanedSidBackup` both change Active Directory, so both declare
`ConfirmImpact = 'High'` and ask for confirmation once before they start. In an interactive
console this is a yes/no prompt. In a session that cannot answer (scheduled task, CI runner, no
host UI) the prompt fails with PowerShell's own host error; the command logs `Restore failed: ...`
(or `Removal failed: ...`) and raises a terminating error before anything is changed.

`-Force` (or `-Confirm:$false`) skips the prompt. `-WhatIf` never prompts.

```powershell
# Unattended restore
Restore-OrphanedSidBackup -TargetObjectDN "OU=Users,DC=contoso,DC=com" -BackupPath "C:\Backups\20250127_143022" -Force
```

### Restore Workflow Functions

`Restore-OrphanedSidBackup` hands each target to `Start-OrchestrationWorkflow -OperationType
'Restore'`, which calls `Invoke-RestoreWorkflow` (`Private/Backup/Invoke-RestoreWorkflow.ps1`)
with `-TargetObjectDN`, `-BackupPath`, `-VerifyRestoration` and the run's `-CorrelationId`
(plus `-WhatIf` when the command was given it). For each selected file `Restore-IndividualObject`
validates the backup, validates the target, and calls `Set-ObjectACL`
(`Private/Backup/Restore-ACLOperation.ps1`), which rebuilds the security descriptor from the
stored SDDL and applies it with `Set-Acl` on the `AD:` drive.

## Validation and Safety Features

### Backup Validation

Before a backup is applied, `Test-BackupIntegrity` (defined in
`Private/Backup/Test-BackupIntegrity.ps1`) runs at the `Standard` level and fails the restore of
that object on any of these:

- A missing or empty required property: `ObjectDN`, `BackupDate`, `SDDL`, `SDDLHash`,
  `ValidationSignature`
- A `ValidationSignature` other than `PSSecurityBackup_v1.0`, `PSSecurityBackup_v2.0` or
  `PSSecurityBackup_v2.1`
- An `ObjectDN` that does not match the target object
- A SHA256 of the stored `SDDL` that does not equal `SDDLHash`
- An `SDDL` string that cannot be parsed into a security descriptor

### Restore Verification

After the ACL is applied (not under `-WhatIf`), `Confirm-RestorationSuccess` reads the object's
current SDDL and compares its access control entries with the backup. At the default `Standard`
tolerance at least 80 percent of the expected entries must be present for the restore to be
reported as verified; `Strict` requires 100 percent and `Permissive` 60 percent. The tolerance is
fixed at `Standard` for restores run through `Restore-OrphanedSidBackup`, and the verification
result is attached to the restore result rather than changing its `Success` value.

### Safety Summary

- **Confirmation**: one prompt per run unless `-Force`, `-Confirm:$false` or `-WhatIf` is given
- **WhatIf**: `-WhatIf` lists what would be restored and writes nothing
- **Logging**: the start of each target and the summary, with its failed count, are logged with
  the run's correlation ID; the individual restore steps write to the verbose and warning streams
- **Failure isolation**: a failed object is recorded and the run continues with the next target

## Recovery Scenarios

### Rollback After a Removal

```powershell
# 1. Removal with backups
Remove-OrphanedSid -SearchBase "OU=Users,DC=contoso,DC=com" -BackupPath "C:\Backups" -Force

# 2. Find the run folder that was created (named by the run timestamp)
Get-ChildItem "C:\Backups" -Directory | Sort-Object Name -Descending | Select-Object -First 1

# 3. Restore everything under the OU from that folder
Restore-OrphanedSidBackup -TargetObjectDN "OU=Users,DC=contoso,DC=com" -BackupPath "C:\Backups\20250127_143022" -WhatIf
Restore-OrphanedSidBackup -TargetObjectDN "OU=Users,DC=contoso,DC=com" -BackupPath "C:\Backups\20250127_143022" -Force
```

### Selective Object Restoration

```powershell
$problemObjects = @(
    "CN=User1,CN=Users,DC=contoso,DC=com",
    "CN=User2,CN=Users,DC=contoso,DC=com"
)

Restore-OrphanedSidBackup -TargetObjectDN $problemObjects -BackupPath "C:\Backups\20250127_143022"
```

## Best Practices

1. Preview with `-WhatIf` before every restore.
2. Point `-BackupPath` at the exact run folder you intend to restore from.
3. Keep the correlation ID from the removal run; it is stored in each backup and appears in the
   run's log lines other than the object-discovery and per-object detection lines.
4. Store backup folders where only the operators who may restore them have access; a backup holds
   the complete security descriptor of each object.
5. Remove old run folders deliberately; the module never deletes backups.

## Troubleshooting

### Common Issues

- **Backup creation fails**: the account cannot write to the timestamped subfolder under
  `-BackupPath`. The log shows `Failed to create ACL backup for <DN> : <message>` followed by
  `SID removal workflow failed for <DN> : <message>`, the removal of that object is abandoned with
  the result's `ErrorMessage` set to `Workflow failed: <message>`, and the run continues.
- **"No backup files found for object ... in path ..."**: `-BackupPath` points at the base folder
  rather than a run subfolder, or no backup in the folder records exactly that `ObjectDN`.
- **"Backup validation failed: ..."**: a required property is missing, the signature is unknown, the
  `ObjectDN` does not match, or the SHA256 hash does not match the stored SDDL.
- **"Target validation failed: ..."**: the object no longer exists or cannot be read.
- **"Restore failed: ..." in a scheduled task or CI job**: the session could not answer the
  confirmation prompt; add `-Force` or `-WhatIf`.

See [Backup-Restore-Issues.md](../Troubleshooting/Common/Backup-Restore-Issues.md) for more.

### Log Analysis

Every operational log line carries the correlation ID in its fourth bracketed field:

```powershell
# All lines for one run (default log location)
Select-String -Path ".\Logs\Restore-OrphanedSidBackup_*.log" -Pattern "12345678-1234-1234-1234-123456789012"
```
