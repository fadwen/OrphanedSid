# Changelog

All notable changes to this module are recorded here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- `Remove-OrphanedSid` returns one `RemovalOperationResult` per object changed, covering all of its
  removed entries, instead of one per entry, and confirms once per object. Under `-WhatIf` it
  previews one object per object. When any of an object's orphaned SIDs is blocked by the security
  check, none of that object's entries is removed.
  ([#40](https://github.com/fadwen/OrphanedSid/issues/40))
- `Find-OrphanedSid` results, and its CSV, carry two new properties: `VerificationStatus`
  (`Orphaned` or `Unverified`) and `VerificationError`, which names each lookup that failed. An
  unverified SID is listed with `Confidence = Low`. Filter on `VerificationStatus -eq 'Orphaned'` to
  keep only confirmed orphans; re-run once the domain controller is reachable and the account can
  read the targets to settle the unverified ones.
- `Remove-OrphanedSid` logs a warning naming each unverified SID it skips, and the processing summary
  reports how many SIDs were unverified.
- `IntendedRemovals` on removal results is a number. It was a one-element string array holding the
  count (`{"2"}`), unlike `ActualRemovals` and `FailedRemovals`.
  ([#28](https://github.com/fadwen/OrphanedSid/issues/28))

### Removed

- The restore pre-check no longer reports write access. It opened an LDAP connection and read the
  security descriptor, which shows read access only, so an account without the right to change
  permissions passed it. A restore that lacks that right fails at the point it applies the ACL,
  with the error from `Set-Acl`. ([#15](https://github.com/fadwen/OrphanedSid/issues/15))
- Nine internal functions that no command called, each with defects of its own:
  `Test-BackupSignature`, `Test-BackupFileIntegrity`, `Start-RestoreOperation`,
  `Complete-RestoreOperation`, `Test-PathTraversal`, `Get-SIDProcessingStatistics`,
  `ConvertTo-ResultSummary`, and the log sanitiser `Protect-LogMessage` with its only caller
  `Write-SecurityLogEvent`. The troubleshooting guides that called three of them now check backups
  with `Test-BackupIntegrity`, the check every restore runs, and summarise results with
  `Group-Object`. ([#18](https://github.com/fadwen/OrphanedSid/issues/18),
  [#24](https://github.com/fadwen/OrphanedSid/issues/24),
  [#25](https://github.com/fadwen/OrphanedSid/issues/25),
  [#30](https://github.com/fadwen/OrphanedSid/issues/30))

### Fixed

- A live principal could be reported orphaned, and its access removed by `Remove-OrphanedSid`, when
  the ordinary directory lookup of its SID failed (for example with a timeout that outlasted the
  retries). The next lookup, which searches deleted objects, also returns live objects, and any match
  there was taken as proof of deletion. Only a match marked `isDeleted` now counts as deleted; a
  live match means the SID exists. ([#39](https://github.com/fadwen/OrphanedSid/issues/39))
- Restoring an object from which `Remove-OrphanedSid` had removed several orphaned SIDs brought back
  only the last one. Each SID was removed in its own step with its own backup, so every backup after
  the first already lacked the SIDs removed before it, and restore uses the newest. When two of
  those backups fell in the same second, the second also overwrote the first. An object's orphaned
  SIDs are now removed together after one backup, and a backup never overwrites an earlier one: a
  second backup of the same object in the same second gets a `_2` suffix.
  ([#40](https://github.com/fadwen/OrphanedSid/issues/40))
- With `-IncludeInherited`, `Remove-OrphanedSid` tried to remove an inherited orphaned entry from the
  child object that inherits it, which cannot work: it backed the child up, changed nothing, and
  reported `ActualRemovals = 1` with `Success = False`. An inherited entry is now left alone with a
  warning naming it, and the child is not backed up for it; the entry is removed on the parent that
  sets it. ([#46](https://github.com/fadwen/OrphanedSid/issues/46))
- An object whose security descriptor the running account may not read was skipped with a
  Debug-level message only, so at the default log level a run that could not examine part of the
  search base looked clean. Each such object is now named in a Warning, and the summary reports
  `Objects not examined (security descriptor not readable): N` and warns when N is above zero.
  ([#47](https://github.com/fadwen/OrphanedSid/issues/47))
- `-CorrelationId` did not reach every log line and result row, as the help says it does: the
  object-discovery and per-object detection steps generated their own IDs, so their log lines and
  every `Find-OrphanedSid` result and CSV row carried other GUIDs. The run's ID is now passed through
  every step. ([#42](https://github.com/fadwen/OrphanedSid/issues/42))
- A SID whose directory lookup failed was reported as orphaned, and `Remove-OrphanedSid` removed its
  access control entries. A timeout, an access-denied error or an unreachable domain controller was
  treated the same as "this SID does not exist", so live principals could lose their access; the
  removal was recoverable only from the backup. A SID is now orphaned only when its deleted object
  is found, or when every lookup completed and none found it. A SID that no lookup found but at
  least one lookup failed to check is reported as unverified and is never removed. This includes a SID from a trusted domain whose domain
  controllers cannot be reached. ([#9](https://github.com/fadwen/OrphanedSid/issues/9))
- A failed lookup no longer sticks for the rest of the run. Unverified results are not cached, so
  the next object that carries the same SID looks it up again.
- The processing summary did not log the processing rate, peak memory, error count or orphaned SID
  count for discovery and removal runs. It read those values only from an object's properties, and
  the processing results are a hashtable.
- `BatchSize` or `MemoryCheckInterval` set to `0` in a `-ConfigPath` file was silently ignored and
  the default used. It is now rejected like any other value outside 1-1000.
  ([#21](https://github.com/fadwen/OrphanedSid/issues/21))
- A `-LogPath` of only spaces left the run unable to write its log: every entry failed with an error
  that the path is a directory. It is now treated as no `-LogPath`, so the log goes to
  `.\Logs\<Command>_<timestamp>.log` under the current directory.
  ([#31](https://github.com/fadwen/OrphanedSid/issues/31))
- A `-LogPath` that the log set-up refuses, such as one under `C:\Windows` or `C:\Program Files`, is
  replaced with a warning by `OrphanedSid_<timestamp>.log` in the current directory; the refused
  path was then put back, and every log entry failed to write. The fallback is now kept.
- The internal garbage-collection helper reported compacting the large object heap without asking
  .NET to do it. It now requests the compaction, and reports it, only for a collection that can
  perform it. ([#23](https://github.com/fadwen/OrphanedSid/issues/23))
- The security check before a removal reported a batch as `High` risk when a high-risk SID followed
  a blocked one, although a blocked SID makes the batch `Critical`. The blocked SID was still not
  removed. ([#27](https://github.com/fadwen/OrphanedSid/issues/27))
- The SID security check listed a low-risk SID twice among the allowed SIDs.
  ([#26](https://github.com/fadwen/OrphanedSid/issues/26))
- The audit entries for the ACL read that verifies a removal carried a new correlation ID instead of
  the run's, so they could not be tied to the removal.
  ([#29](https://github.com/fadwen/OrphanedSid/issues/29))
- `Remove-OrphanedSid` could not back up an object whose distinguished name is longer than about 200
  characters under Windows PowerShell 5.1 unless the backup folder path was very short. The backup
  file name alone could reach 230 characters and the full path passed the 260-character limit, so
  the backup failed and that object's orphaned entries were not removed. The name is now shortened
  to fit the folder it is written to. When it has to be shortened, it carries a hash of the full
  DN, so two long DNs backed up in the same second no longer get the same file name. A backup folder
  too long to hold any backup file is refused with a message saying so.
  ([#19](https://github.com/fadwen/OrphanedSid/issues/19))
- A backup whose SHA256 hash differed from the computed one only in letter case passed the integrity
  check before a restore. The hash is compared case-sensitively now.
  ([#12](https://github.com/fadwen/OrphanedSid/issues/12))
- A backup with an empty `SDDL` or `SDDLHash` passed validation because the integrity checks ran
  only when both had values. An empty required property now fails validation at every level.
  ([#13](https://github.com/fadwen/OrphanedSid/issues/13))
- When `Restore-OrphanedSidBackup` rejected a target object, the error ended in an empty reason
  (`Target object validation failed: `). It now names each problem found.
  ([#16](https://github.com/fadwen/OrphanedSid/issues/16))
- A missing backup folder was logged twice. ([#20](https://github.com/fadwen/OrphanedSid/issues/20))
- Restoring from a specific backup file restored whichever object the file recorded, even when it
  was not the object asked for. A backup file recorded for a different object is now refused.
  Several distinguished names piped into one restore from a backup folder are each restored from
  their own backup. ([#17](https://github.com/fadwen/OrphanedSid/issues/17))
- When reading an object failed, the retry never re-read it: it passed the error instead of the
  object, so every attempt failed, and each failing object still waited through the back-off (12
  seconds with the default `-MaxRetries 3`). The error and retry log lines also named no object. The
  directory read is now retried on the object itself; an object that succeeds on a retry is no
  longer counted as an error, and `Remove-OrphanedSid` removes what the retry finds. A failed
  removal is not retried, so an object is never backed up and changed twice.
  ([#22](https://github.com/fadwen/OrphanedSid/issues/22))
- `Find-OrphanedSid` returned nothing when `$WhatIfPreference` was `$true` in the session, although
  discovery ran and the summary counted what it found.
  ([#14](https://github.com/fadwen/OrphanedSid/issues/14))

## [1.0.1] - 2026-11-09

### Fixed

- `Restore-OrphanedSidBackup` failed for every single object, with `Could not find file
  '<BackupPath>\C'` and `TargetObjectDN = Unknown (from C)`. When one backup file matched the
  object, `Sort-Object` returned the path itself instead of an array, and `[0]` on a string is its
  first character. This broke restoring one object, and the rollback from a removal's CSV shown in
  the README; a container target with more than one backup used a different path and worked.
  Nothing was changed by the failed attempts.
- `Get-SIDProcessingStatistics` counted the keys of a single result's statistics hashtable as the
  number of objects processed. No command calls it.
- A single-object restore picked its backup by file name, and could restore a different object.
  The match was a substring of the sanitized DN, so `CN=User1` also matched a backup of
  `CN=User10`, and a CN matched the same CN in any other OU. The newest match won, and its own
  object was rewritten from its backup while the requested object was left as it was; the result
  named the other object with `Success = True`. Backups are now matched on the `ObjectDN` they
  record, compared exactly without regard to case.

### Changed

- A container restore with a single backup file in the folder now restores the objects under the
  container. It previously fell back to the single-object file-name match.
- A folder that holds several backups of one object restores that object once, from its most recent
  backup. A container restore previously restored every one of them, in no defined order.

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
- The quality-gates workflow set `$ErrorActionPreference = 'Stop'` before `Invoke-Pester`, so every
  `Write-Error` in a function under test terminated instead of continuing; the tests now run with
  the default preference and the gates throw explicitly. The coverage gate is a ratchet: raise it,
  never lower it.
- `.gitignore` ignored every folder named `Backup/`, including `Tests/Unit/Private/Backup/`, so a
  new test file there was never committed. The rule is anchored to the repository root.
- `Write-SecurityLogEvent` and `Export-DiagnosticData` passed `-Data` and `-ErrorRecord` to
  `Write-StructuredLogEntry`, whose parameter is `-Details`.
- `Invoke-GarbageCollection.ps1` redefined `Write-StructuredLog` and `Get-CurrentMemoryUsage` at
  load time, replacing the real functions, so every log line after startup went to the verbose
  stream only. Both stubs are now guarded.
- `Import-SecureClasses` resolved `Classes\` from the current directory, so the script failed
  when run from anywhere but its own folder.
- `Get-SIDValidationCacheStat.CacheHitRatio` was always 100 for a non-empty cache; it is now
  hits over lookups.
- `Remove-OrphanedSidEntry` and `Find-OrphanedSIDsInObject` returned after the first object when
  several were passed by parameter; each now emits per object and carries on. The engine passed
  one object at a time, so neither command was affected.
- `Invoke-RemovalWorkflow` treated the result object of `Set-ModifiedACL` as a success flag; an
  object is truthy even when its `Success` is `$false`, so a failed write was reported as applied.
- The removal summary logged an empty count for successful or failed removals on Windows
  PowerShell 5.1 when exactly one object matched, because a lone object from `Where-Object` has no
  `Count` there. Both counts are taken from an array now.
- `Initialize-ScriptExecution` logged a log rotation as done when `Move-Item` had failed, because
  the failure was non-terminating. It is terminating now and the catch reports it.
- The release workflow published from an Ubuntu runner, where the staged-module check fails
  because `SecurityIdentifier` is Windows-only. The publish job runs on Windows.
- `ScriptConfiguration.LoadFromFile` rejected a `MemoryCheckInterval` above 100 while the validator
  and the documentation allow 1-1000, and `Initialize-MemoryManager` accepted only 256-16384 MB and
  an interval of 5-100. `-MaxMemoryUsageMB` 100-255 or a configured interval outside 5-100 passed
  every earlier check and then failed initialization. All three now accept 100-16384 MB and an
  interval of 1-1000.

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
- The coverage gate is 80%, up from the 62% the inherited suite measured. Six test files that
  defined and tested a stub of their subject (`Set-ModifiedACL`, `Get-ACLForRemoval`,
  `Invoke-SIDRemoval`, `New-ACLBackup`, `Initialize-ScriptExecution`, `Remove-OrphanedSidEntry`)
  now test the real functions, and the session start and stop, the per-object detector, the
  identity resolution helpers, the restore helpers, the backup integrity check, the processing
  summary and the memory cleanup have tests for the first time.
- `Tests/TestHelpers/ADCmdletStubs.ps1` defines a stand-in
  `Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException` when RSAT is absent, so the
  catch clauses in `Test-OrphanedSID` are valid and its resolution order can be tested.

### Removed

- The hash-based "secure class loading" layer (`Private/ClassManagement`, `Test-ClassIntegrity`,
  `Tools/Generate-ClassHashes.ps1`). It existed to vet the script's own dot-sourced files and was
  never enforced; the module manifest and loader make it redundant.
- `Import-LoggingSystem.ps1`, the script-era loader. The root module loads `Private/` directly.
