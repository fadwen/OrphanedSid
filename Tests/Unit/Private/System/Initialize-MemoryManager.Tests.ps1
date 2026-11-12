BeforeAll {
    $ScriptPath = $PSScriptRoot

    $ModulePath = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptPath)))

    . "$ModulePath\Classes\MemoryManager.ps1"

    . "$ModulePath\Private\Logging\Write-StructuredLog.ps1"

    . "$ModulePath\Private\System\Initialize-MemoryManager.ps1"
}

Describe "Initialize-MemoryManager" -Tag 'Unit' {
    BeforeEach {
        Mock Write-StructuredLog {}
        Mock Write-Verbose {}
    }

    Context "Parameter Validation" {
        It "Should require MaxMemoryMB parameter" {
            $command = Get-Command Initialize-MemoryManager
            $attribute = $command.Parameters['MaxMemoryMB'].Attributes | Where-Object { $_ -is [Parameter] }
            $attribute.Mandatory | Should -Be $true
        }

        It "Should require CheckInterval parameter" {
            $command = Get-Command Initialize-MemoryManager
            $attribute = $command.Parameters['CheckInterval'].Attributes | Where-Object { $_ -is [Parameter] }
            $attribute.Mandatory | Should -Be $true
        }

        It "Should reject MaxMemoryMB <Value>, outside 100-16384" -ForEach @(
            @{ Value = 99 }
            @{ Value = 16385 }
        ) {
            { Initialize-MemoryManager -MaxMemoryMB $Value -CheckInterval 25 } | Should -Throw -ExpectedMessage '*MaxMemoryMB*'
        }

        It "Should reject CheckInterval <Value>, outside 1-1000" -ForEach @(
            @{ Value = 0 }
            @{ Value = 1001 }
        ) {
            { Initialize-MemoryManager -MaxMemoryMB 1024 -CheckInterval $Value } | Should -Throw -ExpectedMessage '*CheckInterval*'
        }

        It "Should accept the range boundaries MaxMemoryMB <MaxMemoryMB> and CheckInterval <CheckInterval>" -ForEach @(
            @{ MaxMemoryMB = 100; CheckInterval = 1 }
            @{ MaxMemoryMB = 16384; CheckInterval = 1000 }
        ) {
            $result = Initialize-MemoryManager -MaxMemoryMB $MaxMemoryMB -CheckInterval $CheckInterval

            $result.MaxMemoryMB | Should -Be $MaxMemoryMB
            $result.CheckInterval | Should -Be $CheckInterval
        }

        It "Should replace a whitespace CorrelationId with a new GUID" {
            $result = Initialize-MemoryManager -MaxMemoryMB 1024 -CheckInterval 25 -CorrelationId '   '

            $result.CorrelationId | Should -Match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
            Should -Invoke Write-StructuredLog -Times 4 -Exactly -ParameterFilter { $CorrelationId -eq $result.CorrelationId }
        }
    }

    Context "MemoryManager Creation" {
        It "Should create a MemoryManager with the given threshold, interval and correlation ID" {
            $result = Initialize-MemoryManager -MaxMemoryMB 2048 -CheckInterval 30 -CorrelationId 'creation-test-id'

            $result.GetType().Name | Should -Be 'MemoryManager'
            $result.MaxMemoryMB | Should -Be 2048
            $result.CheckInterval | Should -Be 30
            $result.CorrelationId | Should -Be 'creation-test-id'
        }

        It "Should generate a GUID correlation ID when not provided" {
            $result = Initialize-MemoryManager -MaxMemoryMB 1024 -CheckInterval 25

            $result.CorrelationId | Should -Match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
        }

        It "Should return a single object" {
            $output = @(Initialize-MemoryManager -MaxMemoryMB 1024 -CheckInterval 25)

            $output.Count | Should -Be 1
        }
    }

    Context "Logging Integration" {
        It "Should log the start, success, configuration and completion under the MemoryManagement component" {
            Initialize-MemoryManager -MaxMemoryMB 2048 -CheckInterval 50 -CorrelationId 'log-test-id'

            Should -Invoke Write-StructuredLog -Times 4 -Exactly
            Should -Invoke Write-StructuredLog -Times 4 -Exactly -ParameterFilter {
                $Component -eq 'MemoryManagement' -and $CorrelationId -eq 'log-test-id'
            }
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Message -eq 'Initializing memory manager with threshold 2048 MB' -and $Level -eq 'Information'
            }
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Message -eq 'Memory manager initialized successfully' -and $Level -eq 'Information'
            }
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Message -eq 'Configuration: Threshold=2048 MB, CheckInterval=50 operations' -and $Level -eq 'Debug'
            }
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Message -eq 'Memory manager initialization completed' -and $Level -eq 'Debug'
            }
        }
    }

    Context "WhatIf Support" {
        It "Should still create and return the MemoryManager under -WhatIf" {
            $result = Initialize-MemoryManager -MaxMemoryMB 1024 -CheckInterval 25 -CorrelationId 'whatif-id' -WhatIf

            $result.GetType().Name | Should -Be 'MemoryManager'
            $result.MaxMemoryMB | Should -Be 1024
        }

        It "Should replace the Information logs with a WhatIf note under -WhatIf" {
            Initialize-MemoryManager -MaxMemoryMB 1024 -CheckInterval 25 -CorrelationId 'whatif-id' -WhatIf | Out-Null

            Should -Invoke Write-StructuredLog -Times 0 -Exactly -ParameterFilter { $Level -eq 'Information' }
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Message -eq 'Memory manager created for WhatIf simulation' -and $Level -eq 'Debug' -and $CorrelationId -eq 'whatif-id'
            }
            Should -Invoke Write-Verbose -Times 1 -Exactly -ParameterFilter {
                $Message -eq 'WhatIf: Would initialize memory manager with threshold 1024 MB'
            }
        }
    }

    Context "Failure" {
        It "Should log the failure at Error level and stop with the reason" {
            Mock Write-StructuredLog { throw 'log sink unavailable' } -ParameterFilter { $Level -eq 'Information' }

            { Initialize-MemoryManager -MaxMemoryMB 1024 -CheckInterval 25 -CorrelationId 'fail-id' } |
                Should -Throw -ExpectedMessage 'Memory manager initialization failed: log sink unavailable'

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Error' -and $Message -eq 'Failed to initialize memory manager: log sink unavailable' -and $CorrelationId -eq 'fail-id'
            }
        }
    }

    Context "Configuration Constants" {
        It "Should define the constants the cleanup functions read at load time" {
            $script:MemoryManagementConfig | Should -BeOfType [hashtable]
            $script:MemoryManagementConfig.MemoryPressureAmountMB | Should -Be 50
            $script:MemoryManagementConfig.GCRetryAttempts | Should -Be 3
            $script:MemoryManagementConfig.GCRetryDelayMilliseconds | Should -Be 100
            $script:MemoryManagementConfig.LogComponent | Should -Be 'MemoryManagement'
        }

        It "Is assigned only here, so no cleanup function can drop a key another one reads (#98)" {
            $privateRoot = Join-Path $PSScriptRoot '..\..\..\..\Private'
            $assigners = foreach ($file in Get-ChildItem -Path $privateRoot -Filter *.ps1 -Recurse) {
                $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
                $found = $ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                        $node.Left.Extent.Text -eq '$script:MemoryManagementConfig'
                    }, $true)
                if ($found) { $file.Name }
            }
            @($assigners) | Should -Be @('Initialize-MemoryManager.ps1')
        }
    }
}
