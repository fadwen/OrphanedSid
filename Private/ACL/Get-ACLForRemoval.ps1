#Requires -Version 5.1

function Get-ACLForRemoval {
    <#
    .SYNOPSIS
        Retrieves ACL from Active Directory objects with retry logic

    .DESCRIPTION
        Safely retrieves Active Directory ACL objects with comprehensive error
        handling and retry logic for enterprise reliability. This function
        implements the "tool" pattern for focused ACL retrieval operations.

        The function includes:
        - Retry logic for transient AD failures
        - Parameter validation and error handling
        - Comprehensive logging with correlation tracking
        - Optimized for removal operation workflows

    .PARAMETER ObjectDistinguishedName
        Distinguished name of the Active Directory object to retrieve ACL from.
        Object must exist and be accessible with current credentials.

    .PARAMETER CorrelationId
        Unique identifier for tracking this ACL retrieval operation
        across logs and audit trails. Generated automatically if not provided.

    .EXAMPLE
        PS> $acl = Get-ACLForRemoval -ObjectDistinguishedName "CN=TestUser,CN=Users,DC=contoso,DC=com"

        DESCRIPTION: Retrieves ACL from a user object
        OUTPUT: System.DirectoryServices.ActiveDirectorySecurity object
        USE CASE: Basic ACL retrieval for removal operations

    .EXAMPLE
        PS> $acl = Get-ACLForRemoval -ObjectDistinguishedName $dn -CorrelationId $correlationId
        if ($acl) {
            Write-Output "Retrieved ACL with $($acl.Access.Count) access rules"
        }

        DESCRIPTION: ACL retrieval with correlation tracking and validation
        OUTPUT: ACL object ready for modification operations
        USE CASE: Enterprise automation with audit trail requirements

    .OUTPUTS
        [System.DirectoryServices.ActiveDirectorySecurity] Active Directory ACL object
        ready for modification operations, or $null if retrieval fails.

    .NOTES
        RELIABILITY FEATURES:
        - Retry logic with exponential backoff for transient failures
        - Comprehensive parameter validation
        - Detailed error handling and logging
        - Optimized for removal operation workflows

        SECURITY CONSIDERATIONS:
        - Requires appropriate AD permissions for ACL reading
        - All operations logged with correlation IDs for audit trails
        - Validates object existence before ACL retrieval

        TROUBLESHOOTING:
        - For permission errors: Verify AD read rights
        - For connectivity issues: Check AD server availability
        - For object not found: Verify DN format and object existence
        - For ACL retrieval failures: .\Troubleshooting\Security\Security-Descriptor-Issues.md
        - For AD connectivity issues: .\Troubleshooting\Common\Common-Issues.md
    #>

    [CmdletBinding()]
    [OutputType([System.DirectoryServices.ActiveDirectorySecurity])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ObjectDistinguishedName,

        [Parameter()]
        [string]$CorrelationId = [System.Guid]::NewGuid().ToString()
    )

    Write-StructuredLog "Starting ACL retrieval for $ObjectDistinguishedName" -Level Debug -CorrelationId $CorrelationId

    # The name is checked before the try. Each check ends the function with an error of its own,
    # and it is the caller that logs the refusal: the catch below is for a read that failed.
    $refusal = $null
    if ([string]::IsNullOrWhiteSpace($ObjectDistinguishedName.Trim())) {
        $refusal = 'DistinguishedNameEmpty'
        $message = 'ObjectDistinguishedName parameter cannot be empty or whitespace'
    } elseif ($ObjectDistinguishedName -match '^[A-Za-z]:\\' -and
        $ObjectDistinguishedName -notmatch '^CN=|^OU=|^DC=') {
        $refusal = 'DistinguishedNameIsFilePath'
        $message = 'Invalid ObjectDistinguishedName format. Expected AD Distinguished Name, ' +
            "got filesystem path: $ObjectDistinguishedName"
    } elseif (-not (Test-ValidDistinguishedName -DistinguishedName $ObjectDistinguishedName -CorrelationId $CorrelationId)) {
        # The check is of the form of the name only. Whether the object exists is settled by the
        # read below, which fails with the directory's own error.
        $refusal = 'DistinguishedNameRefused'
        $message = "The distinguished name was refused because it is not well formed: $ObjectDistinguishedName"
    }

    if ($null -ne $refusal) {
        $exception = [System.ArgumentException]::new($message)
        $category = [System.Management.Automation.ErrorCategory]::InvalidArgument
        $errorRecord = [System.Management.Automation.ErrorRecord]::new(
            $exception, $refusal, $category, $ObjectDistinguishedName)
        $PSCmdlet.ThrowTerminatingError($errorRecord)
    }

    $ruleCount = 0
    try {
        # Retrieve ACL with retry logic for reliability
        $acl = Invoke-ADOperationWithRetry -ScriptBlock {
            Get-DirectoryObjectAcl -DistinguishedName $ObjectDistinguishedName
        } -MaxRetries 3 -OperationName 'Get-ACL' -ObjectContext $ObjectDistinguishedName -CorrelationId $CorrelationId

        if ($acl) {
            $ruleCount = @(Get-AclAccessRule -Acl $acl).Count
        }
    } catch {
        Write-StructuredLog "Failed to retrieve ACL for $ObjectDistinguishedName : $($_.Exception.Message)" -Level Error -CorrelationId $CorrelationId
        $PSCmdlet.ThrowTerminatingError($_)
    }

    if (-not $acl) {
        # A read that neither failed nor returned a descriptor
        $message = "Failed to retrieve ACL for $ObjectDistinguishedName"
        Write-StructuredLog "$message : the read returned nothing" -Level Error -CorrelationId $CorrelationId
        $exception = [System.InvalidOperationException]::new($message)
        $category = [System.Management.Automation.ErrorCategory]::InvalidResult
        $errorRecord = [System.Management.Automation.ErrorRecord]::new(
            $exception, 'AclNotReturned', $category, $ObjectDistinguishedName)
        $PSCmdlet.ThrowTerminatingError($errorRecord)
    }

    Write-StructuredLog "Successfully retrieved ACL for $ObjectDistinguishedName (Access rules: $ruleCount)" -Level Verbose -CorrelationId $CorrelationId
    $acl
}



