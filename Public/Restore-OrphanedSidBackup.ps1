function Restore-OrphanedSidBackup {
    <#
    .EXTERNALHELP OrphanedSid-Help.xml
    .SYNOPSIS
        Restores Active Directory ACLs from a backup folder or file written by Remove-OrphanedSid.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'BackupPath')]
    [OutputType('RestoreWorkflowResult')]
    param(
        # The positions are written out. With one parameter set PowerShell gave them by the
        # order of declaration; with two it gives none, and a call that passes the target and
        # the folder by position would no longer bind. They are the positions the command had.

        # [object[]], not [string[]]: by-property binding asks an AD object for 'TargetObjectDN'
        # before the aliases, the AD adapter answers with an empty collection, and binding failed.
        # Each item is read by ConvertTo-DistinguishedName instead.
        [Parameter(Mandatory, ValueFromPipeline, Position = 0)]
        [Alias('DistinguishedName', 'SearchBase')]
        [object[]]$TargetObjectDN,

        [Parameter(Mandatory, ParameterSetName = 'BackupPath', Position = 1)]
        [ValidateScript({
            if (-not (Test-Path -LiteralPath $_ -PathType Container)) {
                throw "Backup folder not found: $_"
            }
            $true
        })]
        [string]$BackupPath,

        # One backup file by name, in place of the folder. The workflow refuses a file that is a
        # backup of another object than the target, so the target is asked for here as well.
        # It has no position: the second value by position is the folder.
        [Parameter(Mandatory, ParameterSetName = 'BackupFile')]
        [ValidateScript({
            if (-not (Test-Path -LiteralPath $_ -PathType Leaf)) {
                throw "Backup file not found: $_"
            }
            $true
        })]
        [string]$BackupFile,

        [Parameter()]
        [switch]$Force,

        [Parameter(Position = 2)]
        [ValidateScript({
            $directory = Split-Path -Parent $_
            if (-not $directory) { $directory = (Get-Location).Path }
            if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
                throw "The folder for -OutputPath does not exist: $directory"
            }
            $true
        })]
        [string]$OutputPath,

        [Parameter(Position = 3)]
        [string]$LogPath,

        [Parameter(Position = 4)]
        [string]$CorrelationId = [System.Guid]::NewGuid().ToString(),

        [Parameter(Position = 5)]
        [ValidateSet('Critical', 'Error', 'Warning', 'Information', 'Debug', 'Verbose')]
        [string]$LogLevel = 'Information',

        [Parameter()]
        [switch]$SuppressConsoleOutput
    )

    begin {
        if ($Force) {
            $ConfirmPreference = 'None'
        }

        $sessionParams = @{
            CommandName            = $MyInvocation.MyCommand.Name
            LogPath                = $LogPath
            CorrelationId          = $CorrelationId
            LogLevel               = $LogLevel
            LogLevelBound          = $PSBoundParameters.ContainsKey('LogLevel')
            SuppressConsoleOutput  = $SuppressConsoleOutput
            RequireActiveDirectory = $true
        }
        try {
            $null = Start-OrphanedSidSession @sessionParams
        } catch {
            # Exception to ERR-11: a failure of the start-up ends the calling script, as a failure
            # in the end block does and as Documentation/Automation.md tells callers.
            # ThrowTerminatingError() would end this command only, and a script with no try
            # around the call would carry on with its next line.
            Write-Error -ErrorRecord $_ -ErrorAction Stop
        }

        $targets = [System.Collections.Generic.List[string]]::new()
    }

    process {
        foreach ($dn in @(ConvertTo-DistinguishedName -InputObject $TargetObjectDN)) {
            $targets.Add($dn)
        }
    }

    end {
        try {
            # The check is a function of its own so that its error enters the catch below, which
            # is what ends the calling script.
            Assert-DistinguishedNameInput -DistinguishedName $targets -InputKind RestoreTarget
            $targetList = $targets -join ', '
            $fromFile = $PSCmdlet.ParameterSetName -eq 'BackupFile'
            $backupSource = $BackupPath
            $sourceKind = 'folder'
            if ($fromFile) {
                $backupSource = $BackupFile
                $sourceKind = 'file'
            }
            if (-not $PSCmdlet.ShouldProcess($targetList, "Restore ACLs from backup $sourceKind $backupSource")) {
                if (-not $WhatIfPreference) {
                    Write-StructuredLog "Restore declined at the confirmation prompt for: $targetList" -Level Warning -Component 'Main' -CorrelationId $CorrelationId
                    return
                }
            }

            $allResults = [System.Collections.Generic.List[object]]::new()
            foreach ($target in $targets) {
                Write-StructuredLog "Starting restore for: $target" -Level Information -Component 'Main' -CorrelationId $CorrelationId

                $restoreParameters = @{
                    TargetObjectDN = $target
                    CorrelationId  = $CorrelationId
                }
                if ($fromFile) {
                    $restoreParameters.BackupFile = $BackupFile
                } else {
                    $restoreParameters.BackupPath = $BackupPath
                }
                if ($WhatIfPreference) {
                    $restoreParameters.WhatIf = $true
                }

                try {
                    $result = Start-OrchestrationWorkflow -OperationType 'Restore' -Parameters $restoreParameters -CorrelationId $CorrelationId
                    if ($result) { $allResults.Add($result) }
                }
                catch {
                    Write-StructuredLog "Restore failed for $target : $($_.Exception.Message)" -Level Error -Component 'Main' -CorrelationId $CorrelationId
                    $allResults.Add([PSCustomObject]@{
                        PSTypeName     = 'RestoreWorkflowResult'
                        Success        = $false
                        TargetObjectDN = $target
                        EntriesRestored = 0
                        ErrorMessage   = $_.Exception.Message
                        CorrelationId  = $CorrelationId
                    })
                }
            }

            foreach ($result in $allResults) {
                Write-Output $result
            }

            $successful = @($allResults | Where-Object { $_.Success -eq $true }).Count
            $failed = @($allResults | Where-Object { $_.Success -ne $true }).Count
            # Added up here and not with Measure-Object. When no restore succeeded it has no input
            # and returns nothing, and under strict mode reading Sum from nothing is an error:
            # it reached the catch below and ended the calling script for a restore that had
            # only failed.
            $entries = 0
            foreach ($restored in $allResults) {
                if ($restored.Success -eq $true) {
                    $entries += [int]$restored.EntriesRestored
                }
            }

            Write-StructuredLog '=== RESTORE OPERATION SUMMARY ===' -Level Information -Component 'Summary' -CorrelationId $CorrelationId
            Write-StructuredLog "Total restore operations: $($allResults.Count)" -Level Information -Component 'Summary' -CorrelationId $CorrelationId
            Write-StructuredLog "Successful restores: $successful" -Level Information -Component 'Summary' -CorrelationId $CorrelationId
            Write-StructuredLog "Failed restores: $failed" -Level Information -Component 'Summary' -CorrelationId $CorrelationId
            if ($entries -gt 0) {
                Write-StructuredLog "Total ACL entries restored: $entries" -Level Information -Component 'Summary' -CorrelationId $CorrelationId
            }
            Write-StructuredLog "Backup source: $backupSource" -Level Information -Component 'Summary' -CorrelationId $CorrelationId

            if ($OutputPath -and $allResults.Count -gt 0) {
                # Export-Csv honours the inherited $WhatIfPreference and writes nothing under -WhatIf
                if ($WhatIfPreference) {
                    Write-StructuredLog "WhatIf: results would be exported to $OutputPath; no file was written" -Level Information -Component 'Summary' -CorrelationId $CorrelationId
                }
                else {
                    $rows = @($allResults |
                            Select-Object Success, TargetObjectDN, EntriesRestored, ErrorMessage, CorrelationId)
                    Export-ResultCsv -InputObject $rows -LiteralPath $OutputPath
                    Write-StructuredLog "Restore results exported to: $OutputPath" -Level Information -Component 'Summary' -CorrelationId $CorrelationId
                }
            }
        }
        catch {
            Write-StructuredLog "Restore failed: $($_.Exception.Message)" -Level Error -Component 'Main' -CorrelationId $CorrelationId
            # Exception to ERR-11: a critical error ends the calling script whatever its error
            # action is, as Documentation/Automation.md tells callers. ThrowTerminatingError()
            # would end this command only, and a script with no try around the call would carry
            # on with its next line.
            Write-Error -ErrorRecord $_ -ErrorAction Stop
        }
        finally {
            Stop-OrphanedSidSession -CorrelationId $CorrelationId
        }
    }
}
