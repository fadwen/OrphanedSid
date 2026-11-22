function Write-StructuredLogEntry {
    <#
    .SYNOPSIS
        Writes structured log entries with consistent formatting

    .DESCRIPTION
        Writes one regular line of the log: the time, the level, the component, the
        correlation ID and the message, and after them the details as compact JSON when
        there are any. The line goes to the console unless console output is suppressed,
        and to the log file when the configured log level keeps it.

        A date among the details is written as text, as yyyy-MM-ddTHH:mm:ss.fff and what
        its kind adds: the offset from UTC for a local time, which is what Get-Date
        returns, Z for a UTC time, and nothing for a date of unspecified kind. That is the
        form that Format-LogMessage gives a date in a JSON entry, and it is the same text
        on PowerShell 7 and on Windows PowerShell 5.1. Only a value of the details itself
        is converted, not a date inside a value.

    .PARAMETER Message
        Text of the line.

    .PARAMETER Level
        Level of the line: Critical, Error, Warning, Information, Debug or Verbose. INFO is
        taken as Information.

    .PARAMETER Component
        Name of the part of the module that writes the line. General when none is given.

    .PARAMETER CorrelationId
        Correlation ID of the line. One is generated when none is given.

    .PARAMETER LogPath
        Path of the log file. Without it the path of the logging system is used, and with
        neither the line goes to the console only.

    .PARAMETER Details
        Values that are added to the line in the file as compact JSON, after " | Details: ".
        $null is taken as no details.
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
        # The invariant culture, so that the time has colons in every session (#193)
        $entryTime = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fff', [cultureinfo]::InvariantCulture)
        $formattedEntryForFile = "[$entryTime] [$Level] [$Component] [$CorrelationId] $Message"
        if ($null -ne $Details -and $Details.Count -gt 0) {
            # A date among the details becomes text, in the format that Format-LogMessage uses
            # for the JSON entries of the security log. ConvertTo-Json writes a date as ISO 8601
            # text on PowerShell 7 and, on Windows PowerShell 5.1, as \/Date(...)\/ or as an
            # object with the properties value, DisplayHint and DateTime, so the details of a
            # failed backup had a time that only one edition wrote readably (#196). Only a
            # value of the details itself is converted, not a date inside a value.
            $detailsForFile = @{}
            foreach ($key in $Details.Keys) {
                $value = $Details[$key]
                if ($value -is [datetime]) {
                    $value = $value.ToString('yyyy-MM-ddTHH:mm:ss.fffK', [cultureinfo]::InvariantCulture)
                }
                $detailsForFile[$key] = $value
            }
            $detailsJson = $detailsForFile | ConvertTo-Json -Compress
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
                    Add-Content -LiteralPath $effectiveLogPath -Value $formattedEntryForFile -Encoding UTF8 -WhatIf:$false -ErrorAction Stop
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
