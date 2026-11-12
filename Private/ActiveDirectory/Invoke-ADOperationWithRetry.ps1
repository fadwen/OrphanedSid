function Invoke-ADOperationWithRetry {
    <#
    .SYNOPSIS
        Executes Active Directory operations with retry logic and security logging

    .DESCRIPTION
        Orchestrates AD operations by combining retry mechanisms with proper security
        audit logging. Provides enterprise-grade reliability for AD interactions.

    .PARAMETER ScriptBlock
        The AD operation to execute

    .PARAMETER MaxRetries
        Total attempts, the first included, for a failure that looks transient (1-11, default 3).
        A caller holding a retry count passes that count plus one.

    .PARAMETER OperationName
        Descriptive name for the operation

    .PARAMETER ObjectContext
        Additional context about the AD object being accessed

    .EXAMPLE
        PS> Invoke-ADOperationWithRetry -ScriptBlock { Get-ADUser 'testuser' } -OperationName 'Get User'

        DESCRIPTION: Executes AD user lookup with retry and audit logging
        OUTPUT: AD user object with full audit trail
        USE CASE: Production AD operations requiring reliability and auditing

    .NOTES
        Author: Jeffrey Stuhr
        Blog: https://www.techbyjeff.net
        LinkedIn: https://www.linkedin.com/in/jeffrey-stuhr-034214aa/

        TROUBLESHOOTING:
        - For operation failures: .\Troubleshooting\Performance\Performance-Tuning.md
    #>

    [CmdletBinding()]
    [OutputType('ADOperationResult')]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,

        [Parameter()]
        # Attempts, the first included: a caller's 10 retries is 11 attempts
        [ValidateRange(1, 11)]
        [int]$MaxRetries = 3,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$OperationName = 'AD Operation',

        [Parameter()]
        [string]$ObjectContext = 'Unknown',

        [Parameter()]
        [string]$CorrelationId = [System.Guid]::NewGuid().ToString()
    )

    begin {
        Write-Verbose "Starting AD operation with retry: $OperationName"

        # Build security context
        $securityContext = @{
            ObjectContext = $ObjectContext
            MaxRetries = $MaxRetries
            ADAccessType = 'Sensitive'
            OperationType = 'SingleOperation'
        }
    }

    process {
        # Log operation attempt
        Write-ADOperationSecurityLog -OperationName $OperationName -Outcome 'Attempt' -SecurityContext $securityContext -CorrelationId $CorrelationId

        try {
            # Execute with retry logic
            $result = Invoke-OperationWithRetry -ScriptBlock $ScriptBlock -MaxRetries $MaxRetries -OperationName $OperationName -CorrelationId $CorrelationId

            # Log successful operation
            $successContext = $securityContext.Clone()
            $successContext['ResultType'] = if ($result) { $result.GetType().Name } else { 'NoResult' }

            Write-ADOperationSecurityLog -OperationName $OperationName -Outcome 'Success' -SecurityContext $successContext -CorrelationId $CorrelationId

            return $result
        }
        catch {
            # Log failed operation
            $failureContext = $securityContext.Clone()
            $failureContext['ErrorMessage'] = $_.Exception.Message
            $failureContext['FailureCategory'] = 'OperationFailed'

            Write-ADOperationSecurityLog -OperationName $OperationName -Outcome 'Failure' -SecurityContext $failureContext -CorrelationId $CorrelationId

            throw
        }
    }
}
