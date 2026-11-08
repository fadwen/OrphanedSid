---
document type: cmdlet
external help file: OrphanedSid-Help.xml
HelpUri: ''
Locale: en-US
Module Name: OrphanedSid
ms.date: 11/08/2026
PlatyPS schema version: 2024-05-01
title: Restore-OrphanedSidBackup
---

# Restore-OrphanedSidBackup

## SYNOPSIS

Restores Active Directory ACLs from a backup folder written by Remove-OrphanedSid.

## SYNTAX

### __AllParameterSets

```
Restore-OrphanedSidBackup [-TargetObjectDN] <string[]> [-BackupPath] <string>
 [[-OutputPath] <string>] [[-LogPath] <string>] [[-CorrelationId] <string>] [[-LogLevel] <string>]
 [-Force] [-SuppressConsoleOutput] [-WhatIf] [-Confirm]
```

## DESCRIPTION

Reads the Clixml backup files in -BackupPath, validates each one (format, object DN, SDDL
and its SHA256 hash), applies the saved security descriptor to the object, and reads the
ACL back to verify the result.

-TargetObjectDN decides the scope.
A container (an OU or the domain root) restores every
backup whose object sits under it.
A single object restores its most recent matching
backup.
-BackupPath is the folder that holds the .xml files, normally one timestamped run
folder under the Remove-OrphanedSid backup root.

The command has ConfirmImpact High: it asks once before writing anything.
-WhatIf previews
the restore.
An unattended run must pass -Force or -Confirm:$false.

One result object per restored object is written to the pipeline; -OutputPath writes the
same rows as CSV.

## EXAMPLES

### EXAMPLE 1

Restore-OrphanedSidBackup -TargetObjectDN 'CN=SRV01,OU=Servers,DC=contoso,DC=com' -BackupPath '.\Backup\20260703_104232' -WhatIf

DESCRIPTION: Shows which backup file would be applied to SRV01
OUTPUT: A WhatIf line naming the backup and the object
USE CASE: Confirming the right run folder before a rollback

### EXAMPLE 2

Restore-OrphanedSidBackup -TargetObjectDN 'OU=Servers,DC=contoso,DC=com' -BackupPath 'D:\ADBackups\20260703_104232' -Force

DESCRIPTION: Rolls back every object under the Servers OU from one run's backups, unattended
OUTPUT: One result per object with Success, EntriesRestored and any error
USE CASE: Undoing a cleanup that removed an entry still in use

### EXAMPLE 3

Import-Csv .\Reports\CHG0012345.csv | Select-Object -ExpandProperty ObjectDN -Unique |
        Restore-OrphanedSidBackup -BackupPath 'D:\ADBackups\20260703_104232' -Force

DESCRIPTION: Restores exactly the objects a removal run reported
OUTPUT: One result per object
USE CASE: Targeted rollback driven by the removal's own CSV

## PARAMETERS

### -BackupPath

Folder containing the backup .xml files.
Must exist.

```yaml
Type: System.String
DefaultValue: ''
SupportsWildcards: false
Aliases: []
ParameterSets:
- Name: (All)
  Position: 1
  IsRequired: true
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

Identifier carried through every log line and result.
Generated when omitted.

```yaml
Type: System.String
DefaultValue: '[System.Guid]::NewGuid().ToString()'
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

### -Force

Proceed without the confirmation prompt.
Required for unattended runs.

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

```yaml
Type: System.String
DefaultValue: Information
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

### -LogPath

Log file.
Defaults to .\Logs\Restore-OrphanedSidBackup_<yyyyMMdd_HHmmss>.log.

```yaml
Type: System.String
DefaultValue: ''
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

CSV file for the restore results.
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

### -TargetObjectDN

Distinguished name of the object or container to restore.
Accepts pipeline input.

```yaml
Type: System.String[]
DefaultValue: ''
SupportsWildcards: false
Aliases:
- DistinguishedName
- SearchBase
ParameterSets:
- Name: (All)
  Position: 0
  IsRequired: true
  ValueFromPipeline: true
  ValueFromPipelineByPropertyName: true
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

### RestoreWorkflowResult

One object per target. For a container it summarises the run (`TotalObjects`,
`SuccessfulRestores`, `FailedRestores`, `IndividualResults`); for a single object it is that
object's restore result. Both carry `Success`, `TargetObjectDN`, `EntriesRestored`, `ErrorMessage`
and `CorrelationId`.
## NOTES

Author: Jeffrey Stuhr
Blog: https://www.techbyjeff.net
LinkedIn: https://www.linkedin.com/in/jeffrey-stuhr-034214aa/

Requires the RSAT ActiveDirectory module and write access to the security descriptor of
each target object.

TROUBLESHOOTING:
- Backups and restores: https://github.com/fadwen/OrphanedSid/blob/main/Troubleshooting/Common/Backup-Restore-Issues.md


## RELATED LINKS

- [Remove-OrphanedSid]()
- [Find-OrphanedSid]()
- [about_OrphanedSid]()
- [Backup and restore guide](https://github.com/fadwen/OrphanedSid/blob/main/Documentation/Backup-and-Restore-Guide.md)
- [Backup and restore issues](https://github.com/fadwen/OrphanedSid/blob/main/Troubleshooting/Common/Backup-Restore-Issues.md)
