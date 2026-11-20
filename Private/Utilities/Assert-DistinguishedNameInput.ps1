function Assert-DistinguishedNameInput {
    <#
    .SYNOPSIS
    Ends a public command whose input held no usable distinguished name.

    .DESCRIPTION
    The public commands collect the distinguished names of their input in the process block, with
    ConvertTo-DistinguishedName, and act on them in the end block. Input that was given and held
    no usable name is a mistake to report: for a search base it must never widen a run to the
    whole domain, and for a restore there is nothing to restore.

    The check is a function of its own because of where its error has to go. The end block of a
    public command does its work in a try, and the catch of that try is what ends the calling
    script. An error raised in that try with $PSCmdlet.ThrowTerminatingError() leaves the command
    without entering the catch, so the calling script would carry on. An error that this function
    raises does enter it.

    The function returns nothing when at least one name is given.

    .PARAMETER DistinguishedName
    The names that the command collected from its input. The collection can be empty.

    .PARAMETER InputKind
    What the names are for. SearchBase is the -SearchBase of Find-OrphanedSid and
    Remove-OrphanedSid, and RestoreTarget is the -TargetObjectDN of Restore-OrphanedSidBackup. It
    selects the message and the error ID.

    .EXAMPLE
    Assert-DistinguishedNameInput -DistinguishedName $searchBases -InputKind SearchBase

    Returns nothing when $searchBases holds a name, and ends with the error SearchBaseNotUsable
    when it is empty.

    .EXAMPLE
    Assert-DistinguishedNameInput -DistinguishedName @() -InputKind RestoreTarget

    Ends with the error RestoreTargetNotUsable.

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
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$DistinguishedName,

        [Parameter(Mandatory)]
        [ValidateSet('SearchBase', 'RestoreTarget')]
        [string]$InputKind
    )

    if ($DistinguishedName.Count -gt 0) {
        return
    }

    if ($InputKind -eq 'SearchBase') {
        $errorId = 'SearchBaseNotUsable'
        $message = 'No usable search base in the input. Pass distinguished names, or objects with a ' +
            'DistinguishedName property; the domain root is used only when -SearchBase is not given at all.'
    } else {
        $errorId = 'RestoreTargetNotUsable'
        $message = 'No usable restore target in the input. Pass distinguished names, or objects with a ' +
            'DistinguishedName property.'
    }

    $exception = [System.ArgumentException]::new($message)
    $category = [System.Management.Automation.ErrorCategory]::InvalidArgument
    $errorRecord = [System.Management.Automation.ErrorRecord]::new($exception, $errorId, $category, $null)
    $PSCmdlet.ThrowTerminatingError($errorRecord)
}
