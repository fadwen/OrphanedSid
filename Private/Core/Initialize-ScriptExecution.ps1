#Requires -Version 5.1

<#
.SYNOPSIS
    Script execution initialization module for Find-UnknownSID

.DESCRIPTION
    Provides comprehensive script initialization capabilities including configuration
    loading, logging setup, memory management initialization, and dependency validation.
    Focused solely on environment setup and preparation for script execution.

.NOTES
    Author: Jeffrey Stuhr
    Blog: https://www.techbyjeff.net
    LinkedIn: https://www.linkedin.com/in/jeffrey-stuhr-034214aa/
    Last Updated: 2025-07-04
    Version: 2.0.0

    TROUBLESHOOTING:
    - For initialization issues: .\Troubleshooting\Common\Initialization-Issues.md
    - For configuration problems: .\Troubleshooting\Common\Configuration-Problems.md
#>


function Initialize-ScriptExecution {
    <#
    .SYNOPSIS
        Initialize script execution environment with comprehensive validation

    .DESCRIPTION
        Sets up the script execution environment including configuration loading,
        logging initialization, memory management setup, and dependency validation.
        Provides comprehensive error handling and validation for enterprise environments.

        BUSINESS VALUE:
        - Ensures consistent environment setup across all script executions
        - Provides comprehensive logging and monitoring capabilities
        - Implements memory management to prevent resource exhaustion
        - Enables enterprise-grade configuration management
        - Supports correlation tracking for audit and troubleshooting

        INITIALIZATION FEATURES:
        - Automatic log file rotation based on size limits
        - Memory usage monitoring and management
        - Configuration validation and error handling
        - Performance statistics initialization
        - Correlation ID tracking for enterprise compliance

    .PARAMETER ConfigPath
        [String] (Optional) Path to configuration JSON file for custom settings.
        If not provided, default configuration will be used.

        VALIDATION RULES:
        - Must be a valid file path if specified
        - File must exist and be readable
        - Must contain valid JSON configuration structure

        BUSINESS CONTEXT:
        Allows customization of script behavior for different environments
        (development, staging, production) while maintaining consistency.

    .PARAMETER LogPath
        [String] (Optional) Path for log file output.
        If not provided, default timestamped log file will be created.

        VALIDATION RULES:
        - Directory must exist or be creatable
        - Must have write permissions to the specified location
        - File extension should be .log for consistency

        BUSINESS CONTEXT:
        Enables centralized logging for enterprise monitoring and compliance
        requirements. Supports integration with log aggregation systems.

    .PARAMETER MaxMemoryUsageMB
        [Int] (Optional) Maximum memory usage threshold in MB (Default: 1024).
        Controls memory management and prevents system resource exhaustion.

        VALIDATION RULES:
        - Must be between 100 and 16384 MB

    .PARAMETER CorrelationId
        [String] (Optional) Unique identifier for tracking operations across log entries.
        If not provided, a new GUID will be generated automatically.

        VALIDATION RULES:
        - Must be a valid non-empty string if provided
        - Should follow GUID format for consistency

        BUSINESS CONTEXT:
        Enables tracking of operations across multiple systems and log files
        for comprehensive audit trails and troubleshooting support.

    .PARAMETER LogLevel
        [String] (Optional) Sets the minimum log level for file output (Default: Information).
        Controls the verbosity of log file output while maintaining performance.

        VALIDATION RULES:
        - Must be one of: Critical, Error, Warning, Information, Debug, Verbose
        - Higher levels include all lower level messages

        BUSINESS CONTEXT:
        Enables fine-tuned control of log file size and performance impact
        while maintaining necessary audit and troubleshooting information.

    .PARAMETER SuppressConsoleOutput
        [Switch] (Optional) Suppresses console output for automation scenarios.
        Logs are still written to file, but console output is disabled.

        VALIDATION RULES:
        - Switch parameter (present/absent)
        - Does not affect file logging

        BUSINESS CONTEXT:
        Enables clean automation scenarios where console output would interfere
        with script integration or scheduled task execution.
        - Should be appropriate for system resources
        - Consider dataset size when setting limits

        PERFORMANCE IMPACT:
        Lower values trigger more frequent memory checks and cleanup.
        Higher values allow larger datasets but risk system instability.

    .PARAMETER CorrelationId
        [String] (Optional) Correlation ID for tracking this execution.
        Auto-generated if not provided for enterprise audit requirements.

    .PARAMETER LogLevel
        [String] (Optional) Logging level for output control (Default: Information).
        Controls verbosity of logging output for different environments.

    .PARAMETER UseConfigLogLevel
        [Switch] (Optional) Replace -LogLevel with the LogLevel of the -ConfigPath file once that
        file is loaded. Start-OrphanedSidSession sets it only when the command line chose no level
        (-LogLevel, -Verbose or -Debug), so the command line always wins over the file. A file
        without LogLevel leaves the level at Information. Without -ConfigPath it has no effect.

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
        COMPLIANCE: Supports SOX and GDPR audit requirements

    .EXAMPLE
        PS> $init = Initialize-ScriptExecution; $init.Statistics.StartTime

        DESCRIPTION: Access initialization results for monitoring
        OUTPUT: Returns initialization timestamp
        INTEGRATION: Enables integration with monitoring dashboards

    .NOTES
        Author: Jeffrey Stuhr
        Blog: https://www.techbyjeff.net
        LinkedIn: https://www.linkedin.com/in/jeffrey-stuhr-034214aa/

        SECURITY CONSIDERATIONS:
        - Configuration files may contain sensitive settings
        - Log files should be protected with appropriate file permissions
        - Memory management prevents denial-of-service scenarios
        - Correlation IDs enable security event tracking

        PERFORMANCE CHARACTERISTICS:
        - Initialization typically completes in 1-3 seconds
        - Memory overhead: ~50MB for management structures
        - Configuration loading scales with complexity
        - Log rotation occurs automatically based on size limits

        TROUBLESHOOTING:
        - For initialization failures: .\Troubleshooting\Common\Initialization-Issues.md
        - For configuration issues: .\Troubleshooting\Common\Configuration-Problems.md
        - For memory management: .\Troubleshooting\Performance\Memory-Management.md
        - For logging problems: .\Troubleshooting\Common\Logging-Issues.md

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

            if ($missingTypes.Count -gt 0) {
                throw "Required types not available: $($missingTypes -join ', '). Classes should be loaded by the main script before calling Initialize-ScriptExecution."
            }

            Write-Verbose "All required classes are available: $($requiredTypes -join ', ')"

            Initialize-LoggingSystem -CorrelationId $CorrelationId -LogLevel $LogLevel -SuppressConsoleOutput:$SuppressConsoleOutput

            # The configuration is read before the log file is set up, because its rotation settings
            # decide whether the existing file is renamed aside before this run writes to it. A file
            # that fails to load is reported once the log exists, so the failure reaches the file.
            $configFromFile = [bool]($ConfigPath -and (Test-Path $ConfigPath))
            $configLoadError = $null
            $script:Config = if ($configFromFile) {
                try {
                    [ScriptConfiguration]::LoadFromFile($ConfigPath)
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
            $null = Initialize-LogDirectory -LogPath $targetLogPath -RotateAboveMB $rotateAboveMB

            if ($script:LogRotation) {
                if ($script:LogRotation.Error) {
                    Write-StructuredLog "Log file rotation failed for $($script:LogRotation.From) ($($script:LogRotation.SizeMB) MB); appending to it: $($script:LogRotation.Error)" -Level Warning -Component 'Initialization' -CorrelationId $CorrelationId
                }
                else {
                    Write-StructuredLog "Rotated log file to: $($script:LogRotation.To) (Size: $($script:LogRotation.SizeMB) MB)" -Level Information -Component 'Initialization' -CorrelationId $CorrelationId
                }
            }

            if ($configLoadError) {
                throw $configLoadError
            }
            if ($configFromFile) {
                Write-StructuredLog "Loaded configuration from file: $ConfigPath" -Level Debug -Component 'Initialization' -CorrelationId $CorrelationId
            } else {
                Write-StructuredLog "Using default configuration" -Level Debug -Component 'Initialization' -CorrelationId $CorrelationId
            }

            # Validate configuration
            if (-not $script:Config.ValidateConfiguration()) {
                throw "Configuration validation failed"
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

            # Initialize log file path from configuration if provided. Otherwise Initialize-LogDirectory
            # has already set $script:LogPath to the resolved path, the default name for a blank one, or
            # the fallback for a refused one; copying the raw -LogPath back would undo all three.
            if ($script:Config.LogFilePath) {
                $script:LogPath = $script:Config.LogFilePath
            }

            # A LogFilePath from the file receives entries only from here on, so it is rotated here;
            # the -LogPath file was rotated by Initialize-LogDirectory before the run wrote to it
            if ($script:Config.LogFilePath -and (Test-Path $script:LogPath)) {
                try {
                    $logFileInfo = Get-Item $script:LogPath
                    $fileSizeMB = [Math]::Round($logFileInfo.Length / 1MB, 2)

                    if ($script:Config.EnableLogFileRotation -and $fileSizeMB -gt $script:Config.MaxLogFileSizeMB) {
                        $rotatedPath = $script:LogPath -replace '\.log$', "_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
                        # -ErrorAction Stop: a non-terminating failure here was logged as a successful rotation
                        Move-Item $script:LogPath $rotatedPath -ErrorAction Stop
                        Write-StructuredLog "Rotated log file to: $rotatedPath (Size: $fileSizeMB MB)" -Level Information -Component 'Initialization' -CorrelationId $CorrelationId
                    }
                } catch {
                    Write-StructuredLog "Log file rotation check failed: $($_.Exception.Message)" -Level Warning -Component 'Initialization' -CorrelationId $CorrelationId
                }
            }

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
            throw
        }
    }
}
