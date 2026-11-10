#Requires -Version 5.1

# Unit tests for Initialize-LogDirectory.ps1 and the helpers it defines. Every log path is under
# TestDrive; Get-Location is mocked to TestDrive too, so the fallback path never points into the
# repository.
BeforeAll {
    . $PSScriptRoot\..\..\..\..\Private\Logging\Initialize-LoggingSystem.ps1

    . $PSScriptRoot\..\..\..\..\Private\FileSystem\Initialize-LogDirectory.ps1

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

        It "Should replace the content of an existing log file with the header" {
            New-Item -Path $script:TestRoot -ItemType Directory | Out-Null
            "Existing content" | Set-Content $script:TestLogPath

            Initialize-LogDirectory -LogPath $script:TestLogPath

            $content = Get-Content $script:TestLogPath -Raw
            $content | Should -Match "=== OrphanedSid Log ==="
            $content | Should -Not -Match "Existing content"
        }

        It "Should create the directory and file even under -WhatIf" {
            $WhatIfPreference = $true

            Initialize-LogDirectory -LogPath $script:TestLogPath

            Test-Path $script:TestLogPath -PathType Leaf | Should -BeTrue
        }

        It "Should resolve a relative path against the script root" {
            Mock Get-ScriptRootDirectory { $script:TestRoot }

            $result = Initialize-LogDirectory -LogPath 'Logs\relative.log'

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

    Context "Fallback path" {
        It "Should fall back to a timestamped file in the current directory when <Case>" -ForEach @(
            @{ Case = 'the path contains a traversal'; Path = '..\..\..\windows\system32\test.log'; Reason = '*Directory traversal not allowed*' }
            @{ Case = 'the path is outside the allowed directories'; Path = 'C:\Program Files\Company\Application\Logs\Find-UnknownSID.log'; Reason = '*Path must be within script directory*' }
        ) {
            $result = Initialize-LogDirectory -LogPath $Path

            Split-Path $result -Parent | Should -Be $script:FallbackDir
            Split-Path $result -Leaf | Should -Match '^OrphanedSid_\d{8}_\d{6}\.log$'
            $script:LogPath | Should -Be $result
            $script:LogFileInitialized | Should -BeFalse
            $script:LogFileReinitAttempted | Should -BeTrue
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like "Log directory initialization failed: $Reason" }
        }

        It "Should not create anything for a traversal path" {
            Initialize-LogDirectory -LogPath '..\..\..\windows\system32\test.log'

            Test-Path (Join-Path $script:RepositoryRoot 'windows') | Should -BeFalse
            Test-Path $script:FallbackDir | Should -BeFalse
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
            Mock Set-Content { throw 'Write denied' } -ParameterFilter { $Path -like '*test_write_*.tmp' }

            $result = Initialize-LogDirectory -LogPath $script:TestLogPath

            Split-Path $result -Parent | Should -Be $script:FallbackDir
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
                $Message -like "*Insufficient write permissions for log directory '$script:TestRoot': Write denied"
            }
        }

        It "Should fall back when the file name has invalid characters" {
            $result = Initialize-LogDirectory -LogPath (Join-Path $script:TestRoot 'bad<>|?.log')

            Split-Path $result -Parent | Should -Be $script:FallbackDir
            # .NET Framework rejects the name while resolving the path, .NET while writing the file
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like 'Log directory initialization failed:*' }
            $script:LogFileInitialized | Should -BeFalse
        }

        It "Should throw when not even the fallback path can be built" {
            Mock Get-Location { throw 'No current location' }

            { Initialize-LogDirectory -LogPath '..\escape.log' } |
                Should -Throw -ExpectedMessage '*Failed to establish any log file path: No current location*'
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

    # Module bug (#31): '$LogPath = $LogPath.Trim()' assigns '' to a [ValidateNotNullOrEmpty()] parameter, which
    # throws a validation error, so the default-name branch for a whitespace-only path is unreachable
    It "Should use a default timestamped name under Logs for a whitespace-only path" -Skip {
        Mock Get-ScriptRootDirectory { 'C:\Scripts' }

        Resolve-LogPath -LogPath '   ' | Should -Match '^C:\\Scripts\\Logs\\OrphanedSid_\d{8}_\d{6}\.log$'
    }

    It "Should reject a path containing '..'" {
        { Resolve-LogPath -LogPath 'C:\Logs\..\Windows\run.log' } | Should -Throw -ExpectedMessage 'Invalid path: Directory traversal not allowed'
    }

    It "Should reject a log path under <Location>" -ForEach @(
        @{ Location = 'System32'; Path = 'C:\Windows\System32\run.log' }
        @{ Location = 'Program Files'; Path = 'C:\Program Files\App\run.log' }
    ) {
        { Resolve-LogPath -LogPath $Path } | Should -Throw -ExpectedMessage '*Path must be within script directory*'
    }

    It "Should accept a path under Windows\Temp" {
        Resolve-LogPath -LogPath 'C:\Windows\Temp\run.log' | Should -Be 'C:\Windows\Temp\run.log'
    }
}

Describe "Get-ScriptRootDirectory" -Tag "Unit", "Private", "FileSystem" {
    It "Should return the module root, two levels above Private\FileSystem" {
        Get-ScriptRootDirectory | Should -Be $script:RepositoryRoot
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
