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
Find-OrphanedSid [[-SearchBase] <Object[]>] [[-OutputPath] <string>] [[-MaxRetries] <int>]
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
A summary (objects processed, orphaned SIDs found, unverified SIDs,
duration, peak memory) goes to the console and the log.

A SID is reported orphaned only when every directory lookup completed and none found it, or
when it is found only among deleted objects.
When no lookup found the SID but at least one failed for another reason, such as a timeout,
access denied or an unreachable domain controller, the SID may still belong to a live
principal. It is listed with VerificationStatus Unverified, Confidence Low and a
VerificationError that names each failed lookup, so it can be re-checked.
When a directory server cannot be contacted, the SID's remaining directory lookups are skipped
rather than each waiting for the same timeout, and VerificationError lists them after
"Not attempted because the directory server could not be contacted:".
Remove-OrphanedSid never removes an unverified SID.
Unverified results are not cached, so a later object or a later run looks the SID up again.

A SID from a trusted domain can only be checked by that domain.
When its domain controllers answer that the principal is gone, the SID is reported orphaned
with LikelySource Foreign Domain/Trust; review those rows before a removal, since the owner
sits outside the domain being cleaned.
When they cannot be reached or the trust is broken, the SID is reported Unverified, and each
such lookup waits for the trust to time out (about 40 seconds per SID in testing).

An account that cannot read a principal gets no error from Active Directory, only an empty
search, so missing read permission alone does not make a SID unverified.
Run the command as an account that can read every object in scope.

Results stream to batch files in the temp directory while the run is in progress; the files
are removed when the command finishes unless -PreserveTempFiles is set.

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
OUTPUT: The SIDs that appear most often across the top-level OUs
USE CASE: Deciding which deleted principals left the widest footprint

### EXAMPLE 4

$results = Find-OrphanedSid -SearchBase 'OU=Servers,DC=contoso,DC=com'
$results | Where-Object VerificationStatus -eq 'Unverified' |
        Select-Object ObjectDN, OrphanedSID, VerificationError

DESCRIPTION: Lists the SIDs a failed directory lookup left unverified, with the reason
OUTPUT: One row per unverified entry, naming each lookup that failed
USE CASE: Re-checking after a domain controller outage or a permissions problem before cleanup

## PARAMETERS

### -ConfigPath

JSON configuration file.
Only WellKnownSIDPatterns, ProtectedSIDs, BatchSize,
MemoryCheckInterval, LogLevel, LogFilePath, EnableLogFileRotation
and MaxLogFileSizeMB are read.
The file's LogLevel applies when -LogLevel, -Verbose and -Debug are all absent.
ProtectedSIDs and WellKnownSIDPatterns replace the default lists in full; repeat the defaults to
keep them. See about_OrphanedSid.

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
When omitted, -Verbose sets Verbose and -Debug sets Debug; without either, the LogLevel of
the -ConfigPath file applies, and Information when there is none.

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
When omitted, the LogFilePath of the -ConfigPath file is used if it sets one, and otherwise
.\Logs\Find-OrphanedSid_<yyyyMMdd_HHmmss>.log under the current directory.
An existing file is appended to; one larger than MaxLogFileSizeMB (default 10) is first renamed
to <name>_<yyyyMMdd_HHmmss>.log.

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

Retries after the first attempt for each directory read that fails with an error that looks
transient, such as a timeout or a busy or unavailable server: the read of each search base, and
each lookup of a SID. Default 3, so a read is tried up to four times.
A domain controller that cannot be contacted is not retried; the SID is reported Unverified.

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

Keep the streaming batch files under $env:TEMP\OrphanedSid-<CorrelationId>\ for
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

Distinguished name of one or more containers to search, or objects that carry one.
Accepts pipeline input. A string is used as the DN; any other object contributes its
DistinguishedName property, so the output of Get-ADOrganizationalUnit or Get-ADObject, and
Import-Csv rows with a DistinguishedName column, can be piped directly. An item with no
DistinguishedName is reported as an error and skipped.
When -SearchBase is not given, the current domain root is searched. Input that yields no usable
DN stops the command instead.

```yaml
Type: System.Object[]
DefaultValue: ''
SupportsWildcards: false
Aliases:
- DistinguishedName
ParameterSets:
- Name: (All)
  Position: 0
  IsRequired: false
  ValueFromPipeline: true
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

### CommonParameters

This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable,
-InformationAction, -InformationVariable, -OutBuffer, -OutVariable, -PipelineVariable,
-ProgressAction, -Verbose, -WarningAction, and -WarningVariable. For more information, see
[about_CommonParameters](https://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

### System.Object[]

Distinguished names as strings, or objects with a `DistinguishedName` property: the output of
`Get-ADOrganizationalUnit` or `Get-ADObject`, or `Import-Csv` rows with that column.
## OUTPUTS

### OrphanedSIDResult

One object per orphaned access control entry, with `ObjectDN`, `ObjectClass`, `OrphanedSID`,
`LikelySource`, `Confidence`, `AnalysisNotes`, `AccessControlType`, `ActiveDirectoryRights`,
`InheritanceType`, `ObjectType`, `InheritedObjectType`, `IsInherited`, `ProcessingMethod`,
`ActionTaken`, `VerificationStatus`, `VerificationError`, `CorrelationId` and `Timestamp`, plus the
note properties `ProcessingContext` and `ProcessingStatistics`.

`VerificationStatus` is `Orphaned` when every lookup completed and none found the SID, or the
SID was found only among deleted objects, and `Unverified` when a lookup failed;
`VerificationError` then names each failed lookup and any lookup not attempted.
## NOTES

Author: Jeffrey Stuhr
Blog: https://www.techbyjeff.net
LinkedIn: https://www.linkedin.com/in/jeffrey-stuhr-034214aa/

Requires the RSAT ActiveDirectory module and read access to the objects under -SearchBase.

TROUBLESHOOTING:
- Common issues: https://github.com/fadwen/OrphanedSid/blob/main/Troubleshooting/Common/Common-Issues.md
- Security descriptors: https://github.com/fadwen/OrphanedSid/blob/main/Troubleshooting/Security/Security-Descriptor-Issues.md
- Unverified SIDs: https://github.com/fadwen/OrphanedSid/blob/main/Troubleshooting/Security/Orphaned-SID-Issues.md
- Memory: https://github.com/fadwen/OrphanedSid/blob/main/Troubleshooting/Performance/Memory-Management.md


## RELATED LINKS

- [Remove-OrphanedSid]()
- [Restore-OrphanedSidBackup]()
- [about_OrphanedSid]()
- [Common issues](https://github.com/fadwen/OrphanedSid/blob/main/Troubleshooting/Common/Common-Issues.md)
- [Security descriptor issues](https://github.com/fadwen/OrphanedSid/blob/main/Troubleshooting/Security/Security-Descriptor-Issues.md)
- [Memory management](https://github.com/fadwen/OrphanedSid/blob/main/Troubleshooting/Performance/Memory-Management.md)
