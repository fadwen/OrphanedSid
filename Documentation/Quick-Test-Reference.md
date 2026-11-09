# Quick Test Reference

How to run the OrphanedSid checks locally. The same checks run in
[Quality Gates](https://github.com/fadwen/OrphanedSid/actions/workflows/quality-gates.yml) on every
push and pull request, on PowerShell 7 and on Windows PowerShell 5.1, plus a help gate on Linux.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7.x.
- Pester 6.1 or later (CI uses 6.1.0 on Windows PowerShell 5.1). The suite uses the `Should -Be`
  operator form and `Should -Invoke`.
- PSScriptAnalyzer 1.25 or later.
- No Active Directory domain and no RSAT. Every Active Directory cmdlet a test touches is mocked;
  `Tests/TestHelpers/ADCmdletStubs.ps1` defines placeholder cmdlets when the module is absent so
  Pester has something to mock.

```powershell
Install-PSResource -Name Pester, PSScriptAnalyzer -Scope CurrentUser -TrustRepository
```

## Run the suite

```powershell
Set-Location <repository root>
Invoke-Pester ./Tests
```

`Tests/Unit` covers the classes, the private functions and the three public commands;
`Tests/Integration` runs the discovery, removal and restore workflows end to end against mocked
directory responses; `Tests/Performance` holds the throughput, memory and scalability checks.
See [Tests/Pester-Test-Mapping.md](../Tests/Pester-Test-Mapping.md) for what each folder covers.

## Run one file

```powershell
Invoke-Pester ./Tests/Unit/Private/SID/Test-OrphanedSID.Tests.ps1 -Output Detailed
```

Each file loads what it needs inside `BeforeAll`, so a single file runs on its own. The public
command tests import the module from `OrphanedSid.psd1` and mock the private engine with
`Mock -ModuleName OrphanedSid`. `Tests/Unit/OrphanedSid.Contract.Tests.ps1` imports the module
with `-Force` and fails when two files define the same function or a call between module
functions names a parameter the callee does not declare.

## Coverage

CI fails below 80% line coverage over `Public/` and `Private/`. To measure it locally:

```powershell
$cfg = New-PesterConfiguration
$cfg.Run.Path = './Tests'
$cfg.CodeCoverage.Enabled = $true
$cfg.CodeCoverage.Path = './Public/*.ps1', './Private/*/*.ps1'
(Invoke-Pester -Configuration $cfg).CodeCoverage.CoveragePercent
```

CI runs the suite shuffled (`Run.Shuffle`) and with `$ErrorActionPreference = 'Continue'`. A test
that passes only in declaration order, or only on a machine whose `TEMP` is not an 8.3 path,
fails there; run with `$cfg.Run.Shuffle = $true` and the printed seed to reproduce it.

## Static analysis

The shipping code runs with every Error and Warning rule; tests and the lab tool run with the
relaxed set in `Tests/PSScriptAnalyzerSettings.psd1`, which drops the rules that fire on every
stub and mock.

```powershell
foreach ($path in 'Classes', 'Private', 'Public', 'Build', 'OrphanedSid.psm1', 'OrphanedSid.psd1') {
    Invoke-ScriptAnalyzer -Path $path -Recurse -Severity Error, Warning
}
foreach ($path in 'Tests', 'Tools') {
    Invoke-ScriptAnalyzer -Path $path -Recurse -Settings ./Tests/PSScriptAnalyzerSettings.psd1
}
```

Both loops are expected to return nothing.

## Help and release rehearsal

```powershell
./Build/Build-Help.ps1 -ValidateOnly     # structure, placeholders, links, drift, .EXTERNALHELP
./Build/Build-Help.ps1                   # rebuild en-US/OrphanedSid-Help.xml after editing docs/
./Build/Publish-Module.ps1 -WhatIf       # stage the allowlist and verify the staged module imports
```

## Writing a new test

- Dot-source the real function under test and mock only its collaborators. Never define a
  function with the name of the subject: the test then covers the stub, not the module.
- Put every dot-source, stub function and variable in `BeforeAll`. Pester 6 runs nothing a file
  defines at its top level.
- Do not define `global:` functions to replace a cmdlet. They outlive the file and replace the
  cmdlet for every file that runs after it; use `Mock` instead.
- Build temporary paths from `(Get-Item -LiteralPath $env:TEMP).FullName` or `$TestDrive`, not
  `$env:TEMP`, which is an 8.3 short path on the GitHub runners.
- Stub `Write-StructuredLog` with a `param` block that names the parameters the code passes
  (`Message`, `Level`, `Component`, `CorrelationId`, `Data`) so `Should -Invoke -ParameterFilter`
  can bind to them.
- Dot-source `Tests/TestHelpers/ADCmdletStubs.ps1` before mocking an Active Directory cmdlet, and
  add the cmdlet to its list when it is not there yet.
- `Should -Invoke` counts calls from the current `It` only. Pass `-Scope Context` or
  `-Scope Describe` when the call under test happens in a setup block.
- `Should -Throw "*text*"` matches with `-like`; escape `[` and `]` as `[[]` and `[]]`.
