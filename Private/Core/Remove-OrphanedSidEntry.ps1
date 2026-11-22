#Requires -Version 5.1

function Remove-OrphanedSidEntry {
    <#
    .SYNOPSIS
        Removes orphaned SIDs from the ACL of an Active Directory object

    .DESCRIPTION
        This function removes orphaned Security Identifiers (SIDs) from
        Active Directory object ACLs with comprehensive security validation, backup creation,
        and verification. The function implements a modular architecture with specialized
        components for maximum reliability and maintainability.

        SECURITY FEATURES:
        - Protected SID validation prevents removal of critical system accounts
        - Security risk assessment with configurable approval workflows
        - Comprehensive backup creation before any modifications
        - Verification of the ACL after each removal
        - Audit logging with correlation tracking

        MODULAR ARCHITECTURE:
        - Security validation: Specialized security assessment and risk analysis
        - ACL operations: Focused ACL retrieval, modification, and application
        - Verification: Independent post-operation validation
        - Workflow orchestration: Coordinated multi-step process management
        - Security logging: Comprehensive audit trail generation

    .PARAMETER ObjectDN
        [String[]] (Mandatory: Yes, Pipeline: ByValue)

        Specifies one or more Active Directory object distinguished names for SID removal.

        VALIDATION RULES:
        - Cannot be null or empty
        - Not checked further here. Invoke-RemovalWorkflow reads the ACL of each object, and
          an object whose ACL cannot be read gets a result with Success = False

        EXAMPLES:
        - Single OU: "OU=Finance,DC=contoso,DC=com"
        - Multiple objects: @("OU=HR,DC=contoso,DC=com", "CN=SharedFolder,CN=Computer,DC=contoso,DC=com")

    .PARAMETER OrphanedSIDs
        [String[]] (Mandatory: Yes)

        Specifies the orphaned SIDs to remove from the target objects.

        VALIDATION RULES:
        - Cannot be null or empty
        - Each SID goes through the security validation of the workflow. A SID that it blocks,
          such as a protected or a well-known one, is not removed

        EXAMPLES:
        - Single SID: "S-1-5-21-1234567890-1234567890-1234567890-1001"
        - Multiple SIDs: @("S-1-5-21-...-1001", "S-1-5-21-...-1002")

    .PARAMETER BackupPath
        [String] (Optional)

        Specifies the directory path for backup storage before SID removal.

        VALIDATION RULES:
        - The folder is created by New-ACLBackup when it does not exist
        - Has no default here: without a path no backup is written. Remove-OrphanedSid
          passes its backup folder, which defaults to .\Backup\[timestamp]

        EXAMPLES:
        - Network path: "\\backup-server\ad-backups\sid-removal"
        - Local path: "C:\ADBackups\SIDRemoval"

    .PARAMETER WhatIfMode
        [Switch] (Optional)

        Enables preview mode to show what changes would be made without executing them.

    .PARAMETER CorrelationId
        [String] (Optional)

        Provides a unique identifier for tracking operations across logs and systems.
        One is generated when none is given.

    .EXAMPLE
        PS> Remove-OrphanedSidEntry -ObjectDN "OU=Finance,DC=contoso,DC=com" -OrphanedSIDs "S-1-5-21-1234567890-1234567890-1234567890-1001"

        DESCRIPTION: Basic orphaned SID removal from a single organizational unit
        OUTPUT: RemovalOperationResult with success status and removal details
        USE CASE: Standard cleanup operation for single object with specific orphaned SID
        DURATION: Typically 2-5 seconds for simple ACL structures

    .EXAMPLE
        PS> Remove-OrphanedSidEntry -ObjectDN "OU=SharedResources,DC=contoso,DC=com" -OrphanedSIDs @("S-1-5-21-...-1001", "S-1-5-21-...-1002") -BackupPath "\\backup\AD" -WhatIfMode

        DESCRIPTION: Preview mode for multiple SID removal with custom backup location
        OUTPUT: Shows planned changes without executing, validates all components
        USE CASE: Production change validation and approval workflow preparation
        DURATION: ~1-2 seconds for preview operations

    .EXAMPLE
        PS> @("OU=HR,DC=contoso,DC=com", "OU=IT,DC=contoso,DC=com") | Remove-OrphanedSidEntry -OrphanedSIDs $orphanedSIDs -CorrelationId "CHANGE-2025-001"

        DESCRIPTION: Pipeline processing of multiple objects with correlation tracking
        OUTPUT: RemovalOperationResult objects for each processed object
        USE CASE: Enterprise automation workflows with change management tracking
        DURATION: Scales linearly with number of objects (~3-7 seconds per object)

    .INPUTS
        [String[]] - ObjectDN values can be provided via pipeline

    .OUTPUTS
        [RemovalOperationResult] Object containing:
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
        - ProcessingTime: Duration of the removal operation
        - SecurityValidation: Comprehensive security validation results

    .NOTES
        SECURITY CONSIDERATIONS:
        - Implements protected SID validation to prevent critical system damage
        - Uses privileged SID pattern detection for additional safety
        - Creates comprehensive backups before any changes
        - Provides rollback capability through backup restoration
        - Logs all security decisions

        TROUBLESHOOTING:
        - For security validation failures: .\Troubleshooting\Security\Security-Validation-Guide.md
        - For ACL access errors: .\Troubleshooting\Common\Common-Issues.md
        - For backup failures: .\Troubleshooting\Common\Backup-Restore-Issues.md

    .LINK
        https://docs.microsoft.com/en-us/powershell/module/activedirectory/
        .\Troubleshooting\Security\Security-Validation-Guide.md
    #>

    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([RemovalOperationResult])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [ValidateNotNullOrEmpty()]
        [string[]]$ObjectDN,

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

    process {
        foreach ($dn in $ObjectDN) {
            try {
                Write-StructuredLog "Starting SID removal operation for $dn" -Level Verbose -CorrelationId $CorrelationId

                # Invoke-RemovalWorkflow honours -WhatIfMode and $WhatIfPreference itself and prints the
                # preview, so both still reach it unchanged; this guard only answers -Confirm.
                if (-not $WhatIfMode -and -not $WhatIfPreference -and
                    -not $PSCmdlet.ShouldProcess($dn, 'Remove orphaned SIDs from the ACL')) {
                    $declined = "Removal declined at the confirmation prompt for $dn"
                    Write-StructuredLog $declined -Level Warning -CorrelationId $CorrelationId
                    continue
                }

                # Delegate to modular workflow orchestration
                $result = Invoke-RemovalWorkflow -ObjectDistinguishedName $dn -OrphanedSIDs $OrphanedSIDs -BackupPath $BackupPath -WhatIfMode:$WhatIfMode -CorrelationId $CorrelationId

                Write-StructuredLog "SID removal operation completed for $dn - Success: $($result.Success)" -Level Verbose -CorrelationId $CorrelationId
                # Emit, do not return: a return here would end the foreach and silently skip every
                # distinguished name after the first when several arrive by parameter
                $result
            }
            catch {
                # Create error result object for consistency
                $errorResult = [RemovalOperationResult]::new()
                $errorResult.ObjectDN = $dn
                $errorResult.CorrelationId = $CorrelationId
                $errorResult.IntendedRemovals = $OrphanedSIDs.Count
                $errorResult.Success = $false
                $errorResult.ErrorMessage = "The removal workflow failed: $($_.Exception.Message)"

                Write-StructuredLog "SID removal operation failed for $dn : $($_.Exception.Message)" -Level Error -CorrelationId $CorrelationId
                $errorResult
            }
        }
    }
}


