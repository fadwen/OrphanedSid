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
├── Integration/
│   ├── EndToEnd/           Discovery, removal and restore workflows against mocked AD responses
│   └── SystemIntegration/  AD access, backup and restore, and logging across function boundaries
├── Performance/
│   ├── Benchmarks/         Throughput, memory baseline, large dataset processing
│   └── LoadTests/          Concurrency, memory pressure, resource cleanup, scalability limits
├── TestHelpers/            Shared stubs and factories, dot-sourced from BeforeAll
├── TestData/               Configurations, fixtures, mock responses, sample data, malicious inputs
└── PSScriptAnalyzerSettings.psd1   Relaxed analyzer rules for Tests/ and Tools/
```

## Unit

| Folder | Covers |
| --- | --- |
| `Unit/Classes` | `ScriptConfiguration` (defaults, JSON overrides, validation), `MemoryManager`, `StreamingResultsManager` (batching, export, disposal), `ProcessingStatistics`, `OrphanedSIDResult`, `SIDAnalysisResult`, `SecurityValidationResult`, `RemovalOperationResult`, `RestoreOperationResult` |
| `Unit/Public` | `Find-OrphanedSid`, `Remove-OrphanedSid`, `Restore-OrphanedSidBackup`: parameter validation, pipeline input, the confirmation gate, result emission, session start and stop. The engine is mocked with `Mock -ModuleName OrphanedSid` |
| `Unit/Private/ACL` | `Get-ACLForRemoval`, `Invoke-SIDRemoval`, `Set-ModifiedACL` |
| `Unit/Private/ActiveDirectory` | `Get-ADObjectFromSearchBase`, `Get-ADObjectsSequential`, `Invoke-ADOperationWithRetry`, `Test-ValidDistinguishedName` |
| `Unit/Private/Backup` | `New-ACLBackup`, `Find-BackupFile`, `Get-BackupFileMetadata`, `Test-BackupValidation` (with `Test-BackupFormat` and `Get-BackupMetadata`), `Test-BackupIntegrity` at each level, `Invoke-RestoreWorkflow`, `Restore-IndividualObject`, `Restore-ACLOperation` (`Set-ObjectACL` with its helpers mocked) and `Restore-ACLOperation.Helpers` (`Get-RestorationTarget`, `Confirm-RestorationSuccess`, `ConvertFrom-BackupToACL` for real) |
| `Unit/Private/Core` | `Initialize-ScriptExecution`, `Invoke-MainProcessingLogic`, `Start-OrchestrationWorkflow`, `Remove-OrphanedSidEntry`, `Start-OrphanedSidSession`, `Stop-OrphanedSidSession` |
| `Unit/Private/FileSystem` | `Get-SafeFileName`, `Initialize-LogDirectory`, `Test-DirectoryAccess` |
| `Unit/Private/Logging` | `Initialize-LoggingConfiguration` (including `Set-LogLevel`), `Initialize-LoggingSystem` (including `Test-LogLevel`), `Format-LogMessage`, `Protect-LogMessage`, `Write-StructuredLogEntry`, `Write-StructuredLog`, `Write-SecurityStructuredLogEntry`, `Write-SecurityLog`, `Write-SecurityLogEvent`, `Write-ADOperationSecurityLog`, `Write-RemovalSecurityLog` |
| `Unit/Private/Operations` | `Invoke-OperationWithRetry`, `Invoke-RemovalWorkflow` |
| `Unit/Private/Reporting` | `Export-DiagnosticData`, `Get-LogFileSummary`, `Write-ProcessingSummary` (parameters) and `Write-ProcessingSummary.Scenarios` (discovery, removal and restore results, CSV export, automation output) |
| `Unit/Private/Security` | `Get-SecurityDescriptor` (`Get-ObjectAccessRule` and its retrieval strategies), `Invoke-SecurityValidation`, `Invoke-RemovalVerification`, `Test-PathTraversal` |
| `Unit/Private/SID` | `Test-SIDFormat` (with `Test-WellKnownSID`), `Test-OrphanedSID` end to end and `Test-OrphanedSID.Resolution` (each lookup in the resolution order, the validation cache), `Resolve-SIDIdentity` (availability) and `Test-AccessRuleForOrphanedSID` (the resolution helpers for real), `Find-OrphanedSIDsInObject`, `Get-SIDAnalysis`, `Test-SIDSecurity`, `New-SIDResult` |
| `Unit/Private/System` | `Get-MemoryStatistics`, `Initialize-MemoryManager`, `Invoke-MemoryMonitoring`, `Invoke-GarbageCollection`, `Invoke-Cleanup`, `Invoke-ResourceDisposal` |
| `Unit/Private/Utilities` | `Get-StringHash`, `Test-BackupFileIntegrity`, `Test-BackupSignature` |

Every unit file dot-sources the class and private files it needs inside `BeforeAll` and stubs
`Write-StructuredLog`; none imports the module except `Unit/Public` and `Unit/OrphanedSid.Contract.Tests.ps1`,
which imports it with `-Force` and checks that no function is defined twice and that every call
between module functions names only parameters the callee declares.

## Integration and performance

| Folder | Covers |
| --- | --- |
| `Integration/EndToEnd` | Complete discovery, removal and restore workflows with `Get-ADObject`, `Set-ADObject`, `New-ADUser` and the rest mocked |
| `Integration/SystemIntegration` | Active Directory access patterns, backup and restore round trips, and the logging system across function boundaries |
| `Performance/Benchmarks` | Large dataset processing, memory usage baseline, throughput measurement |
| `Performance/LoadTests` | Concurrent operations, memory pressure, resource cleanup, scalability limits |

## Helpers

| File | Provides |
| --- | --- |
| `TestHelpers/ADCmdletStubs.ps1` | Global placeholder functions for `Get-ADDomain`, `Get-ADDomainController`, `Get-ADObject`, `Set-ADObject`, `Remove-ADObject`, `Get-ADUser`, `New-ADUser`, `Set-ADUser`, `Get-ADTrust`, `Get-ADRootDSE` and `Test-ADServiceAccount` when RSAT is absent, so Pester can mock them. Dot-source it before the first `Mock` of an AD cmdlet |
| `TestHelpers/ADMockFactory.ps1` | `New-ADMocks`, `Get-MockOrphanedSIDs`, `Reset-ADMocks` |
| `TestHelpers/SecurityTestHelpers.ps1` | `Get-MaliciousInputTestCases`, `Test-InputForMaliciousContent`, `New-SecureMockCredential`, `Write-SecurityTestLog`, `Get-TestDataPath`, `Test-ADSecurity`, `Get-MockADEnvironment` |
| `TestHelpers/BackupTestHelpers.ps1` | `New-TestBackupMetadata`, `New-TestBackupFile`, `Test-BackupPathSecurity`, `New-MaliciousBackupInput`, `Test-BackupFilterValidation`, `New-TestDateRange`, `Assert-BackupResultStructure` |
| `TestHelpers/Initialize-TestLogging.ps1` | Logging defaults for tests that exercise the logging functions |

## Test data

| Folder | Contents |
| --- | --- |
| `TestData/Configurations` | JSON and PSD1 configuration files for the test, development, production, enterprise and security-enhanced scenarios |
| `TestData/Baselines` | Performance and security baselines read by the performance tests |
| `TestData/Fixtures` | Sample backups, corrupt backup files, sample logs, test certificates, performance datasets (each folder documents itself in a README) |
| `TestData/MockResponses` | Recorded directory query, backup, log, database and Graph responses |
| `TestData/SampleData` | Mock AD objects, sample SIDs, complex security descriptors, test ACLs, a large orphaned-SID dataset |
| `TestData/MaliciousInputs` | Attack patterns and injection attempts for the sanitisation tests |

## Conventions

- `#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }` at the top of every file.
- Setup in `BeforeAll` or `BeforeEach`; nothing at the file's top level.
- `Should -Be` operator form; `Should -Invoke` for mock assertions, with `-Scope` only when the
  call happens in setup; `Should -Throw "*text*"` with `[` and `]` escaped.
- Tag every `Describe` (`Unit`, `Integration`, `Performance`, plus the area).
- Timing assertions are regression guards with generous budgets, not benchmarks.
