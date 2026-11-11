function ConvertTo-DistinguishedName {
    <#
    .SYNOPSIS
        Turns whatever a command received as a distinguished name into DN strings.

    .DESCRIPTION
        The public commands take their search base or restore target from the command line or the
        pipeline, and an operator pipes whatever they have: DN strings, objects from
        Get-ADOrganizationalUnit or Get-ADObject, rows from Import-Csv, or hashtables.

        Binding those to a [string[]] parameter by property name does not work for Active Directory
        objects. PowerShell asks for the parameter's own name before its DistinguishedName alias,
        and the AD module's adapter answers any property name with an empty collection, so the
        parameter bound as empty and the command fell back to the domain root. The parameters are
        therefore [object[]], and this function reads each item:

        - A string is trimmed and used as the DN.
        - An object or dictionary with a DistinguishedName property or key contributes its value.
        - Blank values are dropped.
        - Anything else is reported with a non-terminating error naming its type, and skipped.

    .PARAMETER InputObject
        The items bound to the command's DN parameter, as one array or one item at a time.

    .OUTPUTS
        [string] One trimmed distinguished name per usable item.

    .EXAMPLE
        PS> Get-ADOrganizationalUnit -Filter * -SearchScope OneLevel | ForEach-Object { ConvertTo-DistinguishedName -InputObject $_ }

        DESCRIPTION: Reads the DN of each AD object
        OUTPUT: 'OU=Servers,DC=contoso,DC=com', ...
        USE CASE: Normalising a command's -SearchBase input in its process block

    .EXAMPLE
        PS> ConvertTo-DistinguishedName -InputObject ' OU=A,DC=contoso,DC=com ', '', [pscustomobject]@{ DistinguishedName = 'OU=B,DC=contoso,DC=com' }

        DESCRIPTION: Mixed input from the command line and from an Import-Csv row
        OUTPUT: 'OU=A,DC=contoso,DC=com', 'OU=B,DC=contoso,DC=com'

    .NOTES
        Author: Jeffrey Stuhr
        Blog: https://www.techbyjeff.net
        LinkedIn: https://www.linkedin.com/in/jeffrey-stuhr-034214aa/
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$InputObject
    )

    foreach ($item in $InputObject) {
        if ($null -eq $item) {
            continue
        }

        $value = $null
        if ($item -is [string]) {
            $value = $item
        } elseif ($item -is [System.Collections.IDictionary]) {
            if ($item.Contains('DistinguishedName')) {
                $value = $item['DistinguishedName']
            }
        } else {
            $property = $item.PSObject.Properties['DistinguishedName']
            if ($property) {
                $value = $property.Value
            }
        }

        # An AD object can hand back its value wrapped in a one-element collection
        if ($null -ne $value -and $value -isnot [string] -and $value -is [System.Collections.IEnumerable]) {
            $value = @($value | Where-Object { $_ }) | Select-Object -First 1
        }

        if ($null -eq $value) {
            $typeName = $item.GetType().FullName
            $message = "Cannot use an object of type $typeName as a distinguished name: it is not a string and has no DistinguishedName property"
            Write-Error -Message $message -TargetObject $item -Category InvalidArgument -ErrorId 'NotADistinguishedName'
            continue
        }

        $dn = ([string]$value).Trim()
        if ($dn) {
            $dn
        }
    }
}
