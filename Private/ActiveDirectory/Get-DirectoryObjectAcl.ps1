function Get-DirectoryObjectAcl {
    <#
    .SYNOPSIS
    Gets the security descriptor of an Active Directory object by its distinguished name.

    .DESCRIPTION
    Reads the security descriptor through the AD: drive with Get-Acl, as the module always has,
    unless the distinguished name contains a wildcard character. The -Path parameter of Get-Acl
    treats [ ] * and ? as a pattern, so for an object named 'Payroll [EU]' it returns nothing and
    raises no error, and for a name with * or ? it can return the descriptors of other objects.
    Get-Acl -LiteralPath is not a way out: on Windows PowerShell 5.1 it fails on the AD: drive for
    every object. A name with a wildcard character is therefore read from the nTSecurityDescriptor
    attribute with Get-ADObject, which takes the distinguished name literally.

    A failure of either read ends the function with the original error.

    .PARAMETER DistinguishedName
    Distinguished name of the object. Leading and trailing whitespace is removed. A value that is
    empty after that is rejected.

    .EXAMPLE
    Get-DirectoryObjectAcl -DistinguishedName 'OU=Finance,DC=contoso,DC=com'

    Reads the security descriptor through the AD: drive.

    .EXAMPLE
    Get-DirectoryObjectAcl -DistinguishedName 'OU=Payroll [EU],DC=contoso,DC=com'

    Reads the security descriptor from the nTSecurityDescriptor attribute, because the name contains
    square brackets.

    .INPUTS
    None.

    .OUTPUTS
    System.DirectoryServices.ActiveDirectorySecurity. The security descriptor of the object.

    .NOTES
    AUTHOR:
    - Author: Jeffrey Stuhr
    - Blog: https://techbyjeff.net
    - LinkedIn: https://www.linkedin.com/in/jeffrey-stuhr-034214aa/
    - Bluesky: https://bsky.app/profile/techbyjeff.net
    #>
    [CmdletBinding()]
    [OutputType([System.DirectoryServices.ActiveDirectorySecurity])]
    param(
        [Parameter(Mandatory)]
        [string]$DistinguishedName
    )

    $objectDN = $DistinguishedName.Trim()
    if (-not $objectDN) {
        $exception = [System.ArgumentException]::new('DistinguishedName cannot be empty or whitespace.')
        $category = [System.Management.Automation.ErrorCategory]::InvalidArgument
        $errorRecord = [System.Management.Automation.ErrorRecord]::new(
            $exception, 'DistinguishedNameEmpty', $category, $DistinguishedName)
        $PSCmdlet.ThrowTerminatingError($errorRecord)
    }

    try {
        if ([System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($objectDN)) {
            $adObject = Get-ADObject -Identity $objectDN -Properties nTSecurityDescriptor -ErrorAction Stop
            $acl = $adObject.nTSecurityDescriptor
        } else {
            $acl = Get-Acl -Path "AD:\$objectDN" -ErrorAction Stop
        }
    } catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }

    $acl
}
