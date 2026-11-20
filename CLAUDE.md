# OrphanedSid

Finds access control entries in Active Directory whose trustee no longer exists, removes them with
a Clixml backup of every ACL touched, and restores an ACL from that backup. Published to the
PowerShell Gallery.

## Where the conventions live

General PowerShell conventions - module structure, help, Pester, PlatyPS, error handling - come
from [ai-powershell-standards](https://github.com/fadwen/ai-powershell-standards). Its installer
writes them into this repository, and `.github/workflows/sync-copilot-standards.yml` runs it every
week and opens a pull request when they change:

- `.github/copilot-instructions.md` and `AGENTS.md`
- `.github/instructions/powershell-*.instructions.md`
- `.github/instructions/pester-supporting-docs/`
- `.claude/rules/powershell-standards/`
- the `powershell-*` skills under `.github/skills/`, `.claude/skills/` and `.agents/skills/`

**The next sync overwrites those files.** A local edit there is silently reverted, and a file the
standards stop producing is deleted. Changes belong upstream in the standards repository.

This file is not one of them. What follows is the set of local invariants that look wrong or
arbitrary until you know why, and that are cheap to break by accident.

## Invariants

### `RequiredModules` is empty, and the ActiveDirectory module is checked at run time

The ActiveDirectory module is Windows-only RSAT and is not on the Gallery. Declaring it would make
the module unimportable, and the suite unrunnable, on any host without RSAT, including every CI
runner. `Start-OrphanedSidSession -RequireActiveDirectory` performs the check when a public command
starts. Tests that reach the check mock `Get-Module` and `Import-Module` for it, so none needs
RSAT.

### Windows PowerShell 5.1 is a real target

The manifest declares `CompatiblePSEditions = Desktop, Core` and the root module carries
`#Requires -Version 5.1`, because the RSAT module is what most domain-joined management hosts have
and nothing else. A ternary, `??`, `ForEach-Object -Parallel` or `Join-Path` with several child
paths parses fine on 7 and breaks every command on 5.1. The `desktop` job in `quality-gates.yml`
runs the suite under 5.1 for this reason.

### Classes load before any Private file, and Logging before the rest

Five private functions constrain a parameter to a class from `Classes/` (`[MemoryManager]`,
`[OrphanedSIDResult]`). A type literal in a param block must exist when the file is parsed, so
`OrphanedSid.psm1` dot-sources `Classes/` first and then the `Private/` folders in a fixed order
with `Logging` first. Top-level code in `Private/` only sets `$script:` state or defines a guarded
stub; nothing may call a module function at load time: a top-level
`Write-StructuredLog "module loaded"` line once existed in twenty files and broke the import.

The loader requires `Classes`, `Public` and every folder in its `Private` list to exist, and each
dot-source sits in a `try` whose `catch` throws. Without the `try`, PowerShell reports a file that
does not parse and carries on: the import succeeds with all three commands exported, and with
`Test-SIDFormat` missing `Find-OrphanedSid` returned nothing, because each SID failed a check that
only logged a warning. A new folder under `Private` loads without being listed; listing it makes it
required.

### A fallback stub must be guarded

`Invoke-GarbageCollection.ps1` defines a minimal `Write-StructuredLog` and `Get-CurrentMemoryUsage`
for running on its own. Unguarded, those definitions replaced the real functions at import and
every log line after startup went to the verbose stream only. Any such stub is wrapped in
`if (-not (Get-Command ... -ErrorAction SilentlyContinue))`.

### Module state is per run and reset by the session helpers

`Start-OrphanedSidSession` sets `$script:Config`, `$script:MemoryManager` and `$script:Statistics`
and resets `$script:StreamingResults`, `$script:RemovalResults` and `$script:CurrentDomainSID`,
which `Invoke-MainProcessingLogic` then fills for the run. It also creates an empty
`$script:SIDClassificationCache`, the per-SID answer of the format and well-known checks; that
answer depends on the run's `ProtectedSIDs` and `WellKnownSIDPatterns`, so it must not outlive the
run. `Stop-OrphanedSidSession` clears all of them except `$script:Config` and
`$script:CurrentDomainSID`. Every public command calls the first from `begin` and the second from
`finally`. The call in `begin` sits in a `try` whose `catch` raises the error with
`Write-Error -ErrorRecord $_ -ErrorAction Stop`, as the `end` block does. Without that `try`, a
`throw` in start-up follows the caller's error action: under `-ErrorAction SilentlyContinue` it is
swallowed, and `process` and `end` run with no configuration. No ordinary Pester test can see
this, because every test runs inside a `try`; `Tests/Integration/OrphanedSidStartupFailure.Tests.ps1`
runs each command in a process of its own for that reason. It has to be a process and not a second
runspace: the cases assert the exit code of the host, under `-File` and under `-Command`.
The SID validation cache is the exception: it lives for the PowerShell session so the
second run against the same domain is cheaper.

### The classes have no static member

On Windows PowerShell 5.1, once another runspace of the process has imported the module and been
closed, a static method of a PowerShell class fails in the first runspace with a
`NullReferenceException`. A new instance and its instance methods keep working there, and
PowerShell 7 does not fail at all. `[ScriptConfiguration]::LoadFromFile()` was static, so a host
application with a runspace pool lost `-ConfigPath` for the rest of the process (#125). It is an
instance method now, called as `[ScriptConfiguration]::new().LoadFromFile($path)`. The contract
test fails on a static member in `Classes/`. The behaviour itself is covered by one case of
`OrphanedSidStartupFailure.Tests.ps1`, in a process of its own: closing a second runspace inside
the Pester process would break every later test that touches the class on Windows PowerShell 5.1.

### A fatal error of a public command ends the calling script, against ERR-11

The `catch` in `begin` and the `catch` in `end` of each public command raise the failure with
`Write-Error -ErrorRecord $_ -ErrorAction Stop`. ERR-11 of the standards rules that call out in
favour of `$PSCmdlet.ThrowTerminatingError()`, and it is used here on purpose.
`ThrowTerminatingError()` ends only the statement that called the command: a scheduled script
carries on with its next line and `powershell -File` exits with 0, which was measured.
`Documentation/Automation.md` tells callers that a critical error ends the calling script or
command line whatever the error action is, that the process exits with 1, and that `try`/`catch`
is the way to handle it. Replacing the call changes that contract, so it is a change to announce
in a release, not a tidy-up. The exception covers these six lines only. No other `throw` and no
other `Write-Error -ErrorAction Stop` is left in an advanced function of `Private/` or `Public/`
(#130). `Tests/Unit/OrphanedSid.Contract.Tests.ps1` finds both kinds by syntax tree and fails
when one is added. A statement inside a script block that the function hands to a command, such
as `ForEach-Object` or a retry, counts too: a caller's `-ErrorAction SilentlyContinue` was
measured to swallow it like one written directly in the function. The script block of an
attribute, such as a `ValidateScript`, is left out, and so is a class method, which has no
`$PSCmdlet`. The six must stay six and stay in `Public/`. Each carries the comment that DOC-22
of the standards asks for, `# Exception to ERR-11: <reason>`, directly above it, and the contract
tests fail when one is missing.

Writing `$PSCmdlet.ThrowTerminatingError()` where a `throw` would have gone is not enough. Two
things were measured on PowerShell 7 and Windows PowerShell 5.1. An error raised with it inside a
`try`, or from a `catch` nested in it, does not enter the `catch` of that same function: it
leaves the function at once, so a `catch` that logs, cleans up or builds a failed result is
passed by. And it goes to the nearest `try` on the call stack. With none there, it ends only the
statement that called the function, and the caller carries on with its next line.
`Stop-OrphanedSidSession` runs in the `finally` of a public command, with no `try` of the module
around it, so that is not a remote case. Three forms follow from the first measurement, and the
module uses each:

- A check whose failure ends the function is made before the `try`, or after it, and raises an
  error record with an error ID of its own. Where it has to sit inside the `try`, it first does
  what the `catch` would have done for it, such as writing the log entry.
- A check whose failure the `catch` turned into a failed result builds that result itself. The
  functions that do this keep the handling in one script block, which the check and the `catch`
  both run.
- A `catch` that passes an error on raises it with `$PSCmdlet.ThrowTerminatingError($_)`, which
  keeps the exception, the category and the first part of the error ID. A `catch` that adds
  context raises a new record whose exception holds the caught one as its inner exception.

A public command cannot use the first form for a check in its `end` block. The `catch` there is
what ends the calling script, and an error raised in that `try` would pass it by. Such a check is
a private function, as `Assert-DistinguishedNameInput` is, whose error does enter the `catch`.

That every call to a function which raises this way sits inside a `try` is checked by the
contract tests, so that each function is right whatever calls it. A call inside
a script block counts with the `try` the block is written in, as long as the block is handed
straight to a command: that `try` was measured to catch the error while the command runs the
block. A block kept in a variable can run after the `try` has ended, so it needs a `try` of its
own. In a block handed to another function of the module, `$PSCmdlet` is that function's, and an
error raised there carries its name in the error ID.

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
`Get-SIDAnalysis` through `Test-AccessRuleForOrphanedSID` on discovery and `Test-SIDSecurity` on
removal; without it every domain SID is rated
`Unknown Domain` and the run logs `Could not determine the current domain SID`.

### A distinguished name is checked for its form, never for "dangerous" characters

`Test-ValidDistinguishedName` once refused `&`, `;`, `|`, a backtick, `--`, `%`, `...`,
`<script`, `DROP TABLE` and more, and `Get-ACLForRemoval` refused `..`. Those lists are written
for text that reaches a shell, a browser or a SQL query. A distinguished name reaches none of
them: it is one argument to the Active Directory cmdlets. Discovery reads names from the
directory and does not ask the validator, so `OU=R&D` was reported by `Find-OrphanedSid` and
refused by `Remove-OrphanedSid` with `Target path not found`, for ever (#128). The same goes for
the restore: `Get-RestorationTarget` must accept every name a removal accepts, or a backup exists
that cannot be put back. A check that looks like hardening here is a way to strand entries, so
add one only for a name that Active Directory itself cannot hold.

The same holds for the attribute that names a component. The validator and three checks on the
restore path once accepted only `CN=`, `OU=` and `DC=`. The class of an object sets that
attribute in the schema: a `locality` is `L=...` and an `organization` is `O=...`, and both could
be reported and never cleaned (#134). The four places now take any attribute name or dotted
number, with the same pattern, and a change to one of them is a change to all four:
`Test-ValidDistinguishedName`, `Invoke-RestoreWorkflow`, `Get-RestorationTarget` and
`Test-BackupIntegrity`. The contract tests fail when one of them holds a different pattern. The
dot inside a name is deliberate: the directory was measured to take `OU=`, `2.5.4.11=` and
`OID.2.5.4.11=` for the same object. `Invoke-RestoreWorkflow` still decides between one object and a whole
subtree by `OU=` or `DC=`, so a container named otherwise is restored as one object, as a `CN=`
container is.

### Paths are literal, and directory security descriptors go through two helpers

A file path held in a variable is passed with `-LiteralPath`. `[` and `]` in `-BackupPath`,
`-LogPath`, `-OutputPath` or `-ConfigPath` are otherwise read as a pattern that matches nothing:
a removal once ran to the end with only the header in its log. `Get-DirectoryObjectAcl` and
`Set-DirectoryObjectAcl` are the only callers of `Get-Acl` and `Set-Acl` on the `AD:` drive. They
use `-Path` for an ordinary name, and the `nTSecurityDescriptor` attribute for a name that
contains `[`, `]`, `*`, `?`, a backtick or a backslash. The backtick is not an oversight: `-Path`
reads it as an escape and drops it, so for ``OU=Pay`*`` the drive hands back the descriptor of
`OU=Pay*`, a different object. Do not replace that with `-LiteralPath`: on Windows PowerShell 5.1
`Get-Acl -LiteralPath` fails on the `AD:` drive for every object, with
`Cannot find path '//RootDSE/...'`, while on PowerShell 7 it works, so only a 5.1 run against a
real domain notices. The backslash is there for the same edition. The directory escapes `,` `+`
`=` `"` `<` `>` `;` `\` and a leading `#` with one, so a group named `Doe, Jane` is
`CN=Doe\, Jane`, and on Windows PowerShell 5.1 the drive fails for every such name with
`The object name has bad syntax` (#133). The tests cannot see either failure by themselves: the
fake directory in `Tests/Integration/OrphanedSidWorkflow.Tests.ps1` fails the way 5.1 was measured
to, and has to be kept that way.

### The removal reads access rules with `Get-AclAccessRule`, not from `.Access`

`.Access` is not a member of the .NET security descriptor. PowerShell adds it from type data, and
on PowerShell 7 a runspace that a host application creates with `[powershell]::Create()` does not
have it. The removal once read `.Access` there, saw a descriptor with no rules, wrote nothing and
reported success. `Get-AclAccessRule` calls `GetAccessRules()` on the descriptor, which exists
everywhere and does not turn each SID into an account name. Removal, verification and the entry
count of a backup all go through it. A removal that finds fewer entries than it was asked to
remove is a failure, never "nothing to do": discovery only hands over SIDs that hold an explicit
entry on the object.

### Backups are Clixml with a hash, and nothing else reads them

`New-ACLBackup` writes `<DN sanitized>_<yyyyMMdd_HHmmss>[_<n>].xml` with the SDDL, its SHA256, the
object DN, the correlation ID and the writer's identity. `Restore-OrphanedSidBackup` is the only
consumer and validates the hash before applying. Changing the file shape means changing
`Test-BackupIntegrity` in the same change.

### Unit tests of private code dot-source files; they do not import the module

Each class and private-function test file loads the files it needs inside `BeforeAll` and stubs or
loads what they log through. The public-command, contract and integration tests import
`OrphanedSid.psd1` instead, and so does the `Get-OrphanedSidModuleVersion` test, because that
helper reads the version of the module it runs in. Pester 6 runs nothing a file defines at its top
level, so setup outside `BeforeAll` is invisible to the tests. Tests that mock an Active Directory
cmdlet first dot-source `Tests/TestHelpers/ADCmdletStubs.ps1`, which defines global placeholders when RSAT is absent;
Pester can only mock a command that exists. Add to that list when a new test mocks a new cmdlet.

### One scope, so one definition per name and real parameter names at every call

The root module dot-sources every file into one scope, and the last definition of a name wins
with no warning. The unit tests cannot see this: each dot-sources one file, and a mock built with
loose parameters accepts any `-Name`. `Tests/Unit/OrphanedSid.Contract.Tests.ps1` parses
`Classes`, `Private` and `Public` and fails on a function defined twice or a call that names a
parameter its callee lacks. When a helper needs a sibling that works on a file path instead of the
loaded data, give it a distinct name rather than a second definition: two backup helpers once
shared one name that way, and the file-path version silently replaced the other.

### The coverage gate is 93% and only goes up, and every test must be able to fail

`quality-gates.yml` fails below 93% command coverage over `Public/` and `Private/`; the suite measures
about 94.8%. The module arrived with test files that defined a stub of their subject and tested the
stub (`Set-ModifiedACL.Tests.ps1` defined its own `Set-ModifiedACL`), which is why coverage was 62%
with 2,400 passing tests, and with Integration and Performance folders that ran only in-file
simulators. Coverage does not catch the rest: a test with no assertion, an assertion swallowed by a
`catch`, a constant as the actual value, or an assertion on what a mock returned all execute lines
and can never fail. A correct test that fails because the module is wrong is kept with `-Skip` and
a `# Module bug (#N):` comment naming the issue that tracks the fix; it is never weakened to pass. A test file dot-sources the real
function and mocks only its collaborators; `Tests/TestHelpers/ADCmdletStubs.ps1` supplies the Active Directory cmdlets, and the
`ADIdentityNotFoundException` type, when RSAT is absent. Raise the gate as coverage rises; never
lower it. The workflow also sets `$ErrorActionPreference = 'Continue'` before `Invoke-Pester`,
because the GitHub shells prepend a Stop preference to every step: it reaches the functions under
test and turns a per-item `Write-Error` into a termination the tests do not expect.

### The analyzer gate is strict on shipping code and relaxed on tests

`quality-gates.yml` runs PSScriptAnalyzer with every Error and Warning rule over `Classes`,
`Private`, `Public`, `Build`, the root module and the manifest, and with `Tests/PSScriptAnalyzerSettings.psd1`
over `Tests` and `Tools`. The relaxed set drops the rules that fire on every stub and mock. A
suppression in shipping code carries a `Justification`. A second step runs the `ScriptSecurity`
preset over every folder, `Tests` and `Tools` included, and the relaxed set does not apply to it.

### The build tools are pinned in one place

`quality-gates.yml` names the version of Pester, PSScriptAnalyzer and PlatyPS once, under `env:`,
and every job installs and imports exactly that. The two test jobs once ran different Pester
versions without anyone having chosen that: one installed a range and the other a fixed version.
`release.yml` installs PlatyPS with a version of its own, which has to stay the same number.

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
rejects a tag that disagrees with the manifest, stages, verifies and publishes, then creates the
tag's GitHub release from that version's `## [<version>]` CHANGELOG section. That section must exist
and must not be empty, or the job fails; a dry run checks it too. A release that already exists for
the tag is left as written. The API key is the
`PSGALLERY_API_KEY` repository secret; locally the script resolves `-ApiKey`, then
`$env:PSGALLERY_API_KEY`, then a SecretManagement secret named `PSGallery-ApiKey`.

## Checks

```powershell
Invoke-Pester ./Tests                                # Pester 6; no domain or RSAT needed
Invoke-ScriptAnalyzer -Path ./Private -Recurse -Severity Error, Warning   # repeat for Public, Classes, Build
./Build/Build-Help.ps1                               # rebuild MAML after editing docs/
./Build/Publish-Module.ps1 -WhatIf                   # full release rehearsal, publishes nothing
```
