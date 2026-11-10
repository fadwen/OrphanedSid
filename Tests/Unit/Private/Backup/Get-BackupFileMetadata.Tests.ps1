#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
#Requires -Version 5.1

<#
.SYNOPSIS
    Unit tests for Get-BackupFileMetadata, which reads the metadata of one Clixml ACL backup.

.DESCRIPTION
    Tests the real function against backup files written to the Pester test drive: parameter
    validation, file system checks, XML import errors, the shape of the result, error logging and
    correlation ID logging.

.NOTES
    Author: Jeffrey Stuhr
#>

# Stub so this file runs on its own: the real Write-StructuredLog needs the whole logging system
# loaded, and every call in Get-BackupFileMetadata is mocked below anyway.
BeforeAll {
    if (-not (Get-Command Write-StructuredLog -ErrorAction SilentlyContinue)) {
        function Write-StructuredLog {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                Justification = 'Stub; the parameter names are what Mock -ParameterFilter binds to')]
            param($Message, $Level, $Component, $CorrelationId, $Data, $LogPath)
        }
    }
}

Describe "Get-BackupFileMetadata" -Tag "Unit", "Backup", "Metadata" {

    BeforeAll {
        # Dot-source the function under test; the module itself is not imported
        . (Join-Path $PSScriptRoot '..\..\..\..\Private\Backup\Get-BackupFileMetadata.ps1')

        # $env:TEMP, and so TestDrive, is an 8.3 short path (RUNNER~1) on the GitHub runners; Get-Item
        # expands it so the paths the function returns, which are long, compare equal to the ones built here
        $script:TestBackupDir = (Get-Item -LiteralPath $TestDrive).FullName
        $script:ValidBackupPath = Join-Path $script:TestBackupDir "valid_backup.xml"
        $script:InvalidBackupPath = Join-Path $script:TestBackupDir "invalid_backup.xml"
        $script:NonExistentPath = Join-Path $script:TestBackupDir "missing_backup.xml"

        Mock Write-StructuredLog { }

        $script:TestBackupData = @{
            ObjectDN            = 'CN=TestUser,OU=Users,DC=company,DC=com'
            BackupDate          = '2024-07-02T10:36:31.123Z'
            CorrelationId       = [System.Guid]::NewGuid().ToString()
            ACLEntryCount       = 5
            SDDLHash            = 'SHA256:abc123def456789'
            BackupVersion       = '1.0.0'
            ValidationSignature = 'VALID_SIGNATURE_12345'
            UserContext         = 'DOMAIN\BackupUser'
            ComputerName        = 'BACKUP-SERVER'
            DomainContext       = 'COMPANY.COM'
            PowerShellVersion   = '5.1.14393.5127'
            Platform            = 'Win32NT'
            PSEdition           = 'Desktop'
            BackupMethod        = 'XML_EXPORT'
            ScriptVersion       = '2.1.0'
        }

        $script:TestBackupData | Export-Clixml -Path $script:ValidBackupPath -Force
        "Invalid XML Content" | Out-File -FilePath $script:InvalidBackupPath -Force
    }

    Context "Parameter Validation" {
        It "Should reject null BackupFilePath" {
            { Get-BackupFileMetadata -BackupFilePath $null } | Should -Throw "*Cannot validate argument on parameter 'BackupFilePath'*"
        }

        It "Should reject empty BackupFilePath" {
            { Get-BackupFileMetadata -BackupFilePath "" } | Should -Throw "*Cannot validate argument on parameter 'BackupFilePath'. The argument is null or empty. Provide an argument that is not null or empty, and then try the command again.*"
        }

        It "Should reject whitespace-only BackupFilePath" {
            { Get-BackupFileMetadata -BackupFilePath "   " } | Should -Throw "*Failed to extract metadata from backup: BackupFilePath cannot be empty or whitespace*"
        }

        It "Should trim whitespace from BackupFilePath" {
            $result = Get-BackupFileMetadata -BackupFilePath "  $script:ValidBackupPath  "
            $result.FilePath | Should -Be $script:ValidBackupPath
            $result.ObjectDN | Should -Be $script:TestBackupData.ObjectDN
        }

        It "Should accept custom CorrelationId" {
            $customCorrelationId = [System.Guid]::NewGuid().ToString()
            $result = Get-BackupFileMetadata -BackupFilePath $script:ValidBackupPath -CorrelationId $customCorrelationId
            $result.ExtractionCorrelationId | Should -Be $customCorrelationId
        }

        It "Should auto-generate CorrelationId when not provided" {
            $result = Get-BackupFileMetadata -BackupFilePath $script:ValidBackupPath
            $result.ExtractionCorrelationId | Should -Match "^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$"
        }

        It "Should support pipeline input for BackupFilePath" {
            $otherPath = Join-Path $script:TestBackupDir "pipeline_backup.xml"
            @{ ObjectDN = 'CN=Second' } | Export-Clixml -Path $otherPath -Force

            $result = @($script:ValidBackupPath, $otherPath | Get-BackupFileMetadata)

            $result.Count | Should -Be 2
            $result.FilePath | Should -Be @($script:ValidBackupPath, $otherPath)
            $result.ObjectDN | Should -Be @($script:TestBackupData.ObjectDN, 'CN=Second')
        }
    }

    Context "File System Validation" {
        It "Should throw for a non-existent file" {
            { Get-BackupFileMetadata -BackupFilePath $script:NonExistentPath } | Should -Throw "*Failed to extract metadata from backup: Backup file not found or inaccessible: $($script:NonExistentPath)*"
        }

        It "Should throw for a directory path instead of a file" {
            { Get-BackupFileMetadata -BackupFilePath $script:TestBackupDir } | Should -Throw "*Failed to extract metadata from backup: Backup file not found or inaccessible: $($script:TestBackupDir)*"
        }

        It "Should check the file as a literal leaf path and stop before importing when the check fails" {
            Mock Test-Path { $false } -ParameterFilter { $LiteralPath -eq $script:ValidBackupPath }
            Mock Import-Clixml { }

            { Get-BackupFileMetadata -BackupFilePath $script:ValidBackupPath } | Should -Throw "*Backup file not found or inaccessible: $($script:ValidBackupPath)*"

            Should -Invoke Test-Path -Times 1 -Exactly -ParameterFilter {
                $LiteralPath -eq $script:ValidBackupPath -and $PathType -eq 'Leaf'
            }
            Should -Invoke Import-Clixml -Times 0 -Exactly
        }

        It "Should read paths with wildcard characters literally" {
            $specialPath = Join-Path $script:TestBackupDir "test[special]backup.xml"
            $script:TestBackupData | Export-Clixml -LiteralPath $specialPath -Force

            $result = Get-BackupFileMetadata -BackupFilePath $specialPath
            $result.FileName | Should -Be "test[special]backup.xml"
            $result.ObjectDN | Should -Be $script:TestBackupData.ObjectDN
        }

        It "Should read a path containing spaces" {
            $spacedPath = Join-Path $script:TestBackupDir "test backup file.xml"
            $script:TestBackupData | Export-Clixml -Path $spacedPath -Force

            $result = Get-BackupFileMetadata -BackupFilePath $spacedPath
            $result.FilePath | Should -Be $spacedPath
        }

        It "Should extract correct file system information" {
            $result = Get-BackupFileMetadata -BackupFilePath $script:ValidBackupPath
            $fileInfo = Get-Item $script:ValidBackupPath

            $result.FileName | Should -Be $fileInfo.Name
            $result.FilePath | Should -Be $fileInfo.FullName
            $result.FileSize | Should -Be $fileInfo.Length
            $result.FileCreationTime | Should -Be $fileInfo.CreationTime
            $result.FileLastWriteTime | Should -Be $fileInfo.LastWriteTime
        }
    }

    Context "XML Import Processing" {
        It "Should throw for invalid XML content" {
            { Get-BackupFileMetadata -BackupFilePath $script:InvalidBackupPath } | Should -Throw "*Failed to extract metadata from backup: Failed to import backup XML data from $($script:InvalidBackupPath) : Data at the root level is invalid. Line 1, position 1.*"
        }

        It "Should wrap an Import-Clixml failure with the file path" {
            Mock Import-Clixml { throw "XML Import Error" } -ParameterFilter { $LiteralPath -eq $script:ValidBackupPath }
            { Get-BackupFileMetadata -BackupFilePath $script:ValidBackupPath } | Should -Throw "*Failed to extract metadata from backup: Failed to import backup XML data from $($script:ValidBackupPath) : XML Import Error*"
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Error' -and $Message -like "Failed to import backup XML data from $($script:ValidBackupPath) : XML Import Error"
            }
        }

        It "Should fail as an import error for a binary file" {
            $corruptedPath = Join-Path $script:TestBackupDir "corrupted_backup.xml"
            [System.IO.File]::WriteAllBytes($corruptedPath, [byte[]](1..50))

            { Get-BackupFileMetadata -BackupFilePath $corruptedPath } | Should -Throw "*Failed to import backup XML data from $corruptedPath*"
        }

        It "Should report a file lock as an import error" {
            Mock Import-Clixml { throw [System.IO.IOException]::new("The process cannot access the file") }
            { Get-BackupFileMetadata -BackupFilePath $script:ValidBackupPath } | Should -Throw "*Failed to extract metadata from backup: Failed to import backup XML data from $($script:ValidBackupPath) : The process cannot access the file*"
        }

        It "Should return null for metadata the backup does not carry" {
            $minimalPath = Join-Path $script:TestBackupDir "minimal_backup.xml"
            @{
                ObjectDN   = 'CN=MinimalTest'
                BackupDate = '2024-01-01T00:00:00.000Z'
            } | Export-Clixml -Path $minimalPath -Force

            $result = Get-BackupFileMetadata -BackupFilePath $minimalPath
            $result.ObjectDN | Should -Be 'CN=MinimalTest'
            $result.BackupDate | Should -Be '2024-01-01T00:00:00.000Z'
            $result.SDDLHash | Should -BeNullOrEmpty
            $result.BackupCorrelationId | Should -BeNullOrEmpty
            $result.ACLEntryCount | Should -BeNullOrEmpty
        }
    }

    Context "Metadata Extraction" {
        BeforeAll {
            $script:TestResult = Get-BackupFileMetadata -BackupFilePath $script:ValidBackupPath
        }

        It "Should extract all backup content information correctly" {
            $script:TestResult.ObjectDN | Should -Be $script:TestBackupData.ObjectDN
            $script:TestResult.BackupDate | Should -Be $script:TestBackupData.BackupDate
            $script:TestResult.BackupCorrelationId | Should -Be $script:TestBackupData.CorrelationId
            $script:TestResult.ACLEntryCount | Should -Be $script:TestBackupData.ACLEntryCount
        }

        It "Should extract all integrity information correctly" {
            $script:TestResult.SDDLHash | Should -Be $script:TestBackupData.SDDLHash
            $script:TestResult.BackupVersion | Should -Be $script:TestBackupData.BackupVersion
            $script:TestResult.ValidationSignature | Should -Be $script:TestBackupData.ValidationSignature
        }

        It "Should extract all environment context correctly" {
            $script:TestResult.BackupUser | Should -Be $script:TestBackupData.UserContext
            $script:TestResult.BackupComputer | Should -Be $script:TestBackupData.ComputerName
            $script:TestResult.BackupDomain | Should -Be $script:TestBackupData.DomainContext
            $script:TestResult.PowerShellVersion | Should -Be $script:TestBackupData.PowerShellVersion
            $script:TestResult.Platform | Should -Be $script:TestBackupData.Platform
            $script:TestResult.PSEdition | Should -Be $script:TestBackupData.PSEdition
        }

        It "Should extract all processing context correctly" {
            $script:TestResult.BackupMethod | Should -Be $script:TestBackupData.BackupMethod
            $script:TestResult.ScriptVersion | Should -Be $script:TestBackupData.ScriptVersion
        }

        It "Should set correct PSTypeName" {
            $script:TestResult.PSObject.TypeNames[0] | Should -Be 'BackupMetadata'
        }

        It "Should have correct property count" {
            ($script:TestResult | Get-Member -MemberType NoteProperty).Count | Should -Be 22
        }

        It "Should stamp the extraction time in the ISO 8601 format" {
            Mock Get-Date { '2025-01-02T03:04:05.678Z' } -ParameterFilter { $Format -eq 'yyyy-MM-ddTHH:mm:ss.fffZ' }

            $result = Get-BackupFileMetadata -BackupFilePath $script:ValidBackupPath

            $result.ExtractionTime | Should -Be '2025-01-02T03:04:05.678Z'
        }
    }

    Context "Error Handling" {
        It "Should log the failure once with the correlation ID" {
            { Get-BackupFileMetadata -BackupFilePath $script:NonExistentPath -CorrelationId 'corr-err' } | Should -Throw

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Error' -and $Message -eq 'Failed to extract metadata from backup file' -and
                $CorrelationId -eq 'corr-err'
            }
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Error' -and $Message -eq "Backup file not found or inaccessible: $($script:NonExistentPath)"
            }
        }

        It "Should wrap a Get-Item failure" {
            Mock Get-Item { throw "Access denied" }
            { Get-BackupFileMetadata -BackupFilePath $script:ValidBackupPath } | Should -Throw "*Failed to extract metadata from backup: Access denied*"
        }

        It "Should maintain error context for debugging" {
            { Get-BackupFileMetadata -BackupFilePath $script:NonExistentPath -CorrelationId 'corr-ctx' } | Should -Throw

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Error' -and $Data.BackupFilePath -eq $script:NonExistentPath -and
                $Data.Function -eq 'Get-BackupFileMetadata' -and $Data.CorrelationId -eq 'corr-ctx' -and
                $Data.Message -eq "Backup file not found or inaccessible: $($script:NonExistentPath)"
            }
        }
    }

    Context "Enterprise Integration" {
        It "Should log operation start and completion" {
            Get-BackupFileMetadata -BackupFilePath $script:ValidBackupPath | Out-Null

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Debug' -and $Message -eq 'Starting backup metadata extraction operation'
            }
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Debug' -and $Message -eq 'Backup metadata extraction operation completed'
            }
        }

        It "Should log the file being read and the successful extraction" {
            Get-BackupFileMetadata -BackupFilePath $script:ValidBackupPath | Out-Null

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Debug' -and $Message -eq "Extracting metadata from backup: $($script:ValidBackupPath)"
            }
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Verbose' -and
                $Message -eq "Successfully extracted metadata for backup: $($script:TestBackupData.ObjectDN)"
            }
        }

        It "Should pass the supplied correlation ID to every log entry" {
            $customCorrelationId = [System.Guid]::NewGuid().ToString()

            Get-BackupFileMetadata -BackupFilePath $script:ValidBackupPath -CorrelationId $customCorrelationId | Out-Null

            Should -Invoke Write-StructuredLog -Times 4 -Exactly -ParameterFilter { $CorrelationId -eq $customCorrelationId }
            Should -Invoke Write-StructuredLog -Times 0 -Exactly -ParameterFilter { $CorrelationId -ne $customCorrelationId }
        }
    }
}
