function Write-StructuredLogEntry {
    <#
    .SYNOPSIS
        Writes structured log entries with consistent formatting
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Message,

        [Parameter(Mandatory)]
        [ValidateSet('Critical', 'Error', 'Warning', 'Information', 'Debug', 'Verbose', 'INFO')]
        [string]$Level,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$Component = 'General',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$CorrelationId = [System.Guid]::NewGuid().ToString(),

        [Parameter()]
        [string]$LogPath,

        [Parameter()]
        [hashtable]$Details = @{}
    )

    # Normalize INFO to Information
    if ($Level -eq 'INFO') {
        $Level = 'Information'
    }

    # File output honours the configured -LogLevel; console output does not, so that warnings and
    # errors still reach an operator who lowered the file verbosity. Security entries bypass this
    # filter through Write-SecurityStructuredLogEntry.
    $writeToFile = $true
    if ($ExecutionContext.InvokeCommand.GetCommand('Test-LogLevel', 'Function')) {
        $writeToFile = Test-LogLevel $Level
    }

    # Debug and Verbose entries reach the console only when that stream is on, which is the
    # check Write-Debug and Write-Verbose make themselves
    $showOnConsole = -not $script:SuppressConsoleOutput
    if ($showOnConsole -and $Level -eq 'Debug') {
        $showOnConsole = $DebugPreference -notin 'SilentlyContinue', 'Ignore'
    } elseif ($showOnConsole -and $Level -eq 'Verbose') {
        $showOnConsole = $VerbosePreference -notin 'SilentlyContinue', 'Ignore'
    }

    # Most entries detection writes are Debug lines that go nowhere. Formatting one anyway cost
    # several milliseconds, and detection writes several per access rule, so it took about half of
    # each object's time (#111). An entry with no destination stops here.
    if (-not $writeToFile -and -not $showOnConsole) {
        return
    }

    try {
        $formattedEntryForFile = "[$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss.fff')] [$Level] [$Component] [$CorrelationId] $Message"
        if ($Details.Count -gt 0) {
            $detailsJson = $Details | ConvertTo-Json -Compress
            $formattedEntryForFile += " | Details: $detailsJson"
        }

        if ($showOnConsole) {
            Write-ConsoleLogEntry -FormattedMessage "[$Level] [$Component] $Message" -Level $Level
        }

        if ($writeToFile) {
            # Use the path passed in, otherwise the logging system's
            $effectiveLogPath = $LogPath
            if (-not $effectiveLogPath -and $ExecutionContext.InvokeCommand.GetCommand('Get-LoggingSystemState', 'Function')) {
                try {
                    $effectiveLogPath = (Get-LoggingSystemState).LogPath
                } catch {
                    Write-Verbose "Could not retrieve logging system state: $($_.Exception.Message)"
                }
            }

            if ($effectiveLogPath) {
                try {
                    # -WhatIf on the public command reaches here through $WhatIfPreference; the log is
                    # not what is being rehearsed, so the write is pinned
                    # -ErrorAction Stop: Add-Content's failures are non-terminating and would skip the catch
                    Add-Content -Path $effectiveLogPath -Value $formattedEntryForFile -Encoding UTF8 -WhatIf:$false -ErrorAction Stop
                } catch {
                    Write-Warning "Failed to write log entry to file: $($_.Exception.Message)"
                }
            }
        }    } catch {
        Write-Warning "Failed to write structured log entry: $($_.Exception.Message)"
    }
}

function Write-ConsoleLogEntry {
    [CmdletBinding()]
    param(
        [string]$FormattedMessage,
        [string]$Level
    )

    # -SuppressConsoleOutput on the public commands sets this; the file still receives every entry
    if ($script:SuppressConsoleOutput) {
        return
    }

    switch ($Level) {
        'Critical' { Write-Error $FormattedMessage }
        'Error' { Write-Error $FormattedMessage }
        'Warning' { Write-Warning $FormattedMessage }
        'Information' { Write-Information $FormattedMessage -InformationAction Continue }
        'Debug' { Write-Debug $FormattedMessage }
        'Verbose' { Write-Verbose $FormattedMessage }
        default { Write-Information $FormattedMessage -InformationAction Continue }
    }
}
