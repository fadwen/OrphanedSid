#Requires -Version 5.1

# Unit tests for Initialize-LogDirectory.ps1 and the helpers it defines. Every log path is under
# TestDrive; Get-Location is mocked to TestDrive too, so the fallback path never points into the
# repository.
BeforeAll {
    . $PSScriptRoot\..\..\..\..\Private\Logging\Initialize-LoggingSystem.ps1

    . $PSScriptRoot\..\..\..\..\Private\FileSystem\Initialize-LogDirectory.ps1
    . "$PSScriptRoot\..\..\..\..\Private\Utilities\Get-OrphanedSidModuleVersion.ps1"

    $script:RepositoryRoot = (Resolve-Path "$PSScriptRoot\..\..\..\..").Path
}

Describe "Initialize-LogDirectory" -Tag "Unit", "Private", "FileSystem" {

    BeforeEach {
        Initialize-LoggingSystem -CorrelationId 'dir-correlation' -LogLevel 'Debug' -SuppressConsoleOutput
        $script:LogPath = $null

        # TestDrive sits under %TEMP%, which can be an 8.3 short path; expand it so the paths the
        # function returns compare equal to the ones built here
        $script:TestRoot = Join-Path (Get-Item -LiteralPath $TestDrive).FullName ([guid]::NewGuid().ToString('N'))
        $script:TestLogPath = Join-Path $script:TestRoot 'run.log'
        $script:FallbackDir = Join-Path (Get-Item -LiteralPath $TestDrive).FullName 'fallback'

        Mock Get-Location { $script:FallbackDir }
        Mock Write-Warning { }
    }

    Context "Parameter Validation" {
        It "Should reject null or empty LogPath" {
            { Initialize-LogDirectory -LogPath "" } | Should -Throw
            { Initialize-LogDirectory -LogPath $null } | Should -Throw
        }
    }

    Context "Successful initialization" {
        It "Should return the resolved path and record it as the active log" {
            $result = Initialize-LogDirectory -LogPath $script:TestLogPath

            $result | Should -Be $script:TestLogPath
            $script:LogPath | Should -Be $script:TestLogPath
            $script:LogFileInitialized | Should -BeTrue
            Should -Invoke Write-Warning -Times 0 -Exactly
        }

        It "Should create the missing parent directory" {
            Test-Path $script:TestRoot | Should -BeFalse

            Initialize-LogDirectory -LogPath $script:TestLogPath

            Test-Path $script:TestRoot -PathType Container | Should -BeTrue
        }

        It "Should create a nested directory structure" {
            $nestedPath = Join-Path $script:TestRoot "SubDir\SubSubDir\nested.log"

            Initialize-LogDirectory -LogPath $nestedPath | Should -Be $nestedPath

            Test-Path $nestedPath -PathType Leaf | Should -BeTrue
        }

        It "Should leave no write-probe file behind in the directory" {
            Initialize-LogDirectory -LogPath $script:TestLogPath

            @(Get-ChildItem $script:TestRoot -Filter 'test_write_*.tmp').Count | Should -Be 0
        }

        It "Should write a header with the correlation ID, level, user and file path" {
            Initialize-LogDirectory -LogPath $script:TestLogPath

            $content = Get-Content $script:TestLogPath -Raw
            $content | Should -Match '=== OrphanedSid Log ==='
            $content | Should -Match 'Correlation ID: dir-correlation'
            $content | Should -Match 'Log Level: Debug'
            $content | Should -Match ([regex]::Escape("User Context: $env:USERNAME@$env:COMPUTERNAME"))
            $content | Should -Match ([regex]::Escape("Log File: $script:TestLogPath"))
            $content | Should -Match 'Console Output Suppressed: True'
        }

        It "Should append the header to an existing log file, keeping the earlier runs (#44)" {
            New-Item -Path $script:TestRoot -ItemType Directory | Out-Null
            "Existing content" | Set-Content $script:TestLogPath

            Initialize-LogDirectory -LogPath $script:TestLogPath

            $lines = @(Get-Content $script:TestLogPath)
            $lines[0] | Should -Be 'Existing content'
            $lines[1] | Should -Be ''
            $lines[2] | Should -Be '=== OrphanedSid Log ==='
            $script:LogRotation | Should -BeNullOrEmpty
        }
    }

    Context "Rotation (#44)" {
        BeforeEach {
            New-Item -Path $script:TestRoot -ItemType Directory | Out-Null
            $stream = [IO.File]::Create($script:TestLogPath); $stream.SetLength(2MB); $stream.Dispose()
        }

        It "Should rename a file over -RotateAboveMB aside before writing this run's header" {
            Initialize-LogDirectory -LogPath $script:TestLogPath -RotateAboveMB 1 | Should -Be $script:TestLogPath

            $rotated = @(Get-ChildItem $script:TestRoot -Filter 'run_????????_??????.log')
            $rotated.Count | Should -Be 1
            $rotated[0].Length | Should -Be 2MB
            (Get-Content $script:TestLogPath -TotalCount 1) | Should -Be '=== OrphanedSid Log ==='
            $script:LogRotation.From | Should -Be $script:TestLogPath
            $script:LogRotation.To | Should -Be $rotated[0].FullName
            $script:LogRotation.SizeMB | Should -Be 2
        }

        It "Should rotate even under -WhatIf, since a preview run still logs" {
            $WhatIfPreference = $true

            Initialize-LogDirectory -LogPath $script:TestLogPath -RotateAboveMB 1

            @(Get-ChildItem $script:TestRoot -Filter 'run_*.log').Count | Should -Be 1
        }

        It "Should append without rotating when <Case>" -ForEach @(
            @{ Case = 'the file is within the limit'; Limit = 5 }
            @{ Case = 'rotation is off'; Limit = 0 }
        ) {
            Initialize-LogDirectory -LogPath $script:TestLogPath -RotateAboveMB $Limit

            @(Get-ChildItem $script:TestRoot -Filter 'run_*.log').Count | Should -Be 0
            (Get-Item $script:TestLogPath).Length | Should -BeGreaterThan 2MB
            $script:LogRotation | Should -BeNullOrEmpty
        }

        It "Should record a failed rotation and append to the file instead" {
            # A held file handle cannot stand in: on Windows PowerShell 5.1 it blocks the append too
            Mock Move-Item { throw 'The process cannot access the file because it is being used by another process.' }

            Initialize-LogDirectory -LogPath $script:TestLogPath -RotateAboveMB 1 | Should -Be $script:TestLogPath

            $script:LogRotation.Error | Should -Be 'The process cannot access the file because it is being used by another process.'
            $script:LogRotation.To | Should -BeNullOrEmpty
            (Get-Item $script:TestLogPath).Length | Should -BeGreaterThan 2MB
            $script:LogFileInitialized | Should -BeTrue
        }

        It "Should create the directory and file even under -WhatIf" {
            $WhatIfPreference = $true

            Initialize-LogDirectory -LogPath $script:TestLogPath

            Test-Path $script:TestLogPath -PathType Leaf | Should -BeTrue
        }

        It "Should resolve a relative path against the current location, not the module folder (#45)" {
            $null = New-Item -Path $script:TestRoot -ItemType Directory -Force
            Push-Location -Path $script:TestRoot
            try {
                $result = Initialize-LogDirectory -LogPath 'Logs\relative.log'
            }
            finally {
                Pop-Location
            }

            $result | Should -Be (Join-Path $script:TestRoot 'Logs\relative.log')
            Test-Path $result -PathType Leaf | Should -BeTrue
        }

        It "Should warn when the logging system has no correlation ID" {
            Mock Get-LoggingSystemState { [PSCustomObject]@{ CorrelationId = $null; LogLevel = 'Information' } }

            Initialize-LogDirectory -LogPath $script:TestLogPath

            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
                $Message -eq 'Logging system not initialized. Call Initialize-LoggingSystem first.'
            }
        }
    }

    Context "A folder named like a system folder (#149)" {
        It "Should write the log where the path says when a folder is named <Folder>" -ForEach @(
            @{ Folder = 'windows-servers' }
            @{ Folder = 'Program Files' }
            @{ Folder = 'system32' }
        ) {
            $asked = Join-Path (Join-Path $script:TestRoot $Folder) 'run.log'

            $result = Initialize-LogDirectory -LogPath $asked

            $result | Should -Be $asked
            Test-Path -LiteralPath $asked -PathType Leaf | Should -BeTrue
            $script:LogFileInitialized | Should -BeTrue
            Should -Invoke Write-Warning -Times 0 -Exactly
        }

        It "Should read .. in a relative path as the parent folder, as a cmdlet does" {
            $start = Join-Path $script:TestRoot 'Scripts'
            $null = New-Item -Path $start -ItemType Directory -Force
            Push-Location -Path $start
            try {
                $result = Initialize-LogDirectory -LogPath '..\Logs\run.log'
            }
            finally {
                Pop-Location
            }

            $result | Should -Be (Join-Path $script:TestRoot 'Logs\run.log')
            Test-Path -LiteralPath $result -PathType Leaf | Should -BeTrue
            Should -Invoke Write-Warning -Times 0 -Exactly
        }
    }

    Context "Fallback path" {
        It "Should fall back to a timestamped file in the current directory when the path is not a file system path" {
            $result = Initialize-LogDirectory -LogPath 'HKLM:\Software\OrphanedSid\run.log'

            Split-Path $result -Parent | Should -Be $script:FallbackDir
            Split-Path $result -Leaf | Should -Match '^OrphanedSid_\d{8}_\d{6}\.log$'
            $script:LogPath | Should -Be $result
            $script:LogFileInitialized | Should -BeFalse
            $script:LogFileReinitAttempted | Should -BeTrue
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
                $Message -like 'Log directory initialization failed: *is not a file system path*'
            }
            # Nothing is created for it: not in the registry, and not as a folder of that name
            Test-Path $script:FallbackDir | Should -BeFalse
        }

        It "Should fall back when the drive of the path does not exist" {
            $letter = 71..90 | ForEach-Object { [char]$_ } |
                Where-Object { -not (Get-PSDrive -Name $_ -ErrorAction SilentlyContinue) } |
                Select-Object -First 1

            $result = Initialize-LogDirectory -LogPath "${letter}:\Logs\run.log"

            Split-Path $result -Parent | Should -Be $script:FallbackDir
            $script:LogFileInitialized | Should -BeFalse
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
                $Message -like 'Log directory initialization failed:*'
            }
        }

        It "Should fall back when the directory cannot be created" {
            Mock New-Item { throw 'Access denied' } -ParameterFilter { $ItemType -eq 'Directory' }

            $result = Initialize-LogDirectory -LogPath $script:TestLogPath

            Split-Path $result -Parent | Should -Be $script:FallbackDir
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
                $Message -like "*Failed to create log directory '$script:TestRoot': Access denied"
            }
        }

        It "Should fall back when the directory is not writable" {
            Mock Set-Content { throw 'Write denied' } -ParameterFilter { $LiteralPath -like '*test_write_*.tmp' }

            $result = Initialize-LogDirectory -LogPath $script:TestLogPath

            Split-Path $result -Parent | Should -Be $script:FallbackDir
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
                $Message -like "*Insufficient write permissions for log directory '$script:TestRoot': Write denied"
            }
        }

        It "Should fall back when the file name has invalid characters" {
            $result = Initialize-LogDirectory -LogPath (Join-Path $script:TestRoot 'bad<>|?.log')

            Split-Path $result -Parent | Should -Be $script:FallbackDir
            # The name is refused when the path is resolved, on both editions, so the folder of
            # the path is not created
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
                $Message -like "Log directory initialization failed: *'bad<>|?.log' holds a character*"
            }
            $script:LogFileInitialized | Should -BeFalse
            Test-Path -LiteralPath $script:TestRoot | Should -BeFalse
        }

        It "Should fall back for a path in a system folder when asked to refuse one (#162)" {
            $systemFolder = [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
            $inSystemFolder = Join-Path $systemFolder "OrphanedSidProbe-$([guid]::NewGuid().ToString('N'))\run.log"

            $result = Initialize-LogDirectory -LogPath $inSystemFolder -RefuseSystemFolder

            Split-Path $result -Parent | Should -Be $script:FallbackDir
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
                $Message -like 'Log directory initialization failed: *is inside the system folder*'
            }
            $script:LogFileInitialized | Should -BeFalse
            Test-Path -LiteralPath (Split-Path $inSystemFolder -Parent) | Should -BeFalse
        }

        It "Should throw when not even the fallback path can be built" {
            Mock Get-Location { throw 'No current location' }

            $expected = @{
                ErrorId         = 'LogPathNotEstablished,Initialize-LogDirectory'
                ExpectedMessage = 'Failed to establish any log file path: No current location'
                ExceptionType   = [System.IO.IOException]
            }
            { Initialize-LogDirectory -LogPath 'HKLM:\Software\OrphanedSid\run.log' } | Should -Throw @expected
        }
    }

    Context 'The errors of the two steps' {
        It 'New-LogDirectory ends with LogDirectoryNotCreated and keeps the cause as the inner exception' {
            Mock New-Item { throw 'Access denied' } -ParameterFilter { $ItemType -eq 'Directory' }
            $missing = Join-Path $script:TestRoot 'not-there'

            $caught = $null
            try {
                New-LogDirectory -DirectoryPath $missing
            } catch {
                $caught = $_
            }

            $caught | Should -Not -BeNullOrEmpty
            $caught.FullyQualifiedErrorId | Should -Be 'LogDirectoryNotCreated,New-LogDirectory'
            $caught.Exception | Should -BeOfType [System.IO.IOException]
            $caught.Exception.Message | Should -Be "Failed to create log directory '$missing': Access denied"
            $caught.Exception.InnerException.Message | Should -Be 'Access denied'
            $caught.TargetObject | Should -Be $missing
        }

        It 'New-LogDirectory ends with LogDirectoryNotCreated for a folder that cannot be created (#156)' {
            # Nothing is mocked: the parent of the folder is a file
            $null = New-Item -Path $script:TestRoot -ItemType Directory -Force
            $file = Join-Path $script:TestRoot 'a-file.txt'
            Set-Content -LiteralPath $file -Value 'not a folder' -Encoding ascii
            $impossible = Join-Path $file 'logs'

            $caught = $null
            try {
                New-LogDirectory -DirectoryPath $impossible
            } catch {
                $caught = $_
            }

            $caught | Should -Not -BeNullOrEmpty
            $caught.FullyQualifiedErrorId | Should -Be 'LogDirectoryNotCreated,New-LogDirectory'
            $caught.Exception | Should -BeOfType [System.IO.IOException]
            $caught.Exception.Message | Should -BeLike "Failed to create log directory '$impossible': *A part of the path may be a file."
        }

        It 'New-LogDirectory ends with LogDirectoryNotCreated for a folder it is not allowed to create (#156)' {
            # Nothing is mocked: adding a folder to the parent is denied for this case, and
            # allowed again afterwards so that the test drive can be removed. A run that is
            # killed before the finally leaves the folder under %TEMP% with the entry on it:
            # icacls <folder> /reset removes the entry, and the folder can then be deleted.
            $null = New-Item -Path $script:TestRoot -ItemType Directory -Force
            $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            $null = & icacls.exe $script:TestRoot /deny "${identity}:(AD,WD)"
            $refused = Join-Path $script:TestRoot 'logs'
            try {
                $caught = $null
                try {
                    New-LogDirectory -DirectoryPath $refused
                } catch {
                    $caught = $_
                }
            } finally {
                $null = & icacls.exe $script:TestRoot /remove:d $identity
            }

            $caught | Should -Not -BeNullOrEmpty
            $caught.FullyQualifiedErrorId | Should -Be 'LogDirectoryNotCreated,New-LogDirectory'
            $caught.Exception.InnerException | Should -BeOfType [System.UnauthorizedAccessException]
        }

        It 'Initialize-LogDirectory says that the folder could not be created when it falls back (#156)' {
            $null = New-Item -Path $script:TestRoot -ItemType Directory -Force
            $file = Join-Path $script:TestRoot 'a-file.txt'
            Set-Content -LiteralPath $file -Value 'not a folder' -Encoding ascii

            $result = Initialize-LogDirectory -LogPath (Join-Path $file 'logs\run.log')

            Split-Path $result -Parent | Should -Be $script:FallbackDir
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
                $Message -like 'Log directory initialization failed: Failed to create log directory*'
            }
            Should -Invoke Write-Warning -Times 0 -Exactly -ParameterFilter {
                $Message -like '*Insufficient write permissions*'
            }
        }

        It 'New-LogDirectory ends with LogDirectoryNotWritable when the test file cannot be written' {
            Mock Set-Content { throw 'Write denied' } -ParameterFilter { $LiteralPath -like '*test_write_*.tmp' }

            $expected = @{
                ErrorId         = 'LogDirectoryNotWritable,New-LogDirectory'
                ExpectedMessage = "Insufficient write permissions for log directory '$script:TestRoot': Write denied"
                ExceptionType   = [System.UnauthorizedAccessException]
            }
            { New-LogDirectory -DirectoryPath $script:TestRoot } | Should -Throw @expected
        }

        It 'Initialize-LogFile ends with LogFileNotInitialized when the header cannot be written' {
            Mock Set-Content { throw 'Disk full' }
            $logFile = Join-Path $script:TestRoot 'header.log'

            $expected = @{
                ErrorId         = 'LogFileNotInitialized,Initialize-LogFile'
                ExpectedMessage = "Failed to initialize log file '$logFile': Disk full"
                ExceptionType   = [System.IO.IOException]
            }
            { Initialize-LogFile -LogFilePath $logFile } | Should -Throw @expected
        }
    }
}

Describe "Resolve-LogPath" -Tag "Unit", "Private", "FileSystem" {
    BeforeEach {
        Mock Write-Warning { }
    }

    It "Should return an absolute path unchanged" {
        Resolve-LogPath -LogPath 'C:\Logs\OrphanedSid\run.log' | Should -Be 'C:\Logs\OrphanedSid\run.log'
    }

    It "Should trim surrounding whitespace" {
        Resolve-LogPath -LogPath '  C:\Logs\run.log  ' | Should -Be 'C:\Logs\run.log'
    }

    It "Should use a default timestamped name under Logs in the current location for a whitespace-only path" {
        Push-Location -Path $TestDrive
        try {
            $result = Resolve-LogPath -LogPath '   '
        }
        finally {
            Pop-Location
        }

        $result | Should -Match ('^' + [regex]::Escape((Join-Path $TestDrive 'Logs')) + '\\OrphanedSid_\d{8}_\d{6}\.log$')
    }

    It "Should trim the spaces around a path" {
        Push-Location -Path $TestDrive
        try {
            $result = Resolve-LogPath -LogPath '  Logs\run.log  '
        }
        finally {
            Pop-Location
        }

        $result | Should -Be (Join-Path $TestDrive 'Logs\run.log')
    }

    It "Should read .. as the parent folder" {
        Resolve-LogPath -LogPath 'C:\Logs\..\Other\run.log' | Should -Be 'C:\Other\run.log'
    }

    It "Should leave two dots inside a file name alone" {
        Resolve-LogPath -LogPath 'C:\Logs\nightly..run.log' | Should -Be 'C:\Logs\nightly..run.log'
    }

    # The path is not created here, so these name folders that a test must not write to. Each was
    # refused by the words in it, and the log of the run went to the current folder (#149).
    It "Should return a path <Case> as it was given" -ForEach @(
        @{ Case = 'in a folder named windows-servers'; Path = 'C:\Data\windows-servers\run.log' }
        @{ Case = 'under Program Files'; Path = 'C:\Program Files\App\logs\run.log' }
        @{ Case = 'under System32'; Path = 'C:\Windows\System32\run.log' }
        @{ Case = 'under Windows\Temp'; Path = 'C:\Windows\Temp\run.log' }
    ) {
        Resolve-LogPath -LogPath $Path | Should -Be $Path
        Should -Invoke Write-Warning -Times 0 -Exactly
    }

    It "Should not expand wildcard characters" {
        Resolve-LogPath -LogPath 'C:\Logs\run[1].log' | Should -Be 'C:\Logs\run[1].log'
    }

    It "Should end with LogPathInvalidCharacters for <Case>" -ForEach @(
        @{ Case = 'a file name with characters no file can have'; Path = 'C:\Logs\bad<>|?.log'; Segment = 'bad<>|?.log' }
        @{ Case = 'a folder name with such a character'; Path = 'C:\Lo|gs\run.log'; Segment = 'Lo|gs' }
        @{ Case = 'a second colon'; Path = 'C:\Logs\run.log:stream'; Segment = 'run.log:stream' }
    ) {
        $expected = @{
            ErrorId         = 'LogPathInvalidCharacters,Resolve-LogPath'
            ExpectedMessage = "The log path '$Path' cannot be used: '$Segment' holds a character that a file or folder name cannot have."
            ExceptionType   = [System.ArgumentException]
        }
        { Resolve-LogPath -LogPath $Path } | Should -Throw @expected
    }

    It "Should take a network path" {
        Resolve-LogPath -LogPath '\\server\share\logs\run.log' | Should -Be '\\server\share\logs\run.log'
    }

    Context 'With -RefuseSystemFolder, for a path that a configuration file names (#162)' {
        BeforeAll {
            $script:windowsFolder = [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
            $script:programFiles = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
        }

        It 'Should end with LogPathInSystemFolder for a path under <Folder>' -ForEach @(
            @{ Folder = 'Windows' }
            @{ Folder = 'ProgramFiles' }
            @{ Folder = 'ProgramFilesX86' }
        ) {
            $systemFolder = [Environment]::GetFolderPath([Environment+SpecialFolder]$Folder)
            $path = Join-Path $systemFolder 'OrphanedSid\Logs\run.log'

            $expected = @{
                ErrorId         = 'LogPathInSystemFolder,Resolve-LogPath'
                ExpectedMessage = "The log path '$path' is inside the system folder '$systemFolder'.*"
                ExceptionType   = [System.ArgumentException]
            }
            { Resolve-LogPath -LogPath $path -RefuseSystemFolder } | Should -Throw @expected
        }

        It 'Should refuse the folder in another letter case and through ..' {
            $path = $script:windowsFolder.ToLowerInvariant() + '\Temp\..\System32\drivers\etc\run.log'

            { Resolve-LogPath -LogPath $path -RefuseSystemFolder } |
                Should -Throw -ErrorId 'LogPathInSystemFolder,Resolve-LogPath'
        }

        It 'Should refuse the Program Files folder under its short name' {
            # GetFullPath writes the short name out in full. A volume can have short names
            # switched off, and then there is none to test with.
            $shortName = Join-Path (Split-Path $script:programFiles -Qualifier) 'PROGRA~1'
            $resolvesToProgramFiles = (Test-Path -LiteralPath $shortName) -and
                ([System.IO.Path]::GetFullPath($shortName) -eq $script:programFiles)
            if (-not $resolvesToProgramFiles) {
                Set-ItResult -Skipped -Because 'this volume has no short name for Program Files'
                return
            }

            { Resolve-LogPath -LogPath (Join-Path $shortName 'OrphanedSid\run.log') -RefuseSystemFolder } |
                Should -Throw -ErrorId 'LogPathInSystemFolder,Resolve-LogPath'
        }

        It 'Should take a folder whose name only begins like a system folder: <Suffix>' -ForEach @(
            @{ Suffix = 'Logs' }
            @{ Suffix = ' Data' }
            @{ Suffix = '-servers' }
        ) {
            # C:\WindowsLogs is not inside C:\Windows
            $path = "$($script:windowsFolder)$Suffix\run.log"

            Resolve-LogPath -LogPath $path -RefuseSystemFolder | Should -Be $path
        }

        It 'Should take a path outside every system folder' {
            $path = Join-Path (Get-Item -LiteralPath $TestDrive).FullName 'Logs\run.log'

            Resolve-LogPath -LogPath $path -RefuseSystemFolder | Should -Be $path
        }

        It 'Should take a path under a system folder without the switch, as -LogPath is the operator''s choice' {
            $path = Join-Path $script:windowsFolder 'Temp\OrphanedSid\run.log'

            Resolve-LogPath -LogPath $path | Should -Be $path
        }
    }

    It "Should end with LogPathNotFileSystem for a path of another provider" {
        $expected = @{
            ErrorId         = 'LogPathNotFileSystem,Resolve-LogPath'
            ExpectedMessage = "The log path 'HKLM:\Software\run.log' is not a file system path: it belongs to the Registry provider."
            ExceptionType   = [System.ArgumentException]
        }
        { Resolve-LogPath -LogPath 'HKLM:\Software\run.log' } | Should -Throw @expected
    }
}

Describe "New-LogDirectory" -Tag "Unit", "Private", "FileSystem" {
    It "Should leave an existing directory and its files in place" {
        $dir = Join-Path $TestDrive 'existing'
        New-Item -Path $dir -ItemType Directory | Out-Null
        Set-Content -Path (Join-Path $dir 'keep.log') -Value 'keep'

        New-LogDirectory -DirectoryPath $dir

        @(Get-ChildItem $dir).Name | Should -Be @('keep.log')
    }
}
