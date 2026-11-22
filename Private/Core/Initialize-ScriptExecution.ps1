#Requires -Version 5.1

function Initialize-ScriptExecution {
    <#
    .SYNOPSIS
        Initialize script execution environment with comprehensive validation

    .DESCRIPTION
        Sets up the script execution environment including configuration loading,
        logging initialization, memory management setup, and dependency validation.
        Provides comprehensive error handling and validation for enterprise environments.

        INITIALIZATION FEATURES:
        - Rotation of the log file, when the configuration asks for it and the file is over
          its size limit
        - Creation of the memory manager with the limit of -MaxMemoryUsageMB
        - Configuration validation and error handling
        - Performance statistics initialization
        - Correlation ID tracking

    .PARAMETER ConfigPath
        [String] (Optional) Path to configuration JSON file for custom settings.
        If not provided, default configuration will be used.

        VALIDATION RULES:
        - A file that is not there, that cannot be read as JSON, or that holds a value outside
          its range ends the function with the error ConfigurationFileNotLoaded

    .PARAMETER LogPath
        [String] (Optional) Path for log file output.
        If not provided, default timestamped log file will be created.

        VALIDATION RULES:
        - Without a path the file is .\Logs\OrphanedSid_[timestamp].log
        - The folder is created when it does not exist. A path that cannot be used gives a
          warning, and the log goes to a file of that name in the current location

    .PARAMETER MaxMemoryUsageMB
        [Int] (Optional) Maximum memory usage threshold in MB (Default: 1024).
        Controls memory management and prevents system resource exhaustion.

        VALIDATION RULES:
        - Must be between 100 and 16384 MB

        PERFORMANCE IMPACT:
        Lower values trigger more frequent memory checks and cleanup.
        Higher values allow larger datasets but risk system instability.

    .PARAMETER CorrelationId
        [String] (Optional) Unique identifier for tracking operations across log entries.
        If not provided, a new GUID will be generated automatically. The value is not
        checked.

    .PARAMETER LogLevel
        [String] (Optional) Sets the minimum log level for file output (Default: Information).
        Controls the verbosity of log file output while maintaining performance.

        VALIDATION RULES:
        - Must be one of: Critical, Error, Warning, Information, Debug, Verbose
        - A level includes the entries of the levels before it in that list

    .PARAMETER SuppressConsoleOutput
        [Switch] (Optional) Suppresses console output for automation scenarios.
        Logs are still written to file, but console output is disabled.

    .PARAMETER UseConfigLogLevel
        [Switch] (Optional) Replace -LogLevel with the LogLevel of the -ConfigPath file once that
        file is loaded. Start-OrphanedSidSession sets it only when the command line chose no level
        (-LogLevel, -Verbose or -Debug), so the command line always wins over the file. A file
        without LogLevel leaves the level at Information. Without -ConfigPath it has no effect.

    .PARAMETER UseConfigLogPath
        [Switch] (Optional) Use the LogFilePath of the -ConfigPath file, when it sets one, in place
        of -LogPath. Start-OrphanedSidSession sets it only when the command line gave no -LogPath,
        and passes the default name as -LogPath, so -LogPath wins over the file and the file over
        the default. The chosen path is set up before anything is written to it, so one run writes
        one log file.

    .OUTPUTS
        [Hashtable] Initialization results containing:
        - Config: Loaded and validated configuration object
        - MemoryManager: Initialized memory management system
        - Statistics: Performance tracking object
        - LogPath: Resolved log file path
        - CorrelationId: Tracking identifier for this session

    .EXAMPLE
        PS> Initialize-ScriptExecution -LogPath ".\Logs\script.log" -MaxMemoryUsageMB 1024

        DESCRIPTION: Initialize with custom log path and memory limit
        OUTPUT: Hashtable with initialized components
        USE CASE: Standard production environment setup
        DURATION: Typically 1-3 seconds depending on configuration complexity

    .EXAMPLE
        PS> Initialize-ScriptExecution -ConfigPath ".\Config\prod.json" -LogLevel Debug

        DESCRIPTION: Initialize with production configuration and debug logging
        OUTPUT: Hashtable with configuration loaded from file
        BUSINESS CASE: Production deployment with enhanced monitoring

    .EXAMPLE
        PS> $init = Initialize-ScriptExecution; $init.Statistics.StartTime

        DESCRIPTION: Access initialization results for monitoring
        OUTPUT: Returns initialization timestamp

    .NOTES
        Author: Jeffrey Stuhr
        Blog: https://www.techbyjeff.net
        LinkedIn: https://www.linkedin.com/in/jeffrey-stuhr-034214aa/

        SECURITY CONSIDERATIONS:
        - Configuration files may contain sensitive settings
        - Log files should be protected with appropriate file permissions
        - Memory management prevents denial-of-service scenarios
        - Correlation IDs enable security event tracking

        TROUBLESHOOTING:
        - For initialization failures: .\Troubleshooting\Common\Common-Issues.md
        - For memory management: .\Troubleshooting\Performance\Memory-Management.md

        KNOWN LIMITATIONS:
        - Configuration changes require script restart
        - Log file rotation may briefly interrupt logging
        - Memory limits are advisory, not enforced by OS
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
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
        [switch]$UseConfigLogLevel,

        [Parameter()]
        [switch]$UseConfigLogPath,

        [Parameter()]
        [switch]$SuppressConsoleOutput
    )

    begin {
        Write-Verbose "Starting script initialization with CorrelationId: $CorrelationId"
    }

    process {
        try {
            # Verify required classes are available (they should be loaded by the main script)
            Write-Verbose "Verifying required classes are available..."
            $requiredTypes = @('ScriptConfiguration', 'ProcessingStatistics', 'MemoryManager')
            $missingTypes = @()

            foreach ($typeName in $requiredTypes) {
                try {
                    $null = $typeName -as [type]
                    if (-not ($typeName -as [type])) {
                        $missingTypes += $typeName
                    }
                }
                catch {
                    $missingTypes += $typeName
                }
            }

            # The three checks of this try raise their error from inside it, where
            # ThrowTerminatingError() passes the catch below by. Each therefore writes the log
            # entry that the catch writes for an error of a step.
            if ($missingTypes.Count -gt 0) {
                $message = "Required types not available: $($missingTypes -join ', '). " +
                    'Classes should be loaded by the main script before calling Initialize-ScriptExecution.'
                Write-StructuredLog "Script initialization failed: $message" -Level Error -Component 'Initialization' -CorrelationId $CorrelationId
                $exception = [System.InvalidOperationException]::new($message)
                $category = [System.Management.Automation.ErrorCategory]::InvalidOperation
                $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                    $exception, 'RequiredTypeMissing', $category, ($missingTypes -join ', '))
                $PSCmdlet.ThrowTerminatingError($errorRecord)
            }

            Write-Verbose "All required classes are available: $($requiredTypes -join ', ')"

            Initialize-LoggingSystem -CorrelationId $CorrelationId -LogLevel $LogLevel -SuppressConsoleOutput:$SuppressConsoleOutput

            # The configuration is read before the log file is set up, because its rotation settings
            # decide whether the existing file is renamed aside before this run writes to it. A file
            # that fails to load is reported once the log exists, so the failure reaches the file.
            # A path that was given is loaded, whether or not the file is there. A file that
            # has gone since the command checked the path fails in LoadFromFile, like one
            # that cannot be read, so a run that asked for a configuration never goes on
            # with the defaults in its place (#208).
            $configFromFile = -not [string]::IsNullOrWhiteSpace($ConfigPath)
            $configLoadError = $null
            $script:Config = if ($configFromFile) {
                try {
                    [ScriptConfiguration]::new().LoadFromFile($ConfigPath)
                }
                catch {
                    $configLoadError = $_
                    [ScriptConfiguration]::new()
                }
            } else {
                [ScriptConfiguration]::new()
            }

            $rotateAboveMB = 0
            if ($script:Config.EnableLogFileRotation -and $script:Config.MaxLogFileSizeMB -gt 0) {
                $rotateAboveMB = $script:Config.MaxLogFileSizeMB
            }
            $targetLogPath = if ($LogPath) { $LogPath } else { ".\Logs\OrphanedSid_$(Get-Date -Format 'yyyyMMdd_HHmmss').log" }
            # The file's LogFilePath is chosen here, before anything is written, and goes through the
            # same resolution, refusal and rotation as -LogPath. Swapping it in after setup once split
            # a run across two files and overrode -LogPath given on the command line.
            # A path from the file is refused when it lies in a system folder: whoever can edit
            # the file would otherwise choose a file there for a privileged run to append to. A
            # path from the command line is the operator's own choice.
            $logPathFromFile = $false
            if ($UseConfigLogPath -and -not [string]::IsNullOrWhiteSpace($script:Config.LogFilePath)) {
                $targetLogPath = $script:Config.LogFilePath
                $logPathFromFile = $true
            }
            $logDirectoryParameters = @{
                LogPath = $targetLogPath
                RotateAboveMB = $rotateAboveMB
                RefuseSystemFolder = $logPathFromFile
            }
            $null = Initialize-LogDirectory @logDirectoryParameters

            if ($script:LogRotation) {
                # The table has an Error key only when the rotation failed
                if ($script:LogRotation.ContainsKey('Error')) {
                    Write-StructuredLog "Log file rotation failed for $($script:LogRotation.From) ($($script:LogRotation.SizeMB) MB); appending to it: $($script:LogRotation.Error)" -Level Warning -Component 'Initialization' -CorrelationId $CorrelationId
                }
                else {
                    Write-StructuredLog "Rotated log file to: $($script:LogRotation.To) (Size: $($script:LogRotation.SizeMB) MB)" -Level Information -Component 'Initialization' -CorrelationId $CorrelationId
                }
            }

            if ($configLoadError) {
                # The message is the one the file's own check gave. The error gets an ID that a
                # caller can match, and keeps what was raised as its inner exception.
                $message = $configLoadError.Exception.Message
                Write-StructuredLog "Script initialization failed: $message" -Level Error -Component 'Initialization' -CorrelationId $CorrelationId
                $exception = [System.IO.InvalidDataException]::new($message, $configLoadError.Exception)
                $category = [System.Management.Automation.ErrorCategory]::InvalidData
                $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                    $exception, 'ConfigurationFileNotLoaded', $category, $ConfigPath)
                $PSCmdlet.ThrowTerminatingError($errorRecord)
            }
            if ($configFromFile) {
                Write-StructuredLog "Loaded configuration from file: $ConfigPath" -Level Debug -Component 'Initialization' -CorrelationId $CorrelationId
            } else {
                Write-StructuredLog "Using default configuration" -Level Debug -Component 'Initialization' -CorrelationId $CorrelationId
            }

            # Validate configuration
            if (-not $script:Config.ValidateConfiguration()) {
                $message = 'Configuration validation failed'
                Write-StructuredLog "Script initialization failed: $message" -Level Error -Component 'Initialization' -CorrelationId $CorrelationId
                $exception = [System.IO.InvalidDataException]::new($message)
                $category = [System.Management.Automation.ErrorCategory]::InvalidData
                $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                    $exception, 'ConfigurationInvalid', $category, $ConfigPath)
                $PSCmdlet.ThrowTerminatingError($errorRecord)
            }

            # Validated above, so the level is one Test-LogLevel knows. Applied after the lines that
            # precede it, which were filtered at the command's level.
            if ($UseConfigLogLevel -and $configFromFile) {
                $script:LogLevel = $script:Config.LogLevel
                Write-StructuredLog "File log level set to $($script:Config.LogLevel) by the configuration file" -Level Debug -Component 'Initialization' -CorrelationId $CorrelationId
            }

            Write-StructuredLog "Configuration loaded and validated successfully" -Level Debug -Component 'Initialization' -CorrelationId $CorrelationId

            # Initialize memory manager using centralized memory management module
            Write-StructuredLog "Initializing memory manager (Limit: $MaxMemoryUsageMB MB)..." -Level Debug -Component 'Initialization' -CorrelationId $CorrelationId
            # Pinned: creating the manager is setup, not the operation -WhatIf rehearses
            $script:MemoryManager = Initialize-MemoryManager -MaxMemoryMB $MaxMemoryUsageMB -CheckInterval $script:Config.MemoryCheckInterval -CorrelationId $CorrelationId -WhatIf:$false

            # Initialize statistics
            Write-StructuredLog "Initializing performance statistics..." -Level Debug -Component 'Initialization' -CorrelationId $CorrelationId
            $script:Statistics = [ProcessingStatistics]::new()

            # $script:LogPath is the one Initialize-LogDirectory settled on: the resolved path, the
            # default name for a blank one, or the fallback for a refused one.

            # Return initialization results
            $initResults = @{
                Config = $script:Config
                MemoryManager = $script:MemoryManager
                Statistics = $script:Statistics
                LogPath = $script:LogPath
                CorrelationId = $CorrelationId
            }

            Write-StructuredLog "Script initialization completed successfully" -Level Debug -Component 'Initialization' -CorrelationId $CorrelationId
            return $initResults

        } catch {
            Write-StructuredLog "Script initialization failed: $($_.Exception.Message)" -Level Error -Component 'Initialization' -CorrelationId $CorrelationId
            $PSCmdlet.ThrowTerminatingError($_)
        }
    }
}
