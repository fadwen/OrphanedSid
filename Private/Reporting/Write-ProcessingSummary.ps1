#Requires -Version 5.1

<#
.SYNOPSIS
    Processing summary and result reporting module for Find-UnknownSID

.DESCRIPTION
    Provides comprehensive result formatting, summary generation, and export
    capabilities for Find-UnknownSID processing results. Focused solely on
    result presentation and data export functionality.

.NOTES
    Author: Jeffrey Stuhr
    Blog: https://www.techbyjeff.net
    LinkedIn: https://www.linkedin.com/in/jeffrey-stuhr-034214aa/
    Last Updated: 2025-07-04
    Version: 2.0.0

    TROUBLESHOOTING:
    - For output issues: .\Troubleshooting\Common\Common-Issues.md
#>


function Write-ProcessingSummary {
    <#
    .SYNOPSIS
        Write comprehensive processing summary with statistics and results

    .DESCRIPTION
        Generates and displays a comprehensive summary of processing results
        including performance statistics, findings, and recommendations for
        enterprise reporting and audit requirements.

        BUSINESS VALUE:
        - Provides executive-level summary for decision making
        - Supports compliance reporting and audit requirements
        - Enables performance monitoring and optimization
        - Delivers actionable insights for security teams
        - Facilitates automation integration and monitoring

        REPORTING FEATURES:
        - Multi-format output for different audiences
        - Comprehensive performance metrics and statistics
        - Automated CSV export for downstream processing
        - Structured JSON output for automation integration
        - Color-coded console output for immediate assessment

    .PARAMETER ProcessingResults
        [Object] (Mandatory) Hashtable containing processing results and statistics.
        Must include required properties for different operation types.

        EXPECTED PROPERTIES:
        - TotalObjectsProcessed: Number of objects analyzed
        - ProcessingDuration: Time taken for processing
        - ProcessingErrors: Count of errors encountered
        - CorrelationId: Tracking identifier for audit

        OPERATION-SPECIFIC PROPERTIES:
        Discovery/Removal: OrphanedSIDsFound, RemovalResults, StreamingManager
        Restore: SuccessfulRestores, FailedRestores, RestoreResults

    .PARAMETER OutputPath
        [String] (Optional) Path for CSV export of results.
        Enables downstream processing and analysis.

        VALIDATION RULES:
        - Directory must exist or be creatable
        - Must have write permissions to specified location
        - File extension should be .csv for consistency

        BUSINESS CONTEXT:
        Supports integration with reporting systems, compliance
        documentation, and change management processes.

    .PARAMETER CorrelationId
        [String] (Optional) Correlation ID for tracking this operation.
        Auto-generated if not provided for audit purposes.

    .OUTPUTS
        [Void] Writes summary to console and optionally exports to files.
        Side effects include console output and file creation if specified.

    .EXAMPLE
        PS> Write-ProcessingSummary -ProcessingResults $results -OutputPath ".\results.csv"

        DESCRIPTION: Write summary and export results to CSV
        OUTPUT: Console summary and CSV file export
        USE CASE: Standard result reporting and documentation
        COMPLIANCE: Supports audit trail requirements

    .EXAMPLE
        PS> Write-ProcessingSummary -ProcessingResults $restoreResults

        DESCRIPTION: Display restore operation summary
        OUTPUT: Detailed restore operation results
        BUSINESS CASE: Change management and rollback reporting
        AUDIT: Supports compliance documentation requirements

    .NOTES
        Author: Jeffrey Stuhr
        Blog: https://www.techbyjeff.net
        LinkedIn: https://www.linkedin.com/in/jeffrey-stuhr-034214aa/

        SECURITY CONSIDERATIONS:
        - Results may contain sensitive information about AD structure
        - Export files should be protected with appropriate permissions
        - Correlation IDs enable security event tracking
        - Summary data supports security audit requirements

        PERFORMANCE CHARACTERISTICS:
        - Summary generation typically completes in <1 second
        - CSV export time varies with result count (1-10 seconds for large datasets)
        - Memory usage minimal for summary display
        - Streaming export for large result sets

        TROUBLESHOOTING:
        - For output issues: .\Troubleshooting\Common\Common-Issues.md
        - For performance optimization: .\Troubleshooting\Performance\Performance-Tuning.md

        KNOWN LIMITATIONS:
        - Large result sets may impact console display performance
        - CSV export requires sufficient disk space
        - Color output may not display correctly in all terminals
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$ProcessingResults,

        [Parameter()]
        [string]$OutputPath,

        [Parameter()]
        [string]$CorrelationId = [System.Guid]::NewGuid().ToString()
    )

    begin {
        Write-StructuredLog "Generating processing summary" -Level Information -Component 'Summary' -CorrelationId $CorrelationId
    }

    process {
        try {
            # Invoke-MainProcessingLogic returns a hashtable, whose keys PSObject.Properties does not
            # list; read the names from whichever shape arrived
            $resultKeys = if ($ProcessingResults -is [System.Collections.IDictionary]) {
                @($ProcessingResults.Keys)
            } else {
                @($ProcessingResults.PSObject.Properties.Name)
            }

            # Display processing summary
            Write-StructuredLog "Processing summary details:" -Level Information -Component 'Summary' -CorrelationId $CorrelationId
            Write-StructuredLog "=== PROCESSING SUMMARY ===" -Level Information -Component 'Summary' -CorrelationId $CorrelationId
            Write-StructuredLog "Total objects processed: $($ProcessingResults.TotalObjectsProcessed)" -Level Information -Component 'Summary' -CorrelationId $CorrelationId
            Write-StructuredLog "Processing duration: $($ProcessingResults.ProcessingDuration.ToString('hh\:mm\:ss\.fff'))" -Level Information -Component 'Summary' -CorrelationId $CorrelationId

            # Handle different result types
            if ($resultKeys -contains 'ObjectsPerSecond') {
                Write-StructuredLog "Processing rate: $([Math]::Round($ProcessingResults.ObjectsPerSecond, 2)) objects/second" -Level Information -Component 'Summary' -CorrelationId $CorrelationId
            }

            if ($resultKeys -contains 'PeakMemoryUsageMB') {
                Write-StructuredLog "Peak memory usage: $($ProcessingResults.PeakMemoryUsageMB) MB" -Level Information -Component 'Summary' -CorrelationId $CorrelationId
            }

            # Check if this is a restore operation
            if ($resultKeys -contains 'SuccessfulRestores') {
                # Restore operation summary
                Write-StructuredLog "=== RESTORE SUMMARY ===" -Level Information -Component 'Summary' -CorrelationId $CorrelationId
                Write-StructuredLog "Successful restores: $($ProcessingResults.SuccessfulRestores)" -Level Information -Component 'Summary' -CorrelationId $CorrelationId
                Write-StructuredLog "Failed restores: $($ProcessingResults.FailedRestores)" -Level Information -Component 'Summary' -CorrelationId $CorrelationId
                Write-StructuredLog "Backup source: $($ProcessingResults.BackupPath)" -Level Information -Component 'Summary' -CorrelationId $CorrelationId
                Write-StructuredLog "WhatIf mode: $($ProcessingResults.WhatIfMode)" -Level Information -Component 'Summary' -CorrelationId $CorrelationId

                # Show detailed restore results
                if ($ProcessingResults.RestoreResults -and $ProcessingResults.RestoreResults.Count -gt 0) {
                    Write-StructuredLog "=== RESTORE DETAILS ===" -Level Information -Component 'Summary' -CorrelationId $CorrelationId
                    foreach ($result in $ProcessingResults.RestoreResults) {
                        $status = if ($result.Success) { "SUCCESS" } else { "FAILED" }
                        $entriesInfo = if ($result.EntriesRestored) { " ($($result.EntriesRestored) entries)" } else { "" }
                        Write-StructuredLog "  [$status] $($result.ObjectDN)$entriesInfo" -Level Information -Component 'Summary' -CorrelationId $CorrelationId
                        if (-not $result.Success -and $result.ErrorMessage) {
                            Write-StructuredLog "    Error: $($result.ErrorMessage)" -Level Information -Component 'Summary' -CorrelationId $CorrelationId
                        }
                    }
                }

                # Overall restore operation status
                if ($ProcessingResults.FailedRestores -eq 0) {
                    Write-StructuredLog "All restore operations completed successfully!" -Level Information -Component 'Summary' -CorrelationId $CorrelationId
                } else {
                    Write-StructuredLog "Some restore operations failed. Review the details above." -Level Warning -Component 'Summary' -CorrelationId $CorrelationId
                }
            } else {
                # Standard discovery/removal operation summary
                if ($resultKeys -contains 'ProcessingErrors') {
                    Write-StructuredLog "Processing errors: $($ProcessingResults.ProcessingErrors)" -Level Information -Component 'Summary' -CorrelationId $CorrelationId
                }

                if ($resultKeys -contains 'OrphanedSIDsFound') {
                    Write-StructuredLog "Orphaned SIDs found: $($ProcessingResults.OrphanedSIDsFound)" -Level Information -Component 'Summary' -CorrelationId $CorrelationId
                }

                if ($resultKeys -contains 'UnexaminedObjects') {
                    Write-StructuredLog "Objects not examined (security descriptor not readable): $($ProcessingResults.UnexaminedObjects)" -Level Information -Component 'Summary' -CorrelationId $CorrelationId
                    if ($ProcessingResults.UnexaminedObjects -gt 0) {
                        Write-StructuredLog "$($ProcessingResults.UnexaminedObjects) object(s) could not be examined because their security descriptor could not be read; each is named in a Warning above. Orphaned entries on them, if any, were neither reported nor removed. Re-run with an account that may read them." -Level Warning -Component 'Summary' -CorrelationId $CorrelationId
                    }
                }

                if ($resultKeys -contains 'UnverifiedSIDsFound') {
                    Write-StructuredLog "Unverified SIDs (lookup failed, not removed): $($ProcessingResults.UnverifiedSIDsFound)" -Level Information -Component 'Summary' -CorrelationId $CorrelationId
                    if ($ProcessingResults.UnverifiedSIDsFound -gt 0) {
                        Write-StructuredLog "$($ProcessingResults.UnverifiedSIDsFound) SID(s) could not be verified because a directory lookup failed. They are marked VerificationStatus Unverified in the results and were not removed; re-run once the domain controller is reachable and the account can read the targets." -Level Warning -Component 'Summary' -CorrelationId $CorrelationId
                    }
                }
            }

            # Removal summary if applicable
            if ($ProcessingResults.RemovalResults -and $ProcessingResults.RemovalResults.Count -gt 0) {
                # @(...): on Windows PowerShell 5.1 a single object from Where-Object has no Count, so a run
                # with one removal logged an empty number
                $successfulRemovals = @($ProcessingResults.RemovalResults | Where-Object Success).Count
                $failedRemovals = @($ProcessingResults.RemovalResults | Where-Object { -not $_.Success }).Count

                Write-StructuredLog "Removal summary details:" -Level Information -Component 'Summary' -CorrelationId $CorrelationId
                Write-StructuredLog "=== REMOVAL SUMMARY ===" -Level Information -Component 'Summary' -CorrelationId $CorrelationId
                Write-StructuredLog "Removal operations attempted: $($ProcessingResults.RemovalResults.Count)" -Level Information -Component 'Summary' -CorrelationId $CorrelationId
                Write-StructuredLog "Successful removals: $successfulRemovals" -Level Information -Component 'Summary' -CorrelationId $CorrelationId
                Write-StructuredLog "Failed removals: $failedRemovals" -Level Information -Component 'Summary' -CorrelationId $CorrelationId
            }

            # Export results to CSV if path provided
            # Check if we have streaming results or restore results
            $hasStreamingResults = $ProcessingResults.StreamingManager -and $ProcessingResults.StreamingManager.Summary.TotalResults -gt 0
            $hasRestoreResults = $ProcessingResults.RestoreResults -and $ProcessingResults.RestoreResults.Count -gt 0

            if ($hasStreamingResults -or $hasRestoreResults) {
                if ($OutputPath) {
                    try {
                        # Under -WhatIf neither export writes a file: the streaming manager skips it in
                        # WhatIf mode, and Export-Csv honours the inherited $WhatIfPreference
                        $exported = $false
                        if ($hasStreamingResults) {
                            # Use StreamingManager's efficient CSV export
                            $exported = $ProcessingResults.StreamingManager.ExportToCsv($OutputPath)
                        } elseif ($hasRestoreResults) {
                            if (-not $WhatIfPreference) {
                                $ProcessingResults.RestoreResults | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
                                $exported = $true
                            }
                        }
                        if ($exported) {
                            Write-StructuredLog "Results exported to: $OutputPath" -Level Information -Component 'Summary' -CorrelationId $CorrelationId
                        } elseif ($WhatIfPreference -or ($hasStreamingResults -and $ProcessingResults.StreamingManager.WhatIfMode)) {
                            Write-StructuredLog "WhatIf: results would be exported to $OutputPath; no file was written" -Level Information -Component 'Summary' -CorrelationId $CorrelationId
                        } else {
                            Write-StructuredLog "No results were read back to export; $OutputPath was not written" -Level Warning -Component 'Summary' -CorrelationId $CorrelationId
                        }
                    }
                    catch {
                        Write-StructuredLog "Failed to export results to CSV: $($_.Exception.Message)" -Level Error -Component 'Summary' -CorrelationId $CorrelationId
                    }
                }
            } else {
                # Handle different operation types appropriately
                if ($resultKeys -contains 'SuccessfulRestores') {
                    # This is a restore operation with no results - shouldn't happen but handle gracefully
                    Write-StructuredLog "No restore operations were performed." -Level Information -Component 'Summary' -CorrelationId $CorrelationId
                } else {
                    # This is a discovery/removal operation
                    if ($resultKeys -contains 'ProcessingErrors' -and $ProcessingResults.ProcessingErrors -gt 0) {
                        Write-StructuredLog "Consider reviewing the error log for detailed information." -Level Information -Component 'Summary' -CorrelationId $CorrelationId
                    } else {
                        Write-StructuredLog "No orphaned SIDs found. Active Directory ACLs appear to be clean." -Level Information -Component 'Summary' -CorrelationId $CorrelationId
                    }
                }
            }

            Write-StructuredLog "Processing summary completed" -Level Information -Component 'Summary' -CorrelationId $CorrelationId

        }
        catch {
            Write-StructuredLog "Error generating processing summary: $($_.Exception.Message)" -Level Error -Component 'Summary' -CorrelationId $CorrelationId
            throw
        }
    }
}
