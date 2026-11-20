function Remove-OrphanedSid {
    <#
    .EXTERNALHELP OrphanedSid-Help.xml
    .SYNOPSIS
        Removes orphaned access control entries from Active Directory objects after backing up each ACL.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType('RemovalOperationResult')]
    param(
        # [object[]], not [string[]]: by-property binding asks an AD object for 'SearchBase' before
        # the alias, the AD adapter answers with an empty collection, and the removal fell back to
        # the domain root. Each item is read by ConvertTo-DistinguishedName instead.
        [Parameter(ValueFromPipeline)]
        [Alias('DistinguishedName')]
        [object[]]$SearchBase,

        [Parameter()]
        [ValidateScript({
            $parent = Split-Path -Parent $_
            if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
                throw "The parent folder for -BackupPath does not exist: $parent"
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
        [switch]$IncludeInherited,

        [Parameter()]
        [ValidateRange(1, 10)]
        [int]$MaxRetries = 3,

        [Parameter()]
        [ValidateScript({
            if ($_ -and -not (Test-Path -LiteralPath $_ -PathType Leaf)) {
                throw "Configuration file not found: $_"
            }
            $true
        })]
        [string]$ConfigPath,

        [Parameter()]
        [ValidateRange(100, 16384)]
        [int]$MaxMemoryUsageMB = 1024,

        [Parameter()]
        [switch]$PreserveTempFiles,

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
        # -Force skips the ConfirmImpact High prompt. -WhatIf is unaffected because it does not
        # go through $ConfirmPreference.
        if ($Force) {
            $ConfirmPreference = 'None'
        }

        $sessionParams = @{
            CommandName            = $MyInvocation.MyCommand.Name
            ConfigPath             = $ConfigPath
            LogPath                = $LogPath
            MaxMemoryUsageMB       = $MaxMemoryUsageMB
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

        $searchBases = [System.Collections.Generic.List[string]]::new()
        $searchBaseGiven = $false
    }

    process {
        if ($PSBoundParameters.ContainsKey('SearchBase')) {
            $searchBaseGiven = $true
        }
        foreach ($dn in @(ConvertTo-DistinguishedName -InputObject $SearchBase)) {
            $searchBases.Add($dn)
        }
    }

    end {
        try {
            # Input that held no usable DN must never widen a removal to the whole domain.
            # The check is a function of its own so that its error enters the catch below, which
            # is what ends the calling script.
            if ($searchBaseGiven) {
                Assert-DistinguishedNameInput -DistinguishedName $searchBases -InputKind SearchBase
            }
            if ($searchBases.Count -eq 0) {
                Write-Warning 'No search base specified. Using the current domain root.'
                $searchBases.Add((Get-ADDomain).DistinguishedName)
            }

            $target = $searchBases -join ', '
            if (-not $PSCmdlet.ShouldProcess($target, 'Remove orphaned SIDs from ACLs (a backup of each ACL is written first)')) {
                # Under -WhatIf the discovery still runs so the preview lists what would be removed;
                # Invoke-MainProcessingLogic honours $WhatIfPreference for the removal itself.
                if (-not $WhatIfPreference) {
                    Write-StructuredLog "Removal declined at the confirmation prompt for: $target" -Level Warning -Component 'Main' -CorrelationId $CorrelationId
                    return
                }
            }

            $effectiveBackupPath = $BackupPath
            if (-not $effectiveBackupPath) {
                $effectiveBackupPath = Join-Path -Path (Get-Location).Path -ChildPath 'Backup'
            }
            $effectiveBackupPath = Join-Path -Path $effectiveBackupPath -ChildPath (Get-Date -Format 'yyyyMMdd_HHmmss')
            if (-not $WhatIfPreference -and -not (Test-Path -LiteralPath $effectiveBackupPath)) {
                New-Item -Path $effectiveBackupPath -ItemType Directory -Force | Out-Null
                Write-StructuredLog "Created backup folder: $effectiveBackupPath" -Level Information -Component 'Main' -CorrelationId $CorrelationId
            }

            Write-StructuredLog "Starting removal for: $target" -Level Information -Component 'Main' -CorrelationId $CorrelationId

            $processingParams = @{
                SearchBase       = $searchBases.ToArray()
                Remove           = $true
                IncludeInherited = $IncludeInherited
                BackupPath       = $effectiveBackupPath
                MaxRetries       = $MaxRetries
                CorrelationId    = $CorrelationId
            }
            $processingResults = Invoke-MainProcessingLogic @processingParams

            foreach ($removal in @($processingResults.RemovalResults)) {
                Write-Output $removal
            }

            Write-ProcessingSummary -ProcessingResults $processingResults -OutputPath $OutputPath -CorrelationId $CorrelationId
            Write-StructuredLog "Removal completed (CorrelationId: $CorrelationId)" -Level Information -Component 'Main' -CorrelationId $CorrelationId
        }
        catch {
            if ($script:Statistics) { $script:Statistics.CriticalErrors++ }
            Write-StructuredLog "Removal failed: $($_.Exception.Message)" -Level Error -Component 'Main' -CorrelationId $CorrelationId
            # Exception to ERR-11: a critical error ends the calling script whatever its error
            # action is, as Documentation/Automation.md tells callers. ThrowTerminatingError()
            # would end this command only, and a script with no try around the call would carry
            # on with its next line.
            Write-Error -ErrorRecord $_ -ErrorAction Stop
        }
        finally {
            Stop-OrphanedSidSession -PreserveTempFiles:$PreserveTempFiles -CorrelationId $CorrelationId
        }
    }
}
