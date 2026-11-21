#Requires -Version 5.1

function Initialize-LogDirectory {
    <#
    .SYNOPSIS
        Initializes log directory structure and validates log file path

    .DESCRIPTION
        Handles all file system operations for logging setup including:
        - Log path resolution
        - Directory creation with proper permissions
        - Log file initialization with header content
        - Error handling for file system issues

        This function focuses solely on file system operations and integrates
        with Initialize-LoggingSystem for complete logging setup.

    .PARAMETER LogPath
        Absolute or relative path to the log file. Directory will be created if it doesn't exist.
        An existing file is appended to, never truncated, so a path reused across runs keeps the
        earlier runs' entries.

    .PARAMETER RotateAboveMB
        When greater than 0 and the existing log file is larger than this many MB, the file is
        renamed to <name>_<yyyyMMdd_HHmmss>.log before this run writes to it, so the rotated file
        holds only earlier runs. The outcome is left in $script:LogRotation (From, To, SizeMB, or
        Error) for the caller to log once logging is set up. 0, the default, never rotates.

    .PARAMETER RefuseSystemFolder
        Refuses a path inside the Windows or Program Files folders, and falls back to the current
        location as for any other path that cannot be used. Set for a path that a configuration
        file names: see Resolve-LogPath.

    .EXAMPLE
        PS> Initialize-LogDirectory -LogPath "C:\Logs\script.log"

        Creates directory structure and initializes log file at specified path

    .EXAMPLE
        PS> Initialize-LogDirectory -LogPath "C:\Logs\nightly.log" -RotateAboveMB 10

        Renames nightly.log aside first when it has grown past 10 MB, then starts this run's entries

    .EXAMPLE
        PS> Initialize-LogDirectory -LogPath ".\Logs\script.log"

        Creates relative path directory and initializes log file

    .INPUTS
        None. This function does not accept pipeline input.

    .OUTPUTS
        [string] Resolved absolute path to the log file

    .NOTES
        Must be called after Initialize-LoggingSystem to ensure proper state.
        Creates directories as needed and validates write permissions.
        Bypasses WhatIf mode for log file operations to ensure logging works during -WhatIf runs.

        SECURITY CONSIDERATIONS:
        - Writes where the operator's path says. Only with -RefuseSystemFolder is a folder refused
        - Creates directories with inherited permissions
        - Tests write access before setting as active log path

        TROUBLESHOOTING:
        - Path resolution handles relative and absolute paths
        - Graceful fallback to current directory on failures
        - Comprehensive error logging for file system issues
        - For path resolution issues: .\Troubleshooting\Common\Common-Issues.md
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$LogPath,

        [Parameter()]
        [ValidateRange(0, [int]::MaxValue)]
        [int]$RotateAboveMB = 0,

        [Parameter()]
        [switch]$RefuseSystemFolder
    )

    begin {
        Write-Verbose "Initializing log directory for path: $LogPath"
        $script:LogRotation = $null

        # Get current logging system state
        $loggingState = Get-LoggingSystemState
        if (-not $loggingState.CorrelationId) {
            Write-Warning "Logging system not initialized. Call Initialize-LoggingSystem first."
        }
    }

    process {
        try {
            # Validate and normalize the log path
            $resolvedPath = Resolve-LogPath -LogPath $LogPath -RefuseSystemFolder:$RefuseSystemFolder

            # Create directory structure
            $logDirectory = Split-Path -Parent $resolvedPath
            New-LogDirectory -DirectoryPath $logDirectory

            # Rotate before this run writes anything, so the run is never split across two files
            if ($RotateAboveMB -gt 0 -and (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
                $sizeMB = [Math]::Round((Get-Item -LiteralPath $resolvedPath).Length / 1MB, 2)
                if ($sizeMB -gt $RotateAboveMB) {
                    $rotatedPath = $resolvedPath -replace '\.log$', "_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
                    if ($rotatedPath -eq $resolvedPath) {
                        $rotatedPath = "${resolvedPath}_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
                    }
                    try {
                        # Pinned: a preview run still logs, so it still rotates the file it logs to
                        Move-Item -LiteralPath $resolvedPath -Destination $rotatedPath -ErrorAction Stop -WhatIf:$false
                        $script:LogRotation = @{ From = $resolvedPath; To = $rotatedPath; SizeMB = $sizeMB }
                    }
                    catch {
                        # The run appends to the oversized file rather than failing
                        $script:LogRotation = @{ From = $resolvedPath; SizeMB = $sizeMB; Error = $_.Exception.Message }
                    }
                }
            }

            # Initialize log file with header
            Initialize-LogFile -LogFilePath $resolvedPath

            # Update script state with successful path
            $script:LogPath = $resolvedPath
            $script:LogFileInitialized = $true

            Write-Verbose "Log directory initialization completed successfully: $resolvedPath"
            return $resolvedPath
        }
        catch {
            Write-Warning "Log directory initialization failed: $($_.Exception.Message)"

            # Attempt fallback to current directory
            try {
                $fallbackPath = Join-Path (Get-Location) "OrphanedSid_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
                Write-Warning "Attempting fallback log path: $fallbackPath"

                $script:LogPath = $fallbackPath
                $script:LogFileInitialized = $false
                $script:LogFileReinitAttempted = $true

                return $fallbackPath
            }
            catch {
                $message = "Failed to establish any log file path: $($_.Exception.Message)"
                $exception = [System.IO.IOException]::new($message, $_.Exception)
                $category = [System.Management.Automation.ErrorCategory]::OpenError
                $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                    $exception, 'LogPathNotEstablished', $category, $LogPath)
                $PSCmdlet.ThrowTerminatingError($errorRecord)
            }
        }
    }

    end {
        Write-Verbose "Log directory initialization process completed"
    }
}


function Resolve-LogPath {
    <#
    .SYNOPSIS
        Resolves the log file path to a full path

    .DESCRIPTION
        Turns the log path into a full path, as any cmdlet reads a path: a relative path is
        relative to the current location, and .. is the parent folder. A path of only blanks
        becomes a default file name under .\Logs. Wildcard characters are not expanded.

        The path is not checked against a list of folders. Whether its folder can be used is
        settled by New-LogDirectory, which creates the folder and writes a test file there. Two
        things the path itself can show end the function with an error: a path that is not a
        file system path (LogPathNotFileSystem), and a file or folder name with a character that
        the file system does not allow (LogPathInvalidCharacters).

        With -RefuseSystemFolder, a path inside the Windows folder or a Program Files folder also
        ends the function, with LogPathInSystemFolder. That is for a path that comes from a
        configuration file: a scheduled run under a privileged account appends to the file that
        the configuration names, so whoever can edit the configuration would choose a file in
        those folders for it. A path on the command line is the choice of the person who runs
        the command, with that person's own rights, and is not refused.

    .PARAMETER LogPath
        Log file path to resolve

    .PARAMETER RefuseSystemFolder
        Refuses a path inside the folders that [Environment]::GetFolderPath() gives for Windows,
        ProgramFiles and ProgramFilesX86. A short name such as C:\PROGRA~1 is written out in
        full before the comparison. A link or a junction that leads into such a folder is not
        followed.

    .EXAMPLE
        PS> Resolve-LogPath -LogPath ".\logs\script.log"

        Returns absolute path resolved from relative input

    .INPUTS
        None. This function does not accept pipeline input.

    .OUTPUTS
        [string] Resolved absolute path to log file

    .NOTES
        A path on a drive that does not exist ends the function with the error that PowerShell
        raises for it. Initialize-LogDirectory catches each of these errors and falls back to a
        log file in the current location.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$LogPath,

        [Parameter()]
        [switch]$RefuseSystemFolder
    )

    # Handle empty or whitespace-only paths. Trimmed into a plain variable first: assigning '' to
    # the [ValidateNotNullOrEmpty()] parameter would throw before the default could be applied.
    $trimmedPath = $LogPath.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmedPath)) {
        Write-Verbose "LogPath is empty, using default log file name"
        $LogPath = ".\Logs\OrphanedSid_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    }
    else {
        $LogPath = $trimmedPath
    }

    # The path is taken as any cmdlet takes one: relative to the current location, with .. for the
    # parent folder, and in whatever folder the operator names. Whether the folder can be used is
    # settled by New-LogDirectory, which creates it and writes a test file there. A check of the
    # words in the path once refused D:\Logs\windows-servers, and the log of the run went to the
    # current folder.
    $provider = $null
    $drive = $null
    $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $LogPath, [ref]$provider, [ref]$drive)

    # The one thing the path itself can rule out: a path of another provider, such as HKLM:\,
    # resolves to text that the file system would read as a relative path.
    if ($provider.Name -ne 'FileSystem') {
        $message = "The log path '$LogPath' is not a file system path: it belongs to the $($provider.Name) provider."
        $exception = [System.ArgumentException]::new($message)
        $category = [System.Management.Automation.ErrorCategory]::InvalidArgument
        $errorRecord = [System.Management.Automation.ErrorRecord]::new(
            $exception, 'LogPathNotFileSystem', $category, $LogPath)
        $PSCmdlet.ThrowTerminatingError($errorRecord)
    }

    # A name that no file or folder can have is refused here, by the characters the file system
    # itself rules out. Left to the cmdlets, such a path fails at a different step on each edition,
    # and on Windows PowerShell 5.1 with an error of Test-Path beside the fallback.
    $invalidCharacters = [System.IO.Path]::GetInvalidFileNameChars()
    $withoutRoot = $resolvedPath -replace '^([A-Za-z]:|\\\\)', ''
    $separators = [char[]]'\/'
    foreach ($segment in $withoutRoot.Split($separators, [System.StringSplitOptions]::RemoveEmptyEntries)) {
        if ($segment.IndexOfAny($invalidCharacters) -ge 0) {
            $message = "The log path '$resolvedPath' cannot be used: '$segment' holds a character " +
                'that a file or folder name cannot have.'
            $exception = [System.ArgumentException]::new($message)
            $category = [System.Management.Automation.ErrorCategory]::InvalidArgument
            $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                $exception, 'LogPathInvalidCharacters', $category, $resolvedPath)
            $PSCmdlet.ThrowTerminatingError($errorRecord)
        }
    }

    # A path that a configuration file names may not lie in a system folder (SEC-12). The words
    # in the path are not what is compared: the folders are the ones this system reports, and
    # GetFullPath writes a short name such as C:\PROGRA~1 out in full first. The separator after
    # the folder keeps C:\WindowsLogs apart from C:\Windows.
    if ($RefuseSystemFolder) {
        $fullPath = [System.IO.Path]::GetFullPath($resolvedPath)
        $systemFolders = @(
            [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
            [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
            [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86)
            # What a 32-bit process is given as ProgramFiles is the x86 folder
            $env:ProgramW6432
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
        foreach ($systemFolder in $systemFolders) {
            $folderRoot = $systemFolder.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
            if ($fullPath.StartsWith($folderRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                $message = "The log path '$fullPath' is inside the system folder '$systemFolder'. A log " +
                    'path that a configuration file names may not lie there. To write there, name the ' +
                    'path with -LogPath.'
                $exception = [System.ArgumentException]::new($message)
                $category = [System.Management.Automation.ErrorCategory]::SecurityError
                $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                    $exception, 'LogPathInSystemFolder', $category, $fullPath)
                $PSCmdlet.ThrowTerminatingError($errorRecord)
            }
        }
    }

    Write-Verbose "Log path resolved to: $resolvedPath"
    return $resolvedPath
}


function New-LogDirectory {
    <#
    .SYNOPSIS
        Creates log directory structure with proper permissions

    .DESCRIPTION
        Creates the directory structure needed for log files and validates
        write permissions. Handles existing directories gracefully.

    .PARAMETER DirectoryPath
        Path to directory to create

    .EXAMPLE
        PS> New-LogDirectory -DirectoryPath "C:\Logs"

        Creates the logs directory if it doesn't exist

    .INPUTS
        None. This function does not accept pipeline input.

    .OUTPUTS
        None. This function does not return objects to the pipeline.

    .NOTES
        Bypasses WhatIf mode to ensure logging works during preview operations.
        Creates directories with inherited permissions from parent.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates the log folder with -WhatIf:$false by design so a preview run can still log')]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$DirectoryPath
    )

    if (-not (Test-Path -LiteralPath $DirectoryPath)) {
        try {
            # Bypass WhatIf for log directory creation. -ErrorAction Stop, because New-Item
            # only writes its error for a folder that it is not allowed to create, and the catch
            # below would not be reached.
            $null = New-Item -Path $DirectoryPath -ItemType Directory -Force -WhatIf:$false -ErrorAction Stop
        }
        catch {
            $message = "Failed to create log directory '$DirectoryPath': $($_.Exception.Message)"
            $exception = [System.IO.IOException]::new($message, $_.Exception)
            $category = [System.Management.Automation.ErrorCategory]::WriteError
            $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                $exception, 'LogDirectoryNotCreated', $category, $DirectoryPath)
            $PSCmdlet.ThrowTerminatingError($errorRecord)
        }

        # For a folder whose parent is a file, New-Item -Force returns nothing and reports no
        # error, with -ErrorAction Stop as well; measured on both editions. So the folder is
        # looked for. Left to the write test below, the failure was reported as missing write
        # permissions.
        if (-not (Test-Path -LiteralPath $DirectoryPath -PathType Container)) {
            $message = "Failed to create log directory '$DirectoryPath': the folder does not exist after " +
                'it was created without an error. A part of the path may be a file.'
            $exception = [System.IO.IOException]::new($message)
            $category = [System.Management.Automation.ErrorCategory]::WriteError
            $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                $exception, 'LogDirectoryNotCreated', $category, $DirectoryPath)
            $PSCmdlet.ThrowTerminatingError($errorRecord)
        }

        Write-Verbose "Created log directory: $DirectoryPath"
    } else {
        Write-Verbose "Log directory already exists: $DirectoryPath"
    }

    # Test write permissions
    try {
        $testFile = Join-Path $DirectoryPath "test_write_$(Get-Random).tmp"
        Set-Content -LiteralPath $testFile -Value "test" -ErrorAction Stop -WhatIf:$false
        Remove-Item -LiteralPath $testFile -Force -ErrorAction SilentlyContinue -WhatIf:$false
        Write-Verbose "Write permissions validated for directory: $DirectoryPath"
    }
    catch {
        $message = "Insufficient write permissions for log directory '$DirectoryPath': $($_.Exception.Message)"
        $exception = [System.UnauthorizedAccessException]::new($message, $_.Exception)
        $category = [System.Management.Automation.ErrorCategory]::PermissionDenied
        $errorRecord = [System.Management.Automation.ErrorRecord]::new(
            $exception, 'LogDirectoryNotWritable', $category, $DirectoryPath)
        $PSCmdlet.ThrowTerminatingError($errorRecord)
    }
}


function Initialize-LogFile {
    <#
    .SYNOPSIS
        Creates log file with proper header information

    .DESCRIPTION
        Initializes the log file with comprehensive header information
        including system context, correlation ID, and configuration details.
        A new file starts with the header; an existing one has it appended after a blank line.

    .PARAMETER LogFilePath
        Full path to log file to initialize

    .EXAMPLE
        PS> Initialize-LogFile -LogFilePath "C:\Logs\script.log"

        Creates log file with header information

    .INPUTS
        None. This function does not accept pipeline input.

    .OUTPUTS
        None. This function does not return objects to the pipeline.

    .NOTES
        Bypasses WhatIf mode to ensure logging works during preview operations.
        Includes comprehensive system and context information for troubleshooting.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$LogFilePath
    )

    try {
        # Get current logging state
        $loggingState = Get-LoggingSystemState

        # Create comprehensive log header
        $logHeader = @"
=== OrphanedSid Log ===
Module Version: $(Get-OrphanedSidModuleVersion)
Start Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Correlation ID: $($loggingState.CorrelationId)
PowerShell Version: $($PSVersionTable.PSVersion)
User Context: $env:USERNAME@$env:COMPUTERNAME
Domain Context: $env:USERDOMAIN
Log Level: $($loggingState.LogLevel)
Log File: $LogFilePath
Console Output Suppressed: $($loggingState.SuppressConsoleOutput)
==========================================

"@

        # An existing file is appended to: a reused -LogPath keeps the earlier runs' entries, which
        # a tool that changes ACLs must not lose. Bypass WhatIf for log operations.
        if (Test-Path -LiteralPath $LogFilePath -PathType Leaf) {
            Add-Content -LiteralPath $LogFilePath -Value "`r`n$logHeader" -Encoding UTF8 -ErrorAction Stop -WhatIf:$false
            Write-Verbose "Log file appended to: $LogFilePath"
        }
        else {
            Set-Content -LiteralPath $LogFilePath -Value $logHeader -Encoding UTF8 -ErrorAction Stop -WhatIf:$false
            Write-Verbose "Log file initialized successfully: $LogFilePath"
        }
    }
    catch {
        $message = "Failed to initialize log file '$LogFilePath': $($_.Exception.Message)"
        $exception = [System.IO.IOException]::new($message, $_.Exception)
        $category = [System.Management.Automation.ErrorCategory]::WriteError
        $errorRecord = [System.Management.Automation.ErrorRecord]::new(
            $exception, 'LogFileNotInitialized', $category, $LogFilePath)
        $PSCmdlet.ThrowTerminatingError($errorRecord)
    }
}
