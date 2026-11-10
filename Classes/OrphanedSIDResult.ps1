#Requires -Version 5.1

class OrphanedSIDResult {
    [string]$ObjectDN
    [string]$ObjectClass
    [string]$OrphanedSID
    [string]$LikelySource
    [string]$Confidence
    [string]$AnalysisNotes
    [System.Security.AccessControl.AccessControlType]$AccessControlType
    [System.DirectoryServices.ActiveDirectoryRights]$ActiveDirectoryRights
    [System.Security.AccessControl.InheritanceFlags]$InheritanceType
    [System.Guid]$ObjectType
    [System.Guid]$InheritedObjectType
    [bool]$IsInherited
    [string]$ProcessingMethod
    [string]$ActionTaken
    # Orphaned: every lookup completed and none found the SID. Unverified: a lookup failed, so the
    # SID may belong to a live principal; reported for re-checking and never removed.
    [string]$VerificationStatus
    # For Unverified, the lookup failures that prevented a verdict
    [string]$VerificationError
    [string]$CorrelationId
    [DateTime]$Timestamp

    OrphanedSIDResult() {
        $this.VerificationStatus = 'Orphaned'
        $this.Timestamp = Get-Date
        $this.CorrelationId = [System.Guid]::NewGuid().ToString()
    }
}
