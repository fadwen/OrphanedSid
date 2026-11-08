function Restore-OrphanedSidBackup {
    <#
    .EXTERNALHELP OrphanedSid-Help.xml
    .SYNOPSIS
        Restores Active Directory ACLs from a backup folder written by Remove-OrphanedSid.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType('RestoreWorkflowResult')]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('DistinguishedName', 'SearchBase')]
        [string[]]$TargetObjectDN,

        [Parameter(Mandatory)]
        [ValidateScript({
            if (-not (Test-Path -Path $_ -PathType Container)) {
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
            if (-not (Test-Path -Path $directory -PathType Container)) {
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
        $null = Start-OrphanedSidSession @sessionParams

        $targets = [System.Collections.Generic.List[string]]::new()
    }

    process {
        foreach ($dn in $TargetObjectDN) {
            if (-not [string]::IsNullOrWhiteSpace($dn)) {
                $targets.Add($dn.Trim())
            }
        }
    }

    end {
        try {
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
                $allResults |
                    Select-Object Success, TargetObjectDN, EntriesRestored, ErrorMessage, CorrelationId |
                    Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
                Write-StructuredLog "Restore results exported to: $OutputPath" -Level Information -Component 'Summary' -CorrelationId $CorrelationId
            }
        }
        catch {
            Write-StructuredLog "Restore failed: $($_.Exception.Message)" -Level Error -Component 'Main' -CorrelationId $CorrelationId
            Write-Error -ErrorRecord $_ -ErrorAction Stop
        }
        finally {
            Stop-OrphanedSidSession -CorrelationId $CorrelationId
        }
    }
}
