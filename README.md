# OrphanedSid

[![PowerShell Gallery](https://img.shields.io/powershellgallery/v/OrphanedSid?label=PowerShell%20Gallery)](https://www.powershellgallery.com/packages/OrphanedSid)
[![Gallery downloads](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/fadwen/OrphanedSid/badges/downloads.json)](https://www.powershellgallery.com/packages/OrphanedSid)
[![Quality Gates](https://github.com/fadwen/OrphanedSid/actions/workflows/quality-gates.yml/badge.svg)](https://github.com/fadwen/OrphanedSid/actions/workflows/quality-gates.yml)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207.x%20(Windows)-blue)](https://github.com/PowerShell/PowerShell)
[![License](https://img.shields.io/badge/license-MIT-green)](./LICENSE)

Finds access control entries in Active Directory that still grant rights to principals that no
longer exist, removes them with a backup of every ACL it touches, and restores an ACL from that
backup.

## Overview

**Business value:** Orphaned SIDs are access control entries whose trustee was deleted. They
accumulate on every object as users, groups and computers are retired, they grant nothing to
anyone, and they are the first thing an auditor asks about when reviewing delegated permissions.
This module finds them, removes them safely, and can put an ACL back if a removal turns out to be
wrong.

**Technical summary:** Three commands over a shared engine. Discovery walks the objects under a
search base, reads each security descriptor, resolves every identity reference and reports the
ones that do not resolve. Removal validates each SID against protected and well-known lists, backs
the ACL up as Clixml, then strips the orphaned entries. Restore validates the backup's hash and
applies it. Discovery results stream to batch files on disk while the run is in progress.

### Key features

- **Objects on the pipeline.** One `OrphanedSIDResult` per orphaned entry, one
  `RemovalOperationResult` per object changed, one restore result per target. `-OutputPath` also
  writes CSV.
- **Backup before change.** Every `Remove-OrphanedSid` run writes one Clixml file per modified
  object into a timestamped folder; `Restore-OrphanedSidBackup` validates the SHA256 hash before
  applying it.
- **Protected SIDs.** The BUILTIN Administrators, Users and Guests groups, SYSTEM, LOCAL SERVICE and
  NETWORK SERVICE are never removed, and well-known SIDs are never reported as orphaned. Objects whose
  DN matches a critical pattern (Domain Admins, Enterprise Admins, Schema Admins, BUILTIN, the Users
  and Computers containers) are flagged high risk. The configuration file can replace the first two
  lists.
- **A failed lookup is not an orphan.** A SID is reported orphaned only when every directory lookup
  completed and none found it. When a lookup fails with a timeout, access denied or an unreachable
  domain controller, the entry is reported with `VerificationStatus = Unverified` and the failure in
  `VerificationError`, and `Remove-OrphanedSid` leaves it in place. A SID from a trusted domain is
  orphaned only when that domain answers that the principal is gone; an unreachable trust leaves it
  unverified. See [SIDs from a trusted domain](./Troubleshooting/Security/Orphaned-SID-Issues.md#6-sids-from-a-trusted-domain).
- **Confirmation gate.** `Remove-OrphanedSid` and `Restore-OrphanedSidBackup` have
  `ConfirmImpact = 'High'`: they prompt once, `-WhatIf` previews, and an unattended run needs
  `-Force`.
- **Correlation tracking.** One correlation ID per run, carried through every log line, backup
  file and result row. Pass your own with `-CorrelationId` to tie a run to a change record.
- **Audit log that survives filtering.** Security events are written to the log file at every
  `-LogLevel`.

### Target audience

- **Active Directory administrators** cleaning up delegated permissions.
- **Security teams** auditing which objects carry rights for deleted principals.
- **Compliance teams** who need a CSV and a correlated log per run.

## Quick start

```powershell
Install-PSResource -Name OrphanedSid -Scope CurrentUser -TrustRepository

# Discovery: nothing is changed
Find-OrphanedSid -SearchBase 'OU=Users,DC=contoso,DC=com' -OutputPath '.\Reports\audit.csv'

# Preview a removal, then do it
Remove-OrphanedSid -SearchBase 'OU=Decommissioned,DC=contoso,DC=com' -WhatIf
Remove-OrphanedSid -SearchBase 'OU=Decommissioned,DC=contoso,DC=com' -BackupPath 'D:\ADBackups'

# Undo it from the run's backup folder
Restore-OrphanedSidBackup -TargetObjectDN 'OU=Decommissioned,DC=contoso,DC=com' -BackupPath 'D:\ADBackups\20260703_104232'
```

The console shows progress and a summary block. The same lines, with timestamps and the correlation
ID, go to `.\Logs\<Command>_<yyyyMMdd_HHmmss>.log` under the current directory.

## Prerequisites

| Component | Requirement | Notes |
| --- | --- | --- |
| PowerShell | Windows PowerShell 5.1, or PowerShell 7.x on Windows | The ActiveDirectory module is Windows-only |
| ActiveDirectory module | RSAT: Active Directory PowerShell | Not on the Gallery; install RSAT |
| Domain | Domain-joined machine with line of sight to a domain controller | |
| Rights | Read for discovery; Modify Permissions on the target objects for removal and restore | Commands run as the caller |

```powershell
# Windows 10 / 11
Add-WindowsCapability -Online -Name 'Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0'

# Windows Server
Install-WindowsFeature -Name RSAT-AD-PowerShell
```

## Installation

```powershell
# PowerShell Gallery
Install-PSResource -Name OrphanedSid -Scope CurrentUser -TrustRepository

# From a clone
git clone https://github.com/fadwen/OrphanedSid.git
Import-Module .\OrphanedSid\OrphanedSid.psd1
```

On Windows PowerShell 5.1 without PSResourceGet, use `Install-Module -Name OrphanedSid`.

## Usage

### Discovery across several OUs

```powershell
Get-ADOrganizationalUnit -Filter * -SearchScope OneLevel |
    Find-OrphanedSid -IncludeInherited |
    Group-Object OrphanedSID |
    Sort-Object Count -Descending
```

`-SearchBase` accepts pipeline input by value or from the `DistinguishedName` property.
`-IncludeInherited` also reports entries inherited from parent containers.

### Removal, unattended, tagged with a change number

```powershell
Remove-OrphanedSid -SearchBase 'OU=Servers,DC=contoso,DC=com' -Force `
    -BackupPath 'D:\ADBackups' -OutputPath '.\Reports\CHG0012345.csv' -CorrelationId 'CHG0012345'
```

Backups land in `D:\ADBackups\<yyyyMMdd_HHmmss>\`, one `.xml` per modified object, named from
the object's distinguished name with path-unsafe characters, `,`, `=` and spaces replaced by `_`.

### Targeted rollback from a removal's own CSV

```powershell
Import-Csv .\Reports\CHG0012345.csv |
    Select-Object -ExpandProperty ObjectDN -Unique |
    Restore-OrphanedSidBackup -BackupPath 'D:\ADBackups\20260703_104232' -Force
```

### Scheduled task

```powershell
$report = "C:\Reports\orphaned-sids-$(Get-Date -Format yyyyMMdd).csv"
$results = @(Find-OrphanedSid -SearchBase 'DC=contoso,DC=com' -OutputPath $report -SuppressConsoleOutput)
$found = @($results | Where-Object VerificationStatus -eq 'Orphaned')
$unverified = @($results | Where-Object VerificationStatus -eq 'Unverified')
if ($results.Count -gt 0) {
    $subject = "Orphaned SIDs found: $($found.Count), unverified: $($unverified.Count)"
    Send-MailMessage -To 'security-alerts@contoso.com' -From 'ad-hygiene@contoso.com' `
        -SmtpServer 'smtp.contoso.com' -Subject $subject -Body "Report: $report"
}
```

An unverified entry is a SID that no lookup found but at least one lookup failed to check, so it may
still belong to a live principal. `VerificationError` names each failed lookup; re-run once the
cause is fixed.

### Configuration file

`-ConfigPath` accepts a JSON file. Only these top-level keys are read:

| Key | Range | Effect |
| --- | --- | --- |
| `WellKnownSIDPatterns` | regex list | Matching identity references are never reported; **replaces the default list in full** |
| `ProtectedSIDs` | SID list | Never removed, even if unresolvable; **replaces the default list in full** |
| `BatchSize` | 1-1000 | Results per streaming batch file (default 50) |
| `MemoryCheckInterval` | 1-1000 | Operations between memory checks (default 50) |
| `LogLevel` | Critical to Verbose | File log level when the command line sets none; `-LogLevel`, `-Verbose` and `-Debug` win |
| `LogFilePath`, `EnableLogFileRotation`, `MaxLogFileSizeMB` | | Logging behaviour |

A file that sets either SID list uses exactly that list; to add to the defaults, repeat them in the
file. [Automation](Documentation/Automation.md#the-two-sid-lists-replace-the-defaults) shows how
to start a file from the defaults and what stays protected regardless.

Everything else is a command parameter. See `Get-Help Find-OrphanedSid -Full` and
`Get-Help about_OrphanedSid`.

## Architecture

```text
OrphanedSid/
├── OrphanedSid.psd1 / .psm1     # Manifest and loader (Classes, then Private by area, then Public)
├── Public/                      # Find-OrphanedSid, Remove-OrphanedSid, Restore-OrphanedSidBackup
├── Private/                     # One function per file, grouped by area
│   ├── Core/                        # Session start/stop, Invoke-MainProcessingLogic, orchestration
│   ├── SID/                         # Format, orphan test, identity resolution, analysis, security
│   ├── Security/                    # Security descriptor retrieval, validation, verification
│   ├── ACL/                         # Read, modify and write ACLs
│   ├── Backup/                      # New-ACLBackup, backup discovery, validation, restore workflow
│   ├── ActiveDirectory/             # Object enumeration with retry
│   ├── Logging/                     # Structured and security logging
│   └── FileSystem/, System/, Operations/, Reporting/, Utilities/
├── Classes/                     # Configuration, memory manager, streaming results, result types
├── Tests/                       # Pester 6; runs without RSAT (Tests/TestHelpers/ADCmdletStubs.ps1)
├── docs/OrphanedSid/            # PlatyPS Markdown, the source of the command help
├── en-US/                       # Compiled MAML and about_OrphanedSid
├── Build/                       # Build-Help.ps1, Publish-Module.ps1
├── Documentation/, Troubleshooting/
└── Tools/Generate-OrphanedSIDs.ps1   # Seeds a lab domain with orphaned SIDs for testing
```

## Troubleshooting

Start with the log file. Every line carries the correlation ID:

```powershell
Select-String -Path .\Logs\*.log -Pattern '<correlation id>'
```

| Symptom | Where to look |
| --- | --- |
| `The ActiveDirectory PowerShell module is not available` | [Prerequisites](#prerequisites) |
| A prompt appears in a scheduled task, or a `-Confirm` error in a non-interactive session | Pass `-Force` to `Remove-OrphanedSid` or `Restore-OrphanedSidBackup` |
| `All security descriptor retrieval methods failed for <DN>` | [Security descriptor issues](./Troubleshooting/Security/Security-Descriptor-Issues.md) |
| Results with `VerificationStatus = Unverified`, or `Not removing unverified SID` warnings | [Unverified SIDs](./Troubleshooting/Security/Orphaned-SID-Issues.md#5-unverified-sids) |
| `Memory usage threshold exceeded` warnings | [Memory management](./Troubleshooting/Performance/Memory-Management.md) |
| `Backup validation failed` on restore | [Backup and restore issues](./Troubleshooting/Common/Backup-Restore-Issues.md) |

Guides by area: [Common](./Troubleshooting/Common/), [Security](./Troubleshooting/Security/),
[Performance](./Troubleshooting/Performance/), [Integration](./Troubleshooting/Integration/).
Longer references: [Backup and Restore Guide](./Documentation/Backup-and-Restore-Guide.md),
[Automation Guide](./Documentation/Automation.md),
[Security Logging](./Documentation/Security-Logging-Compliance.md).

## Development

```powershell
Invoke-ScriptAnalyzer -Path ./Private -Recurse -Severity Error, Warning   # and Public, Classes, Build
Invoke-Pester ./Tests                                                      # Pester 6, no domain needed
./Build/Build-Help.ps1                                                     # rebuild MAML after editing docs/
./Build/Publish-Module.ps1 -WhatIf                                         # release rehearsal
```

Conventions come from [ai-powershell-standards](https://github.com/fadwen/ai-powershell-standards)
and are mirrored into `.github/` and `.claude/` by a weekly workflow. See [CLAUDE.md](./CLAUDE.md)
for the invariants specific to this module.

## Blog posts

The [OrphanedSid series](https://www.techbyjeff.net/series/orphanedsid/) on techbyjeff.net:

- [OrphanedSid: Find, Remove, Restore](https://www.techbyjeff.net/orphanedsid-find-remove-restore/)
- [Why Find-UnknownSID Left My Monorepo](https://www.techbyjeff.net/why-find-unknownsid-left-my-monorepo/)
- [Moving 2,400 Tests From Pester 3.4 to Pester 6](https://www.techbyjeff.net/migrating-2400-tests-from-pester-3-to-6/)

## History

The code began as `Find-UnknownSID.ps1` in [fadwen/TechbyJeff](https://github.com/fadwen/TechbyJeff)
and is described in two posts on [techbyjeff.net](https://www.techbyjeff.net):
[Understanding Orphaned SIDs in Active Directory](https://www.techbyjeff.net/understanding-orphaned-sids-in-active-directory/)
and
[Testing Security Functions with Pester](https://www.techbyjeff.net/testing-security-functions-with-pester-a-real-world-example/).
`Documentation/Archive/` keeps the development history from that period.
