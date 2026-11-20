#Requires -Version 5.1

class RemovalOperationResult {
    [string]$ObjectDN
    # Number of SIDs the operation set out to remove, as ActualRemovals and FailedRemovals count them
    [int]$IntendedRemovals
    [int]$ActualRemovals
    [int]$FailedRemovals
    [string[]]$RemovedSIDs
    [string[]]$FailedSIDs
    [string[]]$BlockedSIDs
    # SIDs that discovery reported and that held no explicit entry on the object when the removal
    # read it, for example because someone else removed the entry in the meantime. They are not
    # in FailedSIDs: nothing was attempted for them.
    [string[]]$NotFoundSIDs
    [bool]$Success
    [string]$ErrorMessage
    [System.TimeSpan]$ProcessingTime
    [string]$CorrelationId
    [object]$SecurityValidation
    # Full path of the backup written before the change; empty when none was written
    [string]$BackupFile

    RemovalOperationResult() {
        $this.IntendedRemovals = 0
        $this.ActualRemovals = 0
        $this.FailedRemovals = 0
        $this.RemovedSIDs = @()
        $this.FailedSIDs = @()
        $this.BlockedSIDs = @()
        $this.NotFoundSIDs = @()
        $this.Success = $false
        $this.ErrorMessage = $null
        $this.ProcessingTime = [System.TimeSpan]::Zero
        $this.CorrelationId = [System.Guid]::NewGuid().ToString()
        $this.SecurityValidation = $null
        $this.BackupFile = $null
    }
}