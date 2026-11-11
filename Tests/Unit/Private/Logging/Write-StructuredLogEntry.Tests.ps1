# Unit tests for Write-StructuredLogEntry.ps1
BeforeAll {
    . "$PSScriptRoot\..\..\..\..\Private\Logging\Write-StructuredLogEntry.ps1"
}

Describe "Write-StructuredLogEntry" {
    BeforeAll {
        # Placeholders so the optional collaborators can be mocked; the function looks them up with
        # Get-Command and skips them when absent
        function Get-LoggingSystemState { }
        function Test-LogLevel { param($Level) }
    }

    BeforeEach {
        $script:SuppressConsoleOutput = $true
        Mock Get-LoggingSystemState { [PSCustomObject]@{ LogPath = $null } }
        Mock Test-LogLevel { $true }
        Mock Write-ConsoleLogEntry { }
    }

    Context "Parameter Validation" {
        It 'Reports a log file it cannot write through its own warning (#45)' {
        # A folder where the file should be: Add-Content fails with a non-terminating error, which
        # skipped the function's catch and its warning
        $folder = Join-Path $TestDrive 'not-a-file.log'
        $null = New-Item -Path $folder -ItemType Directory -Force

        $warnings = @(Write-StructuredLogEntry -Message 'Test' -Level 'Error' -LogPath $folder 3>&1 2>$null)

        @($warnings | Where-Object { "$_" -like 'Failed to write log entry to file:*' }).Count | Should -Be 1
    }
    It "Should reject an empty Message" {
            { Write-StructuredLogEntry -Message "" -Level "Information" } | Should -Throw
        }

        It "Should reject a Level outside the allowed set" {
            { Write-StructuredLogEntry -Message "Test" -Level "Trace" } | Should -Throw
        }
    }

    Context "File entry" {
        It "Should write level, component, correlation ID and message to the file" {
            $logPath = Join-Path $TestDrive 'entry.log'

            Write-StructuredLogEntry -Message "Test" -Level "Error" -Component "Comp" -CorrelationId "123" -LogPath $logPath

            $line = Get-Content -Path $logPath
            $line | Should -Match '^\[\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}\] \[Error\] \[Comp\] \[123\] Test$'
        }

        It "Should append the details as compressed JSON" {
            $logPath = Join-Path $TestDrive 'details.log'

            Write-StructuredLogEntry -Message "Test" -Level "Information" -Details @{ Key = "Value" } -LogPath $logPath

            Get-Content -Path $logPath | Should -BeLike '* Test | Details: {"Key":"Value"}'
        }

        It "Should normalize INFO to Information" {
            $logPath = Join-Path $TestDrive 'info.log'

            Write-StructuredLogEntry -Message "Test" -Level "INFO" -LogPath $logPath

            Get-Content -Path $logPath | Should -BeLike '*[[]Information] [[]General]*'
            Should -Invoke Write-ConsoleLogEntry -Times 1 -Exactly -ParameterFilter { $Level -eq 'Information' }
        }

        It "Should use the logging system's log path when none is passed" {
            $script:StateLogPath = Join-Path $TestDrive 'state.log'
            Mock Get-LoggingSystemState { [PSCustomObject]@{ LogPath = $script:StateLogPath } }

            Write-StructuredLogEntry -Message "From state" -Level "Information"

            Get-Content -Path $script:StateLogPath | Should -BeLike '*From state'
        }

        It "Should not write to the file when Test-LogLevel filters the level out" {
            $logPath = Join-Path $TestDrive 'filtered.log'
            Mock Test-LogLevel { $false }

            Write-StructuredLogEntry -Message "Filtered" -Level "Debug" -LogPath $logPath

            Test-Path $logPath | Should -BeFalse
            Should -Invoke Write-ConsoleLogEntry -Times 1 -Exactly -ParameterFilter { $FormattedMessage -eq '[Debug] [General] Filtered' }
        }

        It "Should warn instead of throwing when the file cannot be written" {
            Mock Add-Content { throw 'disk full' }
            Mock Write-Warning { }

            Write-StructuredLogEntry -Message "Test" -Level "Information" -LogPath (Join-Path $TestDrive 'x.log')

            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like '*Failed to write log entry to file*disk full*' }
        }

        It "Should send the console form of the entry to Write-ConsoleLogEntry" {
            Write-StructuredLogEntry -Message "Console" -Level "Warning" -Component "Comp"

            Should -Invoke Write-ConsoleLogEntry -Times 1 -Exactly -ParameterFilter {
                $FormattedMessage -eq '[Warning] [Comp] Console' -and $Level -eq 'Warning'
            }
        }
    }
}

Describe "Write-StructuredLogEntry file and console behaviour" {
    # No Add-Content mock here: these tests check what reaches the file and the console streams

    BeforeEach {
        $script:SuppressConsoleOutput = $false
        Mock Write-Warning { }
        Mock Write-Information { }
    }

    Context "Under -WhatIf" {
        It "Still appends the entry to the log file" {
            # -WhatIf on a public command reaches this function through $WhatIfPreference; the log is not
            # the operation being rehearsed and must record the rehearsal
            $logPath = Join-Path $TestDrive 'whatif-entry.log'
            $WhatIfPreference = $true

            Write-StructuredLogEntry -Message "rehearsal entry" -Level "Warning" -LogPath $logPath

            Test-Path $logPath | Should -BeTrue
            Get-Content $logPath -Raw | Should -BeLike '*rehearsal entry*'
        }
    }

    Context "Console suppression" {
        It "Writes nothing to the console streams when console output is suppressed" {
            $script:SuppressConsoleOutput = $true
            $logPath = Join-Path $TestDrive 'suppressed.log'

            Write-StructuredLogEntry -Message "quiet warning" -Level "Warning" -LogPath $logPath
            Write-StructuredLogEntry -Message "quiet info" -Level "Information" -LogPath $logPath

            Should -Invoke Write-Warning -Times 0 -Exactly
            Should -Invoke Write-Information -Times 0 -Exactly
            # The file still receives every entry
            (Get-Content $logPath).Count | Should -Be 2
        }

        It "Writes to the console streams when console output is not suppressed" {
            $logPath = Join-Path $TestDrive 'unsuppressed.log'

            Write-StructuredLogEntry -Message "loud warning" -Level "Warning" -LogPath $logPath

            Should -Invoke Write-Warning -Times 1 -Exactly
        }

        It "Routes <LevelName> to the <Stream> stream" -ForEach @(
            @{ LevelName = 'Critical'; Stream = 'Write-Error' }
            @{ LevelName = 'Error'; Stream = 'Write-Error' }
            @{ LevelName = 'Debug'; Stream = 'Write-Debug' }
            @{ LevelName = 'Verbose'; Stream = 'Write-Verbose' }
        ) {
            Mock Write-Error { }
            Mock Write-Debug { }
            Mock Write-Verbose { }

            Write-ConsoleLogEntry -FormattedMessage "routed $LevelName" -Level $LevelName

            Should -Invoke $Stream -Times 1 -Exactly -ParameterFilter { $Message -eq "routed $LevelName" }
        }
    }
}
