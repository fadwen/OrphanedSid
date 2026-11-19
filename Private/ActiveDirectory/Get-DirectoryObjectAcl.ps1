function Get-DirectoryObjectAcl {
    <#
    .SYNOPSIS
    Gets the security descriptor of an Active Directory object by its distinguished name.

    .DESCRIPTION
    Reads the security descriptor through the AD: drive with Get-Acl, as the module always has,
    unless the distinguished name contains a wildcard character, a backtick or a backslash. The
    -Path parameter of Get-Acl treats [ ] * and ? as a pattern, so for an object named
    'Payroll [EU]' it returns nothing and raises no error, and for a name with * or ? it can return
    the descriptors of other objects. A backtick escapes the character after it, so for an object
    named 'Pay`*' it returns the descriptor of the object named 'Pay*'. Get-Acl -LiteralPath is not
    a way out: on Windows PowerShell 5.1 it fails on the AD: drive for every object.

    A backslash is how the directory escapes a comma, + = " < > ; a backslash and a leading # in
    a distinguished name, so a group named 'Doe, Jane' is 'CN=Doe\, Jane'. On Windows PowerShell 5.1
    the AD: drive does not read such a name: Get-Acl fails with 'The object name has bad syntax',
    or returns nothing. PowerShell 7 reads it.

    A name with any of these characters is therefore read from the nTSecurityDescriptor attribute
    with Get-ADObject, which takes the distinguished name literally, on both editions.

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

    .EXAMPLE
    Get-DirectoryObjectAcl -DistinguishedName 'CN=Doe\, Jane,OU=Staff,DC=contoso,DC=com'

    Reads the security descriptor from the nTSecurityDescriptor attribute, because the name contains
    an escaped comma.

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
        # A backtick is no wildcard character to ContainsWildcardCharacters(), which reads it as an
        # escape. The -Path parameter reads it the same way and drops it: for 'Pay`*' the drive hands
        # back the object named 'Pay*'. Such a name takes the literal route as well.
        # So does a name with a backslash, which the drive does not read on Windows PowerShell 5.1.
        # PowerShell 7 reads it, so only a 5.1 run against a real domain shows the difference.
        $readsAttribute = $objectDN.Contains('`') -or $objectDN.Contains('\') -or
            [System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($objectDN)
        if ($readsAttribute) {
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
