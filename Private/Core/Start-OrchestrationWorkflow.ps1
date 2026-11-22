#Requires -Version 5.1

function Start-OrchestrationWorkflow {
    <#
    .SYNOPSIS
        Starts the restore workflow for Restore-OrphanedSidBackup

    .DESCRIPTION
        Maps the parameters of a restore to those of Invoke-RestoreWorkflow, asks it to verify
        each ACL after it is written, and calls it. The function writes a log line when it
        starts and one when it ends, and logs a failure of the workflow before it passes the
        error on.

        A discovery or a removal does not come through here: Find-OrphanedSid and
        Remove-OrphanedSid call Invoke-MainProcessingLogic themselves.

    .PARAMETER Parameters
        [Hashtable] (Mandatory) The parameters of the restore, by name. TargetObjectDN,
        BackupPath, BackupFile and CorrelationId are passed on, and WhatIf when it is true.
        Other keys are left out. A table without CorrelationId gets the one of -CorrelationId.

    .PARAMETER CorrelationId
        [String] (Optional) Correlation ID of the log lines of this function, and of the
        restore when the parameters hold none. One is generated when none is given.

    .INPUTS
        None.

    .OUTPUTS
        [Object] What Invoke-RestoreWorkflow returns.

    .EXAMPLE
        PS> Start-OrchestrationWorkflow -Parameters @{ TargetObjectDN = 'CN=User1,CN=Users,DC=contoso,DC=com'; BackupPath = 'C:\Backups' }

        DESCRIPTION: Start the restore of one object from a folder of backups
        OUTPUT: Restore operation results
        USE CASE: ACL restoration from backup files

    .NOTES
        Author: Jeffrey Stuhr
        Blog: https://www.techbyjeff.net
        LinkedIn: https://www.linkedin.com/in/jeffrey-stuhr-034214aa/

        TROUBLESHOOTING:
        - For orchestration issues: .\Troubleshooting\Common\SID-Processing-Orchestration-Issues.md
        - For workflow coordination: .\Troubleshooting\Common\Common-Issues.md
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Calls the restore workflow, which gates its own writes with ShouldProcess')]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Parameters,

        [Parameter()]
        [string]$CorrelationId = [System.Guid]::NewGuid().ToString()
    )

    begin {
        Write-StructuredLog 'Starting orchestration workflow: Restore' -Level Information -Component 'Orchestration' -CorrelationId $CorrelationId

        # Ensure CorrelationId is propagated to all operations
        if (-not $Parameters.ContainsKey('CorrelationId')) {
            $Parameters.CorrelationId = $CorrelationId
        }
    }

    process {
        try {
            Write-StructuredLog "Coordinating restore workflow" -Level Debug -Component 'Orchestration' -CorrelationId $CorrelationId

            # Map parameters from main script format to restore workflow format
            $restoreParams = @{}

            # Map TargetObjectDN (individual object for restore)
            if ($Parameters.ContainsKey('TargetObjectDN')) {
                $restoreParams.TargetObjectDN = $Parameters.TargetObjectDN
            }

            # Map BackupPath
            if ($Parameters.ContainsKey('BackupPath')) {
                $restoreParams.BackupPath = $Parameters.BackupPath
            }

            # Map BackupFile: one backup file by name, in place of the folder
            if ($Parameters.ContainsKey('BackupFile')) {
                $restoreParams.BackupFile = $Parameters.BackupFile
            }

            # Map CorrelationId
            if ($Parameters.ContainsKey('CorrelationId')) {
                $restoreParams.CorrelationId = $Parameters.CorrelationId
            }

            # Map WhatIf parameter
            if ($Parameters.ContainsKey('WhatIf') -and $Parameters.WhatIf) {
                $restoreParams.WhatIf = $true
            }

            # Verify the applied ACL against the backup after restoration. Without this the
            # restore workflow reports success on the write alone and never compares entries.
            $restoreParams.VerifyRestoration = $true

            return Invoke-RestoreWorkflow @restoreParams
        }
        catch {
            Write-StructuredLog "Orchestration workflow failed for Restore : $($_.Exception.Message)" -Level Error -Component 'Orchestration' -CorrelationId $CorrelationId
            $PSCmdlet.ThrowTerminatingError($_)
        }
        finally {
            Write-StructuredLog 'Orchestration workflow completed: Restore' -Level Information -Component 'Orchestration' -CorrelationId $CorrelationId
        }
    }
}
