function ConvertTo-NormalizedDistinguishedName {
    <#
    .SYNOPSIS
    Removes the blanks around the separators of a distinguished name.

    .DESCRIPTION
    Active Directory accepts a distinguished name that is typed with a blank after a comma or
    around an equals sign, such as 'CN=Alice, OU=Sales, DC=contoso, DC=com'. The names that a
    subtree search returns, which is how discovery reads objects, have no such blanks, and those
    are the names that backups record. The restore compares the name it is given with them, so
    it needs one spelling for both.

    The name is split at the commas and at the first equals sign of each component, and the
    blanks on either side of those separators are removed. A separator or a blank that is
    escaped with a backslash is part of the value and is left alone, so 'CN=Doe\, Jane' stays
    one component, and a value that ends in an escaped blank keeps it. Letter case is not
    changed, and neither is anything inside a value.

    Text that is not a distinguished name, because a component has no equals sign or no
    attribute before it, is returned as it was given apart from the blanks at its two ends. It
    is for the caller's own check to refuse.

    .PARAMETER DistinguishedName
    The name to normalize. An empty string is returned as it is.

    .EXAMPLE
    ConvertTo-NormalizedDistinguishedName -DistinguishedName 'CN=Alice, OU=Sales, DC=contoso, DC=com'

    Returns 'CN=Alice,OU=Sales,DC=contoso,DC=com'.

    .EXAMPLE
    ConvertTo-NormalizedDistinguishedName -DistinguishedName 'OU = Domain Controllers,DC=contoso,DC=com'

    Returns 'OU=Domain Controllers,DC=contoso,DC=com'. The blank inside the value stays.

    .EXAMPLE
    ConvertTo-NormalizedDistinguishedName -DistinguishedName 'CN=Doe\, Jane , OU=Staff,DC=contoso,DC=com'

    Returns 'CN=Doe\, Jane,OU=Staff,DC=contoso,DC=com'. The escaped comma is not a separator.

    .INPUTS
    None.

    .OUTPUTS
    System.String. The name with the blanks around its separators removed.

    .NOTES
    KNOWN LIMITATIONS:
    - Two spellings of one escaped character, such as '\,' and '\2C', are not made the same.
    - A value in double quotes is not read as one value.

    AUTHOR:
    - Author: Jeffrey Stuhr
    - Blog: https://techbyjeff.net
    - LinkedIn: https://www.linkedin.com/in/jeffrey-stuhr-034214aa/
    - Bluesky: https://bsky.app/profile/techbyjeff.net
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$DistinguishedName
    )

    # Split at the commas that are not escaped. A backslash escapes the character after it. Only
    # the start of the text is trimmed here: a blank at its end can be an escaped one, which the
    # last value keeps.
    $components = [System.Collections.Generic.List[string]]::new()
    $current = [System.Text.StringBuilder]::new()
    $escaped = $false
    foreach ($character in $DistinguishedName.TrimStart().ToCharArray()) {
        if ($escaped) {
            $null = $current.Append($character)
            $escaped = $false
        } elseif ($character -eq '\') {
            $null = $current.Append($character)
            $escaped = $true
        } elseif ($character -eq ',') {
            $components.Add($current.ToString())
            $null = $current.Clear()
        } else {
            $null = $current.Append($character)
        }
    }
    $components.Add($current.ToString())

    # Set to $false, and the loop left, when a component is not of the form attribute=value. The
    # loop is not left with return: inside this assignment, return writes the components that
    # were already made to the output of the function.
    $isName = $true
    $normalized = foreach ($component in $components) {
        # The first equals sign that is not escaped separates the attribute from the value
        $separatorIndex = -1
        $escaped = $false
        for ($index = 0; $index -lt $component.Length; $index++) {
            if ($escaped) {
                $escaped = $false
            } elseif ($component[$index] -eq '\') {
                $escaped = $true
            } elseif ($component[$index] -eq '=') {
                $separatorIndex = $index
                break
            }
        }

        $attribute = ''
        if ($separatorIndex -gt 0) {
            $attribute = $component.Substring(0, $separatorIndex).Trim()
        }
        if (-not $attribute) {
            $isName = $false
            break
        }

        $value = $component.Substring($separatorIndex + 1).TrimStart()
        # A blank at the end is removed unless a backslash escapes it. The backslash does when
        # the number of backslashes in front of the blank is odd.
        while ($value.Length -gt 0 -and [char]::IsWhiteSpace($value[$value.Length - 1])) {
            $backslashes = 0
            $position = $value.Length - 2
            while ($position -ge 0 -and $value[$position] -eq '\') {
                $backslashes++
                $position--
            }
            if ($backslashes % 2 -eq 1) {
                break
            }
            $value = $value.Substring(0, $value.Length - 1)
        }

        "$attribute=$value"
    }

    if (-not $isName) {
        # Not a distinguished name: left for the caller to refuse
        return $DistinguishedName.Trim()
    }

    @($normalized) -join ','
}
