function Get-ADObjectFromSearchBase {
    <#
    .SYNOPSIS
        Retrieves Active Directory objects from a single search base

    .DESCRIPTION
        Performs AD object retrieval from a specified search base, including each object's
        security descriptor. A transient failure is retried through Invoke-ADOperationWithRetry;
        a failure that persists is thrown. Designed for pipeline efficiency.

    .PARAMETER SearchBase
        The distinguished name of the search base

    .PARAMETER IncludeInherited
        Whether to include inherited permissions in security descriptors

    .PARAMETER Properties
        Additional properties to retrieve (nTSecurityDescriptor always included)

    .PARAMETER MaxRetries
        Retries after the first attempt when the read fails with an error that looks transient
        (0-10, default 3). A read that still fails is thrown to the caller.

    .EXAMPLE
        PS> Get-ADObjectFromSearchBase -SearchBase "OU=Users,DC=contoso,DC=com"

        DESCRIPTION: Retrieves all AD objects from the Users OU
        OUTPUT: Collection of AD objects with security descriptors
        USE CASE: Scanning specific organizational units for security analysis

    .EXAMPLE
        PS> @("OU=Users,DC=contoso,DC=com", "OU=Groups,DC=contoso,DC=com") | Get-ADObjectFromSearchBase

        DESCRIPTION: Pipeline processing of multiple search bases
        OUTPUT: Combined collection from all search bases
        USE CASE: Bulk processing of multiple organizational units

    .NOTES
        Author: Jeffrey Stuhr
        Blog: https://www.techbyjeff.net
        LinkedIn: https://www.linkedin.com/in/jeffrey-stuhr-034214aa/

        TROUBLESHOOTING:
        - For search base issues: .\Troubleshooting\Common\Common-Issues.md
    #>

    [CmdletBinding()]
    [OutputType('Microsoft.ActiveDirectory.Management.ADObject')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'IncludeInherited',
        Justification = 'Accepted for call-site parity; inheritance is filtered when the ACL is examined')]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [ValidateNotNullOrEmpty()]
        [string]$SearchBase,

        [Parameter()]
        [switch]$IncludeInherited,

        [Parameter()]
        [string[]]$Properties = @('nTSecurityDescriptor'),

        [Parameter()]
        [ValidateRange(0, 10)]
        [int]$MaxRetries = 3,

        [Parameter()]
        [string]$CorrelationId = [System.Guid]::NewGuid().ToString()
    )

    process {
        Write-Verbose "Retrieving AD objects from search base: $SearchBase - CorrelationId: $CorrelationId"

        # Ensure nTSecurityDescriptor is always included
        $allProperties = @($Properties) + @('nTSecurityDescriptor') | Sort-Object -Unique

        # A transient failure is retried; one that persists is thrown, so Get-ADObjectsSequential
        # counts the search base as failed, warns, and records it in the security log. Swallowing it
        # here once made an unreadable search base count as a successful one with no objects.
        $objects = Invoke-ADOperationWithRetry -ScriptBlock {
            Get-ADObject -SearchBase $SearchBase -Filter * -Properties $allProperties -ErrorAction Stop
        } -MaxRetries ($MaxRetries + 1) -OperationName 'Get-ADObject-SearchBase' -ObjectContext $SearchBase -CorrelationId $CorrelationId

        # Output to pipeline for efficiency
        if ($objects) {
            foreach ($obj in @($objects)) {
                Write-Output $obj
            }
        }

        Write-Verbose "Retrieved $(@($objects).Count) objects from search base: $SearchBase"
    }
}