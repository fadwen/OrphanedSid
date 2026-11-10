#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
#Requires -Version 5.1

<#
.SYNOPSIS
    Unit tests for the Get-SafeFileName function

.DESCRIPTION
    Tests filename sanitization, distinguished name handling, length limits,
    security validation and cross-platform compatibility.

.NOTES
    Author: Jeffrey Stuhr
    Blog: https://www.techbyjeff.net
    LinkedIn: https://www.linkedin.com/in/jeffrey-stuhr-034214aa/
#>

BeforeAll {
    # Pester can only mock a command that exists. The real Write-StructuredLog lives in another file;
    # this placeholder is what the Mock below replaces when the file runs on its own.
    if (-not (Get-Command Write-StructuredLog -ErrorAction SilentlyContinue)) {
        function Write-StructuredLog { param($Message, $Level, $Component, $CorrelationId, $LogPath, $Data) }
    }

    $initLoggingPath = Join-Path $PSScriptRoot "..\..\..\TestHelpers\Initialize-TestLogging.ps1"

    if (Test-Path $initLoggingPath) {
        . $initLoggingPath
    } else {
        Write-Warning "Could not find test logging initialization script"
    }

    $functionPath = Join-Path $PSScriptRoot "..\..\..\..\Private\FileSystem\Get-SafeFileName.ps1"

    if (Test-Path $functionPath) {
        . $functionPath
    } else {
        Write-Error "Cannot find Get-SafeFileName.ps1 at expected path: $functionPath"
    }
}

Describe "Get-SafeFileName" {

    Context "Parameter Validation" {
        
        It "Should accept empty string as valid input" {
            $result = Get-SafeFileName -InputString ""
            $result | Should -Be "Unknown"
        }

        It "Should accept whitespace-only string as valid input" {
            $result = Get-SafeFileName -InputString "   "
            $result | Should -Be "Unknown"
        }

        It "Should validate MaxLength parameter range" {
            { Get-SafeFileName -InputString "test" -MaxLength 5 } | Should -Throw
            { Get-SafeFileName -InputString "test" -MaxLength 250 } | Should -Throw
        }

        It "Should use a default MaxLength of 200" {
            Get-SafeFileName -InputString ("a" * 200) | Should -Be ("a" * 200)
            Get-SafeFileName -InputString ("a" * 201) | Should -Be (("a" * 190) + "_truncated")
        }

        It "Should support pipeline input" {
            $testStrings = @("test1", "test2", "test3")
            $results = $testStrings | Get-SafeFileName
            $results.Count | Should -Be 3
            $results[0] | Should -Be "test1"
            $results[1] | Should -Be "test2"
            $results[2] | Should -Be "test3"
        }
    }

    Context "Basic Filename Sanitization" {

        It "Should return clean filename for normal strings" {
            $result = Get-SafeFileName -InputString "normal_filename"
            $result | Should -Be "normal_filename"
        }

        It "Should replace illegal Windows characters with underscores" {
            $illegalChars = '\/:*?"<>|'
            foreach ($char in $illegalChars.ToCharArray()) {
                $testString = "test${char}file"
                $result = Get-SafeFileName -InputString $testString
                $result | Should -Be "test_file"
            }
        }

        It "Should handle multiple illegal characters in single string" {
            $result = Get-SafeFileName -InputString 'test\file:with*illegal?"chars<>|'
            $result | Should -Be "test_file_with_illegal__chars"
        }

        It "Should consolidate multiple whitespace characters" {
            $result = Get-SafeFileName -InputString "test   multiple    spaces"
            $result | Should -Be "test_multiple_spaces"
        }

        It "Should handle mixed whitespace and illegal characters" {
            $result = Get-SafeFileName -InputString "test file\with:mixed* chars"
            $result | Should -Be "test_file_with_mixed__chars"
        }

        It "Should trim leading and trailing underscores" {
            $result = Get-SafeFileName -InputString "___test___"
            $result | Should -Be "test"
        }

        It "Should trim leading and trailing spaces" {
            $result = Get-SafeFileName -InputString "   test   "
            $result | Should -Be "test"
        }
    }

    Context "Distinguished Name Handling" {

        It "Should sanitize simple Distinguished Name" {
            $dn = "CN=Test User,OU=Users,DC=contoso,DC=com"
            $result = Get-SafeFileName -InputString $dn
            $result | Should -Be "CN=Test_User,OU=Users,DC=contoso,DC=com"
        }

        It "Should handle complex Distinguished Name with special characters" {
            $dn = 'CN=Test\User,OU=IT/Users,DC=contoso,DC=com'
            $result = Get-SafeFileName -InputString $dn
            $result | Should -Be "CN=Test_User,OU=IT_Users,DC=contoso,DC=com"
        }

        It "Should handle Distinguished Name with quotes" {
            $dn = 'CN="Test User",OU=Users,DC=contoso,DC=com'
            $result = Get-SafeFileName -InputString $dn
            $result | Should -Be "CN=_Test_User_,OU=Users,DC=contoso,DC=com"
        }

        It "Should handle very long Distinguished Name" {
            $longDN = "CN=Very Long User Name With Lots Of Text,OU=Very Long Organizational Unit Name,OU=Another Long OU Name,DC=very-long-domain-name,DC=com"
            $result = Get-SafeFileName -InputString $longDN -MaxLength 100
            $result | Should -Match "_truncated$"
            $result.Length | Should -Be 100
        }
    }

    Context "Length Management" {

        It "Should truncate long strings and add suffix" {
            $longString = "a" * 250
            $result = Get-SafeFileName -InputString $longString -MaxLength 50
            $result | Should -Match "_truncated$"
            $result.Length | Should -Be 50
        }

        It "Should preserve content when under length limit" {
            $shortString = "short_filename"
            $result = Get-SafeFileName -InputString $shortString -MaxLength 50
            $result | Should -Be "short_filename"
        }

        It "Should handle edge case where MaxLength equals content length" {
            $testString = "exactly50characters_exactly50characters_exactly50"
            $result = Get-SafeFileName -InputString $testString -MaxLength 50
            $result | Should -Be $testString
        }

        It "Should handle very small MaxLength values" {
            $result = Get-SafeFileName -InputString "test" -MaxLength 15
            $result | Should -Be "test"
        }

        It "Should handle MaxLength smaller than suffix" {
            $result = Get-SafeFileName -InputString "verylongstring" -MaxLength 10
            $result | Should -Be "truncated"
        }

        It "Should calculate truncation correctly with illegal characters" {
            $longStringWithIllegal = ("a" * 100) + "\/:*?" + ("b" * 100)
            $result = Get-SafeFileName -InputString $longStringWithIllegal -MaxLength 50
            $result | Should -Match "_truncated$"
            $result.Length | Should -Be 50
        }
    }

    Context "Edge Cases and Error Handling" {

        It "Should handle string with only illegal characters" {
            $result = Get-SafeFileName -InputString '\/:*?"<>|'
            $result | Should -Match "^Unknown_[a-f0-9]{8}$" # Should generate fallback with hash
            $result.Length | Should -Be 16 # "Unknown_" + 8-char hash
        }

        It "Should handle string that becomes empty after sanitization" {
            $result = Get-SafeFileName -InputString "___"
            $result | Should -Match "^Unknown_[a-f0-9]+$"  # Unknown_ followed by hex characters
        }

        It "Should generate unique fallback names for invalid inputs" {
            $result1 = Get-SafeFileName -InputString "___"
            $result2 = Get-SafeFileName -InputString "___"
            $result1 | Should -Not -Be $result2
        }

        It "Should handle Unicode characters appropriately" {
            $unicodeString = "téšt_fílé_ñámé"
            $result = Get-SafeFileName -InputString $unicodeString
            $result | Should -Be "téšt_fílé_ñámé"
        }

        It "Should handle mixed ASCII and Unicode" {
            $mixedString = "test_fîlé\name:with*ñámé"
            $result = Get-SafeFileName -InputString $mixedString
            $result | Should -Be "test_fîlé_name_with_ñámé"
        }

        It "Should handle numeric input" {
            $result = Get-SafeFileName -InputString "12345"
            $result | Should -Be "12345"
        }

        It "Should handle alphanumeric with symbols" {
            $result = Get-SafeFileName -InputString "test123-file_name.backup"
            $result | Should -Be "test123-file_name.backup"
        }
    }

    Context "Security Validation" {

        It "Should flatten a path traversal attempt '<Text>' into one file name" -ForEach @(
            @{ Text = '..\..\windows\system32'; Expected = '.._.._windows_system32' }
            @{ Text = '../../../../etc/passwd'; Expected = '.._.._.._.._etc_passwd' }
            @{ Text = '..\admin\secrets.txt'; Expected = '.._admin_secrets.txt' }
        ) {
            # With every separator replaced, the dots can no longer address a parent directory
            Get-SafeFileName -InputString $Text | Should -Be $Expected
        }

        It "Should keep characters that are legal in a file name, such as '<Text>'" -ForEach @(
            @{ Text = 'test$(Get-Process).txt' }
            @{ Text = 'file;Remove-Item.log' }
            @{ Text = 'name&dir.backup' }
        ) {
            # Only \/:*?"<>| are illegal on Windows; $, ;, & and parentheses are kept
            Get-SafeFileName -InputString $Text | Should -Be $Text
        }

        It "Should handle potential executable extensions safely" {
            $executableNames = @(
                "malicious.exe",
                "script.bat",
                "trojan.com"
            )
            
            foreach ($name in $executableNames) {
                $result = Get-SafeFileName -InputString $name
                $result | Should -Be $name # Executable extensions are kept unchanged
            }
        }

        It "Should leave reserved device names such as <Text> unchanged" -ForEach @(
            @{ Text = 'CON.txt' }
            @{ Text = 'PRN.log' }
            @{ Text = 'AUX.backup' }
        ) {
            # The function replaces illegal characters only; it does not rename reserved device names
            Get-SafeFileName -InputString $Text | Should -Be $Text
        }
    }

    Context "Cross-Platform Compatibility" {

        It "Should handle Windows UNC path components" {
            $uncPath = "\\server\share\folder\file.txt"
            $result = Get-SafeFileName -InputString $uncPath
            $result | Should -Be "server_share_folder_file.txt"
        }

        It "Should handle Unix-style path components" {
            $unixPath = "/home/user/documents/file.txt"
            $result = Get-SafeFileName -InputString $unixPath
            $result | Should -Be "home_user_documents_file.txt"
        }

        It "Should handle mixed path separators" {
            $mixedPath = "folder\subfolder/file.txt"
            $result = Get-SafeFileName -InputString $mixedPath
            $result | Should -Be "folder_subfolder_file.txt"
        }

        It "Should preserve valid filename extensions" {
            $extensions = @(".txt", ".log", ".csv", ".json", ".xml")
            foreach ($ext in $extensions) {
                $filename = "testfile$ext"
                $result = Get-SafeFileName -InputString $filename
                $result | Should -Be $filename
            }
        }

        It "Should handle filenames with multiple dots" {
            $result = Get-SafeFileName -InputString "file.name.with.dots.txt"
            $result | Should -Be "file.name.with.dots.txt"
        }
    }

    Context "Logging Integration" {

        # Write-StructuredLog is mocked so each test can assert on what was logged
        BeforeEach {
            Mock Write-StructuredLog { }
        }

        It "Should log debug messages for successful operations" {
            $null = Get-SafeFileName -InputString "test_logging"
            
            Should -Invoke Write-StructuredLog -Exactly 1 -ParameterFilter {
                $Message -like "*Safe filename generation successful*" -and $Level -eq "Debug"
            }
        }

        It "Should log debug messages for empty input handling" {
            $null = Get-SafeFileName -InputString ""
            
            Should -Invoke Write-StructuredLog -Exactly 1 -ParameterFilter {
                $Message -like "*Input string was empty*" -and $Level -eq "Debug"
            }
        }

        It "Should log debug messages for truncation operations" {
            $longString = "a" * 250
            $null = Get-SafeFileName -InputString $longString -MaxLength 50
            
            Should -Invoke Write-StructuredLog -Exactly 1 -ParameterFilter {
                $Message -like "*Truncated filename*" -and $Level -eq "Debug"
            }
        }

        It "Should log warning messages for fallback operations" {
            $null = Get-SafeFileName -InputString "___"
            
            Should -Invoke Write-StructuredLog -Exactly 1 -ParameterFilter {
                $Message -like "*Generated fallback filename*" -and $Level -eq "Warning"
            }
        }

        It "Should include correlation ID in all log messages" {
            $testCorrelationId = [System.Guid]::NewGuid().ToString()
            Get-SafeFileName -InputString ("a" * 60) -MaxLength 50 -CorrelationId $testCorrelationId | Out-Null

            # The truncation and the success line
            Should -Invoke Write-StructuredLog -Times 2 -Exactly
            Should -Invoke Write-StructuredLog -Times 2 -Exactly -ParameterFilter {
                $CorrelationId -eq $testCorrelationId
            }
        }

        It "Should generate a correlation ID when none is given" {
            Get-SafeFileName -InputString "test" | Out-Null

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $CorrelationId -match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
            }
        }

        It "Should return an Error_ fallback name and log a warning when processing fails" {
            Mock Write-StructuredLog { throw 'log sink down' } -ParameterFilter { $Level -eq 'Debug' }

            $result = Get-SafeFileName -InputString "test"

            $result | Should -Match '^Error_[a-f0-9]{8}$'
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Warning' -and $Message -eq "Error creating safe filename from 'test': log sink down"
            }
        }
    }

    Context "Enterprise Integration" {

        It "Should fit '<Text>' within MaxLength <Max>" -ForEach @(
            @{ Text = 'configuration_test_filename'; Max = 25; Expected = 'configuration_t_truncated' }
            @{ Text = 'configuration_test_filename'; Max = 50; Expected = 'configuration_test_filename' }
        ) {
            Get-SafeFileName -InputString $Text -MaxLength $Max | Should -Be $Expected
        }

        It "Should leave an already safe name such as '<Text>' unchanged" -ForEach @(
            @{ Text = 'backup_20261110_120000.zip' }
            @{ Text = 'log_server01_20250719.txt' }
            @{ Text = 'config_production_v2.1.json' }
        ) {
            Get-SafeFileName -InputString $Text | Should -Be $Text
        }
    }
}
