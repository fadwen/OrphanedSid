function Stop-OrphanedSidSession {
    <#
    .SYNOPSIS
        Releases the per-run state created by Start-OrphanedSidSession.

    .DESCRIPTION
        Disposes the streaming results manager and the memory manager through
        Invoke-ResourceCleanup, honouring -PreserveTempFiles, then clears the module-scope
        variables so a later command in the same session starts clean. Always called from the
        finally block of a public command, so it must not throw: every failure is downgraded to a
        warning and the fallback is a direct Dispose() plus garbage collection.

    .PARAMETER PreserveTempFiles
        Leave the streaming batch files in the temp directory instead of removing them.

    .PARAMETER CorrelationId
        Correlation identifier of the run being closed.

    .EXAMPLE
        PS> Stop-OrphanedSidSession -CorrelationId $id

        DESCRIPTION: Disposes the run's resources and clears module state
        OUTPUT: None
        USE CASE: The finally block of every public command

    .NOTES
        Author: Jeffrey Stuhr
        Blog: https://www.techbyjeff.net
        LinkedIn: https://www.linkedin.com/in/jeffrey-stuhr-034214aa/

        TROUBLESHOOTING:
        - Temp files left behind: .\Troubleshooting\Performance\Memory-Management.md
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Disposes run resources and clears module-scope state, nothing on the system')]
    param(
        [Parameter()]
        [switch]$PreserveTempFiles,

        [Parameter()]
        [string]$CorrelationId = $script:CorrelationId
    )

    try {
        $additionalResources = @()

        if ($script:StreamingResults) {
            $additionalResources += $script:StreamingResults

            if ($PreserveTempFiles) {
                $script:StreamingResults.PreserveFiles = $true
                Write-StructuredLog "Temporary result files preserved in: $($script:StreamingResults.TempDirectory)" -Level Information -Component 'Main' -CorrelationId $CorrelationId
            }
            else {
                Write-StructuredLog 'Temporary result files will be cleaned up during disposal' -Level Information -Component 'Main' -CorrelationId $CorrelationId
            }
        }

        Invoke-ResourceCleanup -MemoryManager $script:MemoryManager -AdditionalResources $additionalResources -CorrelationId $CorrelationId
        Write-StructuredLog 'All resources cleaned up' -Level Information -Component 'Main' -CorrelationId $CorrelationId
    }
    catch {
        Write-Warning "Error during resource cleanup: $($_.Exception.Message)"
        try {
            if ($script:MemoryManager -and -not $script:MemoryManager.Disposed) {
                $script:MemoryManager.Dispose()
            }
            if ($script:StreamingResults -and -not $script:StreamingResults.Disposed) {
                $script:StreamingResults.Dispose()
            }
            [System.GC]::Collect()
            [System.GC]::WaitForPendingFinalizers()
        }
        catch {
            Write-Warning "Fallback cleanup failed: $($_.Exception.Message)"
        }
    }
    finally {
        $script:StreamingResults = $null
        $script:MemoryManager = $null
        $script:Statistics = $null
        $script:RemovalResults = @()
    }
}
