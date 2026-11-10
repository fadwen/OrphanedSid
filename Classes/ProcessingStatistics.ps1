#Requires -Version 5.1

class ProcessingStatistics {
    [int]$TotalObjects
    [int]$ProcessedObjects
    [int]$OrphanedSIDsFound
    # SIDs no lookup found but at least one lookup failed to check; reported, never removed
    [int]$UnverifiedSIDsFound
    [int]$ProcessingErrors
    [int]$CriticalErrors
    [DateTime]$StartTime
    [DateTime]$EndTime
    [System.TimeSpan]$Duration
    [double]$ObjectsPerSecond
    [long]$PeakMemoryUsageMB

    ProcessingStatistics() {
        $this.StartTime = Get-Date
    }

    [void] Complete() {
        $this.EndTime = Get-Date
        $this.Duration = $this.EndTime - $this.StartTime
        if ($this.Duration.TotalSeconds -gt 0) {
            $this.ObjectsPerSecond = [Math]::Round($this.ProcessedObjects / $this.Duration.TotalSeconds, 2)
        }
    }
}