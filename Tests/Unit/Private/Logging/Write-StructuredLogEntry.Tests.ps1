# Unit tests for Write-StructuredLogEntry.ps1
BeforeAll {
    # As OrphanedSid.psm1 does: in the module the code under test runs under strict mode
    Set-StrictMode -Version Latest

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
        # Write-ConsoleLogEntry is mocked, so nothing reaches the console; suppression would stop the
        # function calling it at all
        $script:SuppressConsoleOutput = $false
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

        It "Should write the time with colons in a session whose culture separates time with a dot (#193)" {
            $logPath = Join-Path $TestDrive 'culture.log'
            $savedCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
            try {
                [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::new('fi-FI')
                Write-StructuredLogEntry -Message "Test" -Level "Error" -Component "Comp" -CorrelationId "123" -LogPath $logPath
            } finally {
                [System.Threading.Thread]::CurrentThread.CurrentCulture = $savedCulture
            }

            $line = Get-Content -Path $logPath
            $line | Should -Match '^\[\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}\] \[Error\] \[Comp\] \[123\] Test$'
        }

        It "Should append the details as compressed JSON" {
            $logPath = Join-Path $TestDrive 'details.log'

            Write-StructuredLogEntry -Message "Test" -Level "Information" -Details @{ Key = "Value" } -LogPath $logPath

            Get-Content -Path $logPath | Should -BeLike '* Test | Details: {"Key":"Value"}'
        }

        It "Should write a date among the details as text with its offset: <Kind> (#196)" -ForEach @(
            @{ Kind = 'a date that was constructed'; Date = [datetime]::new(2026, 11, 21, 11, 38, 29, [System.DateTimeKind]::Local) }
            @{ Kind = 'the object that Get-Date returns'; Date = (Get-Date -Year 2026 -Month 11 -Day 21 -Hour 11 -Minute 38 -Second 29) }
        ) {
            # ConvertTo-Json writes the first as \/Date(...)\/ on Windows PowerShell 5.1 and the
            # second as an object with the properties value, DisplayHint and DateTime. The line
            # is read as text, because ConvertFrom-Json would turn the text back into a date.
            $logPath = Join-Path $TestDrive "details-date-$([guid]::NewGuid().ToString('N')).log"

            Write-StructuredLogEntry -Message "Test" -Level "Error" -Details @{ Function = 'New-ACLBackup'; Timestamp = $Date } -LogPath $logPath

            $line = Get-Content -Path $logPath
            $line | Should -Match '"Timestamp":"2026-11-21T11:38:29\.\d{3}[+-]\d{2}:\d{2}"'
            $line | Should -Match '"Function":"New-ACLBackup"'
            $line | Should -Not -Match 'DisplayHint|\\/Date\('
        }

        It "Should end a date among the details with <Ending> when its kind is <Kind> (#196)" -ForEach @(
            @{ Kind = 'Utc'; Ending = 'Z'; Expected = '"Timestamp":"2026-11-21T11:38:29\.000Z"' }
            @{ Kind = 'Unspecified'; Ending = 'no offset'; Expected = '"Timestamp":"2026-11-21T11:38:29\.000"' }
        ) {
            # Nothing says which offset a date of unspecified kind has, so none is written
            $logPath = Join-Path $TestDrive "details-kind-$Kind.log"
            $date = [datetime]::new(2026, 11, 21, 11, 38, 29, [System.DateTimeKind]$Kind)

            Write-StructuredLogEntry -Message "Test" -Level "Error" -Details @{ Timestamp = $date } -LogPath $logPath

            Get-Content -Path $logPath | Should -Match $Expected
        }

        It "Should write a date among the details with colons in a session whose culture separates time with a dot (#196)" {
            $logPath = Join-Path $TestDrive 'details-culture.log'
            $date = [datetime]::new(2026, 11, 21, 11, 38, 29, [System.DateTimeKind]::Local)
            $savedCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
            try {
                [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::new('fi-FI')
                Write-StructuredLogEntry -Message "Test" -Level "Error" -Details @{ Timestamp = $date } -LogPath $logPath
            } finally {
                [System.Threading.Thread]::CurrentThread.CurrentCulture = $savedCulture
            }

            Get-Content -Path $logPath | Should -Match '"Timestamp":"2026-11-21T11:38:29\.000[+-]\d{2}:\d{2}"'
        }

        It "Should leave the caller's details as they were" {
            $logPath = Join-Path $TestDrive 'details-caller.log'
            $details = @{ Timestamp = [datetime]::new(2026, 11, 21, 11, 38, 29, [System.DateTimeKind]::Local) }

            Write-StructuredLogEntry -Message "Test" -Level "Error" -Details $details -LogPath $logPath

            $details['Timestamp'] | Should -BeOfType [datetime]
        }

        It "Should write the line without details when the details are null" {
            $logPath = Join-Path $TestDrive 'details-null.log'

            $warnings = @(Write-StructuredLogEntry -Message "Test" -Level "Error" -Component "Comp" -CorrelationId "123" -Details $null -LogPath $logPath 3>&1)

            $warnings | Should -BeNullOrEmpty
            Get-Content -Path $logPath | Should -Match '\[Error\] \[Comp\] \[123\] Test$'
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
            $DebugPreference = 'Continue'

            Write-StructuredLogEntry -Message "Filtered" -Level "Debug" -LogPath $logPath

            Test-Path $logPath | Should -BeFalse
            Should -Invoke Write-ConsoleLogEntry -Times 1 -Exactly -ParameterFilter { $FormattedMessage -eq '[Debug] [General] Filtered' }
        }

        It "Formats nothing for a <LevelName> entry the file level filters and the console stream does not show (#111)" -ForEach @(
            @{ LevelName = 'Debug' }
            @{ LevelName = 'Verbose' }
        ) {
            Mock Test-LogLevel { $false }
            Mock Get-Date { throw 'an entry with no destination should not be formatted' }
            $DebugPreference = 'SilentlyContinue'
            $VerbosePreference = 'SilentlyContinue'

            Write-StructuredLogEntry -Message "Discarded" -Level $LevelName -LogPath (Join-Path $TestDrive 'discarded.log')

            Should -Invoke Write-ConsoleLogEntry -Times 0 -Exactly
            Should -Invoke Get-LoggingSystemState -Times 0 -Exactly
            Should -Invoke Get-Date -Times 0 -Exactly
            Test-Path (Join-Path $TestDrive 'discarded.log') | Should -BeFalse
        }

        It "Still shows a <LevelName> entry the file level filters when the <LevelName> stream is on" -ForEach @(
            @{ LevelName = 'Debug'; Preference = 'DebugPreference' }
            @{ LevelName = 'Verbose'; Preference = 'VerbosePreference' }
        ) {
            Mock Test-LogLevel { $false }
            Set-Variable -Name $Preference -Value 'Continue'

            Write-StructuredLogEntry -Message "Shown" -Level $LevelName

            Should -Invoke Write-ConsoleLogEntry -Times 1 -Exactly -ParameterFilter { $FormattedMessage -eq "[$LevelName] [General] Shown" }
        }

        It "Still writes a Debug entry to the file when the file level keeps it and the stream is off" {
            $logPath = Join-Path $TestDrive 'debug-kept.log'
            $DebugPreference = 'SilentlyContinue'

            Write-StructuredLogEntry -Message "Kept" -Level "Debug" -LogPath $logPath

            Get-Content -Path $logPath | Should -BeLike '*[[]Debug] [[]General]*Kept'
            Should -Invoke Write-ConsoleLogEntry -Times 0 -Exactly
        }

        It "Writes a Warning to the file but not the console when console output is suppressed" {
            $logPath = Join-Path $TestDrive 'suppressed-warning.log'
            $script:SuppressConsoleOutput = $true

            Write-StructuredLogEntry -Message "Quiet" -Level "Warning" -LogPath $logPath

            Get-Content -Path $logPath | Should -BeLike '*Quiet'
            Should -Invoke Write-ConsoleLogEntry -Times 0 -Exactly
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
