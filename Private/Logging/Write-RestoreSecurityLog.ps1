#Requires -Version 5.1

function Write-RestoreSecurityLog {
    <#
    .SYNOPSIS
    Writes a security log entry for the restore of the ACL of one object.

    .DESCRIPTION
    A restore replaces the security descriptor of an object with the one in a backup file. This
    function writes the security entry for one step of that: the attempt, the success, or the
    failure. It adds the object, the backup file and whether the run is a -WhatIf preview to
    the entry, and hands it to Write-SecurityLog, which writes it to the log file whatever the
    log level is.

    An entry that cannot be written does not end the restore. The function writes a warning
    and returns: the result of the restore says what happened to the object, and that does not
    depend on the log.

    .PARAMETER Outcome
    [string] (Mandatory: Yes, Pipeline: No)

    Attempt before the ACL is written, Success after it was written, Failure for a restore
    that did not write it or whose write failed.

    .PARAMETER Message
    [string] (Mandatory: Yes, Pipeline: No)

    The text of the entry.

    .PARAMETER TargetObjectDN
    [string] (Mandatory: Yes, Pipeline: No)

    Distinguished name of the object whose ACL is restored. For a backup file that could not
    be read, the caller passes what it knows of the object.

    .PARAMETER BackupFile
    [string] (Mandatory: Yes, Pipeline: No)

    Path of the backup file that the ACL is taken from.

    .PARAMETER CorrelationId
    [string] (Mandatory: No, Pipeline: No)

    The correlation ID of the run. When it is empty, Write-SecurityLog gives the entry an ID
    of its own.

    .PARAMETER Detail
    [hashtable] (Mandatory: No, Pipeline: No)

    Further values for the entry, such as the number of entries restored or the reason of a
    failure. A key given here replaces a key of the same name that the function sets.

    .EXAMPLE
    Write-RestoreSecurityLog -Outcome Attempt -Message 'Restore started' -TargetObjectDN $dn -BackupFile $file

    DESCRIPTION: Writes the entry for the attempt, before the ACL is written.
    OUTPUT: None. The log file has one more security entry.
    USE CASE: The step of a restore that is about to write to the directory.

    .EXAMPLE
    $entry = @{ TargetObjectDN = $dn; BackupFile = $file; CorrelationId = $id }
    Write-RestoreSecurityLog @entry -Outcome Success -Message 'Restore completed' -Detail @{ EntriesRestored = 12 }

    DESCRIPTION: Writes the entry for a restore that was applied, with the number of entries.
    OUTPUT: None. The log file has one more security entry.
    USE CASE: The step of a restore after the write.

    .EXAMPLE
    $entry = @{ TargetObjectDN = $dn; BackupFile = $file; CorrelationId = $id }
    Write-RestoreSecurityLog @entry -Outcome Failure -Message 'Restore failed' -Detail @{ Error = $reason }

    DESCRIPTION: Writes the entry for a restore that was not applied, with the reason.
    OUTPUT: None. The log file has one more security entry, at the Warning level.
    USE CASE: A backup that failed its integrity check, or a write that the directory refused.

    .INPUTS
    None.

    .OUTPUTS
    None.

    .NOTES
    TROUBLESHOOTING:
    - For security logging issues: .\Troubleshooting\Security\Security-Logging-Issues.md
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Attempt', 'Success', 'Failure')]
        [string]$Outcome,

        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter(Mandatory)]
        [string]$TargetObjectDN,

        [Parameter(Mandatory)]
        [string]$BackupFile,

        [Parameter()]
        [string]$CorrelationId,

        [Parameter()]
        [hashtable]$Detail = @{}
    )

    # The preference is the caller's: under -WhatIf the restore validates and previews, and an
    # entry of such a run says so, so that a reader does not take it for a change.
    $securityContext = @{
        Operation = 'RestoreACL'
        TargetObjectDN = $TargetObjectDN
        BackupFile = $BackupFile
        WhatIfMode = [bool]$WhatIfPreference
    }
    foreach ($key in $Detail.Keys) {
        $securityContext[$key] = $Detail[$key]
    }

    $logParameters = @{
        SecurityEventType = 'PrivilegeUse'
        Message = $Message
        Outcome = $Outcome
        SecurityContext = $securityContext
        ErrorAction = 'Stop'
    }
    # An empty ID would be written as it is; without one, Write-SecurityLog makes one
    if (-not [string]::IsNullOrWhiteSpace($CorrelationId)) {
        $logParameters['CorrelationId'] = $CorrelationId
    }

    try {
        Write-SecurityLog @logParameters
    } catch {
        # The restore has a result of its own, which says what happened to the object. An entry
        # that cannot be written must not turn a restore that was applied into a failed one.
        $reason = $_.Exception.Message
        Write-Warning "The security log entry for the restore of '$TargetObjectDN' could not be written: $reason"
    }
}
