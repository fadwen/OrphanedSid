#Requires -Version 5.1

<#
.SYNOPSIS
    SID Security Validation Module for Find-UnknownSID Solution

.DESCRIPTION
    This module provides comprehensive SID security validation and risk assessment
    functionality for the Find-UnknownSID enterprise solution. It focuses exclusively
    on security validation and compliance checking for SID operations.

    This module follows the single-responsibility principle by focusing exclusively
    on security validation and risk assessment. It depends on the Get-SIDAnalysis
    module for detailed SID context and categorization.

    BUSINESS VALUE:
    - Implements defense-in-depth security validation for SID operations
    - Ensures compliance with enterprise security policies
    - Provides risk-based approval workflows for SID removal
    - Supports audit requirements with comprehensive security logging

    TECHNICAL FEATURES:
    - Protected SID detection and blocking
    - Risk-based validation with configurable thresholds
    - Integration with enterprise security policies
    - Comprehensive security audit logging
    - Batch risk assessment for large-scale operations

.NOTES
    Author: Jeffrey Stuhr
    Blog: https://www.techbyjeff.net
    LinkedIn: https://www.linkedin.com/in/jeffrey-stuhr-034214aa/
    Last Updated: 2025-07-04
    Version: 1.0.0
    PowerShell Version: 5.1+ (Windows), 7.x+ (Cross-platform)

    MODULE DESIGN:
    This module implements the single-responsibility principle by focusing
    exclusively on security validation and risk assessment. It provides
    comprehensive security controls while maintaining high cohesion.

    TROUBLESHOOTING:
    - For security validation issues: .\Troubleshooting\Security\Security-Validation-Guide.md
    - For performance optimization: .\Troubleshooting\Performance\Performance-Tuning.md

    DEPENDENCIES:
    - Requires Get-SIDAnalysis.ps1 for SID analysis and categorization
    - Requires Classes.ps1 for SecurityValidationResult type definitions
    - Requires Logging.ps1 for Write-StructuredLog and Write-SecurityLog functions
    - Uses script-scoped $script:Config variable for security configuration access
#>

function Test-SIDSecurity {
    <#
    .SYNOPSIS
        Performs security validation for SID removal operations

    .DESCRIPTION
        Validates whether a SID can be safely removed based on security policies,
        well-known SID protections, and enterprise compliance requirements.
        This function implements defense-in-depth security validation.

    .PARAMETER SIDString
        The Security Identifier to validate for removal

    .PARAMETER ObjectDN
        Distinguished name of the object containing the SID (for context)

    .PARAMETER ValidationLevel
        Level of security validation (Basic, Standard, Strict)

    .PARAMETER CorrelationId
        Unique identifier for tracking this validation operation

    .EXAMPLE
        PS> Test-SIDSecurity -SIDString "S-1-5-21-1234567890-1234567890-1234567890-1001"

        DESCRIPTION: Basic security validation for a domain user SID
        OUTPUT: SecurityValidationResult with validation status and any issues
        USE CASE: Pre-validation before SID removal operations

    .EXAMPLE
        PS> Test-SIDSecurity -SIDString "S-1-5-18" -ValidationLevel "Strict"

        DESCRIPTION: Strict security validation for Local System SID
        OUTPUT: SecurityValidationResult blocking removal of critical system SID
        USE CASE: Protecting critical system SIDs from accidental removal

    .EXAMPLE
        PS> $orphanedSIDs | Test-SIDSecurity -ValidationLevel "Standard" -ObjectDN $objectDN

        DESCRIPTION: Batch security validation with object context
        OUTPUT: Array of SecurityValidationResult objects for approval workflow
        USE CASE: Enterprise compliance validation for batch operations

    .OUTPUTS
        [SecurityValidationResult] Object containing validation status and details

    .NOTES
        Author: Jeffrey Stuhr
        Blog: https://www.techbyjeff.net
        LinkedIn: https://www.linkedin.com/in/jeffrey-stuhr-034214aa/
        Last Updated: 2025-07-04
        Version: 1.0.0

        SECURITY FEATURES:
        - Protected SID detection and blocking
        - Well-known SID preservation
        - Risk-based validation with configurable thresholds
        - Integration with enterprise security policies
        - Comprehensive audit logging

        TROUBLESHOOTING:
        - For blocked SIDs: Check Protected SIDs configuration
        - For validation errors: Review security policy compliance
        - For performance issues: .\Troubleshooting\Performance\Performance-Tuning.md

    .LINK
        .\Troubleshooting\Security\Security-Validation-Guide.md
    #>

    [CmdletBinding()]
    [OutputType('SecurityValidationResult')]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({
            if ([string]::IsNullOrWhiteSpace($_)) {
                throw "SIDString cannot be null, empty, or whitespace only"
            }
            return $true
        })]
        [string]$SIDString,

        [Parameter()]
        [string]$ObjectDN,

        [Parameter()]
        [ValidateSet('Basic', 'Standard', 'Strict')]
        [string]$ValidationLevel = 'Standard',

        [Parameter()]
        [string]$CurrentDomainSID,

        [Parameter()]
        [string]$CorrelationId = [System.Guid]::NewGuid().ToString()
    )

    process {
        try {
            try {
                $logMessage = "Starting security validation for SID: $SIDString (Level: $ValidationLevel)"
                Write-StructuredLog $logMessage -Level Debug -Component 'SIDSecurity' -CorrelationId $CorrelationId
            } catch {
                Write-Debug "Logging unavailable: $($_.Exception.Message)"
            }

            # Log security validation event
            try {
                Write-SecurityLog -SecurityEventType 'DataValidation' -Message "SID security validation initiated" -Outcome 'Attempt' -CorrelationId $CorrelationId -SecurityContext @{
                    SIDString = $SIDString
                    ValidationLevel = $ValidationLevel
                    ObjectDN = $ObjectDN
                    Component = 'SIDSecurity'
                }
            } catch {
                Write-Debug "Logging unavailable: $($_.Exception.Message)"
            }

            $validation = [SecurityValidationResult]::new()
            $validation.IsValid = $true
            $validation.RiskLevel = "Low"

            # Check for malicious input patterns first (highest priority)
            $maliciousPatterns = @('|', '&', ';', 'net user', 'cmd', 'powershell', 'invoke-', 'start-process', '<script', '<', '>', '$(', '`$(')
            foreach ($pattern in $maliciousPatterns) {
                if ($SIDString -like "*$pattern*") {
                    $validation.IsValid = $false
                    $validation.RiskLevel = "Critical"
                    $validation.Issues += "Critical security risk detected - potentially malicious input pattern: $pattern"
                    $validation.BlockedSIDs += $SIDString

                    try {
                        $logMessage = "Malicious input pattern detected in SID: $SIDString"
                        $logParams = @{
                            Level = 'Error'; Component = 'SIDSecurity'; CorrelationId = $CorrelationId
                        }
                        Write-StructuredLog $logMessage @logParams
                    } catch {
                        Write-Debug "Logging unavailable: $($_.Exception.Message)"
                    }

                    try {
                        Write-SecurityLog -SecurityEventType 'SecurityViolation' -Message "Malicious input pattern detected in SID validation" -Outcome 'Failure' -CorrelationId $CorrelationId -SecurityContext @{
                            SIDString = $SIDString
                            ValidationLevel = $ValidationLevel
                            BlockedReason = 'MaliciousInputPattern'
                            DetectedPattern = $pattern
                            RiskLevel = 'Critical'
                            SecurityThreat = $true
                            ObjectDN = $ObjectDN
                        }
                    } catch {
                        Write-Debug "Logging unavailable: $($_.Exception.Message)"
                    }

                    return $validation
                }
            }

            # Check if SID is in protected list
            try {
                $logMessage = "Checking if SID '$SIDString' is in protected list"
                Write-StructuredLog $logMessage -Level Debug -Component 'SIDSecurity' -CorrelationId $CorrelationId
            } catch {
                Write-Debug "Logging unavailable: $($_.Exception.Message)"
            }
            
            if ($script:Config -and $script:Config.ProtectedSIDs -contains $SIDString) {
                try {
                    $logMessage = "SID $SIDString blocked - found in protected SIDs list"
                    $logParams = @{ Level = 'Warning'; Component = 'SIDSecurity'; CorrelationId = $CorrelationId }
                    Write-StructuredLog $logMessage @logParams
                } catch {
                    Write-Debug "Logging unavailable: $($_.Exception.Message)"
                }
                
                $validation.IsValid = $false
                $validation.RiskLevel = "Critical"
                $validation.Issues += "SID is in protected SIDs list - removal blocked by security policy"
                $validation.BlockedSIDs += $SIDString

                # Log security blocking event
                $securityContext = @{
                    SIDString = $SIDString
                    ValidationLevel = $ValidationLevel
                    BlockedReason = 'ProtectedSIDsList'
                    RiskLevel = 'Critical'
                    ObjectDN = $ObjectDN
                }
                try {
                    Write-SecurityLog -SecurityEventType 'DataValidation' -Message "Protected SID validation blocked - removal denied" -Outcome 'Failure' -CorrelationId $CorrelationId -SecurityContext $securityContext
                } catch { 
                    # Store security context for test access even if logging fails
                    $script:LastSecurityContext = $securityContext
                }

                # Early return for protected SIDs - they override all other logic
                return $validation
            }

            # Perform SID analysis early for comprehensive risk assessment
            $analysisParams = @{ SIDString = $SIDString; CorrelationId = $CorrelationId }
            if ($CurrentDomainSID) {
                $analysisParams.CurrentDomainSID = $CurrentDomainSID
            }
            $sidAnalysis = Get-SIDAnalysis @analysisParams

            # Check well-known SIDs using the Test-SIDFormat module
            $isWellKnown = Test-WellKnownSID -SID $SIDString -CorrelationId $CorrelationId
            if ($isWellKnown) {
                if ($ValidationLevel -in @('Standard', 'Strict')) {
                    $validation.IsValid = $false
                    $validation.RiskLevel = "High"
                    $validation.Issues += "Well-known SID detected - removal may impact system security"
                    $validation.BlockedSIDs += $SIDString

                    try {
                        $logMessage = "Well-known SID $SIDString blocked for removal"
                        $logParams = @{
                            Level = 'Warning'; Component = 'SIDSecurity'; CorrelationId = $CorrelationId
                        }
                        Write-StructuredLog $logMessage @logParams
                    } catch {
                        Write-Debug "Logging unavailable: $($_.Exception.Message)"
                    }

                    # Log well-known SID security blocking
                    $securityContext = @{
                        SIDString = $SIDString
                        ValidationLevel = $ValidationLevel
                        BlockedReason = 'WellKnownSID'
                        RiskLevel = 'High'
                        SystemSecurityImpact = $true
                        ObjectDN = $ObjectDN
                        SIDAnalysis = $sidAnalysis
                    }
                    try {
                        Write-SecurityLog -SecurityEventType 'DataValidation' -Message "Well-known SID validation blocked - system security protection" -Outcome 'Failure' -CorrelationId $CorrelationId -SecurityContext $securityContext
                    } catch { 
                        # Store security context for test access even if logging fails
                        $script:LastSecurityContext = $securityContext
                    }

                    # Early return for well-known SIDs in Standard/Strict validation
                    return $validation
                }
            }

            # Handle malicious input patterns with immediate blocking
            if ($sidAnalysis.RiskLevel -eq 'Critical') {
                $validation.IsValid = $false
                $validation.RiskLevel = "Critical"
                $validation.Issues += "Critical security risk detected - potentially malicious input"
                $validation.BlockedSIDs += $SIDString

                try {
                    $logMessage = "Critical risk SID $SIDString blocked for security"
                    $logParams = @{ Level = 'Error'; Component = 'SIDSecurity'; CorrelationId = $CorrelationId }
                    Write-StructuredLog $logMessage @logParams
                } catch {
                    Write-Debug "Logging unavailable: $($_.Exception.Message)"
                }

                # Log critical security blocking
                $securityContext = @{
                    SIDString = $SIDString
                    ValidationLevel = $ValidationLevel
                    BlockedReason = 'CriticalSecurityRisk'
                    RiskLevel = 'Critical'
                    SecurityThreat = $true
                    ObjectDN = $ObjectDN
                    SIDAnalysis = $sidAnalysis
                }
                try {
                    Write-SecurityLog -SecurityEventType 'DataValidation' -Message "Critical risk SID validation blocked - security threat detected" -Outcome 'Failure' -CorrelationId $CorrelationId -SecurityContext $securityContext
                } catch { 
                    # Store security context for test access even if logging fails
                    $script:LastSecurityContext = $securityContext
                }

                # Early return for critical security risks
                return $validation
            }

            # Risk-based validation
            switch ($sidAnalysis.RiskLevel) {
                'High' {
                    $validation.RiskLevel = "High"
                    # Always add the high-risk message for High risk SIDs
                    $validation.Issues += "High-risk SID requires elevated confirmation for removal"
                    
                    if ($ValidationLevel -eq 'Strict') {
                        $validation.RequiresElevatedConfirmation = $true
                        $validation.IsValid = $false
                        $validation.BlockedSIDs += $SIDString
                    } else {
                        $validation.RequiresElevatedConfirmation = $true
                    }

                    # Log high-risk SID validation
                    try {
                        Write-SecurityLog -SecurityEventType 'DataValidation' -Message "High-risk SID identified - elevated validation required" -Outcome 'Attempt' -CorrelationId $CorrelationId -SecurityContext @{
                            SIDString = $SIDString
                            ValidationLevel = $ValidationLevel
                            RiskLevel = 'High'
                            RequiresElevatedConfirmation = $validation.RequiresElevatedConfirmation
                            SIDAnalysis = @{
                                LikelySource = $sidAnalysis.LikelySource
                                Confidence = $sidAnalysis.Confidence
                                Notes = $sidAnalysis.Notes
                            }
                            ObjectDN = $ObjectDN
                        }
                    } catch {
                        Write-Debug "Logging unavailable: $($_.Exception.Message)"
                    }
                }
                'Medium' {
                    if ($ValidationLevel -eq 'Strict') {
                        $validation.RequiresElevatedConfirmation = $true
                    }
                    $validation.RiskLevel = "Medium"
                }
                'Low' {
                    # Nothing to record here; the final determination below adds an allowed SID once
                }
            }

            # Object context validation
            if ($ObjectDN) {
                # Check if object is in critical path
                if ($script:Config -and $script:Config.CriticalObjectPatterns) {
                    foreach ($pattern in $script:Config.CriticalObjectPatterns) {
                        if ($ObjectDN -like $pattern) {
                            $validation.RequiresElevatedConfirmation = $true
                            $validation.Issues += "SID is on critical object: $ObjectDN"
                            $validation.RiskLevel = "High"
                            break
                        }
                    }
                }
            }

            # Final validation determination
            if ($validation.Issues.Count -eq 0 -and $validation.BlockedSIDs.Count -eq 0) {
                $validation.AllowedSIDs += $SIDString

                # Log successful security validation
                try {
                    Write-SecurityLog -SecurityEventType 'DataValidation' -Message "SID security validation completed successfully" -Outcome 'Success' -CorrelationId $CorrelationId -SecurityContext @{
                        SIDString = $SIDString
                        ValidationLevel = $ValidationLevel
                        FinalRiskLevel = $validation.RiskLevel
                        IsValid = $validation.IsValid
                        RequiresElevatedConfirmation = $validation.RequiresElevatedConfirmation
                        ObjectDN = $ObjectDN
                    }
                } catch {
                    Write-Debug "Logging unavailable: $($_.Exception.Message)"
                }
            }

            try {
                $logMessage = "Security validation completed for $SIDString - Valid: $($validation.IsValid), " +
                    "Risk: $($validation.RiskLevel)"
                Write-StructuredLog $logMessage -Level Debug -Component 'SIDSecurity' -CorrelationId $CorrelationId
            } catch {
                Write-Debug "Logging unavailable: $($_.Exception.Message)"
            }
            return $validation
        }
        catch {
            try {
                $logMessage = "Error in security validation for SID $SIDString : $($_.Exception.Message)"
                Write-StructuredLog $logMessage -Level Error -Component 'SIDSecurity' -CorrelationId $CorrelationId
            } catch {
                Write-Debug "Logging unavailable: $($_.Exception.Message)"
            }

            # Log security validation error
            $securityContext = @{
                SIDString = $SIDString
                ValidationLevel = $ValidationLevel
                ErrorMessage = $_.Exception.Message
                ObjectDN = $ObjectDN
            }
            try {
                Write-SecurityLog -SecurityEventType 'DataValidation' -Message "SID security validation error" -Outcome 'Failure' -CorrelationId $CorrelationId -SecurityContext $securityContext
            } catch { 
                # Store security context for test access even if logging fails
                $script:LastSecurityContext = $securityContext
            }

            $validation = [SecurityValidationResult]::new()
            $validation.IsValid = $false
            $validation.RiskLevel = "Critical"
            $validation.Issues += "Validation error: $($_.Exception.Message)"
            return $validation
        }
    }
}
