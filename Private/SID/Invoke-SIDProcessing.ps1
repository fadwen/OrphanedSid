#Requires -Version 5.1

#region SID Processing Orchestration Functions

function Find-OrphanedSIDsInObject {
    <#
    .SYNOPSIS
        Orchestrates orphaned SID detection in Active Directory objects

    .DESCRIPTION
        Main orchestration function that coordinates the complete orphaned SID detection
        workflow across multiple specialized modules. This function manages the entire
        process from security descriptor retrieval through result object creation,
        providing comprehensive error handling and processing statistics.

        The orchestration workflow includes:
        - Input validation and error object filtering
        - Security descriptor retrieval using multiple strategies
        - Access rule processing and identity resolution
        - Orphaned SID detection and analysis
        - Result object creation and metadata population
        - Processing statistics and memory management

    .PARAMETER ADObject
        Active Directory objects to process. Can be from Get-ADObject output,
        background job results, or pipeline input. Objects must have
        DistinguishedName and nTSecurityDescriptor properties.

    .PARAMETER IncludeInherited
        When specified, includes inherited ACL entries in the orphaned SID analysis.
        By default, only explicit (non-inherited) ACL entries are processed.

    .PARAMETER CurrentDomainSID
        The SID of the current domain for context analysis. Used to categorize
        SIDs as local, foreign, or unknown domain objects.

    .PARAMETER MaxRetries
        Retries after the first attempt for each directory lookup of a SID whose failure looks
        transient (0-10, default 3). Passed through Test-AccessRuleForOrphanedSID to
        Test-OrphanedSID; the public commands' -MaxRetries arrives here.

    .PARAMETER CorrelationId
        Unique identifier for tracking this processing operation across logs
        and audit trails. Generated automatically if not provided.

    .EXAMPLE
        PS> $adObjects | Find-OrphanedSIDsInObject

        DESCRIPTION: Basic orphaned SID detection using pipeline processing
        OUTPUT: Array of OrphanedSIDResult objects for all orphaned SIDs found
        USE CASE: Standard security audit of AD objects from Get-ADObject

    .EXAMPLE
        PS> Find-OrphanedSIDsInObject -ADObject $adObjects -IncludeInherited -CurrentDomainSID $domainSID

        DESCRIPTION: Comprehensive analysis including inherited permissions and domain context
        OUTPUT: Complete orphaned SID analysis with enhanced categorization
        BUSINESS CASE: Thorough security audit including all permission sources

    .EXAMPLE
        PS> $jobResults | Find-OrphanedSIDsInObject -CorrelationId $correlationId

        DESCRIPTION: Processing background job results with correlation tracking
        OUTPUT: Orphaned SID results with full audit trail correlation

    .OUTPUTS
        [OrphanedSIDResult[]] Array of comprehensive result objects containing
        detailed information about discovered orphaned SIDs, including object
        context, analysis metadata, and processing information.

    .NOTES
        ORCHESTRATION WORKFLOW:
        1. Input validation and error object filtering
        2. Security descriptor retrieval (delegated to Get-SecurityDescriptor module)
        3. Access rule iteration and processing
        4. Identity resolution and orphaned SID testing (delegated to Resolve-SIDIdentity module)
        5. Result object creation (delegated to New-SIDResult module)
        6. Processing statistics compilation and memory cleanup

        PROCESSING STATISTICS:
        - Total objects processed and skipped
        - Access rules processed and orphaned SIDs found
        - Error counts and success rates
        - Processing timing and performance metrics
        - Memory usage and cleanup statistics

        ERROR HANDLING:
        - Graceful handling of error objects from pipeline
        - Individual access rule error containment
        - Comprehensive logging with correlation tracking
        - Processing statistics for troubleshooting
        - Memory cleanup for large datasets

        INTEGRATION POINTS:
        - Get-ObjectAccessRule for security descriptor processing
        - Test-AccessRuleForOrphanedSID for identity resolution
        - Correlation tracking across all processing modules
        - Enterprise logging and audit trail integration

        TROUBLESHOOTING:
        - For orchestration issues: .\Troubleshooting\Common\SID-Processing-Orchestration-Issues.md
        - For performance problems: .\Troubleshooting\Performance\Performance-Tuning.md
        - For memory management: .\Troubleshooting\Performance\Memory-Management-Issues.md
    #>

    [CmdletBinding()]
    [OutputType([OrphanedSIDResult[]])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [PSObject[]]$ADObject,

        [Parameter()]
        [switch]$IncludeInherited,

        [Parameter()]
        [string]$CurrentDomainSID,

        [Parameter()]
        [ValidateRange(0, 10)]
        [int]$MaxRetries = 3,

        [Parameter()]
        [string]$CorrelationId = [System.Guid]::NewGuid().ToString()
    )

    process {
        foreach ($obj in $ADObject) {
            $results = [System.Collections.Generic.List[OrphanedSIDResult]]::new()

            # Initialize processing statistics for this object
            $processingStats = @{
                ObjectDN = "Unknown"
                StartTime = Get-Date
                ProcessedSIDs = 0
                SkippedSIDs = 0
                OrphanedSIDsFound = 0
                UnverifiedSIDsFound = 0
                ErrorsEncountered = 0
                AccessRulesRetrieved = 0
                ProcessingMethod = "Orchestrated-Workflow"
            }

            try {
                Write-StructuredLog "Starting orchestrated orphaned SID detection for object" -Level Debug -CorrelationId $CorrelationId

                # Handle error objects that may come through the pipeline
                if ($obj.PSObject.Properties['IsError'] -and $obj.IsError -eq $true) {
                    Write-StructuredLog "Skipping error object: $($obj.ErrorMessage)" -Level Debug -CorrelationId $CorrelationId
                    $processingStats.ErrorsEncountered++
                    continue
                }

                # Validate that this is an AD object with required properties. They are read by
                # name, because the input is whatever came down the pipeline: read as a member,
                # a property that is not there is an error under strict mode.
                $nameProperty = $obj.PSObject.Properties['DistinguishedName']
                if ($null -eq $nameProperty -or -not $nameProperty.Value) {
                    Write-StructuredLog "Object missing DistinguishedName property, skipping" -Level Debug -CorrelationId $CorrelationId
                    $processingStats.SkippedSIDs++
                    continue
                }

                $objectDN = $nameProperty.Value
                $processingStats.ObjectDN = $objectDN
                Write-StructuredLog "Processing object: $objectDN" -Level Debug -CorrelationId $CorrelationId

                # Check for security descriptor
                $descriptorProperty = $obj.PSObject.Properties['nTSecurityDescriptor']
                if ($null -eq $descriptorProperty -or -not $descriptorProperty.Value) {
                    Write-StructuredLog "No security descriptor found for $objectDN" -Level Debug -CorrelationId $CorrelationId
                    $processingStats.SkippedSIDs++
                    continue
                }

                # Delegate security descriptor processing to specialized module
                $accessRules = Get-ObjectAccessRule -ADObject $obj -IncludeInherited:$IncludeInherited -CorrelationId $CorrelationId

                if (-not $accessRules) {
                    Write-StructuredLog "No access rules retrieved for $objectDN" -Level Debug -CorrelationId $CorrelationId
                    $processingStats.SkippedSIDs++
                    continue
                }

                # @(): an object with one access rule gives one rule, not a collection of one, and
                # under strict mode one object has no Count
                $ruleCount = @($accessRules).Count
                $processingStats.AccessRulesRetrieved = $ruleCount
                Write-StructuredLog "Retrieved $ruleCount access rules for processing" -Level Debug -CorrelationId $CorrelationId

                # Process each access rule for orphaned SIDs using specialized identity resolution
                foreach ($rule in $accessRules) {
                    try {
                        # Delegate identity resolution and orphaned SID testing to specialized module
                        $orphanedResult = Test-AccessRuleForOrphanedSID -AccessRule $rule -ObjectDN $objectDN -ObjectClass $obj.ObjectClass -CurrentDomainSID $CurrentDomainSID -MaxRetries $MaxRetries -CorrelationId $CorrelationId

                        if ($orphanedResult) {
                            $results.Add($orphanedResult)
                            if ($orphanedResult.VerificationStatus -eq 'Unverified') {
                                $processingStats.UnverifiedSIDsFound++
                            } else {
                                $processingStats.OrphanedSIDsFound++
                            }
                            Write-StructuredLog "$($orphanedResult.VerificationStatus) SID result object created for $objectDN" -Level Verbose -CorrelationId $CorrelationId
                        }

                        $processingStats.ProcessedSIDs++
                    }
                    catch {
                        Write-StructuredLog "Error processing access rule for $objectDN : $($_.Exception.Message)" -Level Warning -CorrelationId $CorrelationId
                        $processingStats.SkippedSIDs++
                        $processingStats.ErrorsEncountered++
                    }
                }

                # Calculate processing duration and log statistics
                $processingStats.EndTime = Get-Date
                $processingStats.Duration = ($processingStats.EndTime - $processingStats.StartTime).TotalMilliseconds

                Write-StructuredLog "Completed processing $objectDN - Processed: $($processingStats.ProcessedSIDs), Orphaned found: $($processingStats.OrphanedSIDsFound), Duration: $($processingStats.Duration)ms" -Level Debug -CorrelationId $CorrelationId

                # Add processing statistics to results if any orphaned SIDs were found
                if ($results.Count -gt 0) {
                    foreach ($result in $results) {
                        if (-not $result.PSObject.Properties['ProcessingStatistics']) {
                            $result | Add-Member -NotePropertyName 'ProcessingStatistics' -NotePropertyValue $processingStats
                        }
                    }
                }

                # Clean up access rules reference to help with memory management
                $accessRules = $null

                # Periodic garbage collection for large processing runs
                if ($processingStats.ProcessedSIDs -gt 0 -and $processingStats.ProcessedSIDs % 100 -eq 0) {
                    Write-StructuredLog "Performing periodic garbage collection after processing $($processingStats.ProcessedSIDs) SIDs" -Level Debug -CorrelationId $CorrelationId
                    [System.GC]::Collect()
                    [System.GC]::WaitForPendingFinalizers()
                }

                # Emit this object's results and carry on: a return here would end the foreach and skip
                # every object after the first when several arrive by parameter
                $results.ToArray()
            }
            catch {
                $processingStats.ErrorsEncountered++
                $processingStats.EndTime = Get-Date
                Write-StructuredLog "Error in orchestrated processing for object $($processingStats.ObjectDN) : $($_.Exception.Message)" -Level Error -CorrelationId $CorrelationId

                # Log final processing statistics even on error
                Write-StructuredLog "Processing statistics for $($processingStats.ObjectDN) : Processed: $($processingStats.ProcessedSIDs), Errors: $($processingStats.ErrorsEncountered), Orphaned found: $($processingStats.OrphanedSIDsFound)" -Level Debug -CorrelationId $CorrelationId

                $results.ToArray()
            }
        }
    }
}

#endregion
