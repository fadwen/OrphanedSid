#Requires -Version 5.1

function Invoke-SecurityValidation {
    <#
    .SYNOPSIS
        Performs comprehensive security validation for SID removal operations

    .DESCRIPTION
        Validates orphaned SIDs against security policies, protected SID lists,
        and privileged account patterns to ensure safe removal operations.

        This function implements the "tool" pattern - it accepts input via parameters,
        performs focused security validation, and outputs structured results to the
        pipeline for maximum reusability.

        Security validation includes:
        - Protected SID pattern detection
        - Privileged account validation
        - Risk level assessment

    .PARAMETER OrphanedSIDs
        Array of orphaned Security Identifiers to validate for removal.
        Each SID will be validated against enterprise security policies.

    .PARAMETER ObjectDN
        Distinguished name of the AD object for validation context.
        Used to determine object-specific security requirements.

    .PARAMETER CorrelationId
        Unique identifier for tracking this validation operation across
        logs and audit trails. Generated automatically if not provided.

    .EXAMPLE
        PS> Invoke-SecurityValidation -OrphanedSIDs @("S-1-5-21-1234567890-1001") -ObjectDN "CN=TestUser,CN=Users,DC=contoso,DC=com"

        DESCRIPTION: Validates a single orphaned SID for removal
        OUTPUT: SecurityValidationResult with validation status and risk assessment
        USE CASE: Basic security validation for targeted SID removal

    .EXAMPLE
        PS> $sids | Invoke-SecurityValidation -ObjectDN $objectDN -CorrelationId $correlationId

        DESCRIPTION: Pipeline processing of multiple SIDs with correlation tracking
        OUTPUT: SecurityValidationResult objects for batch processing
        USE CASE: Enterprise automation with audit trail requirements

    .EXAMPLE
        PS> $validation = Invoke-SecurityValidation -OrphanedSIDs $orphanedSIDs -ObjectDN $dn
        if ($validation.IsValid) {
            Write-Output "Security validation passed for $($validation.AllowedSIDs.Count) SIDs"
        }

        DESCRIPTION: Programmatic validation with result checking
        OUTPUT: Structured validation results for automation
        USE CASE: Conditional processing based on security validation results

    .OUTPUTS
        [SecurityValidationResult] Object containing:
        - IsValid: Boolean indicating overall validation success
        - RiskLevel: String indicating risk assessment (Low/Medium/High/Critical)
        - AllowedSIDs: Array of SIDs approved for removal
        - BlockedSIDs: Array of SIDs blocked by security policies
        - Issues: Array of validation issues and warnings
        - RequiresElevatedConfirmation: Boolean for high-risk operations

    .NOTES
        SECURITY FEATURES:
        - Uses SIDValidation module for comprehensive security testing
        - Implements risk-based validation with graduated responses
        - Provides detailed audit trails with correlation tracking
        - Blocks protected and privileged SIDs automatically
        - Supports enterprise security policy integration

        TROUBLESHOOTING:
        - For blocked SIDs: Check protected SID configuration and policies
        - For validation errors: Verify SID format and AD connectivity
        - For performance issues: Consider batch size and validation complexity
        - For validation failures: .\Troubleshooting\Security\Security-Validation-Guide.md
    #>

    [CmdletBinding()]
    [OutputType([SecurityValidationResult])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [ValidateNotNullOrEmpty()]
        [string[]]$OrphanedSIDs,

        [Parameter()]
        [string]$ObjectDN,

        [Parameter()]
        [string]$CurrentDomainSID,

        [Parameter()]
        [string]$CorrelationId = [System.Guid]::NewGuid().ToString()
    )

    process {
        try {
            Write-StructuredLog "Starting security validation for $($OrphanedSIDs.Count) SIDs (Object: $ObjectDN)" -Level Debug -CorrelationId $CorrelationId

            $validation = [SecurityValidationResult]::new()
            $allowedSIDs = [System.Collections.Generic.List[string]]::new()
            $blockedSIDs = [System.Collections.Generic.List[string]]::new()
            $issues = [System.Collections.Generic.List[string]]::new()

            foreach ($sid in $OrphanedSIDs) {
                Write-StructuredLog "Validating SID for removal: $sid" -Level Debug -CorrelationId $CorrelationId

                # Use SIDValidation module for comprehensive security testing
                $sidValidation = Test-SIDSecurity -SIDString $sid -ObjectDN $ObjectDN -ValidationLevel 'Standard' -CurrentDomainSID $CurrentDomainSID -CorrelationId $CorrelationId

                if (-not $sidValidation.IsValid) {
                    $blockedSIDs.Add($sid)
                    $issues.AddRange($sidValidation.Issues)
                    $validation.RiskLevel = "Critical"
                    Write-StructuredLog "SID blocked from removal: $sid (Validation failed)" -Level Warning -CorrelationId $CorrelationId
                    continue
                }

                if ($sidValidation.RequiresElevatedConfirmation) {
                    # Raise to High, never lower a batch an earlier blocked SID made Critical
                    if ($validation.RiskLevel -ne 'Critical') {
                        $validation.RiskLevel = "High"
                    }
                    $validation.RequiresElevatedConfirmation = $true
                    $issues.Add("High-risk SID detected: $sid")
                }

                $allowedSIDs.Add($sid)
            }

            $validation.IsValid = $blockedSIDs.Count -eq 0
            $validation.Issues = $issues.ToArray()
            $validation.BlockedSIDs = $blockedSIDs.ToArray()
            $validation.AllowedSIDs = $allowedSIDs.ToArray()

            Write-StructuredLog "Security validation completed - Valid: $($validation.IsValid), Allowed: $($allowedSIDs.Count), Blocked: $($blockedSIDs.Count)" -Level Verbose -CorrelationId $CorrelationId
            return $validation
        }
        catch {
            Write-StructuredLog "Error in security validation: $($_.Exception.Message)" -Level Error -CorrelationId $CorrelationId

            $validation = [SecurityValidationResult]::new()
            $validation.IsValid = $false
            $validation.RiskLevel = "Critical"
            $validation.Issues = @("Validation error: $($_.Exception.Message)")
            return $validation
        }
    }
}


