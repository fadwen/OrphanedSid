#region Invoke-RestoreWorkflow.ps1 - Restore Workflow Orchestration Module

function Invoke-RestoreWorkflow {
    <#
    .SYNOPSIS
        Orchestrates complete ACL restoration workflow from backup to completion.

    .DESCRIPTION
        Central orchestration function that coordinates all aspects of ACL restoration:
        - Backup discovery and validation (supports bulk operations)
        - Target object verification
        - ACL application with safety checks
        - Result verification and reporting
        - Error handling and recovery

        This function implements the complete restore workflow with proper error
        handling, rollback capabilities, and comprehensive logging. It supports
        both single object restoration and bulk restoration for search base scopes.

    .PARAMETER TargetObjectDN
        Distinguished name of the object to restore ACL for, OR a search base DN
        for bulk restoration of all objects within that scope.
        Must be a valid Active Directory object DN.

    .PARAMETER BackupPath
        Directory containing backup files for automatic discovery.
        For single objects: finds the most recent backup for the specified object.
        For bulk operations: discovers all backup files within the search base scope.

    .PARAMETER BackupFile
        Specific backup file path for targeted restoration.
        Takes precedence over BackupPath parameter.

    .PARAMETER ValidationLevel
        Level of backup validation: Basic, Standard, or Comprehensive.
        Higher levels provide more thorough validation but take longer.

    .PARAMETER VerifyRestoration
        Whether to verify successful restoration after ACL application.
        Recommended for critical operations requiring confirmation.

    .PARAMETER WhatIf
        Preview restore operation without making actual changes.
        Shows what would be restored for validation purposes.

    .PARAMETER CorrelationId
        Unique identifier for tracking this workflow operation.

    .EXAMPLE
        PS> Invoke-RestoreWorkflow -TargetObjectDN "CN=TestUser,CN=Users,DC=contoso,DC=com" -BackupPath "C:\Backups"

        DESCRIPTION: Complete restore workflow using automatic backup discovery
        OUTPUT: RestoreWorkflowResult with detailed operation status
        USE CASE: Standard restoration for disaster recovery

    .EXAMPLE
        PS> Invoke-RestoreWorkflow -TargetObjectDN $dn -BackupFile $specificBackup -ValidationLevel Comprehensive -VerifyRestoration

        DESCRIPTION: High-assurance restore with comprehensive validation and verification
        OUTPUT: Detailed workflow result with verification status
        USE CASE: Critical system restoration requiring maximum validation

    .EXAMPLE
        PS> Invoke-RestoreWorkflow -TargetObjectDN $dn -BackupPath $path -WhatIf

        DESCRIPTION: Preview restore operation without making changes
        OUTPUT: Shows what would be restored for approval workflow
        USE CASE: Change management and approval processes

    .INPUTS
        [string] TargetObjectDN from pipeline or parameter
        [string] Backup file or directory paths

    .OUTPUTS
        [PSCustomObject] RestoreWorkflowResult with properties:
        - Success: Overall workflow success status
        - TargetObjectDN: DN of the processed object
        - WorkflowSteps: Array of completed workflow steps
        - BackupValidation: Backup validation results
        - TargetValidation: Target object validation results
        - ACLOperation: ACL application results
        - VerificationResult: Optional restoration verification
        - Duration: Total workflow execution time
        - CorrelationId: Tracking identifier

    .NOTES
        Author: Jeffrey Stuhr
        Blog: https://www.techbyjeff.net
        LinkedIn: https://www.linkedin.com/in/jeffrey-stuhr-034214aa/

        WORKFLOW STAGES:
        1. Input validation and parameter processing
        2. Backup discovery and validation
        3. Target object verification
        4. ACL application with safety checks
        5. Optional restoration verification
        6. Result compilation and reporting

        TROUBLESHOOTING:
        - For workflow failures: .\Troubleshooting\Common\Backup-Restore-Issues.md

    .LINK
        .\Troubleshooting\Common\Backup-Restore-Issues.md
        .\Documentation\RestoreOperations-Refactoring-Plan.md
    #>

    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('RestoreWorkflowResult')]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [ValidateNotNullOrEmpty()]
        [string]$TargetObjectDN,

        [Parameter()]
        [string]$BackupPath,

        [Parameter()]
        [string]$BackupFile,

        [Parameter()]
        [ValidateSet('Basic', 'Standard', 'Comprehensive')]
        [string]$ValidationLevel = 'Standard',

        [Parameter()]
        [switch]$VerifyRestoration,

        [Parameter()]
        [string]$CorrelationId = [System.Guid]::NewGuid().ToString()
    )

    begin {
        Write-Verbose "Starting restore workflow orchestration - CorrelationId: $CorrelationId"

        # Import required modules if not already loaded
        if (-not (Get-Command Test-BackupIntegrity -ErrorAction SilentlyContinue)) {
            . $PSScriptRoot\Test-BackupIntegrity.ps1
        }

        if (-not (Get-Command Set-ObjectACL -ErrorAction SilentlyContinue)) {
            . $PSScriptRoot\Restore-ACLOperation.ps1
        }

        if (-not (Get-Command Get-BackupFileForRestore -ErrorAction SilentlyContinue)) {
            . $PSScriptRoot\Get-BackupFileForRestore.ps1
        }

        if (-not (Get-Command ConvertTo-NormalizedDistinguishedName -ErrorAction SilentlyContinue)) {
            $utilitiesPath = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'Utilities'
            . (Join-Path -Path $utilitiesPath -ChildPath 'ConvertTo-NormalizedDistinguishedName.ps1')
        }
    }

    process {
        Write-Verbose "Starting restore workflow for target: $TargetObjectDN"
        Write-Verbose "Starting restore workflow"
        
        # The target is brought into the spelling that the directory returns, without blanks
        # around its separators: it is compared with the names that the backups record, and the
        # directory accepts a name that is typed as 'CN=Alice, OU=Sales, DC=contoso, DC=com'.
        $TargetObjectDN = ConvertTo-NormalizedDistinguishedName -DistinguishedName $TargetObjectDN
        
        # Validate target DN format after trimming. The attribute that names an object is set by
        # its class, so any attribute name is taken, as Test-ValidDistinguishedName does.
        if (-not ($TargetObjectDN -match '^([a-z][a-z0-9.-]*|\d+(\.\d+)+)=')) {
            $exception = [System.ArgumentException]::new('Invalid target object DN format')
            $category = [System.Management.Automation.ErrorCategory]::InvalidArgument
            $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                $exception, 'RestoreTargetNameInvalid', $category, $TargetObjectDN)
            $PSCmdlet.ThrowTerminatingError($errorRecord)
        }
        
        # Validate that either BackupFile or BackupPath is specified
        if (-not $BackupFile -and -not $BackupPath) {
            $exception = [System.ArgumentException]::new('Either BackupFile or BackupPath must be specified')
            $category = [System.Management.Automation.ErrorCategory]::InvalidArgument
            $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                $exception, 'BackupSourceMissing', $category, $TargetObjectDN)
            $PSCmdlet.ThrowTerminatingError($errorRecord)
        }

        # Validate file/path existence and security
        if ($BackupFile) {
            # Resolved as PowerShell sees it: [IO.Path]::GetFullPath uses the process directory, not
            # the current location, so a relative path pointed at the user profile (#80)
            $BackupFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($BackupFile)
            
            # Validate file extension
            $allowedExtensions = @('.xml', '.clixml')
            $fileExtension = [System.IO.Path]::GetExtension($BackupFile).ToLower()
            if ($fileExtension -notin $allowedExtensions) {
                $exception = [System.ArgumentException]::new('Invalid file extension. Only .xml and .clixml files are allowed')
                $category = [System.Management.Automation.ErrorCategory]::InvalidArgument
                $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                    $exception, 'BackupFileExtensionInvalid', $category, $BackupFile)
                $PSCmdlet.ThrowTerminatingError($errorRecord)
            }
            
            # Check if file exists
            if (-not (Test-Path -LiteralPath $BackupFile -PathType Leaf)) {
                $exception = [System.IO.FileNotFoundException]::new("Backup file not found: $BackupFile")
                $category = [System.Management.Automation.ErrorCategory]::ObjectNotFound
                $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                    $exception, 'BackupFileNotFound', $category, $BackupFile)
                $PSCmdlet.ThrowTerminatingError($errorRecord)
            }
        }

        if ($BackupPath) {
            # Resolved as PowerShell sees it: [IO.Path]::GetFullPath uses the process directory, not
            # the current location, so a relative path pointed at the user profile (#80)
            $BackupPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($BackupPath)
            
            # Check if directory exists
            if (-not (Test-Path -LiteralPath $BackupPath -PathType Container)) {
                $exception = [System.IO.DirectoryNotFoundException]::new("Backup directory not found: $BackupPath")
                $category = [System.Management.Automation.ErrorCategory]::ObjectNotFound
                $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                    $exception, 'BackupDirectoryNotFound', $category, $BackupPath)
                $PSCmdlet.ThrowTerminatingError($errorRecord)
            }
        }

        $workflowStartTime = Get-Date
        $workflowSteps = @()
        $overallSuccess = $false
        $errorMessage = $null
        $allResults = @()

        try {
            Write-Verbose "Starting restore workflow for: $TargetObjectDN - CorrelationId: $CorrelationId"

            # Step 1: Validate and prepare inputs
            $workflowSteps += [PSCustomObject]@{
                StepName = "Input Validation"
                StartTime = Get-Date
                Status = "InProgress"
                Duration = $null
                ErrorMessage = $null
            }

            $workflowSteps[-1].Status = "Completed"
            $workflowSteps[-1].Duration = (Get-Date) - $workflowSteps[-1].StartTime

            # Step 2: Determine restore mode and discover backups
            $workflowSteps += [PSCustomObject]@{
                StepName = "Backup Discovery and Mode Detection"
                StartTime = Get-Date
                Status = "InProgress"
                Duration = $null
                BackupFiles = @()
                RestoreMode = $null
                ErrorMessage = $null
            }

            $backupFilesToProcess = @()
            $restoreMode = "Single"

            # The file and the folder were resolved and checked before the try, where a path that
            # does not exist, or a file of another type, ends the function with an error of its own.
            if ($BackupFile) {
                # Single file mode - specific backup file provided
                $backupFilesToProcess = @($BackupFile)
                $restoreMode = "Single"
            } else {
                # Directory mode - discover backup files. A folder that holds none, and a single
                # object that has no backup there, are raised by the selection, and the catch at the
                # end of this try reports them like any other failure of the workflow.
                $selection = Get-BackupFileForRestore -TargetObjectDN $TargetObjectDN -BackupPath $BackupPath
                $restoreMode = $selection.RestoreMode
                $backupFilesToProcess = @($selection.BackupFiles)
            }

            $workflowSteps[-1].Status = "Completed"
            $workflowSteps[-1].Duration = (Get-Date) - $workflowSteps[-1].StartTime
            $workflowSteps[-1].BackupFiles = $backupFilesToProcess
            $workflowSteps[-1].RestoreMode = $restoreMode

            Write-Verbose "Restore mode: $restoreMode - Processing $($backupFilesToProcess.Count) backup files"

            # Step 3: Process each backup file
            $workflowSteps += [PSCustomObject]@{
                StepName = "Bulk Restoration Processing"
                StartTime = Get-Date
                Status = "InProgress"
                Duration = $null
                ProcessedObjects = 0
                SuccessfulRestores = 0
                FailedRestores = 0
                ErrorMessage = $null
            }

            foreach ($fileToProcess in $backupFilesToProcess) {
                # Why this file was not restored: set by the check of the object below and by the
                # catch, and reported after the try, so that both give the same failed result
                $fileFailure = $null
                try {
                    Write-Verbose "Processing backup file: $fileToProcess"

                    # Load backup data to get the actual target object DN
                    $backupData = Import-Clixml -LiteralPath $fileToProcess -ErrorAction Stop
                    $actualTargetDN = $backupData.ObjectDN

                    # A backup chosen by file must be of the object asked for. Directory mode already
                    # selects files by the DN they record. The recorded name is compared in the
                    # spelling that the target was brought into at the start.
                    $recordedName = [string]$actualTargetDN
                    $recordedName = ConvertTo-NormalizedDistinguishedName -DistinguishedName $recordedName
                    $ignoreCase = [System.StringComparison]::OrdinalIgnoreCase
                    $isOtherObject = $restoreMode -eq 'Single' -and $BackupFile -and
                        -not [string]::Equals($recordedName, $TargetObjectDN, $ignoreCase)

                    if ($isOtherObject) {
                        $fileFailure = "Backup file $fileToProcess is a backup of '$actualTargetDN', not of '$TargetObjectDN'"
                    } elseif (-not $WhatIfPreference -and
                        -not $PSCmdlet.ShouldProcess($actualTargetDN, "Restore ACL from backup $fileToProcess")) {
                        # Set-ObjectACL honours $WhatIfPreference and prints the preview itself, so under
                        # -WhatIf the restore still runs through validation; this guard only answers -Confirm.
                        Write-Verbose "Restore declined at the confirmation prompt: $actualTargetDN"
                    } else {
                        # Restore this individual object
                        $individualResult = Restore-IndividualObject -TargetObjectDN $actualTargetDN -BackupData $backupData -BackupFile $fileToProcess -ValidationLevel $ValidationLevel -VerifyRestoration:$VerifyRestoration -CorrelationId $CorrelationId

                        # Add workflow-specific type name
                        $individualResult.PSObject.TypeNames.Insert(0, 'RestoreWorkflowResult')

                        $allResults += $individualResult
                        $workflowSteps[-1].ProcessedObjects++

                        if ($individualResult.Success) {
                            $workflowSteps[-1].SuccessfulRestores++
                            Write-Verbose "Successfully restored: $actualTargetDN"
                        } else {
                            $workflowSteps[-1].FailedRestores++
                            Write-Warning "Failed to restore: $actualTargetDN - $($individualResult.ErrorMessage)"
                        }
                    }
                }
                catch {
                    # Preserve original error message for debugging
                    $fileFailure = $_.Exception.Message
                }

                if ($null -ne $fileFailure) {
                    $workflowSteps[-1].FailedRestores++
                    $workflowSteps[-1].ProcessedObjects++

                    # A file that was given by name was given for this target, so the result is
                    # the target's: Restore-OrphanedSidBackup returns one result for each target,
                    # and its CSV has a row for it. For a file that was found in a folder, the
                    # object is known only as far as the file could be read.
                    $failedTarget = "Unknown (from $fileToProcess)"
                    if ($BackupFile) {
                        $failedTarget = $TargetObjectDN
                    }

                    $failedResult = [PSCustomObject]@{
                        Success = $false
                        TargetObjectDN = $failedTarget
                        EntriesRestored = 0
                        ErrorMessage = $fileFailure
                        BackupFile = $fileToProcess
                        CorrelationId = $CorrelationId
                    }
                    $failedResult.PSTypeNames.Insert(0, 'RestoreWorkflowResult')
                    $allResults += $failedResult

                    Write-Warning "Failed to process backup file $fileToProcess : $fileFailure"
                }
            }

            $workflowSteps[-1].Status = "Completed"
            $workflowSteps[-1].Duration = (Get-Date) - $workflowSteps[-1].StartTime

            # Determine overall success
            $successfulRestores = $workflowSteps[-1].SuccessfulRestores
            $totalProcessed = $workflowSteps[-1].ProcessedObjects
            $overallSuccess = ($successfulRestores -gt 0) -and ($workflowSteps[-1].FailedRestores -eq 0)

            if ($restoreMode -eq "Bulk") {
                Write-Verbose "Bulk restore completed - $successfulRestores/$totalProcessed successful - CorrelationId: $CorrelationId"
            } else {
                Write-Verbose "Single restore completed - Success: $overallSuccess - CorrelationId: $CorrelationId"
            }
        }
        catch {
            $overallSuccess = $false
            $errorMessage = $_.Exception.Message

            # Mark current step as failed if in progress
            if ($workflowSteps.Count -gt 0 -and $workflowSteps[-1].Status -eq "InProgress") {
                $workflowSteps[-1].Status = "Failed"
                $workflowSteps[-1].Duration = (Get-Date) - $workflowSteps[-1].StartTime
                $workflowSteps[-1].ErrorMessage = $errorMessage
            }

            Write-Error "Restore workflow failed for $TargetObjectDN : $errorMessage - CorrelationId: $CorrelationId"
        }

        $workflowDuration = (Get-Date) - $workflowStartTime

        # Compile comprehensive workflow result
        if ($restoreMode -eq "Bulk") {
            # Objects that failed without an exception leave $errorMessage unset; the summary, and the
            # -OutputPath CSV row built from it, would then say nothing about why the restore failed
            if (-not $overallSuccess -and -not $errorMessage) {
                $failedResults = @($allResults | Where-Object { -not $_.Success })
                $processedCount = $workflowSteps[-1].ProcessedObjects
                if ($failedResults.Count -gt 0) {
                    $reasons = @($failedResults | ForEach-Object { $_.ErrorMessage } | Where-Object { $_ } | Select-Object -Unique)
                    $errorMessage = "$($failedResults.Count) of $processedCount objects failed to restore"
                    if ($reasons.Count -gt 0) {
                        $errorMessage += ": $($reasons -join '; ')"
                    }
                } else {
                    $errorMessage = 'No objects were restored'
                }
            }

            # Return summary result for bulk operations
            $result = [PSCustomObject]@{
                Success = $overallSuccess
                TargetObjectDN = $TargetObjectDN
                RestoreMode = $restoreMode
                TotalObjects = $workflowSteps[-1].ProcessedObjects
                SuccessfulRestores = $workflowSteps[-1].SuccessfulRestores
                FailedRestores = $workflowSteps[-1].FailedRestores
                IndividualResults = $allResults
                EntriesRestored = [int](($allResults | Where-Object { $_.Success } | Measure-Object -Property EntriesRestored -Sum).Sum -as [int])
                WorkflowSteps = $workflowSteps
                ValidationLevel = $ValidationLevel
                Duration = $workflowDuration
                WhatIfMode = $WhatIfPreference
                CorrelationId = $CorrelationId
                CompletedAt = Get-Date
                ErrorMessage = if ($overallSuccess) { $null } else { $errorMessage }
            }
            $result.PSTypeNames.Insert(0, 'RestoreWorkflowResult')
        } else {
            # Return individual result for single operations
            if ($allResults.Count -gt 0) {
                $result = $allResults[0]
                # Add workflow-level properties
                $result | Add-Member -MemberType NoteProperty -Name "WorkflowSteps" -Value $workflowSteps -Force
                $result | Add-Member -MemberType NoteProperty -Name "ValidationLevel" -Value $ValidationLevel -Force
                $result | Add-Member -MemberType NoteProperty -Name "Duration" -Value $workflowDuration -Force
                $result | Add-Member -MemberType NoteProperty -Name "WhatIfMode" -Value $WhatIfPreference -Force
                $result | Add-Member -MemberType NoteProperty -Name "CompletedAt" -Value (Get-Date) -Force
            } else {
                # Fallback result
                $result = [PSCustomObject]@{
                    Success = $overallSuccess
                    TargetObjectDN = $TargetObjectDN
                    RestoreMode = $restoreMode
                    EntriesRestored = 0
                    WorkflowSteps = $workflowSteps
                    ValidationLevel = $ValidationLevel
                    Duration = $workflowDuration
                    WhatIfMode = $WhatIfPreference
                    CorrelationId = $CorrelationId
                    CompletedAt = Get-Date
                    ErrorMessage = if ($overallSuccess) { $null } else { $errorMessage }
                }
                $result.PSTypeNames.Insert(0, 'RestoreWorkflowResult')
            }
        }

        Write-Verbose "Restore workflow result compiled - Success: $overallSuccess - Duration: $($workflowDuration.TotalMilliseconds)ms - CorrelationId: $CorrelationId"
        return $result
    }

    end {
        Write-Verbose "Completed restore workflow orchestration - CorrelationId: $CorrelationId"
    }
}


function Restore-IndividualObject {
    <#
    .SYNOPSIS
        Restores a single object from its backup data.

    .DESCRIPTION
        Helper function that handles the restoration of a single Active Directory
        object from backup data. This function performs all the validation,
        verification, and ACL application steps for individual objects.

    .PARAMETER TargetObjectDN
        Distinguished name of the specific object to restore.

    .PARAMETER BackupData
        Pre-loaded backup data for the object.

    .PARAMETER BackupFile
        Path to the backup file (for reference/logging).

    .PARAMETER ValidationLevel
        Level of validation to perform.

    .PARAMETER VerifyRestoration
        Whether to verify the restoration was successful.

    .PARAMETER CorrelationId
        Correlation ID for tracking.

    .OUTPUTS
        [PSCustomObject] Individual restore result
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TargetObjectDN,

        [Parameter(Mandatory)]
        [PSCustomObject]$BackupData,

        [Parameter(Mandatory)]
        [string]$BackupFile,

        [Parameter()]
        [string]$ValidationLevel = 'Standard',

        [Parameter()]
        [switch]$VerifyRestoration,

        [Parameter()]
        [string]$CorrelationId
    )

    $startTime = Get-Date

    # The result of a restore that did not succeed, with the warning that goes with it. The three
    # steps below return it for a step that reports a failure, and the catch returns it for a
    # step that raised an error, so that both are reported in the same way.
    $newFailedResult = {
        param([string]$Reason)

        $errorResult = [PSCustomObject]@{
            Success = $false
            TargetObjectDN = $TargetObjectDN
            BackupFile = $BackupFile
            EntriesRestored = 0
            Duration = (Get-Date) - $startTime
            CorrelationId = $CorrelationId
            ErrorMessage = $Reason
        }
        $errorResult.PSTypeNames.Insert(0, 'RestoreWorkflowResult')

        Write-Warning "Failed to restore object: $TargetObjectDN - $Reason"
        $errorResult
    }

    try {
        Write-Verbose "Restoring individual object: $TargetObjectDN from $BackupFile"

        # Validate backup data
        $backupValidation = Test-BackupIntegrity -BackupData $BackupData -ExpectedObjectDN $TargetObjectDN -ValidationLevel $ValidationLevel -CorrelationId $CorrelationId

        if (-not $backupValidation.IsValid) {
            return (& $newFailedResult "Backup validation failed: $($backupValidation.ErrorMessage)")
        }

        # Validate target object exists and is accessible
        $targetValidation = Get-RestorationTarget -TargetObjectDN $TargetObjectDN -CorrelationId $CorrelationId

        if (-not $targetValidation.IsValid) {
            return (& $newFailedResult "Target validation failed: $($targetValidation.Issues -join '; ')")
        }

        # Apply ACL restoration. The target was validated above; Set-ObjectACL does not check it.
        $aclOperation = Set-ObjectACL -TargetObjectDN $TargetObjectDN -BackupData $BackupData -VerifyApplication:$VerifyRestoration -CorrelationId $CorrelationId

        if (-not $aclOperation.Success) {
            # Set-ObjectACL's message already starts "ACL application failed:" or "ACL operation failed:"
            return (& $newFailedResult $aclOperation.ErrorMessage)
        }

        # Create success result
        $result = [PSCustomObject]@{
            Success = $true
            TargetObjectDN = $TargetObjectDN
            BackupFile = $BackupFile
            EntriesRestored = [int]$(if ($aclOperation.ModificationsApplied) { $aclOperation.ModificationsApplied } else { 0 })
            BackupValidation = $backupValidation
            TargetValidation = $targetValidation
            ACLOperation = $aclOperation
            Duration = (Get-Date) - $startTime
            CorrelationId = $CorrelationId
            ErrorMessage = $null
        }

        $result.PSTypeNames.Insert(0, 'RestoreWorkflowResult')
        Write-Verbose "Successfully restored object: $TargetObjectDN ($($result.EntriesRestored) entries)"
        return $result
    }
    catch {
        return (& $newFailedResult $_.Exception.Message)
    }
}


#endregion
