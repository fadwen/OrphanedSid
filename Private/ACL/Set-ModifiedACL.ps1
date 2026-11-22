#Requires -Version 5.1

function Set-ModifiedACL {
    <#
    .SYNOPSIS
        Safely applies modified ACL to Active Directory objects

    .DESCRIPTION
        Applies ACL changes to AD objects with comprehensive validation, retry logic,
        and proper error handling. This function implements the "tool" pattern for
        focused ACL application.

        The function includes:
        - Parameter validation before AD operations
        - Retry logic for transient AD failures
        - ShouldProcess support for WhatIf scenarios
        - Comprehensive logging with correlation tracking

    .PARAMETER ACL
        The modified Active Directory security descriptor to apply.
        Must be a valid System.DirectoryServices.ActiveDirectorySecurity object
        containing the desired ACL configuration.

    .PARAMETER ObjectDN
        Distinguished name of the target Active Directory object.
        Object must exist and be accessible with current credentials.

    .PARAMETER CorrelationId
        Unique identifier for tracking this ACL application operation
        across logs and audit trails. Generated automatically if not provided.

    .EXAMPLE
        PS> Set-ModifiedACL -ACL $modifiedAcl -ObjectDN "CN=TestUser,CN=Users,DC=contoso,DC=com"

        DESCRIPTION: Applies a modified ACL to a user object
        OUTPUT: Boolean indicating success (True) or failure (False)
        USE CASE: Basic ACL application after SID removal operations

    .EXAMPLE
        PS> $success = Set-ModifiedACL -ACL $acl -ObjectDN $dn -CorrelationId $correlationId
        if ($success) {
            Write-Output "ACL applied successfully"
        }

        DESCRIPTION: Programmatic ACL application with result validation
        OUTPUT: Boolean result for conditional processing
        USE CASE: Automation workflows with error handling

    .EXAMPLE
        PS> Set-ModifiedACL -ACL $acl -ObjectDN $dn -WhatIf

        DESCRIPTION: Preview mode showing what ACL would be applied
        OUTPUT: False (no changes made) with detailed logging
        USE CASE: Validation and approval workflows

    .OUTPUTS
        ACLApplicationResult. A PSCustomObject that carries this type name; the module has no class
        of the name. Its properties:
        - Success: True when the ACL was written. False when the write failed, and under -WhatIf.
        - ErrorMessage: the message of the error that the write raised; null otherwise
        - Verified: True when the ACL could be read back after the write
        - VerificationError: the message of the error that the read-back raised; null otherwise
        A write that fails is returned as a result with Success False, not raised as an error.

    .NOTES
        RELIABILITY FEATURES:
        - Parameter validation before AD operations
        - Retry logic with exponential backoff for transient failures
        - Comprehensive error handling and logging
        - ShouldProcess support for safe operations

        SECURITY CONSIDERATIONS:
        - Requires appropriate AD permissions for ACL modification
        - All operations logged with correlation IDs for audit trails
        - Validates ACL structure before application

        TROUBLESHOOTING:
        - For permission errors: Verify AD modification rights
        - For connectivity issues: Check AD server availability
        - For validation failures: Ensure ACL object integrity
        - For ACL application failures: .\Troubleshooting\Common\Common-Issues.md
    #>

    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('ACLApplicationResult')]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [PSObject]$ACL,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ObjectDN,

        [Parameter()]
        [string]$CorrelationId = [System.Guid]::NewGuid().ToString()
    )

    Write-StructuredLog "Starting ACL application to $ObjectDN" -Level Verbose -CorrelationId $CorrelationId

    # The arguments are checked before the try, and a bad one ends the function with an error. The
    # catch below turns a failure of the write into a result, and these are not such a failure.
    $refusal = $null
    if (-not $ACL) {
        $refusal = 'AclMissing'
        $message = 'ACL parameter must not be null'
    } elseif ([string]::IsNullOrWhiteSpace($ObjectDN.Trim())) {
        $refusal = 'DistinguishedNameEmpty'
        $message = 'ObjectDN parameter cannot be empty or whitespace'
    } elseif (-not (Test-ValidDistinguishedName -DistinguishedName $ObjectDN -CorrelationId $CorrelationId)) {
        # The check is of the form of the name only. Whether the object exists is settled by the
        # write below, which fails with the directory's own error.
        $refusal = 'DistinguishedNameRefused'
        $message = "The distinguished name was refused because it is not well formed: $ObjectDN"
    }

    if ($null -ne $refusal) {
        $exception = [System.ArgumentException]::new($message)
        $category = [System.Management.Automation.ErrorCategory]::InvalidArgument
        $errorRecord = [System.Management.Automation.ErrorRecord]::new($exception, $refusal, $category, $ObjectDN)
        $PSCmdlet.ThrowTerminatingError($errorRecord)
    }

    try {
        $ruleCount = @(Get-AclAccessRule -Acl $ACL).Count
        Write-StructuredLog "ACL contains $ruleCount access rules for application" -Level Debug -CorrelationId $CorrelationId

        $success = $false
        # The backup is the caller's job: Invoke-RemovalWorkflow writes it with New-ACLBackup before
        # calling this function, so nothing here touches the backup folder.

        if ($PSCmdlet.ShouldProcess($ObjectDN, "Apply modified ACL")) {
            # Use retry logic for reliable AD operations. A write that fails goes to the catch at
            # the end of the function, which logs it and returns it as a failed result.
            Invoke-ADOperationWithRetry -ScriptBlock {
                Set-DirectoryObjectAcl -DistinguishedName $ObjectDN -AclObject $ACL
            } -MaxRetries 3 -CorrelationId $CorrelationId

            Write-StructuredLog "Successfully applied ACL changes to $ObjectDN" -Level Verbose -CorrelationId $CorrelationId
            $success = $true
        }
        else {
            Write-StructuredLog "ACL modification skipped due to WhatIf mode for $ObjectDN" -Level Verbose -CorrelationId $CorrelationId
            $success = $false
        }

        # Perform verification by attempting to read the ACL back
        $verified = $false
        $verificationError = $null
        if ($success) {
            try {
                Write-StructuredLog "Verifying ACL application for $ObjectDN" -Level Debug -CorrelationId $CorrelationId
                Invoke-ADOperationWithRetry -ScriptBlock {
                    $null = Get-DirectoryObjectAcl -DistinguishedName $ObjectDN
                } -MaxRetries 2 -CorrelationId $CorrelationId
                $verified = $true
                Write-StructuredLog "ACL verification successful for $ObjectDN" -Level Debug -CorrelationId $CorrelationId
            }
            catch {
                $verificationError = $_.Exception.Message
                Write-StructuredLog "ACL verification failed for $ObjectDN : $verificationError" -Level Warning -CorrelationId $CorrelationId
            }
        }
        
        # Success is what the workflow reads. Verified says whether the ACL could be read back,
        # which is logged above as well.
        return [PSCustomObject]@{
            PSTypeName = 'ACLApplicationResult'
            Success = $success
            ErrorMessage = $null
            Verified = $verified
            VerificationError = $verificationError
        }
    }
    catch {
        $errorMessage = $_.Exception.Message
        Write-StructuredLog "Failed to apply ACL changes to $ObjectDN : $errorMessage" -Level Error -CorrelationId $CorrelationId

        # A write that failed is a result, not an error: the workflow reports it for this object
        # and goes on to the next. The message is that of the error that was caught.
        return [PSCustomObject]@{
            PSTypeName = 'ACLApplicationResult'
            Success = $false
            ErrorMessage = $errorMessage
            Verified = $false
            VerificationError = $null
        }
    }
}

# Module loaded successfully - suppressed output to prevent pipeline pollution

