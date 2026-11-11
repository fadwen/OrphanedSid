#Requires -Version 5.1

<#
.SYNOPSIS
    Core SID discovery and processing logic for Find-UnknownSID

.DESCRIPTION
    Handles the main processing workflow including AD object discovery,
    SID analysis, and optional removal operations. Focused solely on
    the core business logic of orphaned SID processing.

.NOTES
    Author: Jeffrey Stuhr
    Blog: https://www.techbyjeff.net
    LinkedIn: https://www.linkedin.com/in/jeffrey-stuhr-034214aa/
    Last Updated: 2025-07-04
    Version: 2.0.0

    TROUBLESHOOTING:
    - For processing failures: .\Troubleshooting\Common\Processing-Issues.md
    - For AD connectivity: .\Troubleshooting\Common\AD-Connection-Issues.md
#>


function Invoke-MainProcessingLogic {
    <#
    .SYNOPSIS
        Execute the main SID discovery and processing logic

    .DESCRIPTION
        Orchestrates the main processing workflow including AD object discovery,
        SID analysis, and optional removal operations with comprehensive error
        handling and performance monitoring.

        BUSINESS VALUE:
        - Identifies orphaned SIDs that pose security risks
        - Enables cleanup of obsolete access control entries
        - Provides comprehensive audit trail for compliance
        - Supports large-scale AD security remediation
        - Delivers actionable security intelligence

        PROCESSING FEATURES:
        - Parallel processing for improved performance
        - Memory-efficient streaming results management
        - Comprehensive retry logic for resilient operations
        - Real-time progress reporting and monitoring
        - Integration with backup systems for safe removal

    .PARAMETER SearchBase
        [String[]] (Mandatory) Distinguished Names of search bases for processing.
        Each DN must be valid and accessible in Active Directory.

        VALIDATION RULES:
        - Must pass Test-ValidDistinguishedName validation
        - Each DN must exist in Active Directory
        - User must have read permissions to the specified containers

        BUSINESS CONTEXT:
        Defines the scope of orphaned SID discovery operation.
        Consider organizational structure when selecting search bases.

    .PARAMETER Remove
        [Switch] (Optional) Whether to perform SID removal operations.
        Requires additional permissions and triggers backup creation.

        SECURITY IMPLICATIONS:
        - Requires elevated privileges for ACL modification
        - Should be tested thoroughly in non-production environment
        - Backup creation is strongly recommended

    .PARAMETER IncludeInherited
        [Switch] (Optional) Whether to include inherited ACEs in processing.
        Affects scope and performance of SID analysis.

        PERFORMANCE IMPACT:
        Including inherited ACEs significantly increases processing time
        but provides more comprehensive security analysis.

    .PARAMETER MaxRetries
        [Int] (Optional) Maximum retry attempts for failed operations (Default: 3).
        Provides resilience against transient failures.

    .PARAMETER BackupPath
        [String] (Optional) Directory path for storing ACL backups.
        Required for removal operations in production environments.

    .PARAMETER CorrelationId
        [String] (Optional) Correlation ID for tracking this operation.
        Auto-generated if not provided for audit purposes.

    .OUTPUTS
        [Hashtable] Processing results containing:
        - TotalObjectsProcessed: Number of AD objects analyzed
        - OrphanedSIDsFound: Count of orphaned SIDs discovered
        - UnverifiedSIDsFound: Count of SIDs a failed lookup left unverified (never removed)
        - ProcessingErrors: Number of errors encountered
        - ProcessingDuration: Total execution time
        - ObjectsPerSecond: Processing performance metric
        - PeakMemoryUsageMB: Maximum memory consumption
        - StreamingSummary: Results summary from streaming manager
        - RemovalResults: Details of removal operations (if performed)
        - StreamingManager: Reference for accessing detailed results

    .EXAMPLE
        PS> Invoke-MainProcessingLogic -SearchBase "OU=Users,DC=contoso,DC=com"

        DESCRIPTION: Execute discovery mode on Users OU
        OUTPUT: Hashtable with discovered orphaned SIDs and statistics
        USE CASE: Standard orphaned SID discovery operation
        DURATION: Varies based on object count (typically 1-5 seconds per 100 objects)

    .EXAMPLE
        PS> Invoke-MainProcessingLogic -SearchBase @("OU=Users,DC=contoso,DC=com") -Remove -BackupPath "C:\Backups"

        DESCRIPTION: Execute removal operation with backup creation
        OUTPUT: Results including removal statistics and backup location
        BUSINESS CASE: Production cleanup of orphaned SIDs with safety measures
        COMPLIANCE: Supports change management and audit requirements

    .EXAMPLE
        PS> Invoke-MainProcessingLogic -SearchBase "DC=contoso,DC=com" -IncludeInherited

        DESCRIPTION: Comprehensive domain-wide analysis with inherited permissions
        OUTPUT: Complete security analysis results for entire domain
        ENTERPRISE USE: Large-scale security assessment and remediation
        PERFORMANCE: Optimized for reliable sequential processing

    .NOTES
        Author: Jeffrey Stuhr
        Blog: https://www.techbyjeff.net
        LinkedIn: https://www.linkedin.com/in/jeffrey-stuhr-034214aa/

        SECURITY CONSIDERATIONS:
        - Removal operations require elevated AD permissions
        - Backup creation is essential for production safety
        - All operations are logged for security audit
        - ShouldProcess support enables safe testing with -WhatIf

        PERFORMANCE CHARACTERISTICS:
        - Processing rate: 50-200 objects per second (depending on complexity)
        - Memory usage: Optimized with streaming results management
        - Parallel processing scales with available system resources
        - Progress reporting every 50 objects for user feedback

        TROUBLESHOOTING:
        - For processing failures: .\Troubleshooting\Common\Processing-Issues.md
        - For AD connectivity: .\Troubleshooting\Common\AD-Connection-Issues.md
        - For memory issues: .\Troubleshooting\Performance\Memory-Management.md
        - For permission problems: .\Troubleshooting\Security\Permission-Issues.md

        KNOWN LIMITATIONS:
        - Large datasets may require memory management tuning
        - Network latency affects processing speed
        - Some ACL operations may require domain administrator privileges
        - Streaming results are temporarily stored on disk
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-ValidDistinguishedName $_ })]
        [string[]]$SearchBase,

        [Parameter()]
        [switch]$Remove,

        [Parameter()]
        [switch]$IncludeInherited,

        [Parameter()]
        [ValidateRange(1, 10)]
        [int]$MaxRetries = 3,

        [Parameter()]
        [string]$BackupPath,

        [Parameter()]
        [string]$CorrelationId = [System.Guid]::NewGuid().ToString()
    )

    begin {
        Write-StructuredLog "Starting main processing logic" -Level Information -Component 'MainProcessing' -CorrelationId $CorrelationId

        # StreamingResultsManager class is loaded via SecureClassImporter in main script
        # Verify it's available before proceeding
        if (-not ([System.Management.Automation.PSTypeName]'StreamingResultsManager').Type) {
            throw "StreamingResultsManager class not available - ensure SecureClassImporter loaded all classes successfully"
        }        # Initialize streaming results manager instead of in-memory arrays
        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "OrphanedSid-$CorrelationId"

        # -WhatIf on the public command arrives here as $WhatIfPreference. Read it directly: asking
        # ShouldProcess would print a "What if" line about the temp directory, which is not what the
        # caller is rehearsing.
        $whatIfMode = [bool]$WhatIfPreference

        # Batch size comes from the BatchSize configuration key (default 50)
        $batchSize = 50
        if ($script:Config -and $script:Config.BatchSize -ge 1) {
            $batchSize = [int]$script:Config.BatchSize
        }

        # The domain SID lets Get-SIDAnalysis tell a SID from this domain apart from a foreign or
        # unknown one. Discovery still works without it; every domain SID is then rated Unknown Domain.
        $script:CurrentDomainSID = $null
        try {
            $script:CurrentDomainSID = (Get-ADDomain -ErrorAction Stop).DomainSID.Value
        }
        catch {
            Write-StructuredLog "Could not determine the current domain SID: $($_.Exception.Message)" -Level Warning -Component 'MainProcessing' -CorrelationId $CorrelationId
        }

        # Create StreamingResultsManager with 2-argument constructor (doesn't create directory yet)
        $script:StreamingResults = [StreamingResultsManager]::new($tempDir, $batchSize)

        # Configure WhatIf mode and complete initialization (this will handle directory creation properly)
        $script:StreamingResults.ConfigureWhatIfMode($whatIfMode)

        $script:RemovalResults = @()

        Write-StructuredLog "Initialized streaming results manager with temp directory: $tempDir (WhatIf: $whatIfMode)" -Level Debug -Component 'MainProcessing' -CorrelationId $CorrelationId
    }

    process {
        try {
            # Process each search base
            foreach ($searchPath in $SearchBase) {
                Write-StructuredLog "Processing search base: $searchPath" -Level Information -Component 'MainProcessing' -CorrelationId $CorrelationId

                # Log security audit for AD discovery operation attempt
                Write-ADOperationSecurityLog -OperationName 'AD-ObjectDiscovery' -Outcome 'Attempt' -SecurityContext @{
                    SearchBase = $searchPath
                    Operation = 'Get-ADObjectsSequential'
                    Mode = if ($Remove) { 'RemovalMode' } else { 'DiscoveryMode' }
                } -CorrelationId $CorrelationId

                # Always perform discovery phase - ShouldProcess only applies to removal operations
                # Get AD objects for processing using refactored sequential processing
                try {
                    $adObjects = Get-ADObjectsSequential -SearchBase @($searchPath)

                    # Log successful AD discovery
                    Write-ADOperationSecurityLog -OperationName 'AD-ObjectDiscovery' -Outcome 'Success' -SecurityContext @{
                        SearchBase = $searchPath
                        ObjectsFound = @($adObjects).Count
                        Operation = 'Get-ADObjectsSequential'
                    } -CorrelationId $CorrelationId
                } catch {
                    # Log failed AD discovery
                    Write-ADOperationSecurityLog -OperationName 'AD-ObjectDiscovery' -Outcome 'Failure' -SecurityContext @{
                        SearchBase = $searchPath
                        ErrorMessage = $_.Exception.Message
                        Operation = 'Get-ADObjectsSequential'
                    } -CorrelationId $CorrelationId
                    throw
                }

                # Ensure $adObjects is always treated as an array for consistent counting
                $objectArray = @($adObjects)

                # Categorize objects for meaningful user feedback
                $objectStats = @{
                    Users = 0
                    Computers = 0
                    Groups = 0
                    OUs = 0
                    Other = 0
                }

                foreach ($obj in $objectArray) {
                    switch ($obj.ObjectClass) {
                        'user' { $objectStats.Users++ }
                        'computer' { $objectStats.Computers++ }
                        'group' { $objectStats.Groups++ }
                        'organizationalUnit' { $objectStats.OUs++ }
                        default { $objectStats.Other++ }
                    }
                }

                # Report meaningful discovery summary
                $summaryParts = @()
                if ($objectStats.Users -gt 0) { $summaryParts += "$($objectStats.Users) users" }
                if ($objectStats.Computers -gt 0) { $summaryParts += "$($objectStats.Computers) computers" }
                if ($objectStats.Groups -gt 0) { $summaryParts += "$($objectStats.Groups) groups" }
                if ($objectStats.OUs -gt 0) { $summaryParts += "$($objectStats.OUs) OUs" }
                if ($objectStats.Other -gt 0) { $summaryParts += "$($objectStats.Other) other objects" }

                $summaryText = if ($summaryParts.Count -gt 0) { $summaryParts -join ', ' } else { "0 objects" }
                Write-StructuredLog "Discovered: $summaryText (Total: $($objectArray.Count) objects)" -Level Information -Component 'MainProcessing' -CorrelationId $CorrelationId

                Write-StructuredLog "Found $($objectArray.Count) AD objects to process" -Level Debug -Component 'MainProcessing' -CorrelationId $CorrelationId
                $script:Statistics.TotalObjects += $objectArray.Count

                # Process objects for orphaned SIDs - this always happens regardless of WhatIf
                $processedCount = 0
                $orphanedFoundCount = 0
                $null = $objectArray | ForEach-Object {
                    # Captured once: inside a catch block $_ is the error record, not the object
                    $currentObject = $_
                    try {
                        # Pinned: housekeeping, not the operation -WhatIf rehearses
                        Invoke-MemoryCheck -MemoryManager $script:MemoryManager -WhatIf:$false
                        $script:Statistics.ProcessedObjects++
                        $processedCount++

                        # Show progress every 50 objects or on last object
                        if (($processedCount % 50 -eq 0) -or ($processedCount -eq $objectArray.Count)) {
                            $percentComplete = [Math]::Round(($processedCount / $objectArray.Count) * 100, 1)
                            Write-StructuredLog "Processing: $processedCount/$($objectArray.Count) objects ($percentComplete%) - Orphaned SIDs found: $orphanedFoundCount" -Level Information -Component 'MainProcessing' -CorrelationId $CorrelationId
                        }

                        # Detection is the step that reads the directory, so it is the one retried.
                        # Removal below runs once, on the result; a removal error is not retried,
                        # because a second attempt would take a second backup and act on an ACL
                        # the first attempt may already have changed.
                        $orphanedResults = $null
                        $detectionAttempt = 0
                        while ($null -eq $orphanedResults) {
                            try {
                                $orphanedResults = @(Find-OrphanedSIDsInObject -ADObject $currentObject -IncludeInherited:$IncludeInherited -CurrentDomainSID $script:CurrentDomainSID)
                            }
                            catch {
                                $detectionAttempt++
                                if ($detectionAttempt -gt $MaxRetries) {
                                    Write-StructuredLog "Max retries ($MaxRetries) exceeded for object $($currentObject.DistinguishedName)" -Level Error -Component 'MainProcessing' -CorrelationId $CorrelationId
                                    throw
                                }
                                Write-StructuredLog "Retry attempt $detectionAttempt of $MaxRetries for object $($currentObject.DistinguishedName): $($_.Exception.Message)" -Level Warning -Component 'MainProcessing' -CorrelationId $CorrelationId
                                Start-Sleep -Seconds (2 * $detectionAttempt)
                            }
                        }

                        # An Unverified result is a SID that no lookup found but at least one lookup
                        # failed to check. It is reported, counted apart, and never removed.
                        $verifiedResults = @($orphanedResults | Where-Object { $_.VerificationStatus -ne 'Unverified' })
                        $unverifiedResults = @($orphanedResults | Where-Object { $_.VerificationStatus -eq 'Unverified' })

                        # Log security audit for orphaned SID analysis
                        if ($orphanedResults.Count -gt 0) {
                            Write-ADOperationSecurityLog -OperationName 'OrphanedSID-Detection' -Outcome 'Success' -SecurityContext @{
                                ObjectDN = $currentObject.DistinguishedName
                                ObjectClass = $currentObject.ObjectClass
                                OrphanedSIDsFound = $verifiedResults.Count
                                OrphanedSIDs = ($verifiedResults | ForEach-Object { $_.OrphanedSID }) -join ','
                                UnverifiedSIDsFound = $unverifiedResults.Count
                                UnverifiedSIDs = ($unverifiedResults | ForEach-Object { $_.OrphanedSID }) -join ','
                            } -CorrelationId $CorrelationId
                        }

                        # Additional memory management for large operations
                        if ($processedCount % 100 -eq 0) {
                            # Use centralized cleanup for large operations
                            # Pinned: housekeeping, not the operation -WhatIf rehearses
                            $cleanupResult = Invoke-Cleanup -CorrelationId $CorrelationId -WhatIf:$false
                            Write-Verbose "Memory usage at $processedCount objects: $($cleanupResult.MemoryAfterMB) MB (Freed: $($cleanupResult.MemoryFreedMB) MB)"
                        }

                        if ($orphanedResults.Count -gt 0) {
                            $script:Statistics.OrphanedSIDsFound += $verifiedResults.Count
                            $script:Statistics.UnverifiedSIDsFound += $unverifiedResults.Count
                            $orphanedFoundCount += $verifiedResults.Count

                            # Stream results to disk instead of accumulating in memory. Unverified
                            # results go too, marked by VerificationStatus, so they can be re-checked.
                            foreach ($orphanedResult in $orphanedResults) {
                                $script:StreamingResults.AddResult($orphanedResult)
                            }

                            if ($Remove) {
                                foreach ($unverifiedResult in $unverifiedResults) {
                                    Write-StructuredLog "Not removing unverified SID $($unverifiedResult.OrphanedSID) from $($unverifiedResult.ObjectDN): a directory lookup failed, so it may belong to a live principal ($($unverifiedResult.VerificationError))" -Level Warning -Component 'MainProcessing' -CorrelationId $CorrelationId
                                }

                                # One removal per object with all of its verified orphaned SIDs, so the
                                # object is backed up once, before any entry is removed. Removing them one
                                # call at a time backed it up again after each removal, and a restore from
                                # the newest backup could not bring back the SIDs removed first.
                                $sidsToRemove = @($verifiedResults | ForEach-Object { $_.OrphanedSID } | Select-Object -Unique)
                                if ($sidsToRemove.Count -gt 0) {
                                    $objectDN = $currentObject.DistinguishedName
                                    $sidList = $sidsToRemove -join ', '
                                    $target = "$objectDN - SIDs: $sidList"
                                    if ($PSCmdlet.ShouldProcess($target, "Remove Orphaned SIDs")) {
                                        Write-StructuredLog "Removing orphaned SIDs: $sidList from $objectDN" -Level Verbose -Component 'MainProcessing' -CorrelationId $CorrelationId

                                        # Log security audit for SID removal attempt
                                        Write-ADOperationSecurityLog -OperationName 'OrphanedSID-Removal' -Outcome 'Attempt' -SecurityContext @{
                                            ObjectDN = $objectDN
                                            OrphanedSIDs = $sidList
                                            BackupPath = $BackupPath
                                            Operation = 'Remove-OrphanedSidEntry'
                                        } -CorrelationId $CorrelationId

                                        $removalParams = @{
                                            ObjectDN = $objectDN
                                            OrphanedSIDs = $sidsToRemove
                                            CorrelationId = $CorrelationId
                                        }
                                        if ($BackupPath) {
                                            $removalParams.BackupPath = $BackupPath
                                        }

                                        try {
                                            $removalResult = Remove-OrphanedSidEntry @removalParams
                                            $script:RemovalResults += $removalResult

                                            # Log successful SID removal
                                            Write-ADOperationSecurityLog -OperationName 'OrphanedSID-Removal' -Outcome 'Success' -SecurityContext @{
                                                ObjectDN = $objectDN
                                                OrphanedSIDs = $sidList
                                                BackupCreated = $removalResult.BackupCreated
                                                BackupPath = $removalResult.BackupPath
                                                RemovedCount = $removalResult.RemovedCount
                                            } -CorrelationId $CorrelationId
                                        } catch {
                                            # Log failed SID removal
                                            Write-ADOperationSecurityLog -OperationName 'OrphanedSID-Removal' -Outcome 'Failure' -SecurityContext @{
                                                ObjectDN = $objectDN
                                                OrphanedSIDs = $sidList
                                                ErrorMessage = $_.Exception.Message
                                            } -CorrelationId $CorrelationId
                                            throw
                                        }
                                    } else {
                                        Write-StructuredLog "WhatIf: Would remove orphaned SIDs: $sidList from $objectDN" -Level Verbose -Component 'MainProcessing' -CorrelationId $CorrelationId

                                        # Log WhatIf simulation for audit trail
                                        Write-ADOperationSecurityLog -OperationName 'OrphanedSID-Removal' -Outcome 'Attempt' -SecurityContext @{
                                            ObjectDN = $objectDN
                                            OrphanedSIDs = $sidList
                                            SimulationMode = $true
                                            WhatIfMode = $true
                                        } -CorrelationId $CorrelationId
                                        # Create a mock removal result for WhatIf mode
                                        $mockResult = [PSCustomObject]@{
                                            ObjectDN = $objectDN
                                            OrphanedSID = $sidList
                                            Success = $true
                                            ProcessingTime = [TimeSpan]::Zero
                                            ErrorMessage = $null
                                            RemovedSIDs = $sidsToRemove
                                            FailedSIDs = @()
                                            BlockedSIDs = @()
                                            SecurityValidation = 'WhatIf - Would Remove'
                                        }
                                        $script:RemovalResults += $mockResult
                                    }
                                }
                            }

                            return $orphanedResults
                        }
                    }
                    catch {
                        # Detection retries are exhausted, or removal failed. Either way the object
                        # is counted as an error and the run moves on to the next one.
                        $script:Statistics.ProcessingErrors++
                        Write-StructuredLog "Error processing object $($currentObject.DistinguishedName): $($_.Exception.Message)" -Level Error -Component 'MainProcessing' -CorrelationId $CorrelationId
                    }
                }

                # Show completion summary for this search base
                Write-StructuredLog "Completed $searchPath - Objects: $($objectArray.Count), Orphaned SIDs: $orphanedFoundCount" -Level Information -Component 'MainProcessing' -CorrelationId $CorrelationId
            }

            # Complete statistics
            $script:Statistics.Complete()

            # Get summary from streaming results manager
            $streamingSummary = $script:StreamingResults.GetSummary()

            # Generate processing summary with streaming results
            $processingResults = @{
                TotalObjectsProcessed = $script:Statistics.ProcessedObjects
                OrphanedSIDsFound = $script:Statistics.OrphanedSIDsFound
                UnverifiedSIDsFound = $script:Statistics.UnverifiedSIDsFound
                ProcessingErrors = $script:Statistics.ProcessingErrors
                ProcessingDuration = $script:Statistics.Duration
                ObjectsPerSecond = $script:Statistics.ObjectsPerSecond
                PeakMemoryUsageMB = $script:MemoryManager.GetPeakMemoryUsage()
                StreamingSummary = $streamingSummary
                RemovalResults = $script:RemovalResults
                CorrelationId = $CorrelationId
                # Store reference to streaming manager for later access
                StreamingManager = $script:StreamingResults
            }

            Write-StructuredLog "Main processing completed successfully" -Level Information -Component 'MainProcessing' -CorrelationId $CorrelationId
            return $processingResults

        }
        catch {
            $script:Statistics.CriticalErrors++
            Write-StructuredLog "Critical error in main processing: $($_.Exception.Message)" -Level Error -Component 'MainProcessing' -CorrelationId $CorrelationId
            throw
        }
    }
}
