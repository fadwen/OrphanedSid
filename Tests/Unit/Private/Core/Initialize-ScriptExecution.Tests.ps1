#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
#Requires -Version 5.1

<#
.SYNOPSIS
    Unit tests for Initialize-ScriptExecution, which builds a run's configuration, memory manager,
    statistics and log file.

.DESCRIPTION
    Tests the real function with the real classes and the logging, log-directory and memory-manager
    functions mocked. The earlier version of this file defined its own Initialize-ScriptExecution and
    tested that.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\..\Classes\ScriptConfiguration.ps1"
    . "$PSScriptRoot\..\..\..\..\Classes\ProcessingStatistics.ps1"
    . "$PSScriptRoot\..\..\..\..\Classes\MemoryManager.ps1"
    . "$PSScriptRoot\..\..\..\..\Private\Core\Initialize-ScriptExecution.ps1"

    function Write-StructuredLog { param($Message, $Level, $Component, $CorrelationId, $LogPath, $Data) }
    function Initialize-LoggingSystem { param($CorrelationId, $LogLevel, [switch]$SuppressConsoleOutput) }
    function Initialize-LogDirectory { param($LogPath, $RotateAboveMB) }
    function Initialize-MemoryManager { param($MaxMemoryMB, $CheckInterval, $CorrelationId, [switch]$WhatIf) }
}

Describe 'Initialize-ScriptExecution' -Tag 'Unit', 'Core', 'Private' {

    BeforeEach {
        Mock Write-StructuredLog { }
        Mock Initialize-LoggingSystem { }
        # Like the real function: records the path it settled on in module scope and emits it
        Mock Initialize-LogDirectory { $script:LogPath = $LogPath; $LogPath }
        $script:LogRotation = $null
        Mock Initialize-MemoryManager { [PSCustomObject]@{ MaxMemoryMB = $MaxMemoryMB; CheckInterval = $CheckInterval } }
        $script:Config = $null
        $script:MemoryManager = $null
        $script:Statistics = $null
        $script:LogPath = $null
        $script:workDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:workDir | Out-Null
    }

    Context 'Parameter validation' {
        It 'Rejects a memory limit outside 100-16384' {
            { Initialize-ScriptExecution -MaxMemoryUsageMB 20 } | Should -Throw -ExpectedMessage '*MaxMemoryUsageMB*'
        }

        It 'Rejects an unknown log level' {
            { Initialize-ScriptExecution -LogLevel 'Loud' } | Should -Throw -ExpectedMessage '*LogLevel*'
        }
    }

    Context 'Default run' {
        It 'Returns the configuration, memory manager, statistics, log path and correlation ID' {
            $result = Initialize-ScriptExecution -LogPath "$($script:workDir)\run.log" -CorrelationId 'init-1'

            $result.Config | Should -BeOfType [ScriptConfiguration]
            $result.Config.BatchSize | Should -Be 50
            $result.MemoryManager.MaxMemoryMB | Should -Be 1024
            $result.MemoryManager.CheckInterval | Should -Be 50
            $result.Statistics | Should -BeOfType [ProcessingStatistics]
            $result.LogPath | Should -Be "$($script:workDir)\run.log"
            $result.CorrelationId | Should -Be 'init-1'
        }

        It 'Leaves the same objects in module scope' {
            $result = Initialize-ScriptExecution -LogPath "$($script:workDir)\run.log"

            $script:Config | Should -Be $result.Config
            $script:MemoryManager | Should -Be $result.MemoryManager
            $script:Statistics | Should -Be $result.Statistics
            $script:LogPath | Should -Be $result.LogPath
        }

        It 'Initializes logging with the level and console switch, then the log folder with the path' {
            Initialize-ScriptExecution -LogPath "$($script:workDir)\run.log" -LogLevel 'Debug' -SuppressConsoleOutput -CorrelationId 'init-2' | Out-Null

            Should -Invoke Initialize-LoggingSystem -Times 1 -Exactly -ParameterFilter {
                $CorrelationId -eq 'init-2' -and $LogLevel -eq 'Debug' -and $SuppressConsoleOutput
            }
            Should -Invoke Initialize-LogDirectory -Times 1 -Exactly -ParameterFilter { $LogPath -eq "$($script:workDir)\run.log" }
        }

        It 'Keeps the path Initialize-LogDirectory settled on, not the raw -LogPath: <Case>' -ForEach @(
            @{ Case = 'a path of only spaces gets the default name'; Given = '   '; Settled = 'C:\Scripts\Logs\OrphanedSid_20260101_120000.log' }
            @{ Case = 'a refused path falls back'; Given = 'C:\Windows\run.log'; Settled = 'C:\Users\op\AppData\Local\Temp\OrphanedSid_fallback.log' }
        ) {
            Mock Initialize-LogDirectory { $script:LogPath = $Settled; $Settled }

            $result = Initialize-ScriptExecution -LogPath $Given

            $result.LogPath | Should -Be $Settled
            $script:LogPath | Should -Be $Settled
        }

        It 'Returns only the initialization table, not the path Initialize-LogDirectory emits' {
            $result = @(Initialize-ScriptExecution -LogPath "$($script:workDir)\run.log")

            $result.Count | Should -Be 1
            $result[0] | Should -BeOfType [hashtable]
        }
        It 'Defaults the log to .\Logs\OrphanedSid_<timestamp>.log when no path is given' {
            Initialize-ScriptExecution | Out-Null

            Should -Invoke Initialize-LogDirectory -Times 1 -Exactly -ParameterFilter { $LogPath -like '.\Logs\OrphanedSid_????????_??????.log' }
        }

        It 'Passes the memory limit and the configured check interval to the memory manager with WhatIf pinned off' {
            Initialize-ScriptExecution -MaxMemoryUsageMB 2048 -CorrelationId 'init-3' | Out-Null

            Should -Invoke Initialize-MemoryManager -Times 1 -Exactly -ParameterFilter {
                $MaxMemoryMB -eq 2048 -and $CheckInterval -eq 50 -and $CorrelationId -eq 'init-3' -and
                $WhatIf -eq $false
            }
        }
    }

    Context 'Configuration file' {
        It 'Loads settings from the file when it exists' {
            $cfg = Join-Path $script:workDir 'config.json'
            @{ BatchSize = 25; MemoryCheckInterval = 10; LogLevel = 'Warning'; MaxLogFileSizeMB = 1 } | ConvertTo-Json | Set-Content $cfg

            $result = Initialize-ScriptExecution -ConfigPath $cfg

            $result.Config.BatchSize | Should -Be 25
            $result.Config.MemoryCheckInterval | Should -Be 10
            $result.Config.LogLevel | Should -Be 'Warning'
            Should -Invoke Initialize-MemoryManager -Times 1 -Exactly -ParameterFilter { $CheckInterval -eq 10 }
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter { $Message -eq "Loaded configuration from file: $cfg" }
        }

        It "Applies the file's LogLevel when asked to, after the file is validated (#43)" {
            $cfg = Join-Path $script:workDir 'level.json'
            @{ LogLevel = 'Error' } | ConvertTo-Json | Set-Content $cfg
            $script:LogLevel = 'Information'

            Initialize-ScriptExecution -ConfigPath $cfg -UseConfigLogLevel -CorrelationId 'init-5' | Out-Null

            $script:LogLevel | Should -Be 'Error'
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Message -eq 'File log level set to Error by the configuration file' -and $CorrelationId -eq 'init-5'
            }
        }

        It "Leaves the command's level alone without -UseConfigLogLevel" {
            $cfg = Join-Path $script:workDir 'level2.json'
            @{ LogLevel = 'Error' } | ConvertTo-Json | Set-Content $cfg
            $script:LogLevel = 'Debug'

            Initialize-ScriptExecution -ConfigPath $cfg -LogLevel 'Debug' | Out-Null

            $script:LogLevel | Should -Be 'Debug'
        }

        It 'Leaves the level alone with -UseConfigLogLevel when there is no configuration file' {
            $script:LogLevel = 'Warning'

            Initialize-ScriptExecution -ConfigPath (Join-Path $script:workDir 'none.json') -UseConfigLogLevel | Out-Null

            $script:LogLevel | Should -Be 'Warning'
            Should -Invoke Write-StructuredLog -Times 0 -ParameterFilter { $Message -like 'File log level set to*' }
        }

        It 'Falls back to the defaults when the file does not exist' {
            $result = Initialize-ScriptExecution -ConfigPath (Join-Path $script:workDir 'missing.json')

            $result.Config.BatchSize | Should -Be 50
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter { $Message -eq 'Using default configuration' }
        }

        It 'Throws when the file holds an invalid setting' {
            $cfg = Join-Path $script:workDir 'bad.json'
            @{ BatchSize = 5000 } | ConvertTo-Json | Set-Content $cfg

            { Initialize-ScriptExecution -ConfigPath $cfg } | Should -Throw -ExpectedMessage '*BatchSize must be between 1 and 1000*'
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'Error' -and $Message -like 'Script initialization failed:*' }
        }

        It 'Uses the log file path from the configuration over the parameter' {
            $cfg = Join-Path $script:workDir 'logpath.json'
            @{ LogFilePath = 'C:\Logs\from-config.log' } | ConvertTo-Json | Set-Content $cfg

            $result = Initialize-ScriptExecution -ConfigPath $cfg -LogPath "$($script:workDir)\param.log"

            $result.LogPath | Should -Be 'C:\Logs\from-config.log'
        }
    }

    Context 'Log rotation' {
        It 'Asks Initialize-LogDirectory to rotate the -LogPath file above the configured size: <Case>' -ForEach @(
            @{ Case = 'the default 10 MB'; Content = $null; Expected = 10 }
            @{ Case = 'a configured size'; Content = @{ MaxLogFileSizeMB = 3 }; Expected = 3 }
            @{ Case = 'rotation disabled'; Content = @{ MaxLogFileSizeMB = 3; EnableLogFileRotation = $false }; Expected = 0 }
        ) {
            $parameters = @{ LogPath = "$($script:workDir)\run.log" }
            if ($Content) {
                $parameters.ConfigPath = Join-Path $script:workDir 'rotate.json'
                $Content | ConvertTo-Json | Set-Content $parameters.ConfigPath
            }

            Initialize-ScriptExecution @parameters | Out-Null

            Should -Invoke Initialize-LogDirectory -Times 1 -Exactly -ParameterFilter { $RotateAboveMB -eq $Expected }
        }

        It 'Logs the rotation Initialize-LogDirectory performed (#44)' {
            Mock Initialize-LogDirectory {
                $script:LogPath = $LogPath
                $script:LogRotation = @{ From = $LogPath; To = 'C:\Logs\run_20260101_120000.log'; SizeMB = 12.5 }
                $LogPath
            }

            Initialize-ScriptExecution -LogPath "$($script:workDir)\run.log" -CorrelationId 'rot-1' | Out-Null

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Information' -and $CorrelationId -eq 'rot-1' -and
                $Message -eq 'Rotated log file to: C:\Logs\run_20260101_120000.log (Size: 12.5 MB)'
            }
        }

        It 'Warns when the rotation failed and the run appends to the oversized file (#44)' {
            Mock Initialize-LogDirectory {
                $script:LogPath = $LogPath
                $script:LogRotation = @{ From = $LogPath; SizeMB = 12.5; Error = 'The process cannot access the file' }
                $LogPath
            }

            Initialize-ScriptExecution -LogPath "$($script:workDir)\run.log" | Out-Null

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Warning' -and
                $Message -eq "Log file rotation failed for $($script:workDir)\run.log (12.5 MB); appending to it: The process cannot access the file"
            }
            Should -Invoke Write-StructuredLog -Times 0 -ParameterFilter { $Message -like 'Rotated log file to:*' }
        }

        It 'Sets up the log file before reporting a configuration file that fails to load (#44)' {
            $cfg = Join-Path $script:workDir 'bad-rotate.json'
            @{ BatchSize = 5000 } | ConvertTo-Json | Set-Content $cfg

            { Initialize-ScriptExecution -ConfigPath $cfg -LogPath "$($script:workDir)\run.log" } | Should -Throw -ExpectedMessage '*BatchSize must be between 1 and 1000*'

            Should -Invoke Initialize-LogDirectory -Times 1 -Exactly -ParameterFilter { $LogPath -eq "$($script:workDir)\run.log" -and $RotateAboveMB -eq 10 }
        }

        It 'Moves a LogFilePath file that exceeds the configured size aside' {
            $log = Join-Path $script:workDir 'big.log'
            $stream = [IO.File]::Create($log); $stream.SetLength(2MB); $stream.Dispose()
            $cfg = Join-Path $script:workDir 'rotate.json'
            @{ MaxLogFileSizeMB = 1; LogFilePath = $log } | ConvertTo-Json | Set-Content $cfg

            Initialize-ScriptExecution -ConfigPath $cfg -LogPath "$($script:workDir)\run.log" | Out-Null

            Test-Path $log | Should -BeFalse
            @(Get-ChildItem $script:workDir -Filter 'big_*.log').Count | Should -Be 1
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter { $Message -like 'Rotated log file to:*' }
        }

        It 'Leaves an oversized LogFilePath file alone when rotation is disabled' {
            $log = Join-Path $script:workDir 'big2.log'
            $stream = [IO.File]::Create($log); $stream.SetLength(2MB); $stream.Dispose()
            $cfg = Join-Path $script:workDir 'norotate.json'
            @{ MaxLogFileSizeMB = 1; EnableLogFileRotation = $false; LogFilePath = $log } | ConvertTo-Json | Set-Content $cfg

            Initialize-ScriptExecution -ConfigPath $cfg -LogPath "$($script:workDir)\run.log" | Out-Null

            Test-Path $log | Should -BeTrue
        }

        It 'Leaves the -LogPath file to Initialize-LogDirectory when no LogFilePath is set' {
            $log = Join-Path $script:workDir 'param.log'
            $stream = [IO.File]::Create($log); $stream.SetLength(2MB); $stream.Dispose()
            $cfg = Join-Path $script:workDir 'small-limit.json'
            @{ MaxLogFileSizeMB = 1 } | ConvertTo-Json | Set-Content $cfg

            Initialize-ScriptExecution -ConfigPath $cfg -LogPath $log | Out-Null

            # Initialize-LogDirectory is mocked here and rotates nothing; nothing else may
            Test-Path $log | Should -BeTrue
            Should -Invoke Write-StructuredLog -Times 0 -ParameterFilter { $Message -like 'Rotated log file to:*' }
        }

        It 'Warns and carries on when rotating a LogFilePath file fails' {
            $log = Join-Path $script:workDir 'locked.log'
            $cfg = Join-Path $script:workDir 'rotatefail.json'
            @{ MaxLogFileSizeMB = 1; LogFilePath = $log } | ConvertTo-Json | Set-Content $cfg
            $stream = [IO.File]::Create($log); $stream.SetLength(2MB)
            try {
                $result = Initialize-ScriptExecution -ConfigPath $cfg -LogPath "$($script:workDir)\run.log"

                $result.Config | Should -Not -BeNullOrEmpty
                Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'Warning' -and $Message -like 'Log file rotation check failed:*' }
            }
            finally {
                $stream.Dispose()
            }
        }
    }
    Context 'Failures' {
        It 'Logs at Error level and rethrows when logging cannot start' {
            Mock Initialize-LoggingSystem { throw 'no log folder' }

            { Initialize-ScriptExecution -CorrelationId 'init-4' } | Should -Throw -ExpectedMessage '*no log folder*'
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Error' -and $Message -like '*no log folder*' -and $CorrelationId -eq 'init-4'
            }
        }
    }
}
