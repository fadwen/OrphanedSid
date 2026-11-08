# Changelog

All notable changes to this module are recorded here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-11-08

First release as a module. The code was previously the `Find-UnknownSID.ps1` script under
`Powershell/Active Directory/Find-UnknownSID` in [fadwen/TechbyJeff](https://github.com/fadwen/TechbyJeff);
its history is carried over in this repository.

### Added

- `Find-OrphanedSid`, `Remove-OrphanedSid` and `Restore-OrphanedSidBackup` replace the script's
  discovery, `-Remove` and `-Restore` parameter sets. Each writes its results to the pipeline:
  one `OrphanedSIDResult` per orphaned access control entry, one `RemovalOperationResult` per
  modified object, one restore result per target. `-OutputPath` still writes a CSV.
- `Remove-OrphanedSid` and `Restore-OrphanedSidBackup` have `ConfirmImpact = 'High'`: they prompt
  once before changing anything and need `-Force` (or `-Confirm:$false`) to run unattended.
  `-WhatIf` previews either.
- Results from the current domain are told apart from foreign and unknown ones. The domain SID is
  read once per run with `Get-ADDomain` and passed through security validation and analysis;
  previously every domain SID was rated `Unknown Domain`.
- `-PreserveTempFiles` keeps the streaming batch files; `-LogLevel` filters the file log; the
  `BatchSize` configuration key sets the streaming batch size (default 50). All three were
  accepted but ignored by the script.
- Restores verify the applied ACL against the backup and export a CSV when `-OutputPath` is given.

### Fixed

- Discovery enumerated no objects. `Get-ADObjectsSequential` looped with a variable named like
  its `[string[]]` parameter in another letter case, which is the same variable, so every search
  base reached `Get-ADObjectFromSearchBase` as a one-element array, failed to bind, and was logged
  as a failed search base. Found by running against a domain controller; the unit test's mock had
  accepted the array.
- `-SuppressConsoleOutput` was recorded but not honoured: every log entry still reached the
  console streams.
- `-WhatIf` reached the log writer and the housekeeping helpers through `$WhatIfPreference`, so a
  rehearsal wrote no log file and printed `What if:` lines for appending log entries, creating the
  memory manager and disposing resources. Those steps are pinned; only the ACL changes and the
  backup folder honour `-WhatIf`.

- Every restore failed with `A parameter cannot be found that matches parameter name
  'BackupData'`. Two files defined `Test-BackupIntegrity`: the one in
  `Private/Backup/Test-BackupValidation.ps1` validates backup data and is what the restore path
  calls; the one in `Private/Utilities/` validated a file path and, loading later, replaced it. The
  file-path check is now `Test-BackupFileIntegrity`. `Get-BackupMetadata` had the same clash with
  `Find-BackupFile`'s file-path reader, now `Get-BackupFileMetadata`; `Test-LogLevel` was defined
  in two logging files and `Test-BackupFormat` and `Get-BackupMetadata` twice in one file. Each
  name is now defined once.
- Every removal logged `ACL backup failed: A parameter cannot be found that matches parameter name
  'DistinguishedName'`. `Set-ModifiedACL` attempted a second backup with the wrong parameter name
  and without the mandatory ACL and folder; the backup `Invoke-RemovalWorkflow` writes before
  calling it was always the one on disk. The second attempt is gone, and the result object no
  longer carries `BackupCreated`, `BackupPath`, `BackupError` or `BackupCorrelationId`.
- A restore applied the ACL and then reported `Success = False` with `The term 'if' is not
  recognized`. The per-object result built its entry count with `[int](if ...)`, which is not an
  expression; it is `[int]$(if ...)` now, and `Restore-IndividualObject` has its own tests.
- The four help Markdown files under `docs/OrphanedSid/` were committed empty: a path-fixing script
  wrote `$null` back after its regex threw. `Build-Help.ps1` still passed, because PlatyPS classifies
  an empty file as nothing and a `maml/` left by an earlier build was copied as if freshly compiled;
  on a clean Linux checkout the help job failed. The Markdown is regenerated from the functions'
  original help, and the build now deletes `maml/` first and fails when fewer command help files
  are recognised than commands are exported.
- `ScriptConfiguration.ValidateConfiguration()` reported findings with `Write-Error` while returning
  `$false`; under an inherited `-ErrorAction Stop` the caller got an exception instead. Findings
  are warnings now.
- Tests that built paths from `$env:TEMP` compared them against the long paths the functions
  return and failed on the GitHub runners, where `TEMP` is an 8.3 short path; eight test files
  mocked a command no file had defined, asserted a file-load state another test had changed, or
  reused a per-test object from a previous context, so they passed only in declaration order.
  Every test file now passes alone in a fresh process with a shuffled order.
- `Write-SecurityLogEvent` and `Export-DiagnosticData` passed `-Data` and `-ErrorRecord` to
  `Write-StructuredLogEntry`, whose parameter is `-Details`.

### Changed

- Logs default to `.\Logs\<Command>_<timestamp>.log` and backups to `.\Backup\<timestamp>\`
  under the current directory, not under the module folder.
- The private `Remove-OrphanedSID` helper is `Remove-OrphanedSidEntry`, to make room for the
  public command.
- `Tests/Unit/OrphanedSid.Contract.Tests.ps1` fails the suite when two files define the same
  function or a call between module functions names a parameter the callee does not declare.
  Both defects above passed the unit tests, whose mocks accept any parameter name.
- The test suite runs on Pester 6 and needs no RSAT: `Tests/TestHelpers/ADCmdletStubs.ps1`
  defines placeholder Active Directory cmdlets so they can be mocked.

### Removed

- The hash-based "secure class loading" layer (`Private/ClassManagement`, `Test-ClassIntegrity`,
  `Tools/Generate-ClassHashes.ps1`). It existed to vet the script's own dot-sourced files and was
  never enforced; the module manifest and loader make it redundant.
- `Import-LoggingSystem.ps1`, the script-era loader. The root module loads `Private/` directly.

### Fixed

- `Invoke-GarbageCollection.ps1` redefined `Write-StructuredLog` and `Get-CurrentMemoryUsage` at
  load time, replacing the real functions, so every log line after startup went to the verbose
  stream only. Both stubs are now guarded.
- `Import-SecureClasses` resolved `Classes\` from the current directory, so the script failed
  when run from anywhere but its own folder.
- `Get-SIDValidationCacheStat.CacheHitRatio` was always 100 for a non-empty cache; it is now
  hits over lookups.
