function Get-AclAccessRule {
    <#
    .SYNOPSIS
    Gets the access rules of a security descriptor, with each trustee as a SID.

    .DESCRIPTION
    Reads the rules of a directory security descriptor with its GetAccessRules() method, explicit
    and inherited, with every trustee as a SecurityIdentifier.

    The Access property is not used for such an object. It is not part of the .NET type:
    PowerShell adds it from type data, and on PowerShell 7 that type data belongs to the
    Microsoft.PowerShell.Security module. A runspace that a host application creates with
    [powershell]::Create() has the module's commands without the type data, so there the property
    does not exist, and code that read it saw a security descriptor with no rules. The property
    also translates every SID to an account name, which is a directory lookup for each rule.

    An object that is not a directory security descriptor is read through its Access property,
    when it has one. An object with neither ends the function with an error: a descriptor whose
    rules cannot be read is not an empty one.

    .PARAMETER Acl
    The security descriptor, as Get-Acl or the nTSecurityDescriptor attribute returns it.

    .EXAMPLE
    Get-AclAccessRule -Acl (Get-DirectoryObjectAcl -DistinguishedName 'OU=Finance,DC=contoso,DC=com')

    Gets every access rule of the OU, explicit and inherited.

    .EXAMPLE
    @(Get-AclAccessRule -Acl $acl | Where-Object { -not $_.IsInherited }).Count

    Counts the explicit rules of a security descriptor.

    .INPUTS
    None.

    .OUTPUTS
    System.Security.AccessControl.AuthorizationRule. One object for each access rule.

    .NOTES
    AUTHOR:
    - Author: Jeffrey Stuhr
    - Blog: https://techbyjeff.net
    - LinkedIn: https://www.linkedin.com/in/jeffrey-stuhr-034214aa/
    - Bluesky: https://bsky.app/profile/techbyjeff.net
    #>
    [CmdletBinding()]
    [OutputType([System.Security.AccessControl.AuthorizationRule])]
    param(
        [Parameter(Mandatory)]
        [object]$Acl
    )

    if ($Acl -is [System.Security.AccessControl.DirectoryObjectSecurity]) {
        try {
            $rules = $Acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])
        } catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }

        return $rules
    }

    $accessProperty = $Acl.PSObject.Properties['Access']
    if ($null -eq $accessProperty) {
        $message = "The access rules of the security descriptor cannot be read: a $($Acl.GetType().FullName) " +
            'is not a directory security descriptor and has no Access property.'
        $exception = [System.ArgumentException]::new($message)
        $category = [System.Management.Automation.ErrorCategory]::InvalidArgument
        $errorRecord = [System.Management.Automation.ErrorRecord]::new(
            $exception, 'AclAccessRulesUnavailable', $category, $null)
        $PSCmdlet.ThrowTerminatingError($errorRecord)
    }

    $accessProperty.Value
}
