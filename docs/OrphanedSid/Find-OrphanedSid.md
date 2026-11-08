---
document type: cmdlet
external help file: OrphanedSid-Help.xml
HelpUri: ''
Locale: en-US
Module Name: OrphanedSid
ms.date: 11/08/2026
PlatyPS schema version: 2024-05-01
title: Find-OrphanedSid
---

# Find-OrphanedSid

## SYNOPSIS

Finds access control entries in Active Directory that grant rights to principals that no longer exist.

## SYNTAX

### __AllParameterSets

```
Find-OrphanedSid [[-SearchBase] <string[]>] [[-OutputPath] <string>] [[-MaxRetries] <int>]
 [[-ConfigPath] <string>] [[-MaxMemoryUsageMB] <int>] [[-LogPath] <string>]
 [[-CorrelationId] <string>] [[-LogLevel] <string>] [-IncludeInherited] [-PreserveTempFiles]
 [-SuppressConsoleOutput]
```

## DESCRIPTION

Walks every object under one or more search bases, reads each security descriptor, resolves
every identity reference, and reports the ones that cannot be resolved.
Nothing is changed.

Each orphaned access control entry is written to the pipeline as an OrphanedSIDResult with
the object's distinguished name, the unresolvable SID, the rights it still grants, and an
analysis of where the SID probably came from.
The same rows are written to -OutputPath as
CSV when that parameter is given.
A summary (objects processed, orphaned SIDs found,
duration, peak memory) goes to the console and the log.

Results stream to batch files in the temp directory while the run is in progress so memory
stays flat on large OUs; the files are removed when the command finishes unless
-PreserveTempFiles is set.

## EXAMPLES

### EXAMPLE 1

Find-OrphanedSid -SearchBase 'OU=Users,DC=contoso,DC=com'

DESCRIPTION: Lists every orphaned ACE under the Users OU
OUTPUT: One OrphanedSIDResult per orphaned access control entry
USE CASE: A first look at how much cleanup an OU needs

### EXAMPLE 2

Find-OrphanedSid -SearchBase 'DC=contoso,DC=com' -IncludeInherited -OutputPath '.\Reports\audit.csv'

DESCRIPTION: Audits the whole domain including inherited entries and keeps a CSV
OUTPUT: Result objects on the pipeline and the same rows in audit.csv
USE CASE: Periodic compliance evidence

### EXAMPLE 3

Get-ADOrganizationalUnit -Filter * -SearchScope OneLevel |
        Find-OrphanedSid |
        Group-Object OrphanedSID |
        Sort-Object Count -Descending

DESCRIPTION: Pipes OUs in and groups the findings by SID
OUTPUT: The SIDs that appear most often across the domain
USE CASE: Deciding which deleted principals left the widest footprint

## PARAMETERS

### -ConfigPath

JSON configuration file.
Only WellKnownSIDPatterns, ProtectedSIDs, BatchSize,
MemoryCheckInterval, EnableDetailedLogging, LogLevel, LogFilePath, EnableLogFileRotation
and MaxLogFileSizeMB are read.

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

### -CorrelationId

Identifier carried through every log line and result row.
Generated when omitted.

```yaml
Type: System.String
DefaultValue: '[System.Guid]::NewGuid().ToString()'
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

### -IncludeInherited

Also report access control entries inherited from parent containers.
More rows and a longer
run; by default only explicit entries are reported.

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
  Position: 7
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
Defaults to .\Logs\Find-OrphanedSid_<yyyyMMdd_HHmmss>.log under the current
directory.

```yaml
Type: System.String
DefaultValue: ''
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
  Position: 4
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
  Position: 2
  IsRequired: false
  ValueFromPipeline: false
  ValueFromPipelineByPropertyName: false
  ValueFromRemainingArguments: false
DontShow: false
AcceptedValues: []
HelpMessage: ''
```

### -OutputPath

CSV file to write the results to, in addition to the pipeline.
The parent folder must exist.

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

### -PreserveTempFiles

Keep the streaming batch files under $env:TEMP\Find-UnknownSID-<CorrelationId>\ for
inspection after the run.

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

Distinguished name of one or more containers to search.
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

### OrphanedSIDResult

One object per orphaned access control entry, with `ObjectDN`, `ObjectClass`, `OrphanedSID`,
`LikelySource`, `Confidence`, `AnalysisNotes`, `AccessControlType`, `ActiveDirectoryRights`,
`InheritanceType`, `ObjectType`, `InheritedObjectType`, `IsInherited`, `ProcessingMethod`,
`ActionTaken`, `CorrelationId` and `Timestamp`.
## NOTES

Author: Jeffrey Stuhr
Blog: https://www.techbyjeff.net
LinkedIn: https://www.linkedin.com/in/jeffrey-stuhr-034214aa/

Requires the RSAT ActiveDirectory module and read access to the objects under -SearchBase.

TROUBLESHOOTING:
- Common issues: https://github.com/fadwen/OrphanedSid/blob/main/Troubleshooting/Common/Common-Issues.md
- Security descriptors: https://github.com/fadwen/OrphanedSid/blob/main/Troubleshooting/Security/Security-Descriptor-Issues.md
- Memory: https://github.com/fadwen/OrphanedSid/blob/main/Troubleshooting/Performance/Memory-Management.md


## RELATED LINKS

- [Remove-OrphanedSid]()
- [Restore-OrphanedSidBackup]()
- [about_OrphanedSid]()
- [Common issues](https://github.com/fadwen/OrphanedSid/blob/main/Troubleshooting/Common/Common-Issues.md)
- [Security descriptor issues](https://github.com/fadwen/OrphanedSid/blob/main/Troubleshooting/Security/Security-Descriptor-Issues.md)
- [Memory management](https://github.com/fadwen/OrphanedSid/blob/main/Troubleshooting/Performance/Memory-Management.md)
