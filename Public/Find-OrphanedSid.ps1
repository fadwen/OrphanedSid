function Find-OrphanedSid {
    <#
    .EXTERNALHELP OrphanedSid-Help.xml
    .SYNOPSIS
        Finds access control entries in Active Directory that grant rights to principals that no longer exist.
    #>
    [CmdletBinding()]
    [OutputType('OrphanedSIDResult')]
    param(
        # [object[]], not [string[]]: by-property binding asks an AD object for 'SearchBase' before
        # the alias, the AD adapter answers with an empty collection, and the run fell back to the
        # domain root. Each item is read by ConvertTo-DistinguishedName instead.
        [Parameter(ValueFromPipeline)]
        [Alias('DistinguishedName')]
        [object[]]$SearchBase,

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
            # Input that held no usable DN is a mistake to report, not a request for the domain root.
            # The check is a function of its own so that its error enters the catch below, which
            # is what ends the calling script.
            if ($searchBaseGiven) {
                Assert-DistinguishedNameInput -DistinguishedName $searchBases -InputKind SearchBase
            }
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
            Write-StructuredLog "Discovery failed: $($_.Exception.Message)" -Level Error -Component 'Main' -CorrelationId $CorrelationId
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
