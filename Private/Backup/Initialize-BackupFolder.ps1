function Initialize-BackupFolder {
    <#
    .SYNOPSIS
    Creates the folder that backups are written to and confirms that it exists.

    .DESCRIPTION
    A removal writes a backup of every access control list before it changes one, so a backup
    folder that cannot be made is a reason to stop, and the operator has to be told why.
    New-Item does not say by itself: for a parent that denies new folders it only writes its
    error, and for a path of which one part is a file it returns nothing and reports no error at
    all. The folder is therefore created with -ErrorAction Stop and looked for afterwards.

    A folder that is already there is left as it is. A folder that is not there after the
    attempt ends the function with the terminating error BackupFolderNotCreated. Its message
    names the folder and the reason, and its exception holds the error of New-Item, when there
    was one, as its inner exception.

    Under -WhatIf nothing is created and no error is raised.

    .PARAMETER Path
    Path of the backup folder to create.

    .EXAMPLE
    Initialize-BackupFolder -Path 'C:\Backups\20260101_120000'

    Creates the folder and returns True. Returns False when the folder was already there.

    .EXAMPLE
    if (Initialize-BackupFolder -Path $backupPath) { Write-Verbose "Created $backupPath" }

    Reports the folder only when this call created it.

    .INPUTS
    None.

    .OUTPUTS
    System.Boolean. True when the function created the folder. False when the folder was already
    there, and when the creation was not confirmed.

    .NOTES
    AUTHOR:
    - Author: Jeffrey Stuhr
    - Blog: https://techbyjeff.net
    - LinkedIn: https://www.linkedin.com/in/jeffrey-stuhr-034214aa/
    - Bluesky: https://bsky.app/profile/techbyjeff.net
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path -PathType Container) {
        return $false
    }

    if (-not $PSCmdlet.ShouldProcess($Path, 'Create backup folder')) {
        return $false
    }

    # What New-Item raised, when it raised anything. It is reported after the try, with the folder
    # that is missing, so that both ways of failing give the same error ID.
    $cause = $null
    try {
        # -Confirm:$false, because the question was asked on the line above
        $null = New-Item -Path $Path -ItemType Directory -Force -Confirm:$false -ErrorAction Stop
    } catch {
        $cause = $_.Exception
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        if ($null -ne $cause) {
            $message = "The backup folder '$Path' could not be created: $($cause.Message)"
            $exception = [System.IO.IOException]::new($message, $cause)
        } else {
            $message = "The backup folder '$Path' could not be created: the folder does not exist " +
                'after it was created without an error. A part of the path may be a file.'
            $exception = [System.IO.IOException]::new($message)
        }
        $category = [System.Management.Automation.ErrorCategory]::WriteError
        $errorRecord = [System.Management.Automation.ErrorRecord]::new(
            $exception, 'BackupFolderNotCreated', $category, $Path)
        $PSCmdlet.ThrowTerminatingError($errorRecord)
    }

    # False when New-Item raised an error and the folder is there all the same: it was made by
    # something else in the meantime
    $null -eq $cause
}
