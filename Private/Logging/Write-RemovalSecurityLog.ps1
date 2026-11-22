#Requires -Version 5.1

function Write-RemovalSecurityLog {
    <#
    .SYNOPSIS
        Writes specialized security audit logs for SID removal operations

    .DESCRIPTION
        Creates comprehensive security audit logs specifically designed for SID
        removal operations. This function
        implements focused security logging following the "tool" pattern.

        Security logging includes:
        - Operation context and authorization details
        - Risk assessment and security validation results
        - Detailed SID removal tracking

    .PARAMETER SecurityEventType
        Type of security event being logged (e.g., 'PrivilegeUse', 'ObjectAccess').
        Must be a valid security event classification.

    .PARAMETER Message
        Primary security event message describing the operation.
        Should be descriptive and suitable for security audit purposes.

    .PARAMETER Outcome
        Result of the security operation ('Attempt', 'Success', 'Failure').
        Used for security monitoring.

    .PARAMETER CorrelationId
        Unique identifier for tracking this security event across
        logs and audit trails. Generated automatically if not provided.

    .PARAMETER SecurityContext
        Hashtable containing security-specific context information
        such as target objects, SIDs processed, and risk assessments.

    .EXAMPLE
        PS> Write-RemovalSecurityLog -SecurityEventType 'PrivilegeUse' -Message "SID removal operation initiated" -Outcome 'Attempt' -CorrelationId $id -SecurityContext @{TargetObject = $dn; SIDsToRemove = $sids}

        DESCRIPTION: Logs the start of a SID removal operation
        OUTPUT: Security audit log entry
        USE CASE: Enterprise security audit trail for SID removal operations

    .EXAMPLE
        PS> $context = @{Operation = 'RemoveOrphanedSIDs'; RiskLevel = 'Medium'; SIDsRemoved = 3}
        Write-RemovalSecurityLog -SecurityEventType 'ObjectAccess' -Message "ACL modification completed" -Outcome 'Success' -SecurityContext $context

        DESCRIPTION: Logs successful completion of ACL modifications
        OUTPUT: Detailed security log with operation results
        USE CASE: Security monitoring

    .OUTPUTS
        None. This function writes to security audit logs and does not return values.

    .NOTES
        AUDIT FEATURES:
        - Comprehensive operation context logging
        - Risk-based event classification
        - Detailed SID and object tracking

        TROUBLESHOOTING:
        - For missing logs: Check logging configuration and permissions
        - For format issues: Verify security context structure
        - For logging issues: .\Troubleshooting\Common\Common-Issues.md
        - For security logging issues: .\Troubleshooting\Security\Security-Logging-Issues.md
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('PrivilegeUse', 'ObjectAccess', 'SecurityValidation', 'AuditTrail')]
        [string]$SecurityEventType,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Message,

        [Parameter(Mandatory)]
        [ValidateSet('Attempt', 'Success', 'Failure')]
        [string]$Outcome,

        [Parameter()]
        [string]$CorrelationId = [System.Guid]::NewGuid().ToString(),

        [Parameter()]
        [hashtable]$SecurityContext = @{}
    )

    try {
        # Build enhanced security context for removal operations
        $enhancedContext = @{
            Operation = 'SIDRemoval'
            Component = 'RemovalSecurityLogging'
            EventType = $SecurityEventType
            Outcome = $Outcome
            # Local time with its offset. The format once ended in a literal Z, which says
            # UTC, on a time that was local (#192).
            Timestamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffK', [cultureinfo]::InvariantCulture)
            User = $env:USERNAME
            Computer = $env:COMPUTERNAME
            CorrelationId = $CorrelationId
        }

        # Merge provided security context
        foreach ($key in $SecurityContext.Keys) {
            $enhancedContext[$key] = $SecurityContext[$key]
        }

        # Write to security audit log with specialized formatting
        Write-SecurityLog -SecurityEventType $SecurityEventType -Message $Message -Outcome $Outcome -CorrelationId $CorrelationId -SecurityContext $enhancedContext

        # Also write to structured log for operational visibility
        Write-StructuredLog "SECURITY EVENT: $SecurityEventType - $Message (Outcome: $Outcome)" -Level Information -CorrelationId $CorrelationId
    }
    catch {
        # Log security logging errors to ensure audit trail integrity
        Write-StructuredLog "Failed to write security audit log: $($_.Exception.Message)" -Level Error -CorrelationId $CorrelationId

        # Attempt fallback logging to ensure security event is captured
        try {
            Write-StructuredLog "SECURITY EVENT (FALLBACK): $SecurityEventType - $Message (Outcome: $Outcome)" -Level Warning -CorrelationId $CorrelationId
        }
        catch {
            # Final fallback - this should not happen in normal operations
            Write-Warning "Critical: Security audit logging failed completely for correlation ID: $CorrelationId"
        }
    }
}


