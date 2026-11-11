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
            if ($parent -and -not (Test-Path -Path $parent -PathType Container)) {
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
            if (-not (Test-Path -Path $directory -PathType Container)) {
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
            if ($_ -and -not (Test-Path -Path $_ -PathType Leaf)) {
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
        $null = Start-OrphanedSidSession @sessionParams

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
            if ($searchBases.Count -eq 0) {
                if ($searchBaseGiven) {
                    # Input that held no usable DN must never widen a removal to the whole domain
                    throw 'No usable search base in the input. Pass distinguished names, or objects with a DistinguishedName property; the domain root is used only when -SearchBase is not given at all.'
                }
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
            if (-not $WhatIfPreference -and -not (Test-Path -Path $effectiveBackupPath)) {
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
            Write-Error -ErrorRecord $_ -ErrorAction Stop
        }
        finally {
            Stop-OrphanedSidSession -PreserveTempFiles:$PreserveTempFiles -CorrelationId $CorrelationId
        }
    }
}
