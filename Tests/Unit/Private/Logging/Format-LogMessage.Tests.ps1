#Requires -Version 5.1

<#
.SYNOPSIS
    Unit tests for the Format-LogMessage function

.DESCRIPTION
    Tests the Format-LogMessage function for parameter handling, message
    formatting and each output format.
#>

BeforeAll {
    $script:ModuleRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))

    $script:FunctionPath = Join-Path $script:ModuleRoot "Private\Logging\Format-LogMessage.ps1"

    if (Test-Path $script:FunctionPath) {
        . $script:FunctionPath
    }
}

Describe "Format-LogMessage" {
    Context "Parameter Validation" {
        It "Should carry the Message parameter into the output" {
            $data = Format-LogMessage -Message "Test message" -Level "Information" | ConvertFrom-Json
            $data.Message | Should -Be "Test message"
        }

        It "Should reject null or empty Message" {
            { Format-LogMessage -Message "" -Level "Information" } | Should -Throw
            { Format-LogMessage -Message $null -Level "Information" } | Should -Throw
        }

        It "Should carry the Level parameter into the output" {
            $data = Format-LogMessage -Message "Test message" -Level "Warning" | ConvertFrom-Json
            $data.Level | Should -Be "Warning"
        }

        It "Should reject invalid Level values" {
            { Format-LogMessage -Message "Test message" -Level "InvalidLevel" } | Should -Throw
        }

        It "Should use default Component when not specified" {
            $result = Format-LogMessage -Message "Test message" -Level "Information" -Format "PlainText"
            $result | Should -Match "General"
        }

        It "Should accept valid Component parameter" {
            $result = Format-LogMessage -Message "Test message" -Level "Information" -Component "TestComponent" -Format "PlainText"
            $result | Should -Match "TestComponent"
        }

        It "Should auto-generate CorrelationId when not provided" {
            $result = Format-LogMessage -Message "Test message" -Level "Information" -Format "JSON"
            $data = $result | ConvertFrom-Json
            $data.CorrelationId | Should -Match "^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$"
        }

        It "Should accept valid CorrelationId parameter" {
            $testCorrelationId = "test-correlation-123"
            $result = Format-LogMessage -Message "Test message" -Level "Information" -CorrelationId $testCorrelationId -Format "JSON"
            $data = $result | ConvertFrom-Json
            $data.CorrelationId | Should -Be $testCorrelationId
        }

        It "Should use default JSON format when not specified" {
            $result = Format-LogMessage -Message "Test message" -Level "Information"
            # Compressed JSON object, not the bracketed PlainText or the XML document
            $result | Should -Match '^\{.*"Message":"Test message".*\}$'
        }

        It "Should reject invalid Format values" {
            { Format-LogMessage -Message "Test message" -Level "Information" -Format "InvalidFormat" } | Should -Throw
        }

        It "Should add no fields for an empty AdditionalData hashtable" {
            $data = Format-LogMessage -Message "Test message" -Level "Information" -AdditionalData @{} | ConvertFrom-Json
            @($data.PSObject.Properties.Name) | Should -Be @('Timestamp', 'Level', 'Component', 'CorrelationId', 'Message')
        }
    }

    Context "Level Normalization" {
        It "Should normalize INFO to Information" {
            $result = Format-LogMessage -Message "Test message" -Level "INFO" -Format "JSON"
            $data = $result | ConvertFrom-Json
            $data.Level | Should -Be "Information"
        }

        It "Should preserve other valid levels unchanged" {
            $levels = @('Critical', 'Error', 'Warning', 'Information', 'Debug', 'Verbose')
            
            foreach ($level in $levels) {
                $result = Format-LogMessage -Message "Test message" -Level $level -Format "JSON"
                $data = $result | ConvertFrom-Json
                $data.Level | Should -Be $level
            }
        }
    }

    Context "JSON Format Output" {
        It "Should produce valid JSON" {
            $result = Format-LogMessage -Message "Test message" -Level "Information" -Format "JSON"
            { $result | ConvertFrom-Json } | Should -Not -Throw
        }

        It "Should include all required fields in JSON" {
            $result = Format-LogMessage -Message "Test message" -Level "Information" -Format "JSON"
            $data = $result | ConvertFrom-Json
            
            ($data.PSObject.Properties | Where-Object { $_.Name -eq "Timestamp" }) | Should -Not -BeNullOrEmpty
            ($data.PSObject.Properties | Where-Object { $_.Name -eq "Level" }) | Should -Not -BeNullOrEmpty
            ($data.PSObject.Properties | Where-Object { $_.Name -eq "Component" }) | Should -Not -BeNullOrEmpty
            ($data.PSObject.Properties | Where-Object { $_.Name -eq "CorrelationId" }) | Should -Not -BeNullOrEmpty
            ($data.PSObject.Properties | Where-Object { $_.Name -eq "Message" }) | Should -Not -BeNullOrEmpty
        }

        It "Should format timestamp correctly in JSON" {
            $result = Format-LogMessage -Message "Test message" -Level "Information" -Format "JSON"
            # PowerShell 7's ConvertFrom-Json turns an ISO 8601 string into a [DateTime], which is then
            # reformatted on output, so the timestamp text is asserted on the raw JSON instead.
            $result | Should -Match '"Timestamp":\s*"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}[+-]\d{2}:\d{2}"'
        }

        It "Should include AdditionalData fields in JSON" {
            $testData = @{ TestKey = "TestValue"; Number = 42; Boolean = $true }
            $result = Format-LogMessage -Message "Test message" -Level "Information" -Format "JSON" -AdditionalData $testData
            $data = $result | ConvertFrom-Json
            
            $data.TestKey | Should -Be "TestValue"
            $data.Number | Should -Be 42
            $data.Boolean | Should -Be $true
        }

        It "Should produce compressed JSON without whitespace" {
            $result = Format-LogMessage -Message "Test message" -Level "Information" -Format "JSON"
            $result | Should -Not -Match "\n"
            $result | Should -Not -Match "\r"
            $result | Should -Not -Match "  " # Multiple spaces
        }

        It "Should handle complex nested data in JSON" {
            $complexData = @{
                Nested = @{ Inner = "Value"; Deeper = @{ Level3 = 123 } }
                Array = @(1, 2, 3)
                String = "Test"
            }
            $result = Format-LogMessage -Message "Test message" -Level "Information" -Format "JSON" -AdditionalData $complexData
            $data = $result | ConvertFrom-Json
            
            $data.Nested.Inner | Should -Be "Value"
            $data.Nested.Deeper.Level3 | Should -Be 123
            $data.Array.Count | Should -Be 3
        }
    }

    Context "PlainText Format Output" {
        It "Should produce properly formatted plain text" {
            $result = Format-LogMessage -Message "Test message" -Level "Information" -Format "PlainText"
            $result | Should -Match "^\[\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}[+-]\d{2}:\d{2}\] \[Information\] \[General\] \[[a-fA-F0-9-]+\] Test message$"
        }

        It "Should include custom component in plain text" {
            $result = Format-LogMessage -Message "Test message" -Level "Warning" -Component "TestComponent" -Format "PlainText"
            $result | Should -Match "\[TestComponent\]"
        }

        It "Should include custom correlation ID in plain text" {
            $testCorrelationId = "test-123"
            $result = Format-LogMessage -Message "Test message" -Level "Error" -CorrelationId $testCorrelationId -Format "PlainText"
            $result | Should -Match "\[test-123\]"
        }

        It "Should handle special characters in message for plain text" {
            $specialMessage = "Message with [brackets] and (parentheses)"
            $result = Format-LogMessage -Message $specialMessage -Level "Information" -Format "PlainText"
            $escapedMessage = [regex]::Escape($specialMessage)
            $result | Should -Match $escapedMessage
        }

        It "Should ignore AdditionalData in plain text format" {
            $testData = @{ TestKey = "TestValue" }
            $result = Format-LogMessage -Message "Test message" -Level "Information" -Format "PlainText" -AdditionalData $testData
            $result | Should -Not -Match "TestKey"
            $result | Should -Not -Match "TestValue"
        }
    }

    Context "CSV Format Output" {
        It "Should produce properly formatted CSV" {
            $result = Format-LogMessage -Message "Test message" -Level "Information" -Format "CSV"
            $result | Should -Match "^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}[+-]\d{2}:\d{2},Information,General,[a-fA-F0-9-]+,`"Test message`"$"
        }

        It "Should include custom component in CSV" {
            $result = Format-LogMessage -Message "Test message" -Level "Warning" -Component "TestComponent" -Format "CSV"
            $result | Should -Match ",TestComponent,"
        }

        It "Should include custom correlation ID in CSV" {
            $testCorrelationId = "test-123"
            $result = Format-LogMessage -Message "Test message" -Level "Error" -CorrelationId $testCorrelationId -Format "CSV"
            $result | Should -Match ",test-123,"
        }

        It "Should properly quote message with commas in CSV" {
            $messageWithCommas = "Message with, commas, here"
            $result = Format-LogMessage -Message $messageWithCommas -Level "Information" -Format "CSV"
            $result | Should -Match "`"Message with, commas, here`""
        }

        It "Should handle double quotes in message for CSV" {
            $messageWithQuotes = "Message with `"quotes`" here"
            $result = Format-LogMessage -Message $messageWithQuotes -Level "Information" -Format "CSV"
            $result | Should -Match "`"Message with `"quotes`" here`""
        }

        It "Should ignore AdditionalData in CSV format" {
            $testData = @{ TestKey = "TestValue" }
            $result = Format-LogMessage -Message "Test message" -Level "Information" -Format "CSV" -AdditionalData $testData
            $result | Should -Not -Match "TestKey"
            $result | Should -Not -Match "TestValue"
        }
    }

    Context "XML Format Output" {
        It "Should produce valid XML" {
            $result = Format-LogMessage -Message "Test message" -Level "Information" -Format "XML"
            { [xml]$result } | Should -Not -Throw
        }

        It "Should include all required fields in XML" {
            $result = Format-LogMessage -Message "Test message" -Level "Information" -Format "XML"
            $xml = [xml]$result
            $properties = @{}
            foreach ($property in $xml.Objects.Object.Property) {
                $properties[$property.Name] = $property.InnerText
            }

            $properties['Timestamp'] | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}'
            $properties['Level'] | Should -Be 'Information'
            $properties['Component'] | Should -Be 'General'
            $properties['CorrelationId'] | Should -Match '^[a-fA-F0-9-]{36}$'
            $properties['Message'] | Should -Be 'Test message'
        }

        It "Should include AdditionalData fields in XML" {
            $testData = @{ TestKey = "TestValue"; Number = 42 }
            $result = Format-LogMessage -Message "Test message" -Level "Information" -Format "XML" -AdditionalData $testData
            $xml = [xml]$result
            
            ($xml.Objects.Object.Property | Where-Object { $_.Name -eq "TestKey" }).InnerText | Should -Be 'TestValue'
            ($xml.Objects.Object.Property | Where-Object { $_.Name -eq "Number" }).InnerText | Should -Be '42'
        }

        It "Should handle special XML characters properly" {
            $messageWithXmlChars = "Message with <tags> & entities"
            $result = Format-LogMessage -Message $messageWithXmlChars -Level "Information" -Format "XML"
            $result | Should -Match '&lt;tags&gt; &amp; entities'
            $xml = [xml]$result
            ($xml.Objects.Object.Property | Where-Object { $_.Name -eq "Message" }).InnerText | Should -Be $messageWithXmlChars
        }
    }

    Context "Special Characters and Encoding" {
        It "Should handle Unicode characters in message" {
            $unicodeMessage = "Test message with Ã¼Ã±Ã­Ã§Ã¸dÃ© characters Ã±â‚¬"
            $result = Format-LogMessage -Message $unicodeMessage -Level "Information" -Format "JSON"
            $data = $result | ConvertFrom-Json
            $data.Message | Should -Be $unicodeMessage
        }

        It "Should handle newlines and tabs in message" {
            $multilineMessage = "Line 1`nLine 2`tTabbed"
            $result = Format-LogMessage -Message $multilineMessage -Level "Information" -Format "JSON"
            $data = $result | ConvertFrom-Json
            $data.Message | Should -Be $multilineMessage
        }

        It "Should handle PowerShell special characters in message" {
            $specialMessage = "Test `$variable with `"quotes`" and 'apostrophes'"
            $result = Format-LogMessage -Message $specialMessage -Level "Information" -Format "JSON"
            $data = $result | ConvertFrom-Json
            $data.Message | Should -Be $specialMessage
        }

        It "Should handle very long messages" {
            $longMessage = "A" * 10000
            $result = Format-LogMessage -Message $longMessage -Level "Information" -Format "JSON"
            $data = $result | ConvertFrom-Json
            $data.Message.Length | Should -Be 10000
        }

        It "Should handle special characters in component name" {
            $specialComponent = "Component-With_Special.Characters@123"
            $result = Format-LogMessage -Message "Test" -Level "Information" -Component $specialComponent -Format "JSON"
            $data = $result | ConvertFrom-Json
            $data.Component | Should -Be $specialComponent
        }

        It "Should handle special characters in AdditionalData values" {
            $specialData = @{
                "Key With Spaces" = "Value with Ã¼Ã±Ã­Ã§Ã¸dÃ©"
                "Number" = 42.5
                "Special" = "`$null and `"quotes`""
            }
            $result = Format-LogMessage -Message "Test" -Level "Information" -Format "JSON" -AdditionalData $specialData
            $data = $result | ConvertFrom-Json
            
            $data."Key With Spaces" | Should -Be "Value with Ã¼Ã±Ã­Ã§Ã¸dÃ©"
            $data.Number | Should -Be 42.5
            $data.Special | Should -Be "`$null and `"quotes`""
        }
    }

    Context "Timestamp Handling" {
        It "Should stamp the current time" -ForEach @(
            @{ Culture = 'en-US' }
            @{ Culture = 'en-AE' }
            @{ Culture = 'de-DE' }
        ) {
            # The timestamp text is read from the raw JSON and parsed with the exact format the function
            # writes, under the invariant culture, so a day-first culture cannot swap day and month.
            $savedCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
            try {
                [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::new($Culture)
                $before = [DateTimeOffset]::Now
                $result = Format-LogMessage -Message "Test message" -Level "Information" -Format "JSON"
                $after = [DateTimeOffset]::Now
            } finally {
                [System.Threading.Thread]::CurrentThread.CurrentCulture = $savedCulture
            }

            $result -match '"Timestamp":"(?<ts>[^"]+)"' | Should -BeTrue
            $timestamp = [DateTimeOffset]::ParseExact($Matches['ts'],'yyyy-MM-ddTHH:mm:ss.fffzzz',
                [System.Globalization.CultureInfo]::InvariantCulture)

            # The written value is truncated to milliseconds, so allow that much below $before
            $timestamp | Should -BeGreaterOrEqual $before.AddMilliseconds(-1)
            $timestamp | Should -BeLessOrEqual $after
        }
    }

    Context "Error Handling and Edge Cases" {
        It "Should handle null AdditionalData gracefully" {
            $data = Format-LogMessage -Message "Test message" -Level "Information" -AdditionalData $null | ConvertFrom-Json
            @($data.PSObject.Properties.Name) | Should -Be @('Timestamp', 'Level', 'Component', 'CorrelationId', 'Message')
        }

        It "Should handle empty string in AdditionalData values" {
            $testData = @{ EmptyString = ""; ValidValue = "test" }
            $result = Format-LogMessage -Message "Test message" -Level "Information" -Format "JSON" -AdditionalData $testData
            $data = $result | ConvertFrom-Json
            
            $data.EmptyString | Should -Be ""
            $data.ValidValue | Should -Be "test"
        }

        It "Should handle very large AdditionalData hashtables" {
            $largeData = @{}
            for ($i = 1; $i -le 100; $i++) {
                $largeData["Key$i"] = "Value$i"
            }
            
            $result = Format-LogMessage -Message "Large data test" -Level "Information" -Format "JSON" -AdditionalData $largeData
            $data = $result | ConvertFrom-Json
            
            $data.Key1 | Should -Be "Value1"
            $data.Key100 | Should -Be "Value100"
        }

        It "Should handle duplicate keys in AdditionalData gracefully" {
            $testData = @{ Timestamp = "CustomTimestamp"; Level = "CustomLevel" }
            $result = Format-LogMessage -Message "Test message" -Level "Information" -Format "JSON" -AdditionalData $testData
            $data = $result | ConvertFrom-Json
            
            # AdditionalData should override the default values
            $data.Timestamp | Should -Be "CustomTimestamp"
            $data.Level | Should -Be "CustomLevel"
        }
    }

    Context "Enterprise Integration" {
        It "Should support audit trail formatting" {
            $auditData = @{
                UserId = "testuser@domain.com"
                Action = "PermissionModification"
                Resource = "\\server\share\folder"
                Success = $true
            }
            $result = Format-LogMessage -Message "Audit event" -Level "Information" -Component "AuditTrail" -Format "JSON" -AdditionalData $auditData
            $data = $result | ConvertFrom-Json
            
            $data.Component | Should -Be "AuditTrail"
            $data.UserId | Should -Be "testuser@domain.com"
            $data.Action | Should -Be "PermissionModification"
        }

        It "Should support compliance log formatting" {
            $complianceData = @{
                Regulation = "SOX"
                ControlId = "IT-GC-01"
                ComplianceStatus = "Pass"
                Evidence = "Log file verification completed"
            }
            $result = Format-LogMessage -Message "Compliance check" -Level "Information" -Component "Compliance" -Format "JSON" -AdditionalData $complianceData
            $data = $result | ConvertFrom-Json
            
            $data.Regulation | Should -Be "SOX"
            $data.ControlId | Should -Be "IT-GC-01"
            $data.ComplianceStatus | Should -Be "Pass"
        }

        It "Should support security event formatting" {
            $securityData = @{
                SecurityPrincipal = "DOMAIN\ServiceAccount"
                AuthenticationMethod = "Kerberos"
                SourceIP = "192.168.1.100"
                ThreatLevel = "Low"
            }
            $result = Format-LogMessage -Message "Security event" -Level "Warning" -Component "Security" -Format "JSON" -AdditionalData $securityData
            $data = $result | ConvertFrom-Json
            
            $data.SecurityPrincipal | Should -Be "DOMAIN\ServiceAccount"
            $data.AuthenticationMethod | Should -Be "Kerberos"
            $data.ThreatLevel | Should -Be "Low"
        }
    }
}

