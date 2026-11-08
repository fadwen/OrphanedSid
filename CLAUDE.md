# OrphanedSid

Finds access control entries in Active Directory whose trustee no longer exists, removes them with
a Clixml backup of every ACL touched, and restores an ACL from that backup. Published to the
PowerShell Gallery.

## Where the conventions live

General PowerShell conventions - module structure, help, Pester, PlatyPS, error handling - come
from [ai-powershell-standards](https://github.com/fadwen/ai-powershell-standards) and are mirrored
into this repository by `.github/workflows/sync-copilot-standards.yml`:

- `.github/copilot-instructions.md`
- `.github/instructions/`
- `.github/prompts/`
- `.claude/rules/powershell-standards/`
- `powershell-standards/`

**Those paths are mirrored with `rm -rf` + `cp`.** A local edit there is silently reverted on the
next sync. Changes belong upstream in the standards repository.

This file is outside the mirror. What follows is the set of local invariants that look wrong or
arbitrary until you know why, and that are cheap to break by accident.

## Invariants

### `RequiredModules` is empty, and the ActiveDirectory module is checked at run time

The ActiveDirectory module is Windows-only RSAT and is not on the Gallery. Declaring it would make
the module unimportable, and the suite unrunnable, on any host without RSAT, including every CI
runner. `Start-OrphanedSidSession -RequireActiveDirectory` performs the check when a public command
starts. Tests never set that switch.

### Windows PowerShell 5.1 is a real target

The manifest declares `CompatiblePSEditions = Desktop, Core` and the root module carries
`#Requires -Version 5.1`, because the RSAT module is what most domain-joined management hosts have
and nothing else. A ternary, `??`, `ForEach-Object -Parallel` or `Join-Path` with several child
paths parses fine on 7 and breaks every command on 5.1. The `desktop` job in `quality-gates.yml`
runs the suite under 5.1 for this reason.

### Classes load before any Private file, and Logging before the rest

Seven private functions constrain a parameter to a class from `Classes/` (`[MemoryManager]`,
`[OrphanedSIDResult]`). A type literal in a param block must exist when the file is parsed, so
`OrphanedSid.psm1` dot-sources `Classes/` first and then the `Private/` folders in a fixed order
with `Logging` first. Nothing in `Private/` may run code at load time: a top-level
`Write-StructuredLog "module loaded"` line once existed in twenty files and broke the import.

### A fallback stub must be guarded

`Invoke-GarbageCollection.ps1` defines a minimal `Write-StructuredLog` and `Get-CurrentMemoryUsage`
for running on its own. Unguarded, those definitions replaced the real functions at import and
every log line after startup went to the verbose stream only. Any such stub is wrapped in
`if (-not (Get-Command ... -ErrorAction SilentlyContinue))`.

### Module state is per run and reset by the session helpers

`$script:Config`, `$script:MemoryManager`, `$script:Statistics`, `$script:StreamingResults`,
`$script:RemovalResults` and `$script:CurrentDomainSID` are set by `Start-OrphanedSidSession` and
cleared by `Stop-OrphanedSidSession`, which every public command calls from `begin` and `finally`.
A private function reads them; it never creates them. The SID validation cache is the exception:
it lives for the PowerShell session so the second run against the same domain is cheaper.

### Results are emitted before cleanup

`Find-OrphanedSid` reads results back from the streaming batch files with `GetAllResults()` before
`Write-ProcessingSummary` and before `Stop-OrphanedSidSession` disposes the manager, which deletes
those files. Move the emit after either and the command returns nothing.

### Destructive commands prompt, and `-Force` is the unattended switch

`Remove-OrphanedSid` and `Restore-OrphanedSidBackup` carry `ConfirmImpact = 'High'`. `-Force` sets
`$ConfirmPreference = 'None'` for the call; `-WhatIf` is untouched by it and still previews. A
scheduled task that omits `-Force` stops at the prompt. The inner `ShouldProcess` calls in
`Invoke-MainProcessingLogic` and `Set-ObjectACL` keep default `ConfirmImpact`, so they never
prompt a second time.

### Protected SIDs are never orphaned

`ScriptConfiguration.ProtectedSIDs` and `WellKnownSIDPatterns` short-circuit both discovery and
removal. The domain SID is read once per run in `Invoke-MainProcessingLogic` and passed to
`Get-SIDAnalysis` through `Test-SIDSecurity`; without it every domain SID is rated
`Unknown Domain` and the run logs `Could not determine the current domain SID`.

### Backups are Clixml with a hash, and nothing else reads them

`New-ACLBackup` writes `<DN sanitized>_<yyyyMMdd_HHmmss>.xml` with the SDDL, its SHA256, the
object DN, the correlation ID and the writer's identity. `Restore-OrphanedSidBackup` is the only
consumer and validates the hash before applying. Changing the file shape means changing
`Test-BackupValidation` and `Test-BackupIntegrity` in the same change.

### Tests dot-source files; they do not import the module

Each unit test file loads the class and private files it needs inside `BeforeAll` and stubs
`Write-StructuredLog`. Pester 6 runs nothing a file defines at its top level, so setup outside
`BeforeAll` is invisible to the tests. Tests that mock an Active Directory cmdlet first dot-source
`Tests/TestHelpers/ADCmdletStubs.ps1`, which defines global placeholders when RSAT is absent;
Pester can only mock a command that exists. Add to that list when a new test mocks a new cmdlet.

### One scope, so one definition per name and real parameter names at every call

The root module dot-sources every file into one scope, and the last definition of a name wins
with no warning. The unit tests cannot see this: each dot-sources one file, and a mock built with
loose parameters accepts any `-Name`. `Tests/Unit/OrphanedSid.Contract.Tests.ps1` parses
`Classes`, `Private` and `Public` and fails on a function defined twice or a call that names a
parameter its callee lacks. When a helper needs a sibling that works on a file path instead of the
loaded data, give it a distinct name (`Test-BackupFileIntegrity`, `Get-BackupFileMetadata`) rather
than a second definition.

### The coverage gate is a ratchet

`quality-gates.yml` fails below 60% line coverage over `Public/` and `Private/`. The suite the
module inherited measures 62%, because many of its files test a stub of the function rather than
the function (`Set-ModifiedACL.Tests.ps1` defines its own `Set-ModifiedACL`). When a file is
replaced with tests of the real function, raise the number in the workflow to what the run then
measures. Never lower it. The workflow also sets `$ErrorActionPreference = 'Continue'` before `Invoke-Pester`, because the
GitHub shells prepend a Stop preference to every step: it reaches the functions under test and
turns a per-item `Write-Error` into a termination the tests do not expect.

### The analyzer gate is strict on shipping code and relaxed on tests

`quality-gates.yml` runs PSScriptAnalyzer with every Error and Warning rule over `Classes`,
`Private`, `Public`, `Build` and the root module, and with `Tests/PSScriptAnalyzerSettings.psd1`
over `Tests` and `Tools`. The relaxed set drops the rules that fire on every stub and mock. A
suppression in shipping code carries a `Justification`.

### The MAML filename carries a capital H

`en-US/OrphanedSid-Help.xml`, matching every `.EXTERNALHELP OrphanedSid-Help.xml` keyword in
`Public/`. On a case-sensitive filesystem a mismatch makes `Get-Help` fall back to a reflected
stub; the `help` job runs on Linux to catch it, and `Build-Help.ps1` asserts the produced name.

### Help is compiled, and stale help beats correct help

`docs/OrphanedSid/*.md` is the source; `en-US/OrphanedSid-Help.xml` is the artifact. After editing
anything under `docs/`, run `./Build/Build-Help.ps1` and commit the rebuilt MAML in the same
change. CI compares a fresh build against the committed file byte for byte, with PlatyPS pinned to
1.0.3. After changing a public function's signature, refresh the Markdown with
`Update-MarkdownCommandHelp`; put detail in the Markdown, not the function's comment block.

### Never `Publish-PSResource -Path .`

This repository is the module root. Publish through `Build/Publish-Module.ps1`, which stages an
allowlist (`Classes`, `Private`, `Public`, `en-US`, the manifest, loader, LICENSE, README and
CHANGELOG) into a git-ignored `out/`, imports the staged copy in a fresh process, runs a private
helper through it, and checks every command serves its help before anything is uploaded. Under
`-WhatIf` the staging cmdlets are pinned `-WhatIf:$false` and the help build runs with the
preference cleared, or the rehearsal verifies nothing.

### Releases are tag-driven and the tag must match the manifest

Bump `ModuleVersion`, update `CHANGELOG.md` and the manifest's `ReleaseNotes`, then
`git tag v<ModuleVersion> && git push origin v<ModuleVersion>`. `release.yml` re-runs every gate,
rejects a tag that disagrees with the manifest, stages, verifies and publishes. The API key is the
`PSGALLERY_API_KEY` repository secret; locally the script resolves `-ApiKey`, then
`$env:PSGALLERY_API_KEY`, then a SecretManagement secret named `PSGallery-ApiKey`.

## Checks

```powershell
Invoke-Pester ./Tests                                # Pester 6; no domain or RSAT needed
Invoke-ScriptAnalyzer -Path ./Private -Recurse -Severity Error, Warning   # repeat for Public, Classes, Build
./Build/Build-Help.ps1                               # rebuild MAML after editing docs/
./Build/Publish-Module.ps1 -WhatIf                   # full release rehearsal, publishes nothing
```
