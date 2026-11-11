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
    function Initialize-LogDirectory { param($LogPath) }
    function Initialize-MemoryManager { param($MaxMemoryMB, $CheckInterval, $CorrelationId, [switch]$WhatIf) }
}

Describe 'Initialize-ScriptExecution' -Tag 'Unit', 'Core', 'Private' {

    BeforeEach {
        Mock Write-StructuredLog { }
        Mock Initialize-LoggingSystem { }
        # Like the real function: records the path it settled on in module scope and emits it
        Mock Initialize-LogDirectory { $script:LogPath = $LogPath; $LogPath }
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
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter { $Message -like "Loading configuration from file: $cfg" }
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
        It 'Moves a log that exceeds the configured size aside before the run' {
            $cfg = Join-Path $script:workDir 'rotate.json'
            @{ MaxLogFileSizeMB = 1; EnableLogFileRotation = $true } | ConvertTo-Json | Set-Content $cfg
            $log = Join-Path $script:workDir 'big.log'
            $stream = [IO.File]::Create($log); $stream.SetLength(2MB); $stream.Dispose()

            Initialize-ScriptExecution -ConfigPath $cfg -LogPath $log | Out-Null

            Test-Path $log | Should -BeFalse
            @(Get-ChildItem $script:workDir -Filter 'big_*.log').Count | Should -Be 1
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter { $Message -like 'Rotated log file to:*' }
        }

        It 'Leaves a small log alone' {
            $log = Join-Path $script:workDir 'small.log'
            'one line' | Set-Content $log

            Initialize-ScriptExecution -LogPath $log | Out-Null

            Test-Path $log | Should -BeTrue
            Should -Invoke Write-StructuredLog -Times 0 -ParameterFilter { $Message -like 'Rotated log file to:*' }
        }

        It 'Leaves an oversized log alone when rotation is disabled' {
            $cfg = Join-Path $script:workDir 'norotate.json'
            @{ MaxLogFileSizeMB = 1; EnableLogFileRotation = $false } | ConvertTo-Json | Set-Content $cfg
            $log = Join-Path $script:workDir 'big2.log'
            $stream = [IO.File]::Create($log); $stream.SetLength(2MB); $stream.Dispose()

            Initialize-ScriptExecution -ConfigPath $cfg -LogPath $log | Out-Null

            Test-Path $log | Should -BeTrue
        }

        It 'Warns and carries on when the rotation itself fails' {
            $cfg = Join-Path $script:workDir 'rotatefail.json'
            @{ MaxLogFileSizeMB = 1 } | ConvertTo-Json | Set-Content $cfg
            $log = Join-Path $script:workDir 'locked.log'
            $stream = [IO.File]::Create($log); $stream.SetLength(2MB)
            try {
                $result = Initialize-ScriptExecution -ConfigPath $cfg -LogPath $log

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
