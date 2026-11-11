---
document type: cmdlet
external help file: OrphanedSid-Help.xml
HelpUri: ''
Locale: en-US
Module Name: OrphanedSid
ms.date: 11/08/2026
PlatyPS schema version: 2024-05-01
title: Remove-OrphanedSid
---

# Remove-OrphanedSid

## SYNOPSIS

Removes orphaned access control entries from Active Directory objects after backing up each ACL.

## SYNTAX

### __AllParameterSets

```
Remove-OrphanedSid [[-SearchBase] <string[]>] [[-BackupPath] <string>] [[-OutputPath] <string>]
 [[-MaxRetries] <int>] [[-ConfigPath] <string>] [[-MaxMemoryUsageMB] <int>] [[-LogPath] <string>]
 [[-CorrelationId] <string>] [[-LogLevel] <string>] [-Force] [-IncludeInherited]
 [-PreserveTempFiles] [-SuppressConsoleOutput] [-WhatIf] [-Confirm]
```

## DESCRIPTION

Runs the same discovery as Find-OrphanedSid and then, for every object that carries an
orphaned entry, validates each SID against the protected and well-known SID lists, writes a
Clixml backup of the object's ACL, and removes the orphaned entries.
The backup for a run
lands in a timestamped folder so a whole run can be undone with Restore-OrphanedSidBackup.

Only SIDs that every directory lookup confirmed missing are removed.
When a lookup fails for a reason other than "not found", such as a timeout, access denied or an
unreachable domain controller, the SID may still belong to a live principal: it is marked
Unverified, left in place, and named in a warning together with the lookup that failed.
The summary reports how many SIDs were unverified.
Re-run once the domain controller is reachable and the account can read the targets.

A SID from a trusted domain is removed only when that domain answers that the principal no
longer exists; an unreachable trusted domain leaves the SID unverified and in place.
Run Find-OrphanedSid or -WhatIf first and review entries with LikelySource Foreign Domain/Trust:
their owners sit outside the domain being cleaned.

The command has ConfirmImpact High: it asks once before changing anything.
-WhatIf previews
the run, listing the entries that would be removed, and creates no backup.
An unattended run
(scheduled task, CI) cannot answer the prompt and must pass -Force or -Confirm:$false.

Each removal is written to the pipeline as a RemovalOperationResult; -OutputPath writes the
discovered entries as CSV.

## EXAMPLES

### EXAMPLE 1

Remove-OrphanedSid -SearchBase 'OU=Decommissioned,DC=contoso,DC=com' -WhatIf

DESCRIPTION: Shows what would be removed without touching anything
OUTPUT: A WhatIf line for the run and one per object with entries that would be removed
USE CASE: The review step before a cleanup

### EXAMPLE 2

Remove-OrphanedSid -SearchBase 'OU=Decommissioned,DC=contoso,DC=com' -BackupPath 'D:\ADBackups'

DESCRIPTION: Prompts once, backs up every affected ACL to D:\ADBackups\<timestamp>\, then removes
OUTPUT: One RemovalOperationResult per object changed
USE CASE: An interactive cleanup with the backup on a dedicated drive

### EXAMPLE 3

Remove-OrphanedSid -SearchBase 'OU=Servers,DC=contoso,DC=com' -Force -CorrelationId 'CHG0012345' -OutputPath '.\Reports\CHG0012345.csv'

DESCRIPTION: Unattended removal tagged with a change number
OUTPUT: Result objects, a CSV, a log and a backup folder that all carry CHG0012345
USE CASE: A scheduled task or a pipeline step

## PARAMETERS

### -BackupPath

Folder that receives the per-run backup subfolder.
Defaults to .\Backup under the current
directory.
The parent folder must exist; the backup folder itself is created.

```yaml
Type: System.String
DefaultValue: ''
SupportsWildcards: false
Aliases: []
ParameterSets:
- Name: (All)
  Position: 1
  IsRequired: false
  ValueFromPipeline: false
  ValueFromPipelineByPropertyName: false
  ValueFromRemainingArguments: false
DontShow: false
AcceptedValues: []
HelpMessage: ''
```

### -ConfigPath

JSON configuration file; see Find-OrphanedSid for the keys read.
ProtectedSIDs and
WellKnownSIDPatterns are the ones that matter here.

```yaml
Type: System.String
DefaultValue: ''
SupportsWildcards: false
Aliases: []
ParameterSets:
- Name: (All)
  Position: 4
  IsRequired: false
  ValueFromPipeline: false
  ValueFromPipelineByPropertyName: false
  ValueFromRemainingArguments: false
DontShow: false
AcceptedValues: []
HelpMessage: ''
```

### -Confirm

Prompts you for confirmation before running the cmdlet.

```yaml
Type: System.Management.Automation.SwitchParameter
DefaultValue: ''
SupportsWildcards: false
Aliases:
- cf
ParameterSets:
- Name: (All)
  Position: Named
  IsRequired: false
  ValueFromPipeline: false
  ValueFromPipelineByPropertyName: false
  ValueFromRemainingArguments: false
DontShow: false
AcceptedValues: []
HelpMessage: ''
```

### -CorrelationId

Identifier carried through every log line, backup file and result.
Generated when omitted.

```yaml
Type: System.String
DefaultValue: '[System.Guid]::NewGuid().ToString()'
SupportsWildcards: false
Aliases: []
ParameterSets:
- Name: (All)
  Position: 7
  IsRequired: false
  ValueFromPipeline: false
  ValueFromPipelineByPropertyName: false
  ValueFromRemainingArguments: false
DontShow: false
AcceptedValues: []
HelpMessage: ''
```

### -Force

Proceed without the confirmation prompt.
Required for unattended runs.
-WhatIf still wins.

```yaml
Type: System.Management.Automation.SwitchParameter
DefaultValue: False
SupportsWildcards: false
Aliases: []
ParameterSets:
- Name: (All)
  Position: Named
  IsRequired: false
  ValueFromPipeline: false
  ValueFromPipelineByPropertyName: false
  ValueFromRemainingArguments: false
DontShow: false
AcceptedValues: []
HelpMessage: ''
```

### -IncludeInherited

Also evaluate inherited access control entries.
Inherited entries cannot be removed from the
child object, so they are not touched there: each is named in a Warning,
`Not removing inherited entry for orphaned SID <SID> on <DN>: it is inherited from a parent object, so remove it there`,
and the object is neither backed up nor changed for it. The explicit entry is
removed on the parent when the parent is in the search base.

```yaml
Type: System.Management.Automation.SwitchParameter
DefaultValue: False
SupportsWildcards: false
Aliases: []
ParameterSets:
- Name: (All)
  Position: Named
  IsRequired: false
  ValueFromPipeline: false
  ValueFromPipelineByPropertyName: false
  ValueFromRemainingArguments: false
DontShow: false
AcceptedValues: []
HelpMessage: ''
```

### -LogLevel

Lowest level written to the log file.
Security events are written at every level.
When omitted, -Verbose sets Verbose and -Debug sets Debug; without either, the LogLevel of
the -ConfigPath file applies, and Information when there is none.

```yaml
Type: System.String
DefaultValue: Information
SupportsWildcards: false
Aliases: []
ParameterSets:
- Name: (All)
  Position: 8
  IsRequired: false
  ValueFromPipeline: false
  ValueFromPipelineByPropertyName: false
  ValueFromRemainingArguments: false
DontShow: false
AcceptedValues: []
HelpMessage: ''
```

### -LogPath

Log file.
Defaults to .\Logs\Remove-OrphanedSid_<yyyyMMdd_HHmmss>.log.
An existing file is appended to; one larger than MaxLogFileSizeMB (default 10) is first renamed
to <name>_<yyyyMMdd_HHmmss>.log.

```yaml
Type: System.String
DefaultValue: ''
SupportsWildcards: false
Aliases: []
ParameterSets:
- Name: (All)
  Position: 6
  IsRequired: false
  ValueFromPipeline: false
  ValueFromPipelineByPropertyName: false
  ValueFromRemainingArguments: false
DontShow: false
AcceptedValues: []
HelpMessage: ''
```

### -MaxMemoryUsageMB

Working-set threshold in megabytes at which garbage collection is forced.
Default 1024.

```yaml
Type: System.Int32
DefaultValue: 1024
SupportsWildcards: false
Aliases: []
ParameterSets:
- Name: (All)
  Position: 5
  IsRequired: false
  ValueFromPipeline: false
  ValueFromPipelineByPropertyName: false
  ValueFromRemainingArguments: false
DontShow: false
AcceptedValues: []
HelpMessage: ''
```

### -MaxRetries

Retry attempts for a transient Active Directory failure on one object.
Default 3.

```yaml
Type: System.Int32
DefaultValue: 3
SupportsWildcards: false
Aliases: []
ParameterSets:
- Name: (All)
  Position: 3
  IsRequired: false
  ValueFromPipeline: false
  ValueFromPipelineByPropertyName: false
  ValueFromRemainingArguments: false
DontShow: false
AcceptedValues: []
HelpMessage: ''
```

### -OutputPath

CSV file for the discovered entries.
The parent folder must exist.

```yaml
Type: System.String
DefaultValue: ''
SupportsWildcards: false
Aliases: []
ParameterSets:
- Name: (All)
  Position: 2
  IsRequired: false
  ValueFromPipeline: false
  ValueFromPipelineByPropertyName: false
  ValueFromRemainingArguments: false
DontShow: false
AcceptedValues: []
HelpMessage: ''
```

### -PreserveTempFiles

Keep the streaming batch files after the run.

```yaml
Type: System.Management.Automation.SwitchParameter
DefaultValue: False
SupportsWildcards: false
Aliases: []
ParameterSets:
- Name: (All)
  Position: Named
  IsRequired: false
  ValueFromPipeline: false
  ValueFromPipelineByPropertyName: false
  ValueFromRemainingArguments: false
DontShow: false
AcceptedValues: []
HelpMessage: ''
```

### -SearchBase

Distinguished name of one or more containers to clean.
Accepts pipeline input.
Defaults to
the current domain root when omitted.

```yaml
Type: System.String[]
DefaultValue: ''
SupportsWildcards: false
Aliases:
- DistinguishedName
ParameterSets:
- Name: (All)
  Position: 0
  IsRequired: false
  ValueFromPipeline: true
  ValueFromPipelineByPropertyName: true
  ValueFromRemainingArguments: false
DontShow: false
AcceptedValues: []
HelpMessage: ''
```

### -SuppressConsoleOutput

Write progress and the summary to the log file only.

```yaml
Type: System.Management.Automation.SwitchParameter
DefaultValue: False
SupportsWildcards: false
Aliases: []
ParameterSets:
- Name: (All)
  Position: Named
  IsRequired: false
  ValueFromPipeline: false
  ValueFromPipelineByPropertyName: false
  ValueFromRemainingArguments: false
DontShow: false
AcceptedValues: []
HelpMessage: ''
```

### -WhatIf

Runs the command in a mode that only reports what would happen without performing the actions.

```yaml
Type: System.Management.Automation.SwitchParameter
DefaultValue: ''
SupportsWildcards: false
Aliases:
- wi
ParameterSets:
- Name: (All)
  Position: Named
  IsRequired: false
  ValueFromPipeline: false
  ValueFromPipelineByPropertyName: false
  ValueFromRemainingArguments: false
DontShow: false
AcceptedValues: []
HelpMessage: ''
```

### CommonParameters

This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable,
-InformationAction, -InformationVariable, -OutBuffer, -OutVariable, -PipelineVariable,
-ProgressAction, -Verbose, -WarningAction, and -WarningVariable. For more information, see
[about_CommonParameters](https://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

### System.String[]

Distinguished names, by value or by the `DistinguishedName` property of a piped object such as the
output of `Get-ADOrganizationalUnit` or `Get-ADObject`.
## OUTPUTS

### RemovalOperationResult

One object per object changed, covering all of its orphaned entries, with `ObjectDN`, `IntendedRemovals`, `ActualRemovals`,
`FailedRemovals`, `RemovedSIDs`, `FailedSIDs`, `BlockedSIDs`, `Success`, `ErrorMessage`,
`ProcessingTime`, `CorrelationId`, `SecurityValidation` and `BackupFile`, the full path of the
backup written before the change. Its folder is the one to pass to `Restore-OrphanedSidBackup
-BackupPath`. `BackupFile` is empty under `-WhatIf` and when the removal stopped before the backup.
## NOTES

Author: Jeffrey Stuhr
Blog: https://www.techbyjeff.net
LinkedIn: https://www.linkedin.com/in/jeffrey-stuhr-034214aa/

Requires the RSAT ActiveDirectory module and write access to the security descriptor of
every object under -SearchBase (Modify Permissions).
SIDs in ProtectedSIDs and SIDs that
match WellKnownSIDPatterns are never removed, and neither are SIDs a failed lookup left unverified.

TROUBLESHOOTING:
- Backups: https://github.com/fadwen/OrphanedSid/blob/main/Troubleshooting/Common/Backup-Restore-Issues.md
- Security validation: https://github.com/fadwen/OrphanedSid/blob/main/Troubleshooting/Security/Security-Validation-Guide.md
- Unverified SIDs: https://github.com/fadwen/OrphanedSid/blob/main/Troubleshooting/Security/Orphaned-SID-Issues.md


## RELATED LINKS

- [Find-OrphanedSid]()
- [Restore-OrphanedSidBackup]()
- [about_OrphanedSid]()
- [Backup and restore guide](https://github.com/fadwen/OrphanedSid/blob/main/Documentation/Backup-and-Restore-Guide.md)
- [Security validation guide](https://github.com/fadwen/OrphanedSid/blob/main/Troubleshooting/Security/Security-Validation-Guide.md)
