#Requires -Version 5.1

function Invoke-RemovalWorkflow {
    <#
    .SYNOPSIS
        Orchestrates comprehensive SID removal workflow operations

    .DESCRIPTION
        Coordinates the complete SID removal workflow including security validation,
        backup creation, ACL manipulation, application, and verification. This function
        implements the "controller" pattern, delegating specific tasks to specialized
        modules while maintaining overall workflow integrity.

        The workflow includes:
        - Parameter validation and preprocessing
        - Security validation and risk assessment
        - Optional ACL backup creation
        - ACL manipulation and SID removal
        - ACL application to Active Directory
        - Post-operation verification
        - Comprehensive audit logging and tracking

    .PARAMETER ObjectDistinguishedName
        Distinguished name of the Active Directory object to process.
        Object must exist and be accessible with current credentials.

    .PARAMETER OrphanedSIDs
        Array of orphaned Security Identifiers to remove from the object.
        SIDs will be validated against security policies before removal.

    .PARAMETER BackupPath
        Optional directory path for storing ACL backups before removal operations.
        Backups include metadata and integrity verification.

    .PARAMETER WhatIfMode
        When specified, performs validation and shows what would be removed
        without making actual changes. Useful for preview and approval workflows.

    .PARAMETER CorrelationId
        Unique identifier for tracking this removal operation across logs
        and audit trails. Generated automatically if not provided.

    .EXAMPLE
        PS> $result = Invoke-RemovalWorkflow -ObjectDistinguishedName "CN=TestUser,CN=Users,DC=contoso,DC=com" -OrphanedSIDs @("S-1-5-21-1234567890-1001")

        DESCRIPTION: Orchestrates removal workflow for a single SID
        OUTPUT: RemovalOperationResult with comprehensive operation details
        USE CASE: Targeted cleanup with full workflow validation

    .EXAMPLE
        PS> $result = Invoke-RemovalWorkflow -ObjectDistinguishedName $dn -OrphanedSIDs $sids -BackupPath "C:\Backups" -WhatIfMode -CorrelationId $id

        DESCRIPTION: Preview workflow with backup preparation and correlation tracking
        OUTPUT: RemovalOperationResult showing planned operations without changes
        USE CASE: Pre-approval validation for enterprise change management

    .OUTPUTS
        [RemovalOperationResult] Object containing comprehensive operation results:
        - ObjectDN: Distinguished name of processed object
        - CorrelationId: Unique tracking identifier
        - IntendedRemovals: Number of SIDs planned for removal
        - ActualRemovals: Number of SIDs successfully removed
        - FailedRemovals: Number of SIDs that failed removal
        - RemovedSIDs: Array of successfully removed SIDs
        - FailedSIDs: Array of SIDs that failed removal
        - BlockedSIDs: Array of SIDs blocked by security policies
        - NotFoundSIDs: Array of SIDs that held no explicit entry on the object any more
        - Success: Overall operation success status
        - ErrorMessage: Detailed error information if applicable
        - ProcessingTime: Duration of the complete workflow
        - SecurityValidation: Comprehensive security validation results

    .NOTES
        WORKFLOW FEATURES:
        - Modular design with specialized component delegation
        - A failure in any phase ends the workflow with a failed result; nothing is rolled back
        - Security-first approach with validation gates
        - Security log entries for what the workflow does to the ACL, under the correlation ID
        - A backup when a backup path is given, and a verification after every write

        SECURITY CONTROLS:
        - Multi-layer security validation before any changes
        - Protected SID detection and blocking
        - Risk-based operation controls
        - Comprehensive audit logging throughout workflow
        - A backup before the change, which Restore-OrphanedSidBackup restores from

        TROUBLESHOOTING:
        - For security blocks: Review security validation results
        - For ACL failures: Check AD permissions and connectivity
        - For verification issues: Consider AD replication timing
        - For performance: Review object complexity and network latency
        - For workflow failures: .\Troubleshooting\Common\Common-Issues.md
    #>

    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([RemovalOperationResult])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ObjectDistinguishedName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$OrphanedSIDs,

        [Parameter()]
        [string]$BackupPath,

        [Parameter()]
        [switch]$WhatIfMode,

        [Parameter()]
        [string]$CorrelationId = [System.Guid]::NewGuid().ToString()
    )

    # Initialize result object
    $result = [RemovalOperationResult]::new()
    $result.ObjectDN = $ObjectDistinguishedName
    $result.CorrelationId = $CorrelationId
    $result.IntendedRemovals = $OrphanedSIDs.Count

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    # What a failure of the workflow leaves behind: the failed result, a log entry and an audit
    # entry. The catch below runs it for an error of a step, and the two checks that this function
    # makes itself run it and return, so that every failure is reported in the same way.
    $recordFailure = {
        param([string]$Reason)

        $result.Success = $false
        $result.ErrorMessage = "Workflow failed: $Reason"
        Write-StructuredLog "SID removal workflow failed for $ObjectDistinguishedName : $Reason" -Level Error -CorrelationId $CorrelationId

        # Log workflow failure for security audit
        Write-RemovalSecurityLog -SecurityEventType 'PrivilegeUse' -Message "SID removal workflow failed" -Outcome 'Failure' -CorrelationId $CorrelationId -SecurityContext @{
            Operation = 'RemoveOrphanedSIDs'
            TargetObjectDN = $ObjectDistinguishedName
            Error = $Reason
            IntendedRemovals = $result.IntendedRemovals
        }
    }

    try {
        Write-StructuredLog "Starting SID removal workflow for $ObjectDistinguishedName (SIDs: $($OrphanedSIDs.Count), WhatIf: $WhatIfMode)" -Level Verbose -CorrelationId $CorrelationId

        # Phase 1: Parameter Validation
        Write-StructuredLog "Phase 1: Parameter validation" -Level Debug -CorrelationId $CorrelationId
        if ([string]::IsNullOrWhiteSpace($ObjectDistinguishedName.Trim())) {
            & $recordFailure 'ObjectDN parameter cannot be empty or whitespace'
            return $result
        }

        # Phase 2: ACL Retrieval
        Write-StructuredLog "Phase 2: ACL retrieval" -Level Debug -CorrelationId $CorrelationId
        $acl = Get-ACLForRemoval -ObjectDistinguishedName $ObjectDistinguishedName -CorrelationId $CorrelationId

        # Phase 3: Security Validation
        Write-StructuredLog "Phase 3: Security validation" -Level Debug -CorrelationId $CorrelationId
        $securityValidation = Invoke-SecurityValidation -OrphanedSIDs $OrphanedSIDs -ObjectDN $ObjectDistinguishedName -CurrentDomainSID $script:CurrentDomainSID -CorrelationId $CorrelationId

        $result.SecurityValidation = $securityValidation
        $result.BlockedSIDs = $securityValidation.BlockedSIDs

        if (-not $securityValidation.IsValid) {
            $result.ErrorMessage = "Security validation failed: $($securityValidation.Issues -join '; ')"
            $result.Success = $false
            Write-StructuredLog "SECURITY BLOCK: $($result.ErrorMessage)" -Level Error -CorrelationId $CorrelationId
            return $result
        }

        # Phase 4: Backup Creation (if requested and not WhatIf mode)
        if (-not $WhatIfMode -and $BackupPath) {
            Write-StructuredLog "Phase 4: Backup creation" -Level Debug -CorrelationId $CorrelationId
            $backupFile = New-ACLBackup -ObjectDN $ObjectDistinguishedName -ACL $acl -BackupPath $BackupPath -CorrelationId $CorrelationId
            if (-not $backupFile) {
                # A backup that is declined at its own prompt returns nothing. Nothing is removed
                # from an object that has no backup.
                & $recordFailure 'Failed to create ACL backup - aborting removal operation'
                return $result
            }
            $result.BackupFile = $backupFile
        }

        # Phase 5: SID Removal Processing
        Write-StructuredLog "Phase 5: SID removal processing" -Level Debug -CorrelationId $CorrelationId
        $removalResults = Invoke-SIDRemoval -ACL $acl -AllowedSIDs $securityValidation.AllowedSIDs -ObjectDN $ObjectDistinguishedName -WhatIfMode:$WhatIfMode -CorrelationId $CorrelationId

        $result.RemovedSIDs = $removalResults.RemovedSIDs
        $result.FailedSIDs = $removalResults.FailedSIDs
        $result.ActualRemovals = $removalResults.RemovedSIDs.Count
        $result.FailedRemovals = $removalResults.FailedSIDs.Count

        # SIDs that discovery reported and that hold no explicit entry in the ACL read in phase 2,
        # the one that was backed up in phase 4 and changed in phase 5: they were neither removed
        # nor failed. Outside -WhatIf, where nothing is removed by design, they make the result a
        # failure whatever else succeeded.
        $notFoundSIDs = @()
        if (-not $WhatIfMode) {
            $notFoundSIDs = @($securityValidation.AllowedSIDs | Where-Object {
                    $removalResults.RemovedSIDs -notcontains $_ -and $removalResults.FailedSIDs -notcontains $_
                })
        }
        $result.NotFoundSIDs = $notFoundSIDs

        # Phase 6: Security Audit Logging
        Write-RemovalSecurityLog -SecurityEventType 'PrivilegeUse' -Message "ACL modification operation initiated" -Outcome 'Attempt' -CorrelationId $CorrelationId -SecurityContext @{
            Operation = 'RemoveOrphanedSIDs'
            TargetObjectDN = $ObjectDistinguishedName
            SIDsToRemove = $removalResults.RemovedSIDs.Count
            SIDsFailedRemoval = $removalResults.FailedSIDs.Count
            WhatIfMode = $WhatIfMode
            BackupCreated = [bool]$result.BackupFile
            BackupFile = $result.BackupFile
            SecurityValidation = @{
                IsValid = $securityValidation.IsValid
                RiskLevel = $securityValidation.RiskLevel
                BlockedSIDs = $securityValidation.BlockedSIDs.Count
            }
        }

        # Phase 7: ACL Application (if not WhatIf mode and changes exist)
        if (-not $WhatIfMode -and $removalResults.RemovedSIDs.Count -gt 0) {
            Write-StructuredLog "Phase 7: ACL application" -Level Debug -CorrelationId $CorrelationId

            if ($PSCmdlet.ShouldProcess($ObjectDistinguishedName, "Apply SID removal changes")) {
                $applicationSuccess = Set-ModifiedACL -ACL $removalResults.ModifiedACL -ObjectDN $ObjectDistinguishedName -CorrelationId $CorrelationId

                # Set-ModifiedACL returns an ACLApplicationResult, which is truthy even when the write
                # failed; only its Success property says whether the ACL was applied
                if ($applicationSuccess.Success) {
                    # Log successful operation
                    Write-RemovalSecurityLog -SecurityEventType 'PrivilegeUse' -Message "ACL modification operation completed successfully" -Outcome 'Success' -CorrelationId $CorrelationId -SecurityContext @{
                        Operation = 'RemoveOrphanedSIDs'
                        TargetObjectDN = $ObjectDistinguishedName
                        SIDsRemoved = $removalResults.RemovedSIDs
                        ActualRemovals = $result.ActualRemovals
                        BackupFile = $result.BackupFile
                        SecurityValidationPassed = $true
                    }

                    # Phase 8: Verification
                    Write-StructuredLog "Phase 8: Operation verification" -Level Debug -CorrelationId $CorrelationId
                    $verificationResult = Invoke-RemovalVerification -ObjectDN $ObjectDistinguishedName -AllowedSIDs $securityValidation.AllowedSIDs -CorrelationId $CorrelationId
                    $result.Success = $verificationResult.Success

                    if (-not $verificationResult.Success) {
                        $result.ErrorMessage = $verificationResult.ErrorMessage
                        Write-RemovalSecurityLog -SecurityEventType 'PrivilegeUse' -Message "ACL modification verification failed" -Outcome 'Failure' -CorrelationId $CorrelationId -SecurityContext @{
                            Operation = 'RemoveOrphanedSIDs'
                            TargetObjectDN = $ObjectDistinguishedName
                            VerificationError = $verificationResult.ErrorMessage
                            RemainingOrphanedSIDs = $verificationResult.RemainingOrphanedSIDs
                        }
                    }
                } else {
                    $result.Success = $false
                    # The reason of the failed write goes into the result. It was only in the log,
                    # so a reader of the results had to look the object up there. A write that was
                    # declined at a prompt has no reason to give.
                    $writeFailure = $applicationSuccess.ErrorMessage
                    $result.ErrorMessage = 'Failed to apply ACL changes'
                    if ($writeFailure) {
                        $result.ErrorMessage = "Failed to apply ACL changes: $writeFailure"
                    }
                    Write-RemovalSecurityLog -SecurityEventType 'PrivilegeUse' -Message "ACL modification application failed" -Outcome 'Failure' -CorrelationId $CorrelationId -SecurityContext @{
                        Operation = 'RemoveOrphanedSIDs'
                        TargetObjectDN = $ObjectDistinguishedName
                        Error = 'ACLApplicationFailure'
                        IntendedRemovals = $result.IntendedRemovals
                    }
                }
            }
        } elseif ($WhatIfMode) {
            $result.Success = $true
            Write-StructuredLog "WhatIf mode: No changes applied" -Level Verbose -CorrelationId $CorrelationId
        } else {
            # No entry was removed, so nothing was written. Every SID that was asked for either
            # failed, which is reported here, or was not found on the object, which is reported
            # below. There is no third case: validation allows every SID or blocks the object.
            $result.Success = ($removalResults.FailedSIDs.Count -eq 0)
            if (-not $result.Success) {
                $result.ErrorMessage = "The entry could not be removed for: $($removalResults.FailedSIDs -join ', ')"
            }
            Write-StructuredLog "No entry was removed from the ACL of $ObjectDistinguishedName" -Level Warning -CorrelationId $CorrelationId
        }

        if ($notFoundSIDs.Count -gt 0) {
            $result.Success = $false
            $notFoundMessage = "No explicit entry was found on the object for $($notFoundSIDs.Count) of " +
                "$($result.IntendedRemovals) SID(s) reported for removal: $($notFoundSIDs -join ', ')"
            if ($result.ErrorMessage) {
                $result.ErrorMessage = "$($result.ErrorMessage); $notFoundMessage"
            } else {
                $result.ErrorMessage = $notFoundMessage
            }
            Write-StructuredLog "$notFoundMessage (Object: $ObjectDistinguishedName)" -Level Error -CorrelationId $CorrelationId
            Write-RemovalSecurityLog -SecurityEventType 'PrivilegeUse' -Message "ACL modification did not find the entries reported for removal" -Outcome 'Failure' -CorrelationId $CorrelationId -SecurityContext @{
                Operation = 'RemoveOrphanedSIDs'
                TargetObjectDN = $ObjectDistinguishedName
                SIDsNotFound = $notFoundSIDs
                IntendedRemovals = $result.IntendedRemovals
            }
        }

        Write-StructuredLog "SID removal workflow completed for $ObjectDistinguishedName - Success: $($result.Success), Removed: $($result.ActualRemovals), Failed: $($result.FailedRemovals)" -Level Verbose -CorrelationId $CorrelationId
        return $result
    }
    catch {
        & $recordFailure $_.Exception.Message
        return $result
    }
    finally {
        $stopwatch.Stop()
        $result.ProcessingTime = $stopwatch.Elapsed
        Write-StructuredLog "Workflow processing time: $($result.ProcessingTime.TotalMilliseconds)ms" -Level Debug -CorrelationId $CorrelationId
    }
}



