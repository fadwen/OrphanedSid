function Format-LogMessage {
    <#
    .SYNOPSIS
        Formats log messages according to specified style and requirements

    .DESCRIPTION
        Builds one log entry from a message, its level, component and correlation ID, and
        the additional data. The entry starts with the time at which it was built, as
        yyyy-MM-ddTHH:mm:ss.fff followed by the offset from UTC.

        A date among the additional data is written as text in the same format, so that
        PowerShell 7 and Windows PowerShell 5.1 write the same text. What follows the
        milliseconds depends on the kind of the date: the offset for a local time, which
        is what Get-Date returns, Z for a UTC time, and nothing for a date of unspecified
        kind. Only a value of the entry itself is converted, not a date inside a value.

        A value of the additional data whose name says that it holds a secret is written
        as [REDACTED]. That is a name which contains passw, secret, token or credential, or
        api, access, private or signing followed by key, in any letter case. Only the name
        of a value itself is read, not a name inside a value and not the text of the
        message, so a caller still must not put a secret there.

    .PARAMETER Message
        Text of the entry.

    .PARAMETER Level
        Level of the entry: Critical, Error, Warning, Information, Debug or Verbose. INFO is
        taken as Information.

    .PARAMETER Component
        Name of the part of the module that writes the entry. General when none is given.

    .PARAMETER CorrelationId
        Correlation ID of the entry. One is generated when none is given.

    .PARAMETER Format
        Form of the result: JSON, which is the default, PlainText, CSV or XML. The additional
        data is part of the JSON and XML forms only.

    .PARAMETER AdditionalData
        Further values of the entry, by name. $null is taken as no values. A value that
        is named as a secret is not written.
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
        [ValidateSet('JSON', 'PlainText', 'CSV', 'XML')]
        [string]$Format = 'JSON',

        [Parameter()]
        [hashtable]$AdditionalData = @{}
    )

    # Normalize INFO to Information
    if ($Level -eq 'INFO') {
        $Level = 'Information'
    }

    # Formatted with the invariant culture: a colon in a date format stands for the time
    # separator of the culture, so a session in fi-FI wrote 21.54.45 (#193).
    $timestampFormat = 'yyyy-MM-ddTHH:mm:ss.fffK'
    $invariantCulture = [cultureinfo]::InvariantCulture
    $timestamp = (Get-Date).ToString($timestampFormat, $invariantCulture)
    
    $logData = [PSCustomObject]@{
        Timestamp = $timestamp
        Level = $Level
        Component = $Component
        CorrelationId = $CorrelationId
        Message = $Message
    }

    # Add additional data. A date becomes text in the format of Timestamp. ConvertTo-Json
    # writes a date as ISO 8601 text on PowerShell 7, and on Windows PowerShell 5.1 as an
    # object with the properties value, DisplayHint and DateTime, so the Timestamp that
    # Write-SecurityLog passes had two shapes in the file (#191). Only a value of the entry
    # itself is converted, not a date inside a value.
    #
    # A value that is named as a secret is written without its value (SEC-06, #215). 'key'
    # alone is not in the pattern: a value can name a registry key or a cache key.
    # Write-StructuredLogEntry holds the same pattern. The unit tests dot-source these files one
    # at a time, so it is written out in both, and the contract tests compare the two.
    if ($null -ne $AdditionalData -and $AdditionalData.Count -gt 0) {
        $secretNamePattern = 'passw|secret|token|credential|(api|access|private|signing)[_-]?key'
        foreach ($key in $AdditionalData.Keys) {
            $value = $AdditionalData[$key]
            if ("$key" -match $secretNamePattern) {
                $value = '[REDACTED]'
            } elseif ($value -is [datetime]) {
                $value = $value.ToString($timestampFormat, $invariantCulture)
            }
            $logData | Add-Member -MemberType NoteProperty -Name $key -Value $value -Force
        }
    }

    switch ($Format) {
        'JSON' {
            return $logData | ConvertTo-Json -Compress
        }
        'PlainText' {
            return "[$timestamp] [$Level] [$Component] [$CorrelationId] $Message"
        }
        'CSV' {
            return "$timestamp,$Level,$Component,$CorrelationId,`"$Message`""
        }
        'XML' {
            return $logData | ConvertTo-Xml -NoTypeInformation -As String
        }
        default {
            return $logData | ConvertTo-Json -Compress
        }
    }
}
