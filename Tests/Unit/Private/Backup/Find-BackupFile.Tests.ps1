#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
Describe "Find-BackupFile Function Tests" -Tag "Unit", "Backup", "Discovery" {

    BeforeAll {
        $env:PESTER_TESTING = 'true'

        # Placeholder for the logging function, so the logging system need not be loaded; mocked below
        function Write-StructuredLog {
            param($Message, $Level, $CorrelationId, $Component, $Data, $Details)
        }

        # Dot-source the function under test and its collaborator; the module itself is not imported
        $RootPath = Join-Path $PSScriptRoot '..\..\..\..'
        $PrivatePath = Join-Path $RootPath 'Private'

        . (Join-Path $PrivatePath 'Backup\Get-BackupFileMetadata.ps1')
        . (Join-Path $PrivatePath 'Backup\Find-BackupFile.ps1')

        function New-FakeFile {
            param([string]$FullName)
            [PSCustomObject]@{
                Name     = Split-Path -Path $FullName -Leaf
                FullName = $FullName
            }
        }

        function New-FakeMetadata {
            param([string]$ObjectDN, [string]$BackupDate, [string]$Signature)
            [PSCustomObject]@{
                ObjectDN            = $ObjectDN
                BackupDate          = $BackupDate
                BackupVersion       = 'v1.0'
                ValidationSignature = $Signature
                IntegrityStatus     = 'Valid'
                BackupSize          = 1024
                ChecksumValid       = $true
            }
        }

        Mock Write-StructuredLog { }
        Mock Write-Progress { }
        Mock Write-Verbose { }

        # Directory existence: only the known folders exist
        Mock Test-Path { $false }
        Mock Test-Path { $true } -ParameterFilter {
            $Path -in @('C:\ValidBackupPath', 'C:\EmptyBackupPath', 'C:\AccessDeniedPath')
        }

        Mock Get-ChildItem { @() }
        Mock Get-ChildItem {
            @(
                New-FakeFile 'C:\ValidBackupPath\backup1.xml'
                New-FakeFile 'C:\ValidBackupPath\backup2.xml'
                New-FakeFile 'C:\ValidBackupPath\Subfolder\backup3.xml'
            )
        } -ParameterFilter { $Path -eq 'C:\ValidBackupPath' }
        Mock Get-ChildItem {
            throw [System.UnauthorizedAccessException]::new('Access denied to backup directory')
        } -ParameterFilter { $Path -eq 'C:\AccessDeniedPath' }

        Mock Get-BackupFileMetadata {
            switch ($BackupFilePath) {
                'C:\ValidBackupPath\backup1.xml' {
                    New-FakeMetadata 'CN=TestUser1,OU=Users,DC=company,DC=com' '2025-07-10T10:00:00Z' 'Sig1'
                }
                'C:\ValidBackupPath\backup2.xml' {
                    New-FakeMetadata 'CN=TestUser2,OU=Sales,DC=company,DC=com' '2025-07-12T14:30:00Z' 'Sig2'
                }
                'C:\ValidBackupPath\Subfolder\backup3.xml' {
                    New-FakeMetadata 'CN=TestComputer,OU=Computers,DC=company,DC=com' '2025-07-13T08:15:00Z' 'Sig3'
                }
            }
        }
    }

    Context "Parameter Validation" {
        It "Should reject null or empty backup path" {
            { Find-BackupFile -BackupPath $null } | Should -Throw "*Failed to discover backup files: BackupPath cannot be empty or whitespace*"
            { Find-BackupFile -BackupPath '' } | Should -Throw "*Failed to discover backup files: BackupPath cannot be empty or whitespace*"
            { Find-BackupFile -BackupPath '   ' } | Should -Throw "*Failed to discover backup files: BackupPath cannot be empty or whitespace*"
            Should -Invoke Get-ChildItem -Times 0 -Exactly
        }

        It "Should reject non-existent backup path and log the failure" {
            { Find-BackupFile -BackupPath 'C:\InvalidBackupPath' } | Should -Throw "*Failed to discover backup files: Backup directory not found or inaccessible: C:\InvalidBackupPath*"
            Should -Invoke Test-Path -Times 1 -Exactly -ParameterFilter {
                $Path -eq 'C:\InvalidBackupPath' -and $PathType -eq 'Container'
            }
            # The inner catch around Test-Path re-catches the Write-Error, so the message is logged twice (#20)
            Should -Invoke Write-StructuredLog -Times 1 -ParameterFilter {
                $Level -eq 'Error' -and $Message -eq 'Backup directory not found or inaccessible: C:\InvalidBackupPath'
            }
            Should -Invoke Get-ChildItem -Times 0 -Exactly
        }

        It "Should report a path whose existence check throws as inaccessible" {
            Mock Test-Path { throw 'Illegal characters in path' } -ParameterFilter { $Path -eq 'C:\Broken|Path' }

            { Find-BackupFile -BackupPath 'C:\Broken|Path' } | Should -Throw "*Backup directory not found or inaccessible: C:\Broken|Path*"
            Should -Invoke Get-ChildItem -Times 0 -Exactly
        }

        It "Should reject a StartDate that is not a DateTime before checking the path" {
            $invalidDateRange = @{ StartDate = 'invalid'; EndDate = 'invalid' }
            { Find-BackupFile -BackupPath 'C:\ValidBackupPath' -DateRange $invalidDateRange } | Should -Throw "*Failed to discover backup files: DateRange.StartDate must be a DateTime object*"
            Should -Invoke Test-Path -Times 0 -Exactly
        }

        It "Should reject an EndDate that is not a DateTime" {
            $invalidDateRange = @{ StartDate = [DateTime]'2025-07-01'; EndDate = 'invalid' }
            { Find-BackupFile -BackupPath 'C:\ValidBackupPath' -DateRange $invalidDateRange } | Should -Throw "*DateRange.EndDate must be a DateTime object*"
        }

        It "Should validate DateRange start before end" {
            $invalidDateRange = @{
                StartDate = [DateTime]'2025-07-02'
                EndDate   = [DateTime]'2025-07-01'
            }
            { Find-BackupFile -BackupPath 'C:\ValidBackupPath' -DateRange $invalidDateRange } | Should -Throw "*Failed to discover backup files: DateRange.StartDate cannot be later than DateRange.EndDate*"
        }

        It "Should generate a correlation ID if not provided and use it for every metadata call" {
            $result = Find-BackupFile -BackupPath 'C:\ValidBackupPath'

            $generated = $result[0].DiscoveryCorrelationId
            $generated | Should -Match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
            Should -Invoke Get-BackupFileMetadata -Times 3 -Exactly -ParameterFilter { $CorrelationId -eq $generated }
        }

        It "Should accept the backup path from the pipeline" {
            $result = 'C:\ValidBackupPath' | Find-BackupFile

            $result.Count | Should -Be 3
        }
    }

    Context "Core Backup Discovery Functionality" {
        It "Should discover all backup files in valid directory" {
            $result = Find-BackupFile -BackupPath 'C:\ValidBackupPath'

            $result.Count | Should -Be 3
            $result | ForEach-Object { $_.PSObject.TypeNames[0] | Should -Be 'BackupInventoryResult' }
            $result.ObjectDN | Should -Be @(
                'CN=TestUser1,OU=Users,DC=company,DC=com'
                'CN=TestUser2,OU=Sales,DC=company,DC=com'
                'CN=TestComputer,OU=Computers,DC=company,DC=com'
            )
        }

        It "Should copy every metadata property into the result" {
            $result = Find-BackupFile -BackupPath 'C:\ValidBackupPath'

            $result[1].ValidationSignature | Should -Be 'Sig2'
            $result[1].BackupDate | Should -Be '2025-07-12T14:30:00Z'
            $result[1].BackupVersion | Should -Be 'v1.0'
            $result[1].IntegrityStatus | Should -Be 'Valid'
            $result[1].BackupSize | Should -Be 1024
            $result[1].ChecksumValid | Should -BeTrue
        }

        It "Should add discovery context to results" {
            $correlationId = [System.Guid]::NewGuid().ToString()
            $result = Find-BackupFile -BackupPath 'C:\ValidBackupPath' -CorrelationId $correlationId

            foreach ($backup in $result) {
                $backup.DiscoveryCorrelationId | Should -Be $correlationId
                $backup.DiscoveryTime | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$'
                $backup.FilteredByObjectDN | Should -BeFalse
                $backup.FilteredByDateRange | Should -BeFalse
            }
        }

        It "Should return an empty collection for an empty backup directory" {
            $result = Find-BackupFile -BackupPath 'C:\EmptyBackupPath'

            @($result).Count | Should -Be 0
            Should -Invoke Get-BackupFileMetadata -Times 0 -Exactly
        }

        It "Should search recursively for XML files only" {
            $null = Find-BackupFile -BackupPath 'C:\ValidBackupPath'

            Should -Invoke Get-ChildItem -Times 1 -Exactly -ParameterFilter {
                $Path -eq 'C:\ValidBackupPath' -and $Filter -eq '*.xml' -and $Recurse -and $File
            }
        }

        It "Should call Get-BackupFileMetadata once for each discovered file" {
            $null = Find-BackupFile -BackupPath 'C:\ValidBackupPath'

            Should -Invoke Get-BackupFileMetadata -Times 3 -Exactly
            foreach ($path in 'C:\ValidBackupPath\backup1.xml', 'C:\ValidBackupPath\backup2.xml', 'C:\ValidBackupPath\Subfolder\backup3.xml') {
                Should -Invoke Get-BackupFileMetadata -Times 1 -Exactly -ParameterFilter { $BackupFilePath -eq $path }
            }
        }

        It "Should trim whitespace from the backup path before using it" {
            $result = Find-BackupFile -BackupPath '  C:\ValidBackupPath  '

            $result.Count | Should -Be 3
            Should -Invoke Get-ChildItem -Times 1 -Exactly -ParameterFilter { $Path -eq 'C:\ValidBackupPath' }
        }
    }

    Context "ObjectDN Filtering" {
        It "Should filter backups by ObjectDN pattern" {
            $result = Find-BackupFile -BackupPath 'C:\ValidBackupPath' -ObjectDN '*Sales*'

            $result.Count | Should -Be 1
            $result[0].ObjectDN | Should -Be 'CN=TestUser2,OU=Sales,DC=company,DC=com'
            $result[0].FilteredByObjectDN | Should -BeTrue
        }

        It "Should handle wildcard patterns correctly" {
            $result = Find-BackupFile -BackupPath 'C:\ValidBackupPath' -ObjectDN '*User?,*'

            $result.Count | Should -Be 2
            $result.ObjectDN | Should -Be @(
                'CN=TestUser1,OU=Users,DC=company,DC=com'
                'CN=TestUser2,OU=Sales,DC=company,DC=com'
            )
        }

        It "Should return empty results when no matches found" {
            $result = Find-BackupFile -BackupPath 'C:\ValidBackupPath' -ObjectDN '*NonExistent*'

            $result.Count | Should -Be 0
        }

        It "Should handle exact DN matches" {
            $result = Find-BackupFile -BackupPath 'C:\ValidBackupPath' -ObjectDN 'CN=TestUser1,OU=Users,DC=company,DC=com'

            $result.Count | Should -Be 1
            $result[0].ObjectDN | Should -Be 'CN=TestUser1,OU=Users,DC=company,DC=com'
        }

        It "Should treat the ObjectDN filter as a pattern and never evaluate it" {
            Mock Get-BackupFileMetadata {
                New-FakeMetadata '$(Get-Process)' '2025-07-10T10:00:00Z' 'Literal'
            }

            $result = Find-BackupFile -BackupPath 'C:\ValidBackupPath' -ObjectDN '$(Get-Process)'

            $result.Count | Should -Be 3
            $result[0].ObjectDN | Should -Be '$(Get-Process)'
        }
    }

    Context "Date Range Filtering" {
        It "Should filter backups by start date" {
            $dateRange = @{ StartDate = [DateTime]::Parse('2025-07-12T00:00:00Z') }
            $result = Find-BackupFile -BackupPath 'C:\ValidBackupPath' -DateRange $dateRange

            $result.Count | Should -Be 2
            $result.BackupDate | Should -Be @('2025-07-12T14:30:00Z', '2025-07-13T08:15:00Z')
            $result[0].FilteredByDateRange | Should -BeTrue
        }

        It "Should filter backups by end date" {
            $dateRange = @{ EndDate = [DateTime]::Parse('2025-07-11T23:59:59Z') }
            $result = Find-BackupFile -BackupPath 'C:\ValidBackupPath' -DateRange $dateRange

            $result.Count | Should -Be 1
            $result[0].BackupDate | Should -Be '2025-07-10T10:00:00Z'
        }

        It "Should filter backups by date range" {
            $dateRange = @{
                StartDate = [DateTime]::Parse('2025-07-11T00:00:00Z')
                EndDate   = [DateTime]::Parse('2025-07-12T23:59:59Z')
            }
            $result = Find-BackupFile -BackupPath 'C:\ValidBackupPath' -DateRange $dateRange

            $result.Count | Should -Be 1
            $result[0].BackupDate | Should -Be '2025-07-12T14:30:00Z'
        }

        It "Should handle date range with no matches" {
            $dateRange = @{
                StartDate = [DateTime]::Parse('2025-07-01T00:00:00Z')
                EndDate   = [DateTime]::Parse('2025-07-05T23:59:59Z')
            }
            $result = Find-BackupFile -BackupPath 'C:\ValidBackupPath' -DateRange $dateRange

            $result.Count | Should -Be 0
        }

        It "Should skip and log a backup whose date cannot be parsed" {
            Mock Get-BackupFileMetadata {
                New-FakeMetadata 'CN=TestObject,DC=company,DC=com' 'invalid-date-format' 'Bad'
            }

            $dateRange = @{ StartDate = [DateTime]'2025-07-01' }
            $result = Find-BackupFile -BackupPath 'C:\ValidBackupPath' -DateRange $dateRange

            $result.Count | Should -Be 0
            Should -Invoke Write-StructuredLog -Times 3 -Exactly -ParameterFilter {
                $Level -eq 'Warning' -and $Message -like 'Failed to parse backup date for C:\ValidBackupPath\*'
            }
        }
    }

    Context "Combined Filtering" {
        It "Should apply both ObjectDN and DateRange filters" {
            $dateRange = @{ StartDate = [DateTime]::Parse('2025-07-11T00:00:00Z') }
            $result = Find-BackupFile -BackupPath 'C:\ValidBackupPath' -ObjectDN '*User*' -DateRange $dateRange

            $result.Count | Should -Be 1
            $result[0].ObjectDN | Should -Be 'CN=TestUser2,OU=Sales,DC=company,DC=com'
            $result[0].FilteredByObjectDN | Should -BeTrue
            $result[0].FilteredByDateRange | Should -BeTrue
        }

        It "Should return empty when filters exclude all results" {
            $dateRange = @{ EndDate = [DateTime]::Parse('2025-07-01T00:00:00Z') }
            $result = Find-BackupFile -BackupPath 'C:\ValidBackupPath' -ObjectDN '*User*' -DateRange $dateRange

            $result.Count | Should -Be 0
        }
    }

    Context "Error Handling" {
        It "Should fail with the scan error when the directory cannot be read" {
            { Find-BackupFile -BackupPath 'C:\AccessDeniedPath' } | Should -Throw "*Failed to discover backup files: Failed to scan backup directory C:\AccessDeniedPath : Access denied to backup directory*"
        }

        It "Should continue processing when individual files fail and log the failed file" {
            Mock Get-BackupFileMetadata { throw 'Metadata extraction failed' } -ParameterFilter {
                $BackupFilePath -eq 'C:\ValidBackupPath\backup2.xml'
            }

            $result = Find-BackupFile -BackupPath 'C:\ValidBackupPath'

            $result.Count | Should -Be 2
            $result.ObjectDN | Should -Not -Contain 'CN=TestUser2,OU=Sales,DC=company,DC=com'
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Warning' -and
                $Message -eq 'Failed to process backup file C:\ValidBackupPath\backup2.xml: Metadata extraction failed'
            }
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Message -eq 'Backup discovery completed' -and $Data.ProcessingErrors -eq 1 -and
                $Data.ValidBackupsFound -eq 2 -and $Data.TotalFilesScanned -eq 3
            }
        }

        It "Should log the scan failure and the structured error details" {
            { Find-BackupFile -BackupPath 'C:\AccessDeniedPath' -CorrelationId 'corr-err' } | Should -Throw

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Error' -and $Message -like 'Failed to scan backup directory C:\AccessDeniedPath*' -and
                $CorrelationId -eq 'corr-err'
            }
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Error' -and $Message -eq 'Error during backup file discovery' -and
                $Data.BackupPath -eq 'C:\AccessDeniedPath' -and $Data.CorrelationId -eq 'corr-err'
            }
        }
    }

    Context "Progress Reporting" {
        It "Should report progress for each file with its percentage" {
            $null = Find-BackupFile -BackupPath 'C:\ValidBackupPath'

            Should -Invoke Write-Progress -Times 1 -Exactly -ParameterFilter {
                $Status -eq 'Processing file 1 of 3' -and [int]$PercentComplete -eq 33
            }
            Should -Invoke Write-Progress -Times 1 -Exactly -ParameterFilter {
                $Status -eq 'Processing file 3 of 3' -and $PercentComplete -eq 100
            }
        }

        It "Should complete Write-Progress when finished" {
            $null = Find-BackupFile -BackupPath 'C:\ValidBackupPath'

            Should -Invoke Write-Progress -Times 1 -Exactly -ParameterFilter { $Completed }
        }
    }

    Context "Enterprise Integration" {
        It "Should pass the supplied correlation ID to every log entry" {
            $correlationId = [System.Guid]::NewGuid().ToString()
            $null = Find-BackupFile -BackupPath 'C:\ValidBackupPath' -CorrelationId $correlationId

            Should -Invoke Write-StructuredLog -Times 0 -Exactly -ParameterFilter { $CorrelationId -ne $correlationId }
            Should -Invoke Write-StructuredLog -Times 6 -Exactly -ParameterFilter { $CorrelationId -eq $correlationId }
        }

        It "Should log discovery start and completion" {
            $null = Find-BackupFile -BackupPath 'C:\ValidBackupPath'

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Debug' -and $Message -eq 'Starting backup file discovery operation'
            }
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Debug' -and $Message -eq 'Backup file discovery operation completed'
            }
        }

        It "Should log a discovery summary with the filters applied" {
            $null = Find-BackupFile -BackupPath 'C:\ValidBackupPath' -ObjectDN '*Sales*'

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Verbose' -and $Message -eq 'Backup discovery completed' -and
                $Data.TotalFilesScanned -eq 3 -and $Data.ValidBackupsFound -eq 1 -and
                $Data.FilterApplied -eq $true -and $Data.ObjectDNFilter -eq '*Sales*'
            }
        }
    }
}
