function Restore-OrphanedSidBackup {
    <#
    .EXTERNALHELP OrphanedSid-Help.xml
    .SYNOPSIS
        Restores Active Directory ACLs from a backup folder written by Remove-OrphanedSid.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType('RestoreWorkflowResult')]
    param(
        # [object[]], not [string[]]: by-property binding asks an AD object for 'TargetObjectDN'
        # before the aliases, the AD adapter answers with an empty collection, and binding failed.
        # Each item is read by ConvertTo-DistinguishedName instead.
        [Parameter(Mandatory, ValueFromPipeline)]
        [Alias('DistinguishedName', 'SearchBase')]
        [object[]]$TargetObjectDN,

        [Parameter(Mandatory)]
        [ValidateScript({
            if (-not (Test-Path -LiteralPath $_ -PathType Container)) {
                throw "Backup folder not found: $_"
            }
            $true
        })]
        [string]$BackupPath,

        [Parameter()]
        [switch]$Force,

        [Parameter()]
        [ValidateScript({
            $directory = Split-Path -Parent $_
            if (-not $directory) { $directory = (Get-Location).Path }
            if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
                throw "The folder for -OutputPath does not exist: $directory"
            }
            $true
        })]
        [string]$OutputPath,

        [Parameter()]
        [string]$LogPath,

        [Parameter()]
        [string]$CorrelationId = [System.Guid]::NewGuid().ToString(),

        [Parameter()]
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
            if (-not $PSCmdlet.ShouldProcess($targetList, "Restore ACLs from backup folder $BackupPath")) {
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
                    BackupPath     = $BackupPath
                    CorrelationId  = $CorrelationId
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
            $entries = ($allResults | Where-Object { $_.Success -eq $true -and $_.EntriesRestored } |
                Measure-Object -Property EntriesRestored -Sum).Sum

            Write-StructuredLog '=== RESTORE OPERATION SUMMARY ===' -Level Information -Component 'Summary' -CorrelationId $CorrelationId
            Write-StructuredLog "Total restore operations: $($allResults.Count)" -Level Information -Component 'Summary' -CorrelationId $CorrelationId
            Write-StructuredLog "Successful restores: $successful" -Level Information -Component 'Summary' -CorrelationId $CorrelationId
            Write-StructuredLog "Failed restores: $failed" -Level Information -Component 'Summary' -CorrelationId $CorrelationId
            if ($entries -gt 0) {
                Write-StructuredLog "Total ACL entries restored: $entries" -Level Information -Component 'Summary' -CorrelationId $CorrelationId
            }
            Write-StructuredLog "Backup source: $BackupPath" -Level Information -Component 'Summary' -CorrelationId $CorrelationId

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
