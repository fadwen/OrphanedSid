function Start-OrphanedSidSession {
    <#
    .SYNOPSIS
        Prepares module-scope state for one command invocation.

    .DESCRIPTION
        Every public command runs on top of the same per-run state: the ActiveDirectory module,
        the logging system with its correlation ID and level, the configuration object, the
        memory manager and the statistics counters. This function sets all of it up in one place
        so Find-OrphanedSid, Remove-OrphanedSid and Restore-OrphanedSidBackup cannot drift apart
        in how they start.

        The ActiveDirectory module is checked here rather than declared in the manifest. It is
        Windows-only RSAT and not on the Gallery, so declaring it would make the module
        unimportable on any host without RSAT, including the test runners.

        The log level follows -Verbose and -Debug on the calling command when -LogLevel was not
        given explicitly, because an operator who asked for verbose console output expects the
        same detail in the file. When the command line chose no level at all, the LogLevel of the
        -ConfigPath file applies, and Information when the file has none.

    .PARAMETER CommandName
        Name of the public command starting the run. Used for the default log file name and the
        first log line.

    .PARAMETER ConfigPath
        Optional JSON configuration file; see ScriptConfiguration.LoadFromFile for the keys read.

    .PARAMETER LogPath
        Log file path. When omitted the log goes to .\Logs\<CommandName>_<yyyyMMdd_HHmmss>.log
        under the current directory.

    .PARAMETER MaxMemoryUsageMB
        Memory threshold handed to the memory manager.

    .PARAMETER CorrelationId
        Correlation identifier for the run. Generated when omitted.

    .PARAMETER LogLevel
        File log level. Overrides the -Verbose/-Debug inference when bound.

    .PARAMETER LogLevelBound
        True when the caller bound -LogLevel explicitly. Without it the level is inferred from the
        caller's $VerbosePreference and $DebugPreference.

    .PARAMETER SuppressConsoleOutput
        Stops console output; the log file is still written.

    .PARAMETER RequireActiveDirectory
        Fail when the ActiveDirectory module cannot be imported. Every public command sets this;
        it exists as a switch so tests can exercise the session without RSAT.

    .OUTPUTS
        [hashtable] The initialization results from Initialize-ScriptExecution: Config,
        MemoryManager, Statistics, LogPath and CorrelationId.

    .EXAMPLE
        PS> $session = Start-OrphanedSidSession -CommandName 'Find-OrphanedSid' -CorrelationId $id -RequireActiveDirectory

        DESCRIPTION: Sets up logging, configuration and the memory manager for a discovery run
        OUTPUT: The initialization hashtable; module-scope variables are populated as a side effect
        USE CASE: Called from the begin block of every public command

    .NOTES
        Author: Jeffrey Stuhr
        Blog: https://www.techbyjeff.net
        LinkedIn: https://www.linkedin.com/in/jeffrey-stuhr-034214aa/

        TROUBLESHOOTING:
        - Module not found: .\Troubleshooting\Common\Common-Issues.md
        - Logging problems: .\Troubleshooting\Security\Security-Logging-Issues.md
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Sets module-scope run state; the log folder write is pinned -WhatIf:$false by design')]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CommandName,

        [Parameter()]
        [string]$ConfigPath,

        [Parameter()]
        [string]$LogPath,

        [Parameter()]
        [ValidateRange(100, 16384)]
        [int]$MaxMemoryUsageMB = 1024,

        [Parameter()]
        [string]$CorrelationId = [System.Guid]::NewGuid().ToString(),

        [Parameter()]
        [ValidateSet('Critical', 'Error', 'Warning', 'Information', 'Debug', 'Verbose')]
        [string]$LogLevel = 'Information',

        [Parameter()]
        [bool]$LogLevelBound = $false,

        [Parameter()]
        [switch]$SuppressConsoleOutput,

        [Parameter()]
        [switch]$RequireActiveDirectory
    )

    if ($RequireActiveDirectory) {
        if (-not (Get-Module -Name ActiveDirectory -ListAvailable)) {
            $message = 'The ActiveDirectory PowerShell module is not available. Install RSAT: Active Directory ' +
                'PowerShell (Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0) ' +
                'and run the command again.'
            Write-Error $message -ErrorAction Stop
        }
        if (-not (Get-Module -Name ActiveDirectory)) {
            Import-Module -Name ActiveDirectory -ErrorAction Stop
        }
    }

    # Shared logging state. These are read by Write-StructuredLogEntry and the security loggers.
    $script:CorrelationId = $CorrelationId
    $script:SuppressConsoleOutput = [bool]$SuppressConsoleOutput

    # Precedence: -LogLevel, then -Verbose or -Debug, then the -ConfigPath file's LogLevel, then
    # Information. The file is read later, so only the decision is made here.
    $useConfigLogLevel = $false
    if (-not $LogLevelBound) {
        if ($VerbosePreference -eq 'Continue') {
            $LogLevel = 'Verbose'
        }
        elseif ($DebugPreference -eq 'Continue') {
            $LogLevel = 'Debug'
        }
        else {
            $useConfigLogLevel = $true
        }
    }
    $script:LogLevel = $LogLevel

    # Precedence: -LogPath, then the -ConfigPath file's LogFilePath, then the default name below. The
    # file is read later, so only the decision is made here. A path of only spaces is no path: it
    # gets the same default under the current directory.
    $useConfigLogPath = $false
    if ([string]::IsNullOrWhiteSpace($LogPath)) {
        $useConfigLogPath = $true
        $logDirectory = Join-Path -Path (Get-Location).Path -ChildPath 'Logs'
        $LogPath = Join-Path -Path $logDirectory -ChildPath "${CommandName}_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    }

    # Reset per-run state so one command's results never leak into the next in the same session
    $script:StreamingResults = $null
    $script:RemovalResults = @()
    $script:CurrentDomainSID = $null

    $initParams = @{
        ConfigPath            = $ConfigPath
        LogPath               = $LogPath
        UseConfigLogPath      = $useConfigLogPath
        MaxMemoryUsageMB      = $MaxMemoryUsageMB
        CorrelationId         = $CorrelationId
        LogLevel              = $LogLevel
        UseConfigLogLevel     = $useConfigLogLevel
        SuppressConsoleOutput = $SuppressConsoleOutput
    }
    $initResults = Initialize-ScriptExecution @initParams

    $script:Config = $initResults.Config
    $script:MemoryManager = $initResults.MemoryManager
    $script:Statistics = $initResults.Statistics
    $script:LogPath = $initResults.LogPath

    Write-StructuredLog "$CommandName starting (CorrelationId: $CorrelationId)" -Level Information -Component 'Main' -CorrelationId $CorrelationId

    return $initResults
}
