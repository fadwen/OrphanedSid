#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
BeforeAll {
    $ModuleRoot = (Resolve-Path "$PSScriptRoot\..\..\..").Path

    . "$ModuleRoot\Classes\ScriptConfiguration.ps1"

    # Runs ValidateConfiguration and separates its [bool] answer from the warnings that explain it
    function Invoke-Validation {
        param([Parameter(Mandatory)] $Configuration)

        $output = @(& { $Configuration.ValidateConfiguration() } 3>&1)
        [PSCustomObject]@{
            Result   = @($output | Where-Object { $_ -is [bool] })
            Warnings = @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } |
                    ForEach-Object { $_.Message })
        }
    }

    function New-ConfigFile {
        param([Parameter(Mandatory)] [hashtable]$Content)

        $path = Join-Path $TestDrive "config-$([guid]::NewGuid()).json"
        $Content | ConvertTo-Json | Out-File $path -Encoding UTF8
        $path
    }
}

Describe 'ScriptConfiguration Class Tests' -Tag 'Unit', 'Classes', 'ScriptConfiguration' {
    Context 'Constructor Tests' {
        It 'Should initialize all default properties' {
            $config = [ScriptConfiguration]::new()

            $config.BatchSize | Should -Be 50
            $config.MemoryCheckInterval | Should -Be 50
            $config.MaxLogFileSizeMB | Should -Be 10
            $config.EnableLogFileRotation | Should -Be $true
            $config.LogLevel | Should -Be 'Information'
            $config.LogFilePath | Should -BeNullOrEmpty
        }

        It 'Should declare the list properties as string arrays and the settings with their types' {
            $config = [ScriptConfiguration]::new()

            $config.WellKnownSIDPatterns.GetType().Name | Should -Be 'String[]'
            $config.ProtectedSIDs.GetType().Name | Should -Be 'String[]'
            $config.CriticalObjectPatterns.GetType().Name | Should -Be 'String[]'
            $config.BatchSize.GetType().Name | Should -Be 'Int32'
            $config.MemoryCheckInterval.GetType().Name | Should -Be 'Int32'
            $config.MaxLogFileSizeMB.GetType().Name | Should -Be 'Int32'
            $config.EnableLogFileRotation.GetType().Name | Should -Be 'Boolean'
            $config.LogLevel.GetType().Name | Should -Be 'String'
        }
    }

    Context 'InitializeDefaults Method Tests' {
        It 'Should restore defaults over modified values' {
            $config = [ScriptConfiguration]::new()
            $config.BatchSize = 999
            $config.LogLevel = 'Debug'
            $config.ProtectedSIDs = @('S-1-5-21-1-2-3-500')

            $config.InitializeDefaults()

            $config.BatchSize | Should -Be 50
            $config.LogLevel | Should -Be 'Information'
            $config.ProtectedSIDs | Should -Contain 'S-1-5-32-544'
            $config.ProtectedSIDs | Should -Not -Contain 'S-1-5-21-1-2-3-500'
        }

        It 'Should treat the well-known principals as well-known SIDs' {
            $config = [ScriptConfiguration]::new()
            $matchesAny = {
                param($sid)
                @($config.WellKnownSIDPatterns | Where-Object { $sid -match $_ }).Count -gt 0
            }

            foreach ($sid in 'S-1-1-0', 'S-1-5-11', 'S-1-5-32-544', 'S-1-3-0', 'S-1-5-18', 'S-1-5-19',
                'S-1-5-20', 'S-1-5-6', 'S-1-16-12288', 'S-1-5-80-123') {
                & $matchesAny $sid | Should -Be $true -Because "$sid is a well-known SID"
            }
        }

        It 'Should not treat a domain account SID as well-known' {
            $config = [ScriptConfiguration]::new()
            $sid = 'S-1-5-21-1234567890-987654321-123456789-1001'

            @($config.WellKnownSIDPatterns | Where-Object { $sid -match $_ }).Count | Should -Be 0
        }

        It 'Should protect the built-in groups and service accounts' {
            $config = [ScriptConfiguration]::new()

            $config.ProtectedSIDs | Should -Be @('S-1-5-32-544', 'S-1-5-32-545', 'S-1-5-32-546', 'S-1-5-18', 'S-1-5-19', 'S-1-5-20')
        }

        It 'Should mark the privileged groups and default containers as critical objects' {
            $config = [ScriptConfiguration]::new()

            foreach ($dn in 'CN=Domain Admins,CN=Users,DC=contoso,DC=com', 'CN=Schema Admins,CN=Users,DC=contoso,DC=com',
                'CN=Administrators,CN=BUILTIN,DC=contoso,DC=com', 'CN=Computers,DC=contoso,DC=com') {
                @($config.CriticalObjectPatterns | Where-Object { $dn -like $_ }).Count |
                    Should -BeGreaterThan 0 -Because "$dn is a critical object"
            }
        }
    }

    Context 'ValidateConfiguration Method Tests' {
        It 'Should return true with no warnings for the default configuration' {
            $validation = Invoke-Validation -Configuration ([ScriptConfiguration]::new())

            $validation.Result | Should -Be @($true)
            $validation.Warnings.Count | Should -Be 0
        }

        It 'Should accept BatchSize and MemoryCheckInterval at both ends of 1-1000' {
            $config = [ScriptConfiguration]::new()

            $config.BatchSize = 1
            $config.MemoryCheckInterval = 1
            $config.ValidateConfiguration() | Should -Be $true

            $config.BatchSize = 1000
            $config.MemoryCheckInterval = 1000
            $config.ValidateConfiguration() | Should -Be $true
        }

        It 'Should return false and warn for <Name>' -ForEach @(
            @{ Name = 'BatchSize 0'; Property = 'BatchSize'; Value = 0; Warning = 'BatchSize out of valid range (1-1000): 0' }
            @{ Name = 'BatchSize 1001'; Property = 'BatchSize'; Value = 1001; Warning = 'BatchSize out of valid range (1-1000): 1001' }
            @{ Name = 'MemoryCheckInterval 1001'; Property = 'MemoryCheckInterval'; Value = 1001; Warning = 'MemoryCheckInterval out of valid range (1-1000): 1001' }
            @{ Name = 'MemoryCheckInterval 0'; Property = 'MemoryCheckInterval'; Value = 0; Warning = 'MemoryCheckInterval out of valid range (1-1000): 0' }
            @{ Name = 'an unknown LogLevel'; Property = 'LogLevel'; Value = 'InvalidLevel'; Warning = 'Invalid LogLevel specified: InvalidLevel*' }
            @{ Name = 'an invalid SID pattern'; Property = 'WellKnownSIDPatterns'; Value = @('[invalid-regex'); Warning = 'Invalid regex pattern in WellKnownSIDPatterns: `[invalid-regex*' }
            @{ Name = 'a malformed protected SID'; Property = 'ProtectedSIDs'; Value = @('invalid-sid-format'); Warning = 'Invalid protected SID format: invalid-sid-format' }
            @{ Name = 'a protected SID .NET rejects'; Property = 'ProtectedSIDs'; Value = @('S-1-99999999999999999'); Warning = 'Protected SID failed .NET validation: S-1-99999999999999999*' }
            @{ Name = 'an empty critical object pattern'; Property = 'CriticalObjectPatterns'; Value = @(' '); Warning = 'Empty critical object pattern detected' }
            @{ Name = 'a critical object pattern under 3 characters'; Property = 'CriticalObjectPatterns'; Value = @('*a'); Warning = 'Critical object pattern has invalid length: `*a' }
        ) {
            $config = [ScriptConfiguration]::new()
            $config.$Property = $Value

            $validation = Invoke-Validation -Configuration $config

            $validation.Result | Should -Be @($false)
            $validation.Warnings.Count | Should -Be 1
            $validation.Warnings[0] | Should -BeLike $Warning
        }
    }

    Context 'LoadFromFile Static Method Tests' {
        It 'Should load every setting from a valid file' {
            $file = New-ConfigFile -Content @{
                WellKnownSIDPatterns  = @('^S-1-1-0$', '^S-1-5-18$')
                ProtectedSIDs         = @('S-1-5-32-544', 'S-1-5-18')
                BatchSize             = 75
                MemoryCheckInterval   = 25
                LogLevel              = 'Debug'
                LogFilePath           = 'C:\Logs\test.log'
                EnableLogFileRotation = $false
                MaxLogFileSizeMB      = 20
            }

            $config = [ScriptConfiguration]::LoadFromFile($file)

            $config.WellKnownSIDPatterns | Should -Be @('^S-1-1-0$', '^S-1-5-18$')
            $config.ProtectedSIDs | Should -Be @('S-1-5-32-544', 'S-1-5-18')
            $config.BatchSize | Should -Be 75
            $config.MemoryCheckInterval | Should -Be 25
            $config.LogLevel | Should -Be 'Debug'
            $config.LogFilePath | Should -Be 'C:\Logs\test.log'
            $config.EnableLogFileRotation | Should -Be $false
            $config.MaxLogFileSizeMB | Should -Be 20
        }

        It 'Still loads a file that carries the removed EnableDetailedLogging key, and ignores it (#43)' {
            $file = New-ConfigFile -Content @{ EnableDetailedLogging = $true; LogLevel = 'Error' }

            $config = [ScriptConfiguration]::LoadFromFile($file)

            $config.LogLevel | Should -Be 'Error'
            $config.PSObject.Properties.Name | Should -Not -Contain 'EnableDetailedLogging'
        }

        It 'Should keep defaults for settings the file leaves out' {
            $file = New-ConfigFile -Content @{ LogLevel = 'Warning' }

            $config = [ScriptConfiguration]::LoadFromFile($file)

            $config.LogLevel | Should -Be 'Warning'
            $config.BatchSize | Should -Be 50
            $config.EnableLogFileRotation | Should -Be $true
            $config.ProtectedSIDs | Should -Contain 'S-1-5-32-544'
        }

        It 'Accepts a MemoryCheckInterval anywhere in the 1-1000 range the validator allows' {
            # The loader once stopped at 100 while ValidateConfiguration and the documentation said 1-1000
            $file = New-ConfigFile -Content @{ MemoryCheckInterval = 500 }
            [ScriptConfiguration]::LoadFromFile($file).MemoryCheckInterval | Should -Be 500

            $file = New-ConfigFile -Content @{ MemoryCheckInterval = 1001 }
            { [ScriptConfiguration]::LoadFromFile($file) } | Should -Throw -ExpectedMessage '*MemoryCheckInterval must be between 1 and 1000, got: 1001*'
        }

        It 'Should reject <Name>' -ForEach @(
            @{ Name = 'a BatchSize over 1000'; Content = @{ BatchSize = 1001 }; Message = '*BatchSize must be between 1 and 1000, got: 1001*' }
            @{ Name = 'a BatchSize of 0'; Content = @{ BatchSize = 0 }; Message = '*BatchSize must be between 1 and 1000, got: 0*' }
            @{ Name = 'a MemoryCheckInterval of 0'; Content = @{ MemoryCheckInterval = 0 }; Message = '*MemoryCheckInterval must be between 1 and 1000, got: 0*' }
            @{ Name = 'an invalid SID pattern'; Content = @{ WellKnownSIDPatterns = @('[unclosed') }; Message = '*Invalid regex pattern in WellKnownSIDPatterns: `[unclosed*' }
            @{ Name = 'a malformed protected SID'; Content = @{ ProtectedSIDs = @('not-a-sid') }; Message = '*Invalid SID format in ProtectedSIDs: not-a-sid*' }
        ) {
            $file = New-ConfigFile -Content $Content

            { [ScriptConfiguration]::LoadFromFile($file) } | Should -Throw -ExpectedMessage "Failed to load configuration from $file : $Message"
        }

        It 'Should throw naming the path for a non-existent file' {
            $missing = Join-Path $TestDrive 'NonExistent\config.json'

            { [ScriptConfiguration]::LoadFromFile($missing) } | Should -Throw -ExpectedMessage "Configuration file not found: $missing"
        }

        It 'Should throw naming the path for an invalid JSON file' {
            $invalidConfigFile = Join-Path $TestDrive 'invalid-config.json'
            '{ invalid json }' | Out-File $invalidConfigFile -Encoding UTF8

            { [ScriptConfiguration]::LoadFromFile($invalidConfigFile) } | Should -Throw -ExpectedMessage "Failed to load configuration from $invalidConfigFile : *"
        }
    }
}
