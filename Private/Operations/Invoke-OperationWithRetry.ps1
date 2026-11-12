function Invoke-OperationWithRetry {
    <#
    .SYNOPSIS
        Executes a script block with configurable retry logic for transient failures

    .DESCRIPTION
        Provides a reusable retry mechanism for any operation that may experience
        transient failures. Uses exponential backoff with jitter for optimal retry timing.

    .PARAMETER ScriptBlock
        The operation to execute with retry logic

    .PARAMETER MaxRetries
        Total attempts, the first included, for an error matching RetryableErrorPattern (1-11,
        default 3). A caller holding a retry count passes that count plus one.

    .PARAMETER RetryableErrorPattern
        Regex pattern to identify retryable errors

    .PARAMETER OperationName
        Descriptive name for logging purposes

    .EXAMPLE
        PS> Invoke-OperationWithRetry -ScriptBlock { Get-ADUser 'testuser' } -OperationName 'Get User'

        DESCRIPTION: Executes AD user lookup with automatic retry on transient failures
        OUTPUT: AD user object or throws on permanent failure
        USE CASE: Handling intermittent AD connectivity issues

    .NOTES
        Author: Jeffrey Stuhr
        Blog: https://www.techbyjeff.net
        LinkedIn: https://www.linkedin.com/in/jeffrey-stuhr-034214aa/

        TROUBLESHOOTING:
        - For retry configuration: .\Troubleshooting\Performance\Performance-Tuning.md
    #>

    [CmdletBinding()]
    [OutputType('OperationResult')]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,

        [Parameter()]
        # Attempts, the first included: a caller's 10 retries is 11 attempts
        [ValidateRange(1, 11)]
        [int]$MaxRetries = 3,

        [Parameter()]
        [string]$RetryableErrorPattern = 'timeout|network|connection|busy|unavailable|server not operational|replication|domain controller',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$OperationName = 'Operation',

        [Parameter()]
        [string]$CorrelationId = [System.Guid]::NewGuid().ToString()
    )

    begin {
        $startMessage = "Starting retry operation: $OperationName (Max Retries: $MaxRetries)"
        Write-Verbose "$startMessage - CorrelationId: $CorrelationId"
    }

    process {
        $attempt = 0
        $lastError = $null

        do {
            $attempt++
            try {
                Write-Verbose "Executing $OperationName (attempt $attempt/$MaxRetries)"
                $result = & $ScriptBlock

                Write-Verbose "Operation '$OperationName' succeeded on attempt $attempt"
                return $result
            }
            catch {
                $lastError = $_
                $isRetryable = $_.Exception.Message -match $RetryableErrorPattern

                if (-not $isRetryable -or $attempt -ge $MaxRetries) {
                    Write-Verbose "Operation '$OperationName' failed permanently after $attempt attempts"
                    throw $lastError
                }

                $waitTime = [Math]::Min([Math]::Pow(2, $attempt - 1) + (Get-Random -Maximum 2), 30)
                Write-Verbose "Operation '$OperationName' failed (attempt $attempt/$MaxRetries), retrying in $waitTime seconds"
                Start-Sleep -Seconds $waitTime
            }
        } while ($attempt -lt $MaxRetries)

        throw $lastError
    }
}
