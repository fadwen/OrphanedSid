#Requires -Version 5.1

function Write-ProcessingSummary {
    <#
    .SYNOPSIS
        Writes the summary of a discovery or a removal to the log

    .DESCRIPTION
        Logs the totals of a run of Find-OrphanedSid or Remove-OrphanedSid: the objects
        processed and the duration, and, where the result has them, the rate, the peak memory
        use, the processing errors, the orphaned SIDs found, the objects that could not be
        examined and the SIDs that could not be verified. Each of the last two gets a line at
        Warning level when it is not zero.

        For a run that removed entries it logs how many removals were attempted, how many
        succeeded and how many failed, and, when there is one, how many of the failed ones had
        an entry that was no longer on the object.

        When the run streamed results and -OutputPath is given, the streaming manager of the
        result writes them to that CSV file, and a line says where the file is. Under -WhatIf
        no file is written and a line says so. When the manager writes nothing outside
        -WhatIf, a line at Warning level says that the file was not written. An export that
        fails is logged at Error level and reported as a non-terminating error: the results
        were already returned, so the command goes on. A run that streamed no result gets a
        line that says the directory is clean, or, when it had processing errors, a line that
        points at the error log.

        Every line goes through Write-StructuredLog with the component Summary. A restore is
        not summarised here: Restore-OrphanedSidBackup writes its own summary.

    .PARAMETER ProcessingResults
        The result of Invoke-MainProcessingLogic, as a hashtable or as an object with the same
        names. TotalObjectsProcessed and ProcessingDuration, a TimeSpan, are read from every
        result. ObjectsPerSecond, PeakMemoryUsageMB, ProcessingErrors, OrphanedSIDsFound,
        UnexaminedObjects, UnverifiedSIDsFound, RemovalResults and StreamingManager are read
        when the result has them.

    .PARAMETER OutputPath
        Path of the CSV file for the streamed results. The function does not check the path:
        the public commands check its folder before a run starts.

    .PARAMETER CorrelationId
        Correlation ID of the log lines. One is generated when none is given.

    .INPUTS
        None.

    .OUTPUTS
        None.

    .EXAMPLE
        PS> Write-ProcessingSummary -ProcessingResults $results -OutputPath '.\results.csv' -CorrelationId $id

        Logs the summary of the run and exports its streamed results to results.csv.

    .NOTES
        Author: Jeffrey Stuhr
        Blog: https://www.techbyjeff.net
        LinkedIn: https://www.linkedin.com/in/jeffrey-stuhr-034214aa/

        TROUBLESHOOTING:
        - For output issues: .\Troubleshooting\Common\Common-Issues.md
        - For performance optimization: .\Troubleshooting\Performance\Performance-Tuning.md
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

            # The values, in one table whichever shape arrived. A result has only the values of
            # its kind of run, and under strict mode a read of a key or a property that is not
            # there is an error. Read from this table with the index, it is $null.
            $values = @{}
            foreach ($key in $resultKeys) {
                if ($ProcessingResults -is [System.Collections.IDictionary]) {
                    $values[$key] = $ProcessingResults[$key]
                } else {
                    $values[$key] = $ProcessingResults.PSObject.Properties[$key].Value
                }
            }

            # Display processing summary
            Write-StructuredLog "Processing summary details:" -Level Information -Component 'Summary' -CorrelationId $CorrelationId
            Write-StructuredLog "=== PROCESSING SUMMARY ===" -Level Information -Component 'Summary' -CorrelationId $CorrelationId
            Write-StructuredLog "Total objects processed: $($values['TotalObjectsProcessed'])" -Level Information -Component 'Summary' -CorrelationId $CorrelationId
            Write-StructuredLog "Processing duration: $($values['ProcessingDuration'].ToString('hh\:mm\:ss\.fff'))" -Level Information -Component 'Summary' -CorrelationId $CorrelationId

            # Handle different result types
            if ($resultKeys -contains 'ObjectsPerSecond') {
                Write-StructuredLog "Processing rate: $([Math]::Round($values['ObjectsPerSecond'], 2)) objects/second" -Level Information -Component 'Summary' -CorrelationId $CorrelationId
            }

            if ($resultKeys -contains 'PeakMemoryUsageMB') {
                Write-StructuredLog "Peak memory usage: $($values['PeakMemoryUsageMB']) MB" -Level Information -Component 'Summary' -CorrelationId $CorrelationId
            }

            # The lines of a discovery or a removal. A restore is not summarised here:
            # Restore-OrphanedSidBackup writes its own summary.
            if ($resultKeys -contains 'ProcessingErrors') {
                Write-StructuredLog "Processing errors: $($values['ProcessingErrors'])" -Level Information -Component 'Summary' -CorrelationId $CorrelationId
            }

            if ($resultKeys -contains 'OrphanedSIDsFound') {
                Write-StructuredLog "Orphaned SIDs found: $($values['OrphanedSIDsFound'])" -Level Information -Component 'Summary' -CorrelationId $CorrelationId
            }

            if ($resultKeys -contains 'UnexaminedObjects') {
                Write-StructuredLog "Objects not examined (security descriptor not readable): $($values['UnexaminedObjects'])" -Level Information -Component 'Summary' -CorrelationId $CorrelationId
                if ($values['UnexaminedObjects'] -gt 0) {
                    Write-StructuredLog "$($values['UnexaminedObjects']) object(s) could not be examined because their security descriptor could not be read; each is named in a Warning above. Orphaned entries on them, if any, were neither reported nor removed. Re-run with an account that may read them." -Level Warning -Component 'Summary' -CorrelationId $CorrelationId
                }
            }

            if ($resultKeys -contains 'UnverifiedSIDsFound') {
                Write-StructuredLog "Unverified SIDs (lookup failed, not removed): $($values['UnverifiedSIDsFound'])" -Level Information -Component 'Summary' -CorrelationId $CorrelationId
                if ($values['UnverifiedSIDsFound'] -gt 0) {
                    Write-StructuredLog "$($values['UnverifiedSIDsFound']) SID(s) could not be verified because a directory lookup failed. They are marked VerificationStatus Unverified in the results and were not removed; re-run once the domain controller is reachable and the account can read the targets." -Level Warning -Component 'Summary' -CorrelationId $CorrelationId
                }
            }

            # Removal summary if applicable
            if ($values['RemovalResults'] -and @($values['RemovalResults']).Count -gt 0) {
                # @(...): on Windows PowerShell 5.1 a single object from Where-Object has no Count, so a run
                # with one removal logged an empty number
                $successfulRemovals = @($values['RemovalResults'] | Where-Object Success).Count
                $failedRemovals = @($values['RemovalResults'] | Where-Object { -not $_.Success }).Count

                Write-StructuredLog "Removal summary details:" -Level Information -Component 'Summary' -CorrelationId $CorrelationId
                Write-StructuredLog "=== REMOVAL SUMMARY ===" -Level Information -Component 'Summary' -CorrelationId $CorrelationId
                Write-StructuredLog "Removal operations attempted: $(@($values['RemovalResults']).Count)" -Level Information -Component 'Summary' -CorrelationId $CorrelationId
                Write-StructuredLog "Successful removals: $successfulRemovals" -Level Information -Component 'Summary' -CorrelationId $CorrelationId
                Write-StructuredLog "Failed removals: $failedRemovals" -Level Information -Component 'Summary' -CorrelationId $CorrelationId

                # A result in which an entry that discovery reported was no longer on the object is a
                # failed removal. This line tells such a result from one in which an entry could not
                # be removed, and is written only when there is one.
                $goneCounts = @(foreach ($removalResult in $values['RemovalResults']) {
                        $notFound = $removalResult.PSObject.Properties['NotFoundSIDs']
                        if ($null -ne $notFound -and @($notFound.Value).Count -gt 0) {
                            @($notFound.Value).Count
                        }
                    })
                if ($goneCounts.Count -gt 0) {
                    $goneEntries = ($goneCounts | Measure-Object -Sum).Sum
                    $goneMessage = "Of the failed removals, with an entry that was no longer on the object: " +
                        "$($goneCounts.Count) ($goneEntries SID(s))"
                    Write-StructuredLog $goneMessage -Level Information -Component 'Summary' -CorrelationId $CorrelationId
                }
            }

            # Export results to CSV if path provided. Only a run that streamed results has
            # something to export.
            $hasStreamingResults = $values['StreamingManager'] -and $values['StreamingManager'].Summary.TotalResults -gt 0

            if ($hasStreamingResults) {
                if ($OutputPath) {
                    try {
                        # Under -WhatIf the export writes no file: the streaming manager skips it
                        # in WhatIf mode
                        $exported = $values['StreamingManager'].ExportToCsv($OutputPath)
                        if ($exported) {
                            Write-StructuredLog "Results exported to: $OutputPath" -Level Information -Component 'Summary' -CorrelationId $CorrelationId
                        } elseif ($WhatIfPreference -or $values['StreamingManager'].WhatIfMode) {
                            Write-StructuredLog "WhatIf: results would be exported to $OutputPath; no file was written" -Level Information -Component 'Summary' -CorrelationId $CorrelationId
                        } else {
                            Write-StructuredLog "No results were read back to export; $OutputPath was not written" -Level Warning -Component 'Summary' -CorrelationId $CorrelationId
                        }
                    }
                    catch {
                        Write-StructuredLog "Failed to export results to CSV: $($_.Exception.Message)" -Level Error -Component 'Summary' -CorrelationId $CorrelationId

                        # The results were already returned, so this does not end the command. It is
                        # an error and not only a log line because the caller asked for a file and
                        # has none.
                        $message = "Results could not be exported to '$OutputPath': $($_.Exception.Message)"
                        $exception = [System.IO.IOException]::new($message, $_.Exception)
                        $category = [System.Management.Automation.ErrorCategory]::WriteError
                        $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                            $exception, 'ResultExportFailed', $category, $OutputPath)
                        $PSCmdlet.WriteError($errorRecord)
                    }
                }
            } else {
                if ($resultKeys -contains 'ProcessingErrors' -and $values['ProcessingErrors'] -gt 0) {
                    Write-StructuredLog "Consider reviewing the error log for detailed information." -Level Information -Component 'Summary' -CorrelationId $CorrelationId
                } else {
                    Write-StructuredLog "No orphaned SIDs found. Active Directory ACLs appear to be clean." -Level Information -Component 'Summary' -CorrelationId $CorrelationId
                }
            }

            Write-StructuredLog "Processing summary completed" -Level Information -Component 'Summary' -CorrelationId $CorrelationId

        }
        catch {
            Write-StructuredLog "Error generating processing summary: $($_.Exception.Message)" -Level Error -Component 'Summary' -CorrelationId $CorrelationId
            $PSCmdlet.ThrowTerminatingError($_)
        }
    }
}
