# Unit tests for Write-StructuredLogEntry.ps1
BeforeAll {
    . "$PSScriptRoot\..\..\..\..\Private\Logging\Write-StructuredLogEntry.ps1"
}

Describe "Write-StructuredLogEntry" {
    # Silence the file write and every output stream
    BeforeAll {
    Mock Add-Content { }
        Mock Write-Warning { }
        Mock Write-Error { }
        Mock Write-Information { }
        Mock Write-Debug { }
        Mock Write-Verbose { }
        Mock Write-Host { }
        
        # Mock Write-ConsoleLogEntry which is defined in the same file
        Mock Write-ConsoleLogEntry { }
        
        # Report Get-LoggingSystemState as unavailable
        Mock Get-Command { 
            return $null 
        } -ParameterFilter { $Name -eq 'Get-LoggingSystemState' }
    }
    
    Context "Parameter Validation" {
        It "Should accept valid parameters without error" {
            { Write-StructuredLogEntry -Message "Test" -Level "Information" } | Should -Not -Throw
        }
        
        It "Should work with all optional parameters" {
            { Write-StructuredLogEntry -Message "Test" -Level "Information" -Component "Test" -CorrelationId "123" -Details @{Key="Value"} } | Should -Not -Throw
        }
    }
    
    Context "Basic Functionality" {
        It "Should complete without error" {
            { Write-StructuredLogEntry -Message "Test message" -Level "Information" } | Should -Not -Throw
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
    }
}
