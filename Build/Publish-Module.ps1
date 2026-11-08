#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Microsoft.PowerShell.PSResourceGet'; ModuleVersion = '1.0.0' }

<#
.SYNOPSIS
    Stages the shipping files into a clean folder and publishes them to a PSResource repository.

.DESCRIPTION
    Publish-PSResource packages the whole directory that contains the manifest. This repository
    IS the module root, so publishing from here directly would ship the entire working tree -
    Tests and their fixtures, docs, Build, .github, the Archive, and every object under .git.

    A Gallery version can never be deleted, only unlisted, and the .nupkg stays downloadable at
    its direct URL after unlisting. Anything published once is published permanently.

    So the shipping set below is an allowlist, not an exclusion list. A new folder added to the
    repository does not ship until someone names it here deliberately.

    Before staging, Build-Help.ps1 validates the help Markdown under docs/ and rebuilds
    en-US/OrphanedSid-Help.xml, which is the help every exported command serves.

.PARAMETER ApiKey
    PowerShell Gallery API key. Usually omitted - see -SecretName. Never needed with -WhatIf.

.PARAMETER SecretName
    Name of the SecretManagement secret holding the Gallery API key. Defaults to
    'PSGallery-ApiKey'. Store it once with:

        Set-Secret -Name PSGallery-ApiKey -Secret '<key>'

.PARAMETER Repository
    Target repository name. Defaults to PSGallery.

.PARAMETER StagingPath
    Where to assemble the shipping tree. Defaults to out/ in the repository root, which is
    git-ignored. Removed and recreated on every run.

.PARAMETER ModuleRoot
    Repository root. Defaults to the parent of the folder holding this script.

.PARAMETER SkipHelpBuild
    Skip the help gates. Only for iterating on this script itself.

.EXAMPLE
    ./Build/Publish-Module.ps1 -WhatIf

    DESCRIPTION: Stages the shipping tree and reports exactly what would be published
    OUTPUT: The staged file list, total size, and the resolved version
    USE CASE: The rehearsal to run before every real publish

.EXAMPLE
    ./Build/Publish-Module.ps1

    DESCRIPTION: Stages, verifies the staged tree imports in a fresh process, and publishes
    OUTPUT: A confirmation naming the published version
    USE CASE: The actual release, after the tests pass and CHANGELOG.md is updated

.EXAMPLE
    ./Build/Publish-Module.ps1 -Repository LocalTest -ApiKey ignored

    DESCRIPTION: Publishes to a local file-system repository registered with Register-PSResourceRepository
    OUTPUT: A .nupkg in the local repository folder
    USE CASE: Inspecting the real package contents without consuming a Gallery version

.NOTES
    Author: Jeffrey Stuhr
    Blog: https://www.techbyjeff.net
    LinkedIn: https://www.linkedin.com/in/jeffrey-stuhr-034214aa/
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter()]
    [string]$ApiKey,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$SecretName = 'PSGallery-ApiKey',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$Repository = 'PSGallery',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$StagingPath,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ModuleRoot = (Split-Path -Parent $PSScriptRoot),

    [Parameter()]
    [switch]$SkipHelpBuild
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$moduleName = 'OrphanedSid'

# The complete shipping set. Anything not named here stays out of the package.
$shipFiles = @(
    "$moduleName.psd1"
    "$moduleName.psm1"
    'LICENSE'
    'README.md'
    'CHANGELOG.md'
)
$shipFolders = @(
    'Classes'
    'Private'
    'Public'
    'en-US'
)

if (-not $StagingPath) {
    $StagingPath = Join-Path $ModuleRoot 'out'
}

# --- 0. Resolve the API key -------------------------------------------------------
# Resolved first, so a missing key costs a second rather than failing after the help build and
# the whole staging pass. Skipped under -WhatIf, which publishes nothing.
if (-not $WhatIfPreference -and -not $ApiKey) {
    $vaultError = $null

    if ($env:PSGALLERY_API_KEY) {
        $ApiKey = $env:PSGALLERY_API_KEY
        Write-Information 'API key: $env:PSGALLERY_API_KEY.' -InformationAction Continue
    }
    elseif (Get-Module -ListAvailable Microsoft.PowerShell.SecretManagement) {
        Import-Module Microsoft.PowerShell.SecretManagement

        # try/catch, not -ErrorAction SilentlyContinue: a locked SecretStore throws from the vault
        # extension and SilentlyContinue does not suppress it.
        try {
            $stored = Get-Secret -Name $SecretName -AsPlainText -ErrorAction Stop
        }
        catch {
            $vaultError = $_.Exception.Message
            $stored = $null
        }

        if ($stored) {
            $ApiKey = $stored
            Write-Information "API key: the '$SecretName' secret." -InformationAction Continue
        }
    }

    if (-not $ApiKey) {
        $lines = @('No PowerShell Gallery API key found.')
        if ($vaultError) {
            $lines += "The secret vault could not be read: $vaultError"
            $lines += 'If the key is already stored there, run Unlock-SecretStore and try again.'
            $lines += ''
        }
        $lines += 'Create a key at https://www.powershellgallery.com/account/apikeys, then supply it by any of:'
        $lines += "  Set-Secret -Name $SecretName -Secret '<key>'   (stored once, recommended)"
        $lines += '  $env:PSGALLERY_API_KEY = ''<key>''            (this session only)'
        $lines += "  ./Build/Publish-Module.ps1 -ApiKey '<key>'    (one-off)"

        throw ($lines -join [Environment]::NewLine)
    }
}

# --- 1. Help gates ----------------------------------------------------------------
# $WhatIfPreference is cleared for the duration. Preference variables are inherited by child
# scopes, so under -WhatIf it would reach Export-MamlCommandHelp inside Build-Help.ps1, which then
# compiles nothing and the rehearsal silently stops verifying the help build.
if (-not $SkipHelpBuild) {
    $priorWhatIf = $WhatIfPreference
    $WhatIfPreference = $false
    try {
        & (Join-Path $PSScriptRoot 'Build-Help.ps1') -ModuleRoot $ModuleRoot | Out-Null
    }
    finally {
        $WhatIfPreference = $priorWhatIf
    }
    Write-Information 'Help gates passed and MAML rebuilt.' -InformationAction Continue
}

# --- 2. Manifest ------------------------------------------------------------------
$manifestPath = Join-Path $ModuleRoot "$moduleName.psd1"
$manifest = Test-ModuleManifest -Path $manifestPath
$version = $manifest.Version

# An empty URI key fails the NuGet pack with 'IconUrl cannot be empty', naming neither the
# manifest nor the key.
foreach ($uriKey in 'IconUri', 'ProjectUri', 'LicenseUri', 'HelpInfoUri') {
    $value = $manifest.PSObject.Properties[$uriKey].Value
    if ($null -ne $value -and [string]::IsNullOrWhiteSpace([string]$value)) {
        throw "$uriKey is present but empty in the manifest. Remove the key entirely - an empty URI fails the NuGet pack."
    }
}

if (-not $manifest.Description) {
    throw 'The manifest needs a Description; the Gallery rejects a package without one.'
}
if (-not $manifest.Tags) {
    throw 'The manifest needs Tags for the module to be discoverable.'
}

# Gallery metadata limits are enforced only at upload. Measure them here so a pull request fails
# rather than the tag-driven release.
$rawManifest = Import-PowerShellDataFile -Path $manifestPath
$tags = @($rawManifest.PrivateData.PSData.Tags) + 'PSModule' + 'PSIncludes_Function' +
    @($rawManifest.CompatiblePSEditions | ForEach-Object { "PSEdition_$_" }) +
    @($manifest.ExportedFunctions.Keys | ForEach-Object { "PSFunction_$_"; "PSCommand_$_" })
$limits = @{
    Description  = @{ Length = $manifest.Description.Length; Limit = 4000 }
    Tags         = @{ Length = ($tags -join ' ').Length; Limit = 4000 }
    ReleaseNotes = @{ Length = ([string]$rawManifest.PrivateData.PSData.ReleaseNotes).Length; Limit = 10600 }
}
foreach ($field in $limits.Keys) {
    $measured = $limits[$field]
    if ($measured.Length -gt $measured.Limit) {
        throw "The manifest's $field is $($measured.Length) characters; the Gallery accepts at most $($measured.Limit)."
    }
}

# --- 3. Already published? --------------------------------------------------------
if (-not $WhatIfPreference) {
    $existing = Find-PSResource -Name $moduleName -Repository $Repository -Version "$version" -ErrorAction SilentlyContinue
    if ($existing) {
        throw "$moduleName $version is already on $Repository. Gallery versions cannot be replaced - bump ModuleVersion and update CHANGELOG.md."
    }
}

# --- 4. Stage ---------------------------------------------------------------------
# Every staging cmdlet is pinned to -WhatIf:$false. SupportsShouldProcess on this script propagates
# $WhatIfPreference to each of them, so an unpinned -WhatIf run would copy nothing and then fail on
# the empty folder. Only the publish at the end is gated by ShouldProcess.
if (Test-Path $StagingPath) {
    Remove-Item -LiteralPath $StagingPath -Recurse -Force -WhatIf:$false
}
$stageModule = Join-Path $StagingPath $moduleName
New-Item -Path $stageModule -ItemType Directory -Force -WhatIf:$false | Out-Null

foreach ($file in $shipFiles) {
    $source = Join-Path $ModuleRoot $file
    if (-not (Test-Path -LiteralPath $source)) {
        throw "Shipping file '$file' is missing from the repository root."
    }
    Copy-Item -LiteralPath $source -Destination $stageModule -Force -WhatIf:$false
}

foreach ($folder in $shipFolders) {
    $source = Join-Path $ModuleRoot $folder
    if (-not (Test-Path -LiteralPath $source)) {
        throw "Shipping folder '$folder' is missing from the repository root."
    }
    Copy-Item -LiteralPath $source -Destination $stageModule -Recurse -Force -WhatIf:$false
}

$staged = Get-ChildItem -LiteralPath $stageModule -Recurse -File
$totalKb = [math]::Round(($staged | Measure-Object -Property Length -Sum).Sum / 1KB, 1)

Write-Information "Staged $($staged.Count) file(s), $totalKb KB, to $stageModule" -InformationAction Continue
$staged |
    ForEach-Object { $_.FullName.Substring($stageModule.Length + 1) } |
    Sort-Object |
    ForEach-Object { Write-Information "  $_" -InformationAction Continue }

# --- 5. Prove the staged tree imports ----------------------------------------------
# The staged copy is what users get. If the allowlist dropped something the module needs - a
# Private helper, a class file, or the en-US folder holding the MAML - it should fail here in a
# fresh process, not after someone installs it. Every command must serve the compiled help: with
# .EXTERNALHELP on each export there is no comment block to fall back on.
#
# One private function is exercised through the module too, because a module that imports and
# serves help can still be missing a helper that only runs when a command does. Test-SIDFormat is
# pure and needs no directory.
$stagedManifest = Join-Path $stageModule "$moduleName.psd1"
$expectedCount = @($manifest.ExportedFunctions.Keys).Count

$check = @"
`$ErrorActionPreference = 'Stop'
Import-Module '$stagedManifest' -Force
`$commands = @((Get-Module $moduleName).ExportedFunctions.Keys) | Sort-Object
if (`$commands.Count -ne $expectedCount) {
    throw "Staged module exported `$(`$commands.Count) command(s); the manifest declares $expectedCount."
}
`$ok = & (Get-Module $moduleName) { Test-SIDFormat -SID 'S-1-5-21-1-2-3-1001' }
if (-not `$ok) {
    throw 'Staged module could not validate a well-formed SID through its private helper.'
}
`$noHelp = @(foreach (`$name in `$commands) {
    if (-not (Get-Help `$name -Full -ErrorAction SilentlyContinue).Description) { `$name }
})
if (`$noHelp) {
    throw "Staged module served no MAML help for: `$(`$noHelp -join ', ')"
}
'STAGED-OK'
"@

$result = pwsh -NoProfile -NonInteractive -Command $check 2>&1
if ($LASTEXITCODE -ne 0 -or "$result" -notmatch 'STAGED-OK') {
    throw "The staged module failed verification:`n$($result -join [Environment]::NewLine)"
}
Write-Information 'Staged module imports, exports the declared commands, runs a private helper, and serves MAML help for every command.' -InformationAction Continue

# --- 6. Publish -------------------------------------------------------------------
if (-not $PSCmdlet.ShouldProcess("$moduleName $version -> $Repository", 'Publish')) {
    Write-Information "WhatIf: nothing published. Staged tree left at $stageModule for inspection." -InformationAction Continue
    return
}

Publish-PSResource -Path $stageModule -Repository $Repository -ApiKey $ApiKey -SkipDependenciesCheck

Write-Information "Published $moduleName $version to $Repository." -InformationAction Continue
Write-Information "Indexing takes a few minutes, then: Install-PSResource -Name $moduleName" -InformationAction Continue
