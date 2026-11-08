function Find-OrphanedSid {
    <#
    .EXTERNALHELP OrphanedSid-Help.xml
    .SYNOPSIS
        Finds access control entries in Active Directory that grant rights to principals that no longer exist.
    #>
    [CmdletBinding()]
    [OutputType('OrphanedSIDResult')]
    param(
        [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('DistinguishedName')]
        [string[]]$SearchBase,

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
    }

    process {
        foreach ($dn in $SearchBase) {
            if (-not [string]::IsNullOrWhiteSpace($dn)) {
                $searchBases.Add($dn.Trim())
            }
        }
    }

    end {
        try {
            if ($searchBases.Count -eq 0) {
                Write-Warning 'No search base specified. Using the current domain root.'
                $searchBases.Add((Get-ADDomain).DistinguishedName)
            }

            Write-StructuredLog 'Starting discovery' -Level Information -Component 'Main' -CorrelationId $CorrelationId

            $processingParams = @{
                SearchBase       = $searchBases.ToArray()
                IncludeInherited = $IncludeInherited
                MaxRetries       = $MaxRetries
                CorrelationId    = $CorrelationId
            }
            $processingResults = Invoke-MainProcessingLogic @processingParams

            # Emit before the summary disposes anything. GetAllResults reads the batch files back.
            if ($processingResults.StreamingManager) {
                foreach ($result in @($processingResults.StreamingManager.GetAllResults())) {
                    Write-Output $result
                }
            }

            Write-ProcessingSummary -ProcessingResults $processingResults -OutputPath $OutputPath -CorrelationId $CorrelationId
            Write-StructuredLog "Discovery completed (CorrelationId: $CorrelationId)" -Level Information -Component 'Main' -CorrelationId $CorrelationId
        }
        catch {
            if ($script:Statistics) { $script:Statistics.CriticalErrors++ }
            Write-StructuredLog "Discovery failed: $($_.Exception.Message)" -Level Error -Component 'Main' -CorrelationId $CorrelationId
            Write-Error -ErrorRecord $_ -ErrorAction Stop
        }
        finally {
            Stop-OrphanedSidSession -PreserveTempFiles:$PreserveTempFiles -CorrelationId $CorrelationId
        }
    }
}
