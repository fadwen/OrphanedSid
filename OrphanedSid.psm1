#Requires -Version 5.1

# OrphanedSid PowerShell module
# Finds access control entries in Active Directory that still grant rights to principals that no
# longer exist, removes them with a backup of every ACL touched, and restores an ACL from that
# backup.

$ModuleRoot = $PSScriptRoot
Write-Verbose "Initializing OrphanedSid module from: $ModuleRoot"

# Classes first: several private functions constrain a parameter to one of these types, and a type
# literal in a param block must already be defined when the file that uses it is parsed.

# Private functions, one per file, grouped in folders by area. Logging\ goes first because every
# other function logs through Write-StructuredLog, and its own files depend on
# Initialize-LoggingConfiguration having defined the shared state.
$privateFolders = @(
    'Logging'
    'FileSystem'
    'System'
    'ActiveDirectory'
    'Operations'
    'SID'
    'Security'
    'ACL'
    'Backup'
    'Utilities'
    'Reporting'
    'Core'
)

# Every folder named here has to be present. A missing one is an incomplete installation, and
# skipping it would import the module with commands that fail, or report nothing, when they run.
$classesPath = Join-Path -Path $ModuleRoot -ChildPath 'Classes'
$publicPath = Join-Path -Path $ModuleRoot -ChildPath 'Public'
$privateRoot = Join-Path -Path $ModuleRoot -ChildPath 'Private'
$requiredFolders = @(
    $classesPath
    foreach ($folder in $privateFolders) {
        Join-Path -Path $privateRoot -ChildPath $folder
    }
    $publicPath
)
foreach ($folderPath in $requiredFolders) {
    if (-not (Test-Path -LiteralPath $folderPath -PathType Container)) {
        $message = "OrphanedSid cannot be imported: the folder '$folderPath' is missing. Install the module again."
        throw [System.IO.DirectoryNotFoundException]::new($message)
    }
}

$classFiles = @(Get-ChildItem -LiteralPath $classesPath -Filter '*.ps1' -File -ErrorAction Stop)
$orderedPrivateFiles = @(
    foreach ($folder in $privateFolders) {
        $folderPath = Join-Path -Path $privateRoot -ChildPath $folder
        Get-ChildItem -LiteralPath $folderPath -Filter '*.ps1' -File -ErrorAction Stop
    }
)

# Any Private folder not named above still loads; the explicit list only fixes the order.
$orderedPrivatePaths = @($orderedPrivateFiles | ForEach-Object { $_.FullName })
$otherPrivateFiles = @(
    Get-ChildItem -LiteralPath $privateRoot -Filter '*.ps1' -File -Recurse -ErrorAction Stop |
        Where-Object { $orderedPrivatePaths -notcontains $_.FullName }
)
$publicFiles = @(Get-ChildItem -LiteralPath $publicPath -Filter '*.ps1' -File -ErrorAction Stop)

foreach ($sourceFile in $classFiles + $orderedPrivateFiles + $otherPrivateFiles + $publicFiles) {
    Write-Verbose "Loading $($sourceFile.FullName)"
    try {
        . $sourceFile.FullName
    } catch {
        # A file that fails to load has to fail the import. Left to itself, PowerShell reports a
        # file that does not parse and carries on, and the module is imported with that file's
        # functions missing.
        $message = "OrphanedSid cannot be imported: '$($sourceFile.FullName)' failed to load. $($_.Exception.Message)"
        throw [System.InvalidOperationException]::new($message, $_.Exception)
    }
}

# The loader's own variables are removed, so that none of them stays in module scope, where a
# function that reads a variable of the same name before assigning it would find the leftover.
$loaderVariables = @(
    'classesPath', 'publicPath', 'privateRoot', 'privateFolders', 'requiredFolders', 'folder', 'folderPath'
    'classFiles', 'orderedPrivateFiles', 'orderedPrivatePaths', 'otherPrivateFiles', 'publicFiles', 'sourceFile'
)
Remove-Variable -Name $loaderVariables -Scope Script
Remove-Variable -Name 'loaderVariables' -Scope Script

# Module-scope state shared by the private functions. A command sets these for the duration of
# one run through Start-OrphanedSidSession and clears them in Stop-OrphanedSidSession.
$script:Config = $null
$script:MemoryManager = $null
$script:Statistics = $null
$script:StreamingResults = $null
$script:RemovalResults = @()
$script:CurrentDomainSID = $null
$script:SIDValidationCache = @{}
$script:SIDValidationCacheLookups = 0
$script:SIDValidationCacheHits = 0

Export-ModuleMember -Function @(
    'Find-OrphanedSid'
    'Remove-OrphanedSid'
    'Restore-OrphanedSidBackup'
)

$ExecutionContext.SessionState.Module.OnRemove = {
    Write-Verbose 'Cleaning up OrphanedSid module'
    foreach ($name in 'Config', 'MemoryManager', 'Statistics', 'StreamingResults', 'RemovalResults', 'CurrentDomainSID', 'SIDValidationCache') {
        Remove-Variable -Name $name -Scope Script -ErrorAction SilentlyContinue
    }
}
