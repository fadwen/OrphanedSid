function Set-DirectoryObjectAcl {
    <#
    .SYNOPSIS
    Writes a security descriptor to an Active Directory object named by its distinguished name.

    .DESCRIPTION
    Writes the security descriptor through the AD: drive with Set-Acl, as the module always has,
    unless the distinguished name contains a wildcard character, a backtick or a backslash. The
    -Path parameter of Set-Acl treats [ ] * and ? as a pattern, so for an object named
    'Payroll [EU]' it matches nothing, and for a name with * or ? it can match other objects. A
    backtick escapes the character after it, so a path for an object named 'Pay`*' names the
    object 'Pay*'. Set-Acl -LiteralPath is not a way out: on Windows PowerShell 5.1 the AD: drive
    does not resolve a literal path for any object.

    A backslash is how the directory escapes a comma, + = " < > ; a backslash and a leading # in
    a distinguished name, so a group named 'Doe, Jane' is 'CN=Doe\, Jane'. On Windows PowerShell 5.1
    Set-Acl fails for such a name on the AD: drive with 'The object name has bad syntax'.

    A name with any of these characters is therefore written to the nTSecurityDescriptor attribute
    with Set-ADObject, which takes the distinguished name literally, on both editions. That write
    needs no more than the right to change permissions on the object, as Set-Acl does.

    Set-Acl and Set-ADObject both honour -WhatIf and -Confirm from the calling command, so this
    function adds no confirmation of its own. A failure of either write ends the function with the
    original error.

    .PARAMETER DistinguishedName
    Distinguished name of the object. Leading and trailing whitespace is removed. A value that is
    empty after that is rejected.

    .PARAMETER AclObject
    The security descriptor to write.

    .EXAMPLE
    Set-DirectoryObjectAcl -DistinguishedName 'OU=Finance,DC=contoso,DC=com' -AclObject $acl

    Writes the security descriptor through the AD: drive.

    .EXAMPLE
    Set-DirectoryObjectAcl -DistinguishedName 'OU=Payroll [EU],DC=contoso,DC=com' -AclObject $acl

    Writes the security descriptor to the nTSecurityDescriptor attribute, because the name contains
    square brackets.

    .EXAMPLE
    Set-DirectoryObjectAcl -DistinguishedName 'CN=Doe\, Jane,OU=Staff,DC=contoso,DC=com' -AclObject $acl

    Writes the security descriptor to the nTSecurityDescriptor attribute, because the name contains
    an escaped comma.

    .INPUTS
    None.

    .OUTPUTS
    None.

    .NOTES
    AUTHOR:
    - Author: Jeffrey Stuhr
    - Blog: https://techbyjeff.net
    - LinkedIn: https://www.linkedin.com/in/jeffrey-stuhr-034214aa/
    - Bluesky: https://bsky.app/profile/techbyjeff.net
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Set-Acl and Set-ADObject ask ShouldProcess themselves; a guard here would prompt twice')]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [string]$DistinguishedName,

        [Parameter(Mandatory)]
        [System.Security.AccessControl.ObjectSecurity]$AclObject
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
        # So does a name with a backslash, for which the drive fails on Windows PowerShell 5.1.
        # PowerShell 7 writes it, so only a 5.1 run against a real domain shows the difference.
        $writesAttribute = $objectDN.Contains('`') -or $objectDN.Contains('\') -or
            [System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($objectDN)
        if ($writesAttribute) {
            Set-ADObject -Identity $objectDN -Replace @{ nTSecurityDescriptor = $AclObject } -ErrorAction Stop
        } else {
            Set-Acl -Path "AD:\$objectDN" -AclObject $AclObject -ErrorAction Stop
        }
    } catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }
}
