# Shared logging state and configuration variables
# These script-scoped variables maintain the logging system state across all logging modules

<#
.SYNOPSIS
    Shared logging configuration and state management

.DESCRIPTION
    This module provides centralized management of logging system state variables
    that are shared across all logging modules. It maintains the logging configuration,
    state tracking, and level hierarchies used throughout the logging system.

.NOTES
    Author: Jeffrey Stuhr
    Blog: https://www.techbyjeff.net
    LinkedIn: https://www.linkedin.com/in/jeffrey-stuhr-034214aa/

    SCOPE: Script-level variables are shared across all logging modules
    THREAD-SAFETY: PowerShell script variables are not thread-safe by default
    PERSISTENCE: Variables are reset when PowerShell session ends

    TROUBLESHOOTING:
    - For state issues: .\Troubleshooting\Logging\State-Management.md
    - For configuration: .\Troubleshooting\Common\Logging-Issues.md
#>

# Primary logging configuration
$script:LogPath = $null                    # Full path to the active log file
$script:LogFileInitialized = $false        # Whether log file has been created and initialized
$script:LogFileReinitAttempted = $false    # Whether reinitialization has been attempted (prevents loops)
$script:SuppressConsoleOutput = $false     # Whether to suppress console output for logging
$script:CorrelationId = $null              # Current correlation ID for operation tracking
$script:LogLevel = 'Information'           # Default log level for file output filtering

# Log level hierarchy for filtering and priority determination
# Lower numbers indicate higher priority/severity
$script:LogLevels = @{
    'Critical'    = 0    # System failures, data corruption, security breaches
    'Error'       = 1    # Operation failures, exceptions, recoverable errors
    'Warning'     = 2    # Potential issues, deprecated usage, performance concerns
    'Information' = 3    # Normal operations, business events, state changes
    'Debug'       = 4    # Detailed tracing, variable values, flow control
    'Verbose'     = 5    # Comprehensive tracing, internal operations, diagnostics
}