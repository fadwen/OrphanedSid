# Test Map

What each folder under `Tests/` covers and which helpers it relies on. The suite targets Pester 6
on Windows PowerShell 5.1 and PowerShell 7, needs no Active Directory domain, and runs in
[Quality Gates](https://github.com/fadwen/OrphanedSid/actions/workflows/quality-gates.yml). How to
run it is in [Documentation/Quick-Test-Reference.md](../Documentation/Quick-Test-Reference.md).

## Layout

```text
Tests/
├── Unit/
│   ├── Classes/            One file per class in Classes/
│   ├── Public/             One file per exported command
│   └── Private/<Area>/     One file per private function, mirroring Private/<Area>/
├── Integration/            The three public commands end to end against an in-memory directory
├── TestHelpers/            Active Directory cmdlet stubs and logging set-up, dot-sourced from BeforeAll
└── PSScriptAnalyzerSettings.psd1   Relaxed analyzer rules for Tests/ and Tools/
```

## Unit

| Folder | Covers |
| --- | --- |
| `Unit/Classes` | `ScriptConfiguration` (defaults, JSON overrides, validation), `MemoryManager`, `StreamingResultsManager` (batching, export, disposal), `ProcessingStatistics`, `OrphanedSIDResult`, `SIDAnalysisResult`, `SecurityValidationResult`, `RemovalOperationResult`, `RestoreOperationResult` |
| `Unit/Public` | `Find-OrphanedSid`, `Remove-OrphanedSid`, `Restore-OrphanedSidBackup`: parameter validation, pipeline input, the confirmation gate, result emission, session start and stop. The engine is mocked with `Mock -ModuleName OrphanedSid` |
| `Unit/Private/ACL` | `Get-ACLForRemoval`, `Invoke-SIDRemoval`, `Set-ModifiedACL` |
| `Unit/Private/ActiveDirectory` | `Get-ADObjectFromSearchBase`, `Get-ADObjectsSequential`, `Invoke-ADOperationWithRetry`, `Test-ValidDistinguishedName` |
| `Unit/Private/Backup` | `New-ACLBackup`, `Test-BackupIntegrity` at each level, `Invoke-RestoreWorkflow` and `Invoke-RestoreWorkflow.SingleObject` (single-object restore and container scope), `Restore-IndividualObject`, `Restore-ACLOperation` (`Set-ObjectACL` with its helpers mocked) and `Restore-ACLOperation.Helpers` (`Get-RestorationTarget` and `Confirm-RestorationSuccess` for real) |
| `Unit/Private/Core` | `Initialize-ScriptExecution`, `Invoke-MainProcessingLogic`, `Start-OrchestrationWorkflow`, `Remove-OrphanedSidEntry`, `Start-OrphanedSidSession`, `Stop-OrphanedSidSession` |
| `Unit/Private/FileSystem` | `Initialize-LogDirectory` |
| `Unit/Private/Logging` | `Initialize-LoggingConfiguration`, `Initialize-LoggingSystem` (including `Test-LogLevel`), `Format-LogMessage`, `Write-StructuredLogEntry`, `Write-StructuredLog`, `Write-SecurityStructuredLogEntry`, `Write-SecurityLog`, `Write-ADOperationSecurityLog`, `Write-RemovalSecurityLog` |
| `Unit/Private/Operations` | `Invoke-OperationWithRetry`, `Invoke-RemovalWorkflow` |
| `Unit/Private/Reporting` | `Write-ProcessingSummary` (parameters) and `Write-ProcessingSummary.Scenarios` (discovery, removal and restore results, CSV export) |
| `Unit/Private/Security` | `Get-SecurityDescriptor` (`Get-ObjectAccessRule` and its retrieval strategies), `Invoke-SecurityValidation`, `Invoke-RemovalVerification` |
| `Unit/Private/SID` | `Test-SIDFormat` (with `Test-WellKnownSID`), `Test-OrphanedSID` end to end and `Test-OrphanedSID.Resolution` (each lookup in the resolution order, the validation cache), `Resolve-SIDIdentity` (availability) and `Test-AccessRuleForOrphanedSID` (the resolution helpers for real), `Find-OrphanedSIDsInObject`, `Get-SIDAnalysis`, `Test-SIDSecurity`, `New-SIDResult` |
| `Unit/Private/System` | `Get-MemoryStatistics`, `Initialize-MemoryManager`, `Invoke-MemoryMonitoring`, `Invoke-Cleanup`, `Invoke-ResourceDisposal` (`Invoke-ResourceCleanup`) |
| `Unit/Private/Utilities` | `ConvertTo-DistinguishedName`, `Get-OrphanedSidModuleVersion` |

Every unit file dot-sources the class and private files it needs inside `BeforeAll`; none imports
the module except `Unit/Public` and `Unit/OrphanedSid.Contract.Tests.ps1`, which imports it with
`-Force` and checks that no function is defined twice and that every call
between module functions names only parameters the callee declares.

## Integration

`Integration/OrphanedSidWorkflow.Tests.ps1` imports the module and runs `Find-OrphanedSid`,
`Remove-OrphanedSid` and `Restore-OrphanedSidBackup` as an operator would. Nothing inside the
module is mocked. Only the boundary is, in module scope: the ActiveDirectory module check, its
cmdlets and
`Get-Acl`/`Set-Acl` on `AD:\` paths read and write a hashtable of objects whose security
descriptors are real `ActiveDirectorySecurity` instances. The directory holds a built-in principal, a live user, an orphaned SID and a SID whose
lookups fail with access denied, and the tests assert on what each command returns, the SDDL it
leaves on each object, and the backups and CSV it writes:

- discovery reports the orphaned SID, marks the failing one `Unverified`, and changes nothing;
- removal strips only the orphaned ACE, keeps live, built-in and unverified ones, backs up each
  object it changes, and changes nothing under `-WhatIf`;
- restore puts a backed-up descriptor back and refuses a backup whose hash no longer matches;
- a run looks up each SID once however many ACEs reference it, and a failed lookup is not cached
  (tagged `Performance`).

## Helpers

| File | Provides |
| --- | --- |
| `TestHelpers/ADCmdletStubs.ps1` | Global placeholder functions for `Get-ADDomain`, `Get-ADDomainController`, `Get-ADObject`, `Set-ADObject`, `Remove-ADObject`, `Get-ADUser`, `Get-ADGroup`, `Get-ADComputer`, `New-ADUser`, `Set-ADUser`, `Get-ADTrust`, `Get-ADRootDSE` and `Test-ADServiceAccount` when RSAT is absent, so Pester can mock them. Dot-source it before the first `Mock` of an AD cmdlet |
| `TestHelpers/Initialize-TestLogging.ps1` | Loads and initialises the real logging system for the tests that exercise it, and stops the file if that fails |

## Conventions

For new test files; not every existing file follows the first and fourth points.

- `#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }` at the top of the file.
- Setup in `BeforeAll` or `BeforeEach`; nothing at the file's top level.
- `Should -Be` operator form; `Should -Invoke` for mock assertions, with `-Scope` only when the
  call happens in setup; `Should -Throw "*text*"` with `[` and `]` escaped.
- Tag every `Describe` (`Unit`, `Integration`, `Performance`, plus the area).
- Every test must be able to fail when the behaviour its name describes breaks in the module. No
  assertion inside a `catch` that swallows it, no constant as the actual value, no assertion on
  what a mock returned, and no timing budget on an operation with no performance contract: assert
  a count of directory calls instead of milliseconds.
