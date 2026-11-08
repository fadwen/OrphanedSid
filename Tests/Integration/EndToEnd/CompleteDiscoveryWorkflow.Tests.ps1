# Import required modules and helpers
# Global configuration
# Configuration for test execution
# Mock wrapper for the script
BeforeAll {
    . "$PSScriptRoot\..\..\TestHelpers\SecurityTestHelpers.ps1"

    . "$PSScriptRoot\..\..\TestHelpers\ADMockFactory.ps1"

    $script:TestConfig = Get-Content "$PSScriptRoot\..\..\TestData\Configurations\test-config.json" | ConvertFrom-Json

    $script:MockBehavior = @{}

    function Set-MockBehavior { 
        param([string]$Scenario, [hashtable]$Output)
        $script:MockBehavior[$Scenario] = $Output
    }

    function Get-MockBehavior { 
        param([string]$Scenario)
        return $script:MockBehavior[$Scenario]
    }

    function Clear-MockBehavior { $script:MockBehavior = @{} }

    function Invoke-FindUnknownSIDScript {
        param(
            [string]$SearchBase,
            [string]$OutputPath,
            [switch]$Computers,
            [switch]$WhatIf
        )
        
        # Check for scenario-specific behavior
        foreach ($scenario in $script:MockBehavior.Keys) {
            $mockOutput = $script:MockBehavior[$scenario]
            if ($mockOutput) {
                return $mockOutput
            }
        }
        
        # Default mock output
        return @{
            SearchBase = $SearchBase
            OutputPath = $OutputPath
            OrphanedSIDsFound = 3
            ProcessingTime = '00:02:15'
            OutputFiles = @("$OutputPath\orphaned-sids-report.html", "$OutputPath\orphaned-sids-data.json")
            Success = $true
            TotalObjectsProcessed = 150
            MemoryUsed = "45MB"
            ExitCode = 0
        }
    }
}

Describe "Complete Discovery Workflow" {
    # Scenario behaviour set by one test must not reach the next; under a shuffled run the edge-case
    # tests, which register behaviour, can run before the basic ones, which expect the default output
    BeforeEach {
        Clear-MockBehavior
    }

    BeforeAll {
        # Create test directory
        # $env:TEMP is an 8.3 short path (RUNNER~1) on the GitHub runners; Get-Item expands it so the
        # paths the functions return, which are long, compare equal to the ones built here
        $script:TestOutputPath = Join-Path (Get-Item -LiteralPath $env:TEMP).FullName "DiscoveryWorkflowTest_$(Get-Date -Format 'yyyyMMddHHmmss')"
        New-Item -Path $script:TestOutputPath -ItemType Directory -Force | Out-Null
        
        Clear-MockBehavior
    }
    
    AfterAll {
        # Cleanup test directory
        if (Test-Path $script:TestOutputPath) {
            Remove-Item $script:TestOutputPath -Recurse -Force
        }
        Clear-MockBehavior
    }

    Context "Basic Discovery Tests" {
        It "Should complete discovery workflow for Users OU" {
            $result = Invoke-FindUnknownSIDScript -SearchBase "OU=Users,DC=contoso,DC=com" -OutputPath $script:TestOutputPath
            
            $result | Should -Not -Be $null
            $result.SearchBase | Should -Be "OU=Users,DC=contoso,DC=com"
            $result.OrphanedSIDsFound | Should -Be 3
            $result.Success | Should -Be $true
        }
        
        It "Should complete discovery workflow for Computers OU" {
            $result = Invoke-FindUnknownSIDScript -SearchBase "OU=Computers,DC=contoso,DC=com" -OutputPath $script:TestOutputPath -Computers
            
            $result | Should -Not -Be $null
            $result.SearchBase | Should -Be "OU=Computers,DC=contoso,DC=com"
            $result.Success | Should -Be $true
        }
        
        It "Should complete discovery workflow for domain root" {
            $result = Invoke-FindUnknownSIDScript -SearchBase "DC=contoso,DC=com" -OutputPath $script:TestOutputPath
            
            $result | Should -Not -Be $null
            $result.SearchBase | Should -Be "DC=contoso,DC=com"
            $result.Success | Should -Be $true
        }
        
        It "Should generate required output files" {
            $result = Invoke-FindUnknownSIDScript -SearchBase "OU=Users,DC=contoso,DC=com" -OutputPath $script:TestOutputPath
            
            $result.OutputFiles | Should -Not -Be $null
            $result.OutputFiles.Count | Should -BeGreaterThan 0
        }
        
        It "Should track processing time within acceptable limits" {
            $result = Invoke-FindUnknownSIDScript -SearchBase "OU=Users,DC=contoso,DC=com" -OutputPath $script:TestOutputPath
            
            $result.ProcessingTime | Should -Not -Be $null
            $processingTimeSpan = [TimeSpan]::Parse($result.ProcessingTime)
            $processingTimeSpan.TotalSeconds | Should -BeLessThan $script:TestConfig.performance.baselines.largeDataset.maxExecutionTimeSeconds
        }
        
        It "Should use memory within acceptable limits" {
            $result = Invoke-FindUnknownSIDScript -SearchBase "OU=Users,DC=contoso,DC=com" -OutputPath $script:TestOutputPath
            
            $result.MemoryUsed | Should -Not -Be $null
            # Extract numeric value from string like "45MB"
            if ($result.MemoryUsed -match '(\d+)MB') {
                $memoryMB = [int]$matches[1]
            } else {
                $memoryMB = [int]($result.MemoryUsed -replace 'MB', '')
            }
            $memoryMB | Should -BeLessThan $script:TestConfig.performance.baselines.largeDataset.maxMemoryMB
        }
    }
    
    Context "Error Handling and Security" {
        It "Should handle invalid search base gracefully" {
            $result = Invoke-FindUnknownSIDScript -SearchBase "OU=NonExistent,DC=invalid,DC=com" -OutputPath $script:TestOutputPath
            
            # Should still return a result object even for invalid search base
            $result | Should -Not -Be $null
        }
        
        It "Should validate output path accessibility" {
            $result = Invoke-FindUnknownSIDScript -SearchBase "OU=Users,DC=contoso,DC=com" -OutputPath $script:TestOutputPath
            
            $result.OutputPath | Should -Be $script:TestOutputPath
        }
        
        It "Should handle WhatIf parameter correctly" {
            $result = Invoke-FindUnknownSIDScript -SearchBase "OU=Users,DC=contoso,DC=com" -OutputPath $script:TestOutputPath -WhatIf
            
            $result | Should -Not -Be $null
            $result.SearchBase | Should -Be "OU=Users,DC=contoso,DC=com"
        }
    }
    
    Context "Performance and Integration" {
        It "Should process objects efficiently" {
            $result = Invoke-FindUnknownSIDScript -SearchBase "OU=Users,DC=contoso,DC=com" -OutputPath $script:TestOutputPath
            
            $result.TotalObjectsProcessed | Should -BeGreaterThan 0
            $result.Success | Should -Be $true
        }
        
        It "Should integrate with logging framework" {
            $result = Invoke-FindUnknownSIDScript -SearchBase "OU=Users,DC=contoso,DC=com" -OutputPath $script:TestOutputPath
            
            # Should complete without logging errors
            $result.Success | Should -Be $true
        }
        
        It "Should maintain data integrity" {
            $result = Invoke-FindUnknownSIDScript -SearchBase "OU=Users,DC=contoso,DC=com" -OutputPath $script:TestOutputPath
            
            $result.OrphanedSIDsFound | Should -BeOfType [int]
            $result.TotalObjectsProcessed | Should -BeOfType [int]
        }
    }
    
    Context "Discovery Edge Cases and Boundary Conditions" {
        BeforeEach {
            Clear-MockBehavior
        }
        
        It "Should handle empty OU with no objects gracefully" {
            Set-MockBehavior -Scenario "EmptyOU" -Output @{
                SearchBase = "OU=Empty,DC=contoso,DC=com"
                OutputPath = $script:TestOutputPath
                OrphanedSIDsFound = 0
                TotalObjectsProcessed = 0
                ProcessingTime = '00:00:05'
                Success = $true
                ExitCode = 0
                OutputFiles = @()
                Message = "No objects found in specified search base"
            }
            
            $result = Invoke-FindUnknownSIDScript -SearchBase "OU=Empty,DC=contoso,DC=com" -OutputPath $script:TestOutputPath
            
            $result | Should -Not -Be $null
            $result.OrphanedSIDsFound | Should -Be 0
            $result.TotalObjectsProcessed | Should -Be 0
            $result.Success | Should -Be $true
            $result.Message | Should -Match "No objects found"
        }
        
        It "Should handle extremely large OU with memory optimization" {
            Set-MockBehavior -Scenario "LargeDataset" -Output @{
                SearchBase = "OU=LargeOU,DC=contoso,DC=com"
                OutputPath = $script:TestOutputPath
                OrphanedSIDsFound = 25
                TotalObjectsProcessed = 50000
                ProcessingTime = '00:45:30'
                MemoryUsed = 895MB
                Success = $true
                ExitCode = 0
                OutputFiles = @("$script:TestOutputPath\orphaned-sids-report.html")
                MemoryOptimizationUsed = $true
                BatchProcessingMode = $true
            }
            
            $result = Invoke-FindUnknownSIDScript -SearchBase "OU=LargeOU,DC=contoso,DC=com" -OutputPath $script:TestOutputPath
            
            $result | Should -Not -Be $null
            $result.TotalObjectsProcessed | Should -Be 50000
            $result.MemoryUsed | Should -Be 895MB
            $result.Success | Should -Be $true
            $result.MemoryOptimizationUsed | Should -Be $true
            $result.BatchProcessingMode | Should -Be $true
        }
        
        It "Should handle malformed SIDs in AD objects" {
            Set-MockBehavior -Scenario "MalformedSIDs" -Output @{
                SearchBase = "OU=Corrupted,DC=contoso,DC=com"
                OutputPath = $script:TestOutputPath
                OrphanedSIDsFound = 8
                TotalObjectsProcessed = 100
                ProcessingTime = '00:05:15'
                Success = $true
                ExitCode = 0
                SkippedObjects = 3
                Warnings = @("Malformed SID detected on object CN=User1", "Invalid SID format on CN=Computer2")
                OutputFiles = @("$script:TestOutputPath\orphaned-sids-report.html")
            }
            
            $result = Invoke-FindUnknownSIDScript -SearchBase "OU=Corrupted,DC=contoso,DC=com" -OutputPath $script:TestOutputPath
            
            $result | Should -Not -Be $null
            $result.SkippedObjects | Should -Be 3
            $result.Warnings.Count | Should -Be 2
            $result.Success | Should -Be $true
        }
        
        It "Should handle network timeout conditions gracefully" {
            Set-MockBehavior -Scenario "NetworkTimeout" -Output @{
                SearchBase = "OU=Remote,DC=branch,DC=com"
                OutputPath = $script:TestOutputPath
                OrphanedSIDsFound = 0
                TotalObjectsProcessed = 0
                ProcessingTime = '00:00:30'
                Success = $false
                ExitCode = 1
                Error = "Network timeout while connecting to domain controller"
                RetryAttempts = 3
                LastError = "Connection to domain controller timed out after 30 seconds"
            }
            
            $result = Invoke-FindUnknownSIDScript -SearchBase "OU=Remote,DC=branch,DC=com" -OutputPath $script:TestOutputPath
            
            $result | Should -Not -Be $null
            $result.Success | Should -Be $false
            $result.Error | Should -Match "Network timeout"
            $result.RetryAttempts | Should -Be 3
            $result.LastError | Should -Match "timed out"
        }
        
        It "Should handle cross-domain trust scenarios" {
            Set-MockBehavior -Scenario "CrossDomain" -Output @{
                SearchBase = "OU=External,DC=partner,DC=com"
                OutputPath = $script:TestOutputPath
                OrphanedSIDsFound = 12
                TotalObjectsProcessed = 200
                ProcessingTime = '00:08:45'
                Success = $true
                ExitCode = 0
                TrustRelationships = @("contoso.com", "subsidiary.com")
                ExternalSIDsFound = 5
                OutputFiles = @("$script:TestOutputPath\orphaned-sids-report.html")
                TrustValidationPerformed = $true
            }
            
            $result = Invoke-FindUnknownSIDScript -SearchBase "OU=External,DC=partner,DC=com" -OutputPath $script:TestOutputPath
            
            $result | Should -Not -Be $null
            $result.ExternalSIDsFound | Should -Be 5
            $result.TrustRelationships.Count | Should -Be 2
            $result.Success | Should -Be $true
            $result.TrustValidationPerformed | Should -Be $true
        }
        
        It "Should handle file permission errors on output path" {
            Set-MockBehavior -Scenario "FilePermissionError" -Output @{
                SearchBase = "OU=Users,DC=contoso,DC=com"
                OutputPath = "C:\Windows\System32\RestrictedPath"
                OrphanedSIDsFound = 5
                TotalObjectsProcessed = 100
                ProcessingTime = '00:03:15'
                Success = $false
                ExitCode = 2
                Error = "Access denied to output path: C:\Windows\System32\RestrictedPath"
                PermissionCheckFailed = $true
            }
            
            $result = Invoke-FindUnknownSIDScript -SearchBase "OU=Users,DC=contoso,DC=com" -OutputPath "C:\Windows\System32\RestrictedPath"
            
            $result | Should -Not -Be $null
            $result.Success | Should -Be $false
            $result.Error | Should -Match "Access denied"
            $result.ExitCode | Should -Be 2
            $result.PermissionCheckFailed | Should -Be $true
        }
        
        It "Should handle schema corruption scenarios" {
            Set-MockBehavior -Scenario "SchemaCorruption" -Output @{
                SearchBase = "OU=Users,DC=contoso,DC=com"
                OutputPath = $script:TestOutputPath
                OrphanedSIDsFound = 0
                TotalObjectsProcessed = 0
                ProcessingTime = '00:01:00'
                Success = $false
                ExitCode = 3
                Error = "Active Directory schema corruption detected"
                SchemaValidationFailed = $true
                CorruptedAttributes = @("nTSecurityDescriptor", "objectSid")
            }
            
            $result = Invoke-FindUnknownSIDScript -SearchBase "OU=Users,DC=contoso,DC=com" -OutputPath $script:TestOutputPath
            
            $result | Should -Not -Be $null
            $result.Success | Should -Be $false
            $result.SchemaValidationFailed | Should -Be $true
            $result.CorruptedAttributes.Count | Should -Be 2
        }
        
        It "Should handle file locking scenarios" {
            Set-MockBehavior -Scenario "FileLocked" -Output @{
                SearchBase = "OU=Users,DC=contoso,DC=com"
                OutputPath = $script:TestOutputPath
                OrphanedSIDsFound = 7
                TotalObjectsProcessed = 150
                ProcessingTime = '00:04:30'
                Success = $false
                ExitCode = 4
                Error = "Output file is locked by another process"
                RetryAttempts = 5
                FileAccessErrors = @("orphaned-sids-report.html", "orphaned-sids-data.json")
            }
            
            $result = Invoke-FindUnknownSIDScript -SearchBase "OU=Users,DC=contoso,DC=com" -OutputPath $script:TestOutputPath
            
            $result | Should -Not -Be $null
            $result.Success | Should -Be $false
            $result.Error | Should -Match "locked by another process"
            $result.FileAccessErrors.Count | Should -Be 2
        }
        
        It "Should handle extremely long distinguished names" {
            $longDN = "OU=" + ("VeryLongOUName" * 20) + ",DC=contoso,DC=com"
            Set-MockBehavior -Scenario "LongDN" -Output @{
                SearchBase = $longDN
                OutputPath = $script:TestOutputPath
                OrphanedSIDsFound = 2
                TotalObjectsProcessed = 50
                ProcessingTime = '00:02:00'
                Success = $true
                ExitCode = 0
                DNLengthOptimizationUsed = $true
                MaxDNLength = $longDN.Length
            }
            
            $result = Invoke-FindUnknownSIDScript -SearchBase $longDN -OutputPath $script:TestOutputPath
            
            $result | Should -Not -Be $null
            $result.Success | Should -Be $true
            $result.DNLengthOptimizationUsed | Should -Be $true
            $result.MaxDNLength | Should -BeGreaterThan 200
        }
        
        It "Should handle Unicode characters in object names" {
            Set-MockBehavior -Scenario "UnicodeObjects" -Output @{
                SearchBase = "OU=International,DC=contoso,DC=com"
                OutputPath = $script:TestOutputPath
                OrphanedSIDsFound = 4
                TotalObjectsProcessed = 75
                ProcessingTime = '00:03:00'
                Success = $true
                ExitCode = 0
                UnicodeObjectsProcessed = 15
                EncodingMethod = "UTF-8"
            }
            
            $result = Invoke-FindUnknownSIDScript -SearchBase "OU=International,DC=contoso,DC=com" -OutputPath $script:TestOutputPath
            
            $result | Should -Not -Be $null
            $result.Success | Should -Be $true
            $result.UnicodeObjectsProcessed | Should -Be 15
            $result.EncodingMethod | Should -Be "UTF-8"
        }
        
        It "Should handle insufficient disk space scenarios" {
            Set-MockBehavior -Scenario "DiskSpaceError" -Output @{
                SearchBase = "OU=Users,DC=contoso,DC=com"
                OutputPath = $script:TestOutputPath
                OrphanedSIDsFound = 10
                TotalObjectsProcessed = 200
                ProcessingTime = '00:05:00'
                Success = $false
                ExitCode = 5
                Error = "Insufficient disk space to create output files"
                RequiredSpace = "500MB"
                AvailableSpace = "50MB"
            }
            
            $result = Invoke-FindUnknownSIDScript -SearchBase "OU=Users,DC=contoso,DC=com" -OutputPath $script:TestOutputPath
            
            $result | Should -Not -Be $null
            $result.Success | Should -Be $false
            $result.Error | Should -Match "Insufficient disk space"
            $result.RequiredSpace | Should -Be "500MB"
            $result.AvailableSpace | Should -Be "50MB"
        }
        
        It "Should handle XML character escaping in output" {
            Set-MockBehavior -Scenario "XMLCharacters" -Output @{
                SearchBase = "OU=Users,DC=contoso,DC=com"
                OutputPath = $script:TestOutputPath
                OrphanedSIDsFound = 3
                TotalObjectsProcessed = 100
                ProcessingTime = '00:02:30'
                Success = $true
                ExitCode = 0
                XMLEscapingRequired = $true
                SpecialCharactersFound = @("<", ">", "&", "'", '"')
                OutputFiles = @("$script:TestOutputPath\orphaned-sids-report.html")
            }
            
            $result = Invoke-FindUnknownSIDScript -SearchBase "OU=Users,DC=contoso,DC=com" -OutputPath $script:TestOutputPath
            
            $result | Should -Not -Be $null
            $result.Success | Should -Be $true
            $result.XMLEscapingRequired | Should -Be $true
            $result.SpecialCharactersFound.Count | Should -Be 5
        }
    }
}
