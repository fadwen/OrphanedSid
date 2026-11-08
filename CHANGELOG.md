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

### Changed

- Logs default to `.\Logs\<Command>_<timestamp>.log` and backups to `.\Backup\<timestamp>\`
  under the current directory, not under the module folder.
- The private `Remove-OrphanedSID` helper is `Remove-OrphanedSidEntry`, to make room for the
  public command.
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
