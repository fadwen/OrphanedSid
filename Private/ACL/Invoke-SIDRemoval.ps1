#Requires -Version 5.1

<#
.SYNOPSIS
    Pure ACL manipulation module for SID removal operations

.DESCRIPTION
    Provides focused ACL manipulation functionality for removing SIDs from
    Active Directory security descriptors. This module implements the "tool"
    pattern with pure ACL processing logic, enabling independent testing
    without Active Directory dependencies.

    This module focuses solely on in-memory ACL manipulation, making it
    highly testable and reusable across different removal scenarios.

.NOTES
    Author: Jeffrey Stuhr
    Blog: https://www.techbyjeff.net
    LinkedIn: https://www.linkedin.com/in/jeffrey-stuhr-034214aa/
    PowerShell Version: 5.1+ (Windows), 7.x+ (Cross-platform)

    TROUBLESHOOTING:
    - For ACL manipulation errors: .\Troubleshooting\Common\Common-Issues.md
    - For performance issues: .\Troubleshooting\Performance\Performance-Tuning.md

    DEPENDENCIES:
    - Requires Logging.ps1 for Write-StructuredLog function
    - System.DirectoryServices.ActiveDirectorySecurity for ACL objects
#>

function Invoke-SIDRemoval {
    <#
    .SYNOPSIS
        Performs pure ACL manipulation to remove specified SIDs

    .DESCRIPTION
        Processes Active Directory ACL objects to remove specified SIDs while
        maintaining ACL integrity and providing detailed operation tracking.

        This function implements focused ACL manipulation using the "tool" pattern:
        - Accepts ACL objects and SID lists as input
        - Performs in-memory ACL modifications
        - Returns structured results for further processing
        - No external dependencies on Active Directory connections

        The function supports both actual removal and preview (WhatIf) modes,
        making it suitable for validation and approval workflows.

    .PARAMETER ACL
        The Active Directory security descriptor object to modify.
        Must be a valid System.DirectoryServices.ActiveDirectorySecurity object.

    .PARAMETER AllowedSIDs
        Array of orphaned Security Identifiers that are approved for removal from the ACL.
        Only these SIDs will be processed for removal operations.

    .PARAMETER ObjectDN
        Distinguished name of the AD object for logging context.
        Used for correlation and audit trail purposes only.

    .PARAMETER WhatIfMode
        When specified, performs validation and shows what would be removed
        without making actual changes to the ACL object.

    .PARAMETER CorrelationId
        Unique identifier for tracking this removal operation across
        logs and audit trails. Generated automatically if not provided.

    .EXAMPLE
        PS> $result = Invoke-SIDRemoval -ACL $aclObject -AllowedSIDs @("S-1-5-21-1234567890-1001")

        DESCRIPTION: Removes a single SID from an ACL object
        OUTPUT: PSCustomObject with ModifiedACL, RemovedSIDs, and FailedSIDs
        USE CASE: Basic ACL manipulation for targeted SID removal

    .EXAMPLE
        PS> $result = Invoke-SIDRemoval -ACL $acl -AllowedSIDs $sids -WhatIfMode

        DESCRIPTION: Preview mode showing what would be removed without changes
        OUTPUT: Results showing planned operations without ACL modification
        USE CASE: Validation and approval workflows before actual removal

    .EXAMPLE
        PS> $removal = Invoke-SIDRemoval -ACL $acl -AllowedSIDs $approvedSIDs -ObjectDN $dn -CorrelationId $id
        Write-Output "Removed $($removal.RemovedSIDs.Count) SIDs successfully"

        DESCRIPTION: Full ACL processing with correlation tracking and result validation
        OUTPUT: Comprehensive removal results with audit trail
        USE CASE: Enterprise automation with full logging and tracking

    .OUTPUTS
        SIDRemovalResult. An object with these properties:
        - ModifiedACL: the ACL object after the removal
        - RemovedSIDs: the SIDs whose entries were removed
        - FailedSIDs: the SIDs whose removal raised an error
        - FoundSIDs: the SIDs of the allowed list that hold an explicit entry on the object
        - Success: True when no removal raised an error
        - ErrorMessage: for each SID in FailedSIDs, the SID and the message of the error that was
          caught, joined with '; '; null when nothing failed

    .NOTES

        DESIGN PRINCIPLES:
        - Pure function with no external dependencies
        - Supports both actual and preview operations
        - Comprehensive error handling with detailed logging
        - Maintains ACL integrity throughout processing

        TROUBLESHOOTING:
        - For ACE removal failures: Check SID format and ACL structure
        - For performance issues: Consider ACL size and complexity
        - For logging problems: Verify correlation ID propagation
    #>

    [CmdletBinding()]
    [OutputType('SIDRemovalResult')]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [PSObject]$ACL,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$AllowedSIDs,

        [Parameter()]
        [string]$ObjectDN,

        [Parameter()]
        [switch]$WhatIfMode,

        [Parameter()]
        [string]$CorrelationId = [System.Guid]::NewGuid().ToString()
    )

    # The arguments are checked before the try. Each check ends the function with an error of its
    # own, and it is the caller that logs it: the catch below is for a failure of the removal.
    foreach ($sid in $AllowedSIDs) {
        if ($sid -notmatch '^S-\d+-\d+(-\d+)*$') {
            $message = "Invalid SID format: $sid. SIDs must follow the pattern S-X-Y-Z..."
            $exception = [System.ArgumentException]::new($message)
            $category = [System.Management.Automation.ErrorCategory]::InvalidArgument
            $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                $exception, 'SidFormatInvalid', $category, $sid)
            $PSCmdlet.ThrowTerminatingError($errorRecord)
        }
    }

    if (-not $ACL) {
        $exception = [System.ArgumentException]::new('ACL parameter cannot be null or empty.')
        $category = [System.Management.Automation.ErrorCategory]::InvalidArgument
        $errorRecord = [System.Management.Automation.ErrorRecord]::new(
            $exception, 'AclMissing', $category, $ObjectDN)
        $PSCmdlet.ThrowTerminatingError($errorRecord)
    }

    try {
        # The rules are read once, with GetAccessRules() for a directory security descriptor. An
        # object whose rules cannot be read ends the function here. It used to be given an empty
        # Access property, and the removal then found nothing to remove and reported success.
        $accessRules = @(Get-AclAccessRule -Acl $ACL)

        Write-StructuredLog "Starting ACL SID removal for $($AllowedSIDs.Count) SIDs (Object: $ObjectDN, WhatIf: $WhatIfMode)" -Level Debug -CorrelationId $CorrelationId

        # Initialize result collections
        $workingACL = $ACL
        $foundSIDs = [System.Collections.Generic.List[string]]::new()
        $removedSIDs = [System.Collections.Generic.List[string]]::new()
        $failedSIDs = [System.Collections.Generic.List[string]]::new()
        # For each SID that failed, the SID and the message of the error that was caught
        $failureMessages = [System.Collections.Generic.List[string]]::new()

        # Find SIDs in ACL that ARE in the allowed list (these are orphaned SIDs to be removed).
        # Only explicit entries: an inherited entry comes from a parent object and cannot be removed
        # from this one, so it is neither removed nor counted.
        $acesToRemove = $accessRules | Where-Object {
            -not $_.IsInherited -and $AllowedSIDs -contains $_.IdentityReference.Value
        }

        foreach ($ace in $acesToRemove) {
            try {
                $sid = $ace.IdentityReference.Value
                Write-StructuredLog "Processing SID for ACL removal: $sid" -Level Debug -CorrelationId $CorrelationId

                # Track that we found this SID to remove
                if (-not $foundSIDs.Contains($sid)) {
                    $foundSIDs.Add($sid)
                }

                # Process ACE for removal
                if ($WhatIfMode) {
                    Write-StructuredLog "WOULD REMOVE ACE: $sid - $($ace.ActiveDirectoryRights)" -Level Verbose -CorrelationId $CorrelationId
                    # In WhatIf mode, don't add to removedSIDs
                } else {
                    # Perform actual ACE removal
                    $workingACL.RemoveAccessRuleSpecific($ace)
                    if (-not $removedSIDs.Contains($sid)) {
                        $removedSIDs.Add($sid)
                    }
                    Write-StructuredLog "REMOVED ACE: $sid - $($ace.ActiveDirectoryRights)" -Level Verbose -CorrelationId $CorrelationId
                }
            }
            catch {
                $sid = $ace.IdentityReference.Value
                if (-not $failedSIDs.Contains($sid)) {
                    $failedSIDs.Add($sid)
                    $failureMessages.Add("${sid}: $($_.Exception.Message)")
                }
                Write-StructuredLog "FAILED to process SID $sid : $($_.Exception.Message)" -Level Error -CorrelationId $CorrelationId
            }
        }

        # What the workflow reads, and what the function found out. The message is that of the
        # errors that were caught, which the log has as well, one entry for each SID.
        $errorMessage = $null
        if ($failureMessages.Count -gt 0) {
            $errorMessage = $failureMessages -join '; '
        }
        $result = [PSCustomObject]@{
            PSTypeName = 'SIDRemovalResult'
            ModifiedACL = $workingACL
            RemovedSIDs = $removedSIDs.ToArray()
            FailedSIDs = $failedSIDs.ToArray()
            FoundSIDs = $foundSIDs.ToArray()
            Success = ($failedSIDs.Count -eq 0)
            ErrorMessage = $errorMessage
        }

        Write-StructuredLog "ACL SID removal completed - Removed: $($result.RemovedSIDs.Count), Failed: $($result.FailedSIDs.Count)" -Level Verbose -CorrelationId $CorrelationId
        return $result
    }
    catch {
        Write-StructuredLog "Error in ACL SID removal processing: $($_.Exception.Message)" -Level Error -CorrelationId $CorrelationId
        $PSCmdlet.ThrowTerminatingError($_)
    }
}


