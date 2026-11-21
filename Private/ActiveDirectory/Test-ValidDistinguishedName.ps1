#Requires -Version 5.1

function Test-ValidDistinguishedName {
    <#
    .SYNOPSIS
    Tests whether a string has the form of an Active Directory distinguished name.

    .DESCRIPTION
    Checks the form of the name and nothing else. The name is not empty, is at most 1024 characters
    long and holds no control character. Every component is the name of an attribute, an equals
    sign and a value, and at least one component is DC=. A comma that is escaped with a backslash,
    or that sits inside a quoted value, does not end a component.

    The attribute that names an object is set by the class of the object in the schema. CN, OU and
    DC are the common ones; a locality is L= and an organization is O=. The function therefore
    takes any attribute name, and a dotted number, and does not hold a list of them.

    The function does not look the object up, and it does not refuse a character because a shell,
    a browser or a database gives it a meaning. A distinguished name is passed to the Active
    Directory cmdlets as one argument, so an ampersand, a semicolon, a pipe, a backtick, two
    hyphens, a percent sign and a run of dots are ordinary characters in it: an organizational unit
    named 'R&D' has the distinguished name 'OU=R&D,...'. Refusing such a name would leave an object
    that Find-OrphanedSid reports and Remove-OrphanedSid can never clean.

    Each refusal is written to the log with its reason: at Warning for a name that is too long or
    holds a control character, and at Debug for the others.

    .PARAMETER DistinguishedName
    The string to test. An empty or missing value gives $false.

    .PARAMETER CorrelationId
    Correlation ID for the log entries. A new GUID is used when none is given.

    .EXAMPLE
    Test-ValidDistinguishedName -DistinguishedName 'OU=Users,DC=contoso,DC=com'

    Returns $true.

    .EXAMPLE
    Test-ValidDistinguishedName -DistinguishedName 'OU=R&D,DC=contoso,DC=com'

    Returns $true. The ampersand is an ordinary character in a distinguished name.

    .EXAMPLE
    Test-ValidDistinguishedName -DistinguishedName 'O=Acme,L=Springfield,DC=contoso,DC=com'

    Returns $true. An organization and a locality are named by the attributes O and L.

    .EXAMPLE
    'CN=User1,DC=contoso,DC=com', 'OU=Sales' | Test-ValidDistinguishedName

    Returns $true and then $false. The second name has no DC= component.

    .INPUTS
    System.String. You can pipe names to this function.

    .OUTPUTS
    System.Boolean. $true when the string has the form of a distinguished name.

    .NOTES
    TROUBLESHOOTING:
    - For DN validation issues: .\Troubleshooting\Security\Security-Validation-Guide.md
    - For AD object access: .\Troubleshooting\Common\Common-Issues.md

    AUTHOR:
    - Author: Jeffrey Stuhr
    - Blog: https://techbyjeff.net
    - LinkedIn: https://www.linkedin.com/in/jeffrey-stuhr-034214aa/
    - Bluesky: https://bsky.app/profile/techbyjeff.net
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(ValueFromPipeline)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$DistinguishedName,

        [Parameter()]
        [string]$CorrelationId = [System.Guid]::NewGuid().ToString()
    )

    process {
        try {
            # Handle null or empty strings
            if ([string]::IsNullOrWhiteSpace($DistinguishedName)) {
                Write-StructuredLog "Distinguished Name validation failed: Empty or null value" -Level Debug -Component 'DNValidator' -CorrelationId $CorrelationId
                return $false
            }

            # Length validation (LDAP DN maximum length)
            if ($DistinguishedName.Length -gt 1024) {
                Write-StructuredLog "Distinguished Name validation failed: Length exceeds 1024 characters ($($DistinguishedName.Length))" -Level Warning -Component 'DNValidator' -CorrelationId $CorrelationId
                return $false
            }

            # The name starts with an attribute and an equals sign. Which attribute names an object
            # is set by its class, so none is refused here. That a DC= component is present is
            # checked below, component by component. A comma before it is not required: the root
            # of a domain with a single label, such as DC=corp, has none.
            #
            # The directory takes three spellings of an attribute: its name (OU), its dotted number
            # (2.5.4.11) and that number after "OID." (OID.2.5.4.11). The dot inside a name is there
            # for the third, so the pattern is wider than the LDAP grammar on purpose.
            # Invoke-RestoreWorkflow, Get-RestorationTarget and Test-BackupIntegrity hold the same
            # pattern, and the contract tests fail when one of the four differs.
            $attributeName ='([a-z][a-z0-9.-]*|\d+(\.\d+)+)'
            if (-not ($DistinguishedName -match "^$attributeName\s*=.+$")) {
                Write-StructuredLog "Distinguished Name validation failed: Invalid format structure" -Level Debug -Component 'DNValidator' -CorrelationId $CorrelationId
                return $false
            }

            # The directory writes a control character in a name as an escape, such as \0A, so a
            # raw one is not part of a name that the directory returned. No other character is
            # refused: a distinguished name reaches the Active Directory cmdlets as one argument,
            # and names such as 'R&D' exist.
            if ($DistinguishedName -match '[\x00-\x1f\x7f-\x9f]') {
                Write-StructuredLog "Distinguished Name validation failed: Contains control characters" -Level Warning -Component 'DNValidator' -CorrelationId $CorrelationId
                return $false
            }

            # Validate DN components structure - handle escaped commas and quoted values properly
            # Split on commas that are not escaped (not preceded by backslash) and not inside quotes
            $components = @()
            $current = ""
            $chars = $DistinguishedName.ToCharArray()
            $inQuotes = $false
            
            for ($i = 0; $i -lt $chars.Length; $i++) {
                $char = $chars[$i]
                
                if ($char -eq '"' -and ($i -eq 0 -or $chars[$i-1] -ne '\')) {
                    # Toggle quote state for unescaped quotes
                    $inQuotes = -not $inQuotes
                    $current += $char
                } elseif ($char -eq ',' -and -not $inQuotes -and ($i -eq 0 -or $chars[$i-1] -ne '\')) {
                    # Found unescaped comma outside quotes - component boundary
                    $components += $current.Trim()
                    $current = ""
                } else {
                    $current += $char
                }
            }
            # Add the last component
            if ($current) {
                $components += $current.Trim()
            }
            foreach ($component in $components) {
                $component = $component.Trim()

                # Each component must have format: TYPE=VALUE (case-insensitive)
                # Handle quoted values and escaped characters - ensure single equals sign
                if (-not ($component -match "^$attributeName\s*=[^=].*$")) {
                    Write-StructuredLog "Distinguished Name validation failed: Invalid component format: $component" -Level Debug -Component 'DNValidator' -CorrelationId $CorrelationId
                    return $false
                }

                # Component value cannot be empty after the equals sign
                # Handle spaces around equals sign and quoted values
                # Split on equals that is not escaped (not preceded by backslash)
                $equalsIndex = -1
                for ($j = 0; $j -lt $component.Length; $j++) {
                    if ($component[$j] -eq '=' -and ($j -eq 0 -or $component[$j-1] -ne '\')) {
                        $equalsIndex = $j
                        break
                    }
                }
                
                if ($equalsIndex -eq -1) {
                    Write-StructuredLog "Distinguished Name validation failed: No unescaped equals found in component: $component" -Level Debug -Component 'DNValidator' -CorrelationId $CorrelationId
                    return $false
                }
                
                $value = $component.Substring($equalsIndex + 1).Trim()
                
                # Handle quoted values - remove quotes for validation
                if ($value.StartsWith('"') -and $value.EndsWith('"') -and $value.Length -gt 1) {
                    $value = $value.Substring(1, $value.Length - 2)
                }
                
                # Value cannot be empty
                if ([string]::IsNullOrWhiteSpace($value)) {
                    Write-StructuredLog "Distinguished Name validation failed: Empty component value: $component" -Level Debug -Component 'DNValidator' -CorrelationId $CorrelationId
                    return $false
                }
            }

            # Must contain at least one DC component (case-insensitive)
            $domainComponents = @($components | Where-Object { $_ -match '(?i)^DC\s*=' })
            if ($domainComponents.Count -eq 0) {
                Write-StructuredLog "Distinguished Name validation failed: No domain components (DC=) found" -Level Debug -Component 'DNValidator' -CorrelationId $CorrelationId
                return $false
            }

            Write-StructuredLog "Distinguished Name validation successful: $DistinguishedName" -Level Debug -Component 'DNValidator' -CorrelationId $CorrelationId
            return $true
        }
        catch {
            Write-StructuredLog "Distinguished Name validation error: $($_.Exception.Message)" -Level Warning -Component 'DNValidator' -CorrelationId $CorrelationId
            return $false
        }
    }
}
