#Requires -Version 5.1

# Unit tests for Test-DirectoryAccess.ps1. Directories are created under TestDrive and
# Write-StructuredLog is mocked so each test can assert what was logged.
BeforeAll {
    . $PSScriptRoot\..\..\..\..\Private\FileSystem\Test-DirectoryAccess.ps1

    # Placeholder for the logging function defined in another file: Pester can only mock a command
    # that exists
    function Write-StructuredLog { param($Message, $Level, $Component, $CorrelationId, $LogPath, $Data) }
}

Describe "Test-DirectoryAccess" -Tag "Unit", "Private", "FileSystem" {
    BeforeEach {
        Mock Write-StructuredLog { }

        # TestDrive sits under %TEMP%, which can be an 8.3 short path; expand it so the paths built
        # here match what the function logs
        $script:TestTempDir = Join-Path (Get-Item -LiteralPath $TestDrive).FullName ([guid]::NewGuid().ToString('N'))
        $script:TestNonExistentDir = Join-Path $script:TestTempDir "NonExistent"
        New-Item -Path $script:TestTempDir -ItemType Directory | Out-Null
    }

    Context "Parameter Validation" {
        It "Should reject null path" {
            { Test-DirectoryAccess -Path $null } | Should -Throw
        }

        It "Should reject empty path" {
            { Test-DirectoryAccess -Path "" } | Should -Throw
        }

        It "Should return false and warn for a whitespace-only path" {
            Test-DirectoryAccess -Path "   " | Should -BeFalse

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Warning' -and $Message -eq 'Directory access test failed: Path parameter was empty or null'
            }
        }

        It "Should return one result per path piped in" {
            $paths = (Join-Path $script:TestTempDir 'A'), (Join-Path $script:TestTempDir 'B'), '..\escape'

            $results = $paths | Test-DirectoryAccess

            $results | Should -Be @($true, $true, $false)
        }
    }

    Context "Directory Creation" {
        It "Should create a non-existent directory and log the creation" {
            Test-DirectoryAccess -Path $script:TestNonExistentDir | Should -BeTrue

            Test-Path $script:TestNonExistentDir -PathType Container | Should -BeTrue
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Information' -and $Message -eq "Successfully created directory: $script:TestNonExistentDir"
            }
        }

        It "Should create a nested directory structure" {
            $nestedPath = Join-Path $script:TestNonExistentDir "Level1\Level2\Level3"

            Test-DirectoryAccess -Path $nestedPath | Should -BeTrue

            Test-Path $nestedPath -PathType Container | Should -BeTrue
        }

        It "Should return true for an existing directory without creating it" {
            Test-DirectoryAccess -Path $script:TestTempDir | Should -BeTrue

            Should -Invoke Write-StructuredLog -Times 0 -Exactly -ParameterFilter { $Message -like 'Directory does not exist*' }
        }

        It "Should handle a directory name with spaces and symbols" {
            $specialPath = Join-Path $script:TestTempDir "Test Dir with spaces & symbols"

            Test-DirectoryAccess -Path $specialPath | Should -BeTrue
            Test-Path -LiteralPath $specialPath -PathType Container | Should -BeTrue
        }

        It "Should create the directory even under -WhatIf" {
            $WhatIfPreference = $true

            Test-DirectoryAccess -Path $script:TestNonExistentDir | Should -BeTrue
            Test-Path $script:TestNonExistentDir -PathType Container | Should -BeTrue
        }

        It "Should return false and log when the directory cannot be created" {
            Mock New-Item { throw 'Access denied' }

            Test-DirectoryAccess -Path $script:TestNonExistentDir | Should -BeFalse

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Warning' -and $Message -eq "Failed to create directory '$script:TestNonExistentDir': Access denied"
            }
        }

        It "Should return false for a path with characters a directory name cannot hold" {
            Test-DirectoryAccess -Path (Join-Path $script:TestTempDir 'Test<Dir|') | Should -BeFalse
        }
    }

    Context "Write Permission Testing" {
        It "Should leave no probe file behind" {
            Test-DirectoryAccess -Path $script:TestTempDir | Should -BeTrue

            @(Get-ChildItem $script:TestTempDir -Filter 'access_test_*.tmp').Count | Should -Be 0
        }

        It "Should return false and log when the probe file cannot be written" {
            Mock Out-File { throw [System.UnauthorizedAccessException]::new("Access denied") }

            Test-DirectoryAccess -Path $script:TestTempDir | Should -BeFalse

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Warning' -and $Message -eq "Write access test failed for directory '$script:TestTempDir': Access denied"
            }
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Warning' -and $Message -eq "Directory access validation failed: $script:TestTempDir"
            }
        }

        It "Should return false when the probe file does not appear after the write" {
            # The directory check still sees the directory; only the probe file is reported missing
            Mock Test-Path { $true }
            Mock Test-Path { $false } -ParameterFilter { $Path -like '*access_test_*.tmp' }

            Test-DirectoryAccess -Path $script:TestTempDir | Should -BeFalse

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Message -eq "Write access test failed: File was not created in directory: $script:TestTempDir"
            }
        }
    }

    Context "Security Validation" {
        It "Should refuse a path containing '<Fragment>' without touching the file system" -ForEach @(
            @{ Fragment = '..'; Suffix = '..\..\Windows\System32' }
            @{ Fragment = '\\.\'; Suffix = '\\.\PhysicalDrive0' }
            @{ Fragment = '/./'; Suffix = 'a/./b' }
        ) {
            Mock New-Item { }
            # Concatenated rather than joined: Join-Path would normalize the separators away
            $path = $script:TestTempDir + '\' + $Suffix

            Test-DirectoryAccess -Path $path | Should -BeFalse

            Should -Invoke New-Item -Times 0 -Exactly
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Warning' -and $Message -eq "Directory access test failed: Path contains potential traversal elements: $path"
            }
        }
    }

    Context "Unexpected errors" {
        It "Should return false and log when an unexpected error occurs" {
            Mock Join-Path { throw 'unexpected' }

            Test-DirectoryAccess -Path $script:TestTempDir | Should -BeFalse

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Message -eq "Directory access test error for '$script:TestTempDir': unexpected"
            }
        }
    }

    Context "Logging Integration" {
        It "Should log every entry under the FileSystem-Utilities component and the given correlation ID" {
            $customCorrelationId = [System.Guid]::NewGuid().ToString()

            Test-DirectoryAccess -Path $script:TestNonExistentDir -CorrelationId $customCorrelationId

            Should -Invoke Write-StructuredLog -Times 0 -Exactly -ParameterFilter {
                $CorrelationId -ne $customCorrelationId -or $Component -ne 'FileSystem-Utilities'
            }
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Debug' -and $Message -eq "Directory access validation successful: $script:TestNonExistentDir"
            }
        }
    }
}
