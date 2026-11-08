#Requires -Version 5.1

# OrphanedSid PowerShell module
# Finds access control entries in Active Directory that still grant rights to principals that no
# longer exist, removes them with a backup of every ACL touched, and restores an ACL from that
# backup.

$ModuleRoot = $PSScriptRoot
Write-Verbose "Initializing OrphanedSid module from: $ModuleRoot"

# Classes first: several private functions constrain a parameter to one of these types, and a type
# literal in a param block must already be defined when the file that uses it is parsed.
$classFiles = Get-ChildItem -Path (Join-Path $ModuleRoot 'Classes') -Filter '*.ps1' -ErrorAction SilentlyContinue
foreach ($class in $classFiles) {
    Write-Verbose "Loading class: $($class.Name)"
    . $class.FullName
}

# Private functions, one per file, grouped in folders by area. Logging\ goes first because every
# other function logs through Write-StructuredLog, and its own files depend on
# Initialize-LoggingConfiguration having defined the shared state.
$privateRoot = Join-Path $ModuleRoot 'Private'
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
$loadedPrivate = foreach ($folder in $privateFolders) {
    $folderPath = Join-Path $privateRoot $folder
    foreach ($function in (Get-ChildItem -Path $folderPath -Filter '*.ps1' -ErrorAction SilentlyContinue)) {
        Write-Verbose "Loading private function: $($function.Name)"
        . $function.FullName
        $function.FullName
    }
}

# Any Private folder not named above still loads; the explicit list only fixes the order.
$remaining = Get-ChildItem -Path $privateRoot -Filter '*.ps1' -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notin $loadedPrivate }
foreach ($function in $remaining) {
    Write-Verbose "Loading private function: $($function.Name)"
    . $function.FullName
}

# Public functions
$publicFunctions = Get-ChildItem -Path (Join-Path $ModuleRoot 'Public') -Filter '*.ps1' -ErrorAction SilentlyContinue
foreach ($function in $publicFunctions) {
    Write-Verbose "Loading public function: $($function.Name)"
    . $function.FullName
}

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
