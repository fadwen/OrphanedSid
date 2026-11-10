#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
# Unit tests for Write-StructuredLog. Write-StructuredLogEntry and Format-LogMessage are loaded
# for real; individual tests mock Write-StructuredLogEntry where they inspect what it receives.

BeforeAll {
    . "$PSScriptRoot\..\..\..\TestHelpers\Initialize-TestLogging.ps1"

    . "$PSScriptRoot\..\..\..\..\Private\Logging\Write-StructuredLog.ps1"

    . "$PSScriptRoot\..\..\..\..\Private\Logging\Write-StructuredLogEntry.ps1"

    . "$PSScriptRoot\..\..\..\..\Private\Logging\Format-LogMessage.ps1"
}

Describe "Write-StructuredLog" {

    Context "Parameter Validation" {

        It "Should require Message parameter" {
            # Omitting a mandatory parameter makes an interactive host prompt, so the declaration is
            # read instead of invoking the function without it
            $messageAttributes = (Get-Command Write-StructuredLog).Parameters['Message'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] }
            $messageAttributes.Mandatory | Should -BeTrue
        }

        It "Should reject empty string as Message" {
            { Write-StructuredLog -Message "" } | Should -Throw
        }

        It "Should use default Level when not specified" {
            Mock Write-StructuredLogEntry { }
            Write-StructuredLog -Message "Test"
            Should -Invoke Write-StructuredLogEntry -Times 1 -Exactly -ParameterFilter { $Level -eq 'Information' }
        }

        It "Should use default Component when not specified" {
            Mock Write-StructuredLogEntry { }
            Write-StructuredLog -Message "Test"
            Should -Invoke Write-StructuredLogEntry -Times 1 -Exactly -ParameterFilter { $Component -eq 'General' }
        }

        It "Should auto-generate CorrelationId when not provided" {
            Mock Write-StructuredLogEntry { }
            Write-StructuredLog -Message "Test"
            Should -Invoke Write-StructuredLogEntry -Times 1 -Exactly -ParameterFilter {
                $CorrelationId -match "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
            }
        }

        It "Should generate a different CorrelationId for each call" {
            $script:SeenCorrelationIds = [System.Collections.Generic.List[string]]::new()
            Mock Write-StructuredLogEntry { $script:SeenCorrelationIds.Add($CorrelationId) }

            Write-StructuredLog -Message "First"
            Write-StructuredLog -Message "Second"

            $script:SeenCorrelationIds.Count | Should -Be 2
            $script:SeenCorrelationIds[0] | Should -Not -Be $script:SeenCorrelationIds[1]
        }

        It "Should use empty hashtable as default Data when not specified" {
            Mock Write-StructuredLogEntry { }
            Write-StructuredLog -Message "Test"
            Should -Invoke Write-StructuredLogEntry -Times 1 -Exactly -ParameterFilter {
                $Details -is [hashtable] -and $Details.Count -eq 0
            }
        }
    }

    Context "Parameter Forwarding" {

        BeforeEach {
            Mock Write-StructuredLogEntry { }
        }

        It "Should forward Message parameter correctly" {
            $testMessage = "Test log message with special characters: Ã Ã©Ã®Ã´Ã¹"
            Write-StructuredLog -Message $testMessage

            Should -Invoke Write-StructuredLogEntry -Exactly 1 -ParameterFilter {
                $Message -eq $testMessage
            }
        }

        It "Should forward Level parameter correctly" {
            Write-StructuredLog -Message "Test" -Level "Warning"

            Should -Invoke Write-StructuredLogEntry -Exactly 1 -ParameterFilter {
                $Level -eq "Warning"
            }
        }

        It "Should forward Component parameter correctly" {
            Write-StructuredLog -Message "Test" -Component "TestComponent"

            Should -Invoke Write-StructuredLogEntry -Exactly 1 -ParameterFilter {
                $Component -eq "TestComponent"
            }
        }

        It "Should forward CorrelationId parameter correctly" {
            $testGuid = [System.Guid]::NewGuid().ToString()
            Write-StructuredLog -Message "Test" -CorrelationId $testGuid

            Should -Invoke Write-StructuredLogEntry -Exactly 1 -ParameterFilter {
                $CorrelationId -eq $testGuid
            }
        }

        It "Should forward LogPath parameter when provided" {
            $testPath = "C:\Temp\test.log"
            Write-StructuredLog -Message "Test" -LogPath $testPath

            Should -Invoke Write-StructuredLogEntry -Exactly 1 -ParameterFilter {
                $LogPath -eq $testPath
            }
        }

        It "Should not include LogPath parameter when not provided" {
            Write-StructuredLog -Message "Test"

            Should -Invoke Write-StructuredLogEntry -Times 1 -Exactly -ParameterFilter {
                -not $PSBoundParameters.ContainsKey('LogPath')
            }
        }

        It "Should forward Data as Details parameter" {
            $testData = @{ TestKey = 'TestValue'; Number = 42 }
            Write-StructuredLog -Message "Test" -Data $testData

            Should -Invoke Write-StructuredLogEntry -Exactly 1 -ParameterFilter {
                $Details.TestKey -eq 'TestValue' -and $Details.Number -eq 42
            }
        }
    }

    Context "Level Variations" {

        BeforeEach {
            Mock Write-StructuredLogEntry { }
        }

        It "Should forward the <LevelName> level" -ForEach @(
            @{ LevelName = 'Critical' }
            @{ LevelName = 'Error' }
            @{ LevelName = 'Warning' }
            @{ LevelName = 'Information' }
            @{ LevelName = 'Debug' }
            @{ LevelName = 'Verbose' }
        ) {
            Write-StructuredLog -Message "$LevelName message" -Level $LevelName

            Should -Invoke Write-StructuredLogEntry -Exactly 1 -ParameterFilter {
                $Level -eq $LevelName
            }
        }
    }

    Context "Component Variations" {

        BeforeEach {
            Mock Write-StructuredLogEntry { }
        }

        It "Should forward the component name '<ComponentName>' unchanged" -ForEach @(
            @{ ComponentName = 'Security' }
            @{ ComponentName = 'My Custom Component' }
            @{ ComponentName = 'Component-With_Special.Characters' }
        ) {
            Write-StructuredLog -Message "Test" -Component $ComponentName

            Should -Invoke Write-StructuredLogEntry -Exactly 1 -ParameterFilter {
                $Component -eq $ComponentName
            }
        }
    }

    Context "Data Handling" {

        BeforeEach {
            Mock Write-StructuredLogEntry { }
        }

        It "Should handle simple data types" {
            $testDate = Get-Date
            $testData = @{
                StringValue = "Test String"
                IntValue = 42
                BoolValue = $true
                DateValue = $testDate
            }

            Write-StructuredLog -Message "Test" -Data $testData

            Should -Invoke Write-StructuredLogEntry -Exactly 1 -ParameterFilter {
                $Details.StringValue -eq "Test String" -and
                $Details.IntValue -eq 42 -and
                $Details.BoolValue -eq $true -and
                $Details.DateValue -eq $testDate
            }
        }

        It "Should handle complex nested data" {
            $testData = @{
                SimpleValue = "Simple"
                NestedObject = @{
                    SubProperty = "Nested Value"
                    SubNumber = 123
                }
                ArrayValue = @("Item1", "Item2", "Item3")
            }

            Write-StructuredLog -Message "Test" -Data $testData

            Should -Invoke Write-StructuredLogEntry -Exactly 1 -ParameterFilter {
                $Details.SimpleValue -eq "Simple" -and
                $Details.NestedObject.SubProperty -eq "Nested Value" -and
                $Details.NestedObject.SubNumber -eq 123 -and
                ($Details.ArrayValue -join ',') -eq 'Item1,Item2,Item3'
            }
        }

        It "Should handle data with special characters" {
            $testData = @{
                "Key With Spaces" = "Value with spaces"
                "Key-With-Dashes" = "Value-with-dashes"
                "Key_With_Underscores" = "Value_with_underscores"
            }

            Write-StructuredLog -Message "Test" -Data $testData

            Should -Invoke Write-StructuredLogEntry -Exactly 1 -ParameterFilter {
                $Details."Key With Spaces" -eq "Value with spaces" -and
                $Details."Key-With-Dashes" -eq "Value-with-dashes" -and
                $Details."Key_With_Underscores" -eq "Value_with_underscores"
            }
        }

        It "Should pass sensitive data through unchanged for the entry writer to handle" {
            $sensitiveData = @{
                Password = "SuperSecretPassword123!"
                APIKey = "sk_live_1234567890abcdef"
            }

            Write-StructuredLog -Message "Sensitive test" -Data $sensitiveData

            Should -Invoke Write-StructuredLogEntry -Exactly 1 -ParameterFilter {
                $Details.Password -eq "SuperSecretPassword123!" -and $Details.APIKey -eq "sk_live_1234567890abcdef"
            }
        }

        It "Should handle very long messages" {
            $longMessage = "A" * 10000

            Write-StructuredLog -Message $longMessage

            Should -Invoke Write-StructuredLogEntry -Exactly 1 -ParameterFilter {
                $Message -eq $longMessage
            }
        }

        It "Should handle very large data objects" {
            $largeData = @{}
            1..100 | ForEach-Object { $largeData["Key$_"] = "Value$_" * 100 }

            Write-StructuredLog -Message "Test" -Data $largeData

            Should -Invoke Write-StructuredLogEntry -Exactly 1 -ParameterFilter {
                $Details.Count -eq 100 -and $Details.Key100 -eq ("Value100" * 100)
            }
        }
    }

    Context "Error Handling" {

        It "Should propagate errors from Write-StructuredLogEntry" {
            Mock Write-StructuredLogEntry { throw "Simulated logging error" }

            { Write-StructuredLog -Message "Test" } | Should -Throw "*Simulated logging error*"
        }

        It "Should reject null CorrelationId" {
            # $null binds as an empty string, which Write-StructuredLogEntry's ValidateNotNullOrEmpty refuses
            { Write-StructuredLog -Message "Test" -CorrelationId $null } | Should -Throw -ExpectedMessage '*CorrelationId*'
        }
    }

    Context "Integration with Write-StructuredLogEntry" {
        # Write-StructuredLogEntry runs for real and writes to a file under TestDrive

        It "Should write the entry with its level, component, correlation ID and data to the log file" {
            $logPath = Join-Path $TestDrive 'integration.log'
            $testGuid = [System.Guid]::NewGuid().ToString()

            $logParams = @{
                Message = "Integration test message"
                Level = 'Warning'
                Component = "IntegrationTest"
                CorrelationId = $testGuid
                Data = @{ TestKey = "TestValue" }
                LogPath = $logPath
            }
            Write-StructuredLog @logParams

            $line = Get-Content -Path $logPath -Raw
            $line | Should -BeLike "*[[]Warning] [[]IntegrationTest] [[]$testGuid] Integration test message*"
            $line | Should -BeLike '*Details: {"TestKey":"TestValue"}*'
        }

        It "Should append one line per call" {
            $logPath = Join-Path $TestDrive 'several.log'

            foreach ($message in "Message 1", "Message 2", "Message 3") {
                Write-StructuredLog -Message $message -LogPath $logPath
            }

            $lines = @(Get-Content -Path $logPath)
            $lines.Count | Should -Be 3
            $lines[0] | Should -BeLike '*[[]Information] [[]General] *Message 1'
            $lines[2] | Should -BeLike '*Message 3'
        }
    }
}
