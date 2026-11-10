#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
<#
.SYNOPSIS
    Unit tests for the Test-BackupSignature utility function

.DESCRIPTION
    Tests Test-BackupSignature parameter validation, signature verification,
    input that should be rejected, and error handling.

.NOTES
    Author: Jeffrey Stuhr
    Blog: https://www.techbyjeff.net
    LinkedIn: https://www.linkedin.com/in/jeffrey-stuhr-034214aa/
#>

BeforeAll {
    $ModuleRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    . "$ModuleRoot\Private\Utilities\Test-BackupSignature.ps1"
}

Describe "Test-BackupSignature" {
    BeforeAll {
        $script:TestCorrelationId = [System.Guid]::NewGuid().ToString()
        
        # Define valid signatures for testing
        $script:ValidSignatures = @(
            "PSSecurityBackup_v2.1",
            "PSSecurityBackup_v2.0",
            "PowerShellSecurityBackup"
        )
        
        # Define invalid signatures for testing
        $script:InvalidSignatures = @(
            "InvalidSignature",
            "PSSecurityBackup_v1.0",
            "MaliciousBackup_v1.0",
            "UnknownBackupFormat",
            "   ",
            "PSSecurityBackup_v3.0",  # Future version not yet valid
            "BadSignature"
        )
        
        Mock Write-Verbose { }
        Mock Write-Warning { }
    }
    
    Context "Parameter Validation" {
        It "Should require Signature parameter" {
            # Omitting a mandatory parameter makes PowerShell prompt for it, so the call runs in a job
            # and the test checks that the job is blocked waiting for input
            $job = Start-Job -ScriptBlock {
                $ModuleRoot = $args[0]
                . "$ModuleRoot\Private\Utilities\Test-BackupSignature.ps1"
                Test-BackupSignature
            } -ArgumentList $ModuleRoot
            
            Start-Sleep -Seconds 1
            $job.State | Should -Be "Blocked"

            $job | Stop-Job | Remove-Job
        }
        
        It "Should accept valid signature string" {
            { Test-BackupSignature -Signature "PSSecurityBackup_v2.1" } | Should -Not -Throw
        }
        
        It "Should reject empty signature string via parameter validation" {
            # Function rejects empty strings via parameter validation
            { Test-BackupSignature -Signature "" } | Should -Throw "*Cannot bind argument to parameter 'Signature' because it is an empty string*"
        }
        
        It "Should reject null signature via parameter validation" {
            # Function rejects null via parameter validation
            { Test-BackupSignature -Signature $null } | Should -Throw "*Cannot bind argument to parameter 'Signature' because it is an empty string*"
        }
        
        It "Should accept whitespace-only signature" {
            { Test-BackupSignature -Signature "   " } | Should -Not -Throw
        }
        
        It "Should accept custom CorrelationId" {
            $customCorrelationId = [System.Guid]::NewGuid().ToString()
            { Test-BackupSignature -Signature "PSSecurityBackup_v2.1" -CorrelationId $customCorrelationId } | Should -Not -Throw
        }
        
        It "Should generate CorrelationId when not provided" {
            $result = Test-BackupSignature -Signature "PSSecurityBackup_v2.1"
            $result.CorrelationId | Should -Not -BeNullOrEmpty
            $result.CorrelationId | Should -Match "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
        }
        
        It "Should accept very long signature strings" {
            $longSignature = "A" * 1000
            { Test-BackupSignature -Signature $longSignature } | Should -Not -Throw
        }
        
        It "Should accept signature with special characters" {
            $specialSignature = "Test!@#$%^&*()_+{}|:<>?[];"
            { Test-BackupSignature -Signature $specialSignature } | Should -Not -Throw
        }
    }
    
    Context "Valid Signature Recognition" {
        It "Should validate PSSecurityBackup_v2.1 signature" {
            $result = Test-BackupSignature -Signature "PSSecurityBackup_v2.1"
            $result.Valid | Should -Be $true
            $result.SecurityRisk | Should -Be $false
        }
        
        It "Should validate PSSecurityBackup_v2.0 signature" {
            $result = Test-BackupSignature -Signature "PSSecurityBackup_v2.0"
            $result.Valid | Should -Be $true
            $result.SecurityRisk | Should -Be $false
        }
        
        It "Should validate PowerShellSecurityBackup signature" {
            $result = Test-BackupSignature -Signature "PowerShellSecurityBackup"
            $result.Valid | Should -Be $true
            $result.SecurityRisk | Should -Be $false
        }
        
        It "Should validate all known valid signatures" {
            foreach ($signature in $script:ValidSignatures) {
                $result = Test-BackupSignature -Signature $signature
                $result.Valid | Should -Be $true
                $result.SecurityRisk | Should -Be $false
            }
        }
        
        It "Should -be case insensitive for signatures" {
            # PowerShell -contains is case-insensitive by default
            $result = Test-BackupSignature -Signature "psSecurityBackup_v2.1"
            $result.Valid | Should -Be $true
            $result.SecurityRisk | Should -Be $false
        }
        
        It "Should not accept signatures with extra whitespace" {
            $result = Test-BackupSignature -Signature " PSSecurityBackup_v2.1 "
            $result.Valid | Should -Be $false
            $result.SecurityRisk | Should -Be $true
        }
    }
    
    Context "Invalid Signature Detection" {
        It "Should reject empty signature via parameter validation" {
            { Test-BackupSignature -Signature "" } | Should -Throw "*Cannot bind argument to parameter 'Signature' because it is an empty string*"
        }
        
        It "Should reject null signature via parameter validation" {
            { Test-BackupSignature -Signature $null } | Should -Throw "*Cannot bind argument to parameter 'Signature' because it is an empty string*"
        }
        
        It "Should reject whitespace-only signature" {
            $result = Test-BackupSignature -Signature "   "
            $result.Valid | Should -Be $false
            $result.SecurityRisk | Should -Be $true
        }
        
        It "Should reject unknown signature formats" {
            foreach ($signature in $script:InvalidSignatures) {
                $result = Test-BackupSignature -Signature $signature
                $result.Valid | Should -Be $false
                $result.SecurityRisk | Should -Be $true
            }
        }
        
        It "Should reject potentially malicious signatures" {
            $maliciousSignatures = @(
                "MaliciousBackup_v1.0",
                "EvilBackup",
                "HackerBackup_v2.1",
                "PSSecurityBackup_v999.0"
            )
            
            foreach ($signature in $maliciousSignatures) {
                $result = Test-BackupSignature -Signature $signature
                $result.Valid | Should -Be $false
                $result.SecurityRisk | Should -Be $true
            }
        }
        
        It "Should reject signature with SQL injection attempts" {
            $sqlInjectionSignature = "PSSecurityBackup'; DROP TABLE Backups; --"
            $result = Test-BackupSignature -Signature $sqlInjectionSignature
            $result.Valid | Should -Be $false
            $result.SecurityRisk | Should -Be $true
        }
        
        It "Should reject signature with script injection attempts" {
            $scriptInjectionSignature = "PSSecurityBackup`$(Get-Process)"
            $result = Test-BackupSignature -Signature $scriptInjectionSignature
            $result.Valid | Should -Be $false
            $result.SecurityRisk | Should -Be $true
        }
        
        It "Should reject signature with path traversal attempts" {
            $pathTraversalSignature = "PSSecurityBackup../../etc/passwd"
            $result = Test-BackupSignature -Signature $pathTraversalSignature
            $result.Valid | Should -Be $false
            $result.SecurityRisk | Should -Be $true
        }
    }
    
    Context "Return Object Structure" {
        It "Should return PSCustomObject with required properties" {
            $result = Test-BackupSignature -Signature "PSSecurityBackup_v2.1"
            
            $result | Should -BeOfType [PSCustomObject]
            $result.Valid | Should -Not -BeNullOrEmpty
            $result.SecurityRisk | Should -Not -BeNullOrEmpty  
            $result.CorrelationId | Should -Not -BeNullOrEmpty
        }
        
        It "Should return boolean for Valid property" {
            $result = Test-BackupSignature -Signature "PSSecurityBackup_v2.1"
            $result.Valid | Should -BeOfType [bool]
        }
        
        It "Should return boolean for SecurityRisk property" {
            $result = Test-BackupSignature -Signature "PSSecurityBackup_v2.1"
            $result.SecurityRisk | Should -BeOfType [bool]
        }
        
        It "Should preserve custom CorrelationId" {
            $customCorrelationId = [System.Guid]::NewGuid().ToString()
            $result = Test-BackupSignature -Signature "PSSecurityBackup_v2.1" -CorrelationId $customCorrelationId
            $result.CorrelationId | Should -Be $customCorrelationId
        }
        
        It "Should generate unique CorrelationId for each call" {
            $result1 = Test-BackupSignature -Signature "PSSecurityBackup_v2.1"
            $result2 = Test-BackupSignature -Signature "PSSecurityBackup_v2.1"
            
            $result1.CorrelationId | Should -Not -Be $result2.CorrelationId
        }
    }
    
    Context "Security Risk Assessment" {
        It "Should not flag security risk for valid signatures" {
            foreach ($signature in $script:ValidSignatures) {
                $result = Test-BackupSignature -Signature $signature
                $result.SecurityRisk | Should -Be $false
            }
        }
        
        It "Should flag security risk for invalid signatures" {
            foreach ($signature in $script:InvalidSignatures) {
                $result = Test-BackupSignature -Signature $signature
                $result.SecurityRisk | Should -Be $true
            }
        }
        
        It "Should have inverse relationship between Valid and SecurityRisk" {
            $testSignatures = $script:ValidSignatures + $script:InvalidSignatures
            
            foreach ($signature in $testSignatures) {
                $result = Test-BackupSignature -Signature $signature
                
                if ($result.Valid -eq $true) {
                    $result.SecurityRisk | Should -Be $false
                } else {
                    $result.SecurityRisk | Should -Be $true
                }
            }
        }
        
        It "Should flag security risk for potentially dangerous patterns" {
            $dangerousPatterns = @(
                "PSSecurityBackup_v2.1; rm -rf /",
                "PSSecurityBackup_v2.1 && format c:",
                "PSSecurityBackup_v2.1 | cmd.exe",
                "PSSecurityBackup_v2.1`nGet-Process"
            )
            
            foreach ($pattern in $dangerousPatterns) {
                $result = Test-BackupSignature -Signature $pattern
                $result.Valid | Should -Be $false
                $result.SecurityRisk | Should -Be $true
            }
        }
    }
    
    Context "Edge Cases and Boundary Conditions" {
        It "Should handle signature exactly matching valid signature" {
            $exactSignature = "PSSecurityBackup_v2.1"
            $result = Test-BackupSignature -Signature $exactSignature
            $result.Valid | Should -Be $true
        }
        
        It "Should handle signature with Unicode characters" {
            $unicodeSignature = "PSSecurityBackup_v2.1üñíçødé"
            $result = Test-BackupSignature -Signature $unicodeSignature
            $result.Valid | Should -Be $false
            $result.SecurityRisk | Should -Be $true
        }
        
        It "Should handle signature with control characters" {
            $controlCharSignature = "PSSecurityBackup_v2.1`t`r`n"
            $result = Test-BackupSignature -Signature $controlCharSignature
            $result.Valid | Should -Be $false
            $result.SecurityRisk | Should -Be $true
        }
        
        It "Should handle very long invalid signatures" {
            $longInvalidSignature = "InvalidSignature" + ("X" * 10000)
            $result = Test-BackupSignature -Signature $longInvalidSignature
            $result.Valid | Should -Be $false
            $result.SecurityRisk | Should -Be $true
        }
        
        It "Should handle signature containing null characters" {
            # -contains compares culture-aware, and culture-aware comparison ignores an embedded null
            # character, so this matches "PSSecurityBackup_v2.1"
            $nullCharSignature = "PSSecurityBackup`0_v2.1"
            $result = Test-BackupSignature -Signature $nullCharSignature
            $result.Valid | Should -Be $true
            $result.SecurityRisk | Should -Be $false
        }
        
        It "Should handle signature with embedded quotes" {
            $quotedSignature = 'PSSecurityBackup"_v2.1'
            $result = Test-BackupSignature -Signature $quotedSignature
            $result.Valid | Should -Be $false
            $result.SecurityRisk | Should -Be $true
        }
    }
    
    Context "Performance and Reliability" {
        It "Should complete validation quickly" {
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            Test-BackupSignature -Signature "PSSecurityBackup_v2.1"
            $stopwatch.Stop()
            
            # Should complete within 1 second
            $stopwatch.ElapsedMilliseconds | Should -BeLessThan 1000
        }
        
        It "Should handle multiple rapid calls efficiently" {
            $results = @()
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            
            1..100 | ForEach-Object {
                $results += Test-BackupSignature -Signature "PSSecurityBackup_v2.1"
            }
            
            $stopwatch.Stop()
            
            # 100 calls should complete within 5 seconds
            $stopwatch.ElapsedMilliseconds | Should -BeLessThan 5000
            $results.Count | Should -Be 100
            $results | ForEach-Object { $_.Valid | Should -Be $true }
        }
        
        It "Should handle concurrent validation calls" {
            $jobs = @()
            
            try {
                # Start multiple background jobs
                1..10 | ForEach-Object {
                    $jobs += Start-Job -ScriptBlock {
                        param($ModuleRoot, $Signature)
                        . "$ModuleRoot\Private\Utilities\Test-BackupSignature.ps1"
                        Test-BackupSignature -Signature $Signature
                    } -ArgumentList $ModuleRoot, "PSSecurityBackup_v2.1"
                }
                
                # Wait for all jobs to complete
                $results = $jobs | Wait-Job | Receive-Job
                
                # Verify all jobs completed successfully
                $results.Count | Should -Be 10
                $results | ForEach-Object {
                    $_.Valid | Should -Be $true
                    $_.SecurityRisk | Should -Be $false
                }
            }
            finally {
                # Clean up jobs
                $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
            }
        }
        
        It "Should -be consistent across multiple calls" {
            $signature = "PSSecurityBackup_v2.1"
            $results = @()
            
            # Run same validation multiple times
            1..50 | ForEach-Object {
                $results += Test-BackupSignature -Signature $signature
            }
            
            # All results should be identical apart from CorrelationId
            $validResults = $results | Where-Object { $_.Valid -eq $true }
            $securityRiskResults = $results | Where-Object { $_.SecurityRisk -eq $false }
            
            $validResults.Count | Should -Be 50
            $securityRiskResults.Count | Should -Be 50
        }
    }
    
    Context "Error Handling" {
        It "Should handle signature validation without throwing exceptions for valid input types" {
            $problemSignatures = @(
                123,  # Non-string type (will be converted to string)
                "ValidSignature"
            )
            
            foreach ($signature in $problemSignatures) {
                { Test-BackupSignature -Signature $signature } | Should -Not -Throw
            }
        }
        
        It "Should gracefully handle type conversion issues" {
            # Test with various types that need string conversion
            $result1 = Test-BackupSignature -Signature 123
            $result2 = Test-BackupSignature -Signature $true
            $result3 = Test-BackupSignature -Signature (Get-Date)
            
            $result1.Valid | Should -Be $false
            $result2.Valid | Should -Be $false
            $result3.Valid | Should -Be $false
        }
    }
    
    Context "Integration and Correlation" {
        It "Should maintain correlation ID throughout validation process" {
            $testCorrelationId = "TEST-CORRELATION-ID-12345"
            $result = Test-BackupSignature -Signature "PSSecurityBackup_v2.1" -CorrelationId $testCorrelationId
            $result.CorrelationId | Should -Be $testCorrelationId
        }
        
        It "Should work with Get-StringHash correlation pattern" {
            $result = Test-BackupSignature -Signature "PSSecurityBackup_v2.1"
            
            # A GUID, in the format the other utilities use
            { [System.Guid]::Parse($result.CorrelationId) } | Should -Not -Throw
        }
        
        It "Should support logging integration scenarios" {
            $result = Test-BackupSignature -Signature "InvalidSignature"
            
            # The result carries everything a log entry needs
            $result.Valid | Should -Be $false
            $result.SecurityRisk | Should -Be $true
            $result.CorrelationId | Should -Not -BeNullOrEmpty
        }
    }
    
    Context "Signature Format Specifications" {
        It "Should accept PSSecurityBackup_v2.1 as current version" {
            $result = Test-BackupSignature -Signature "PSSecurityBackup_v2.1"
            $result.Valid | Should -Be $true
        }
        
        It "Should accept PSSecurityBackup_v2.0 as legacy version" {
            $result = Test-BackupSignature -Signature "PSSecurityBackup_v2.0"
            $result.Valid | Should -Be $true
        }
        
        It "Should accept PowerShellSecurityBackup as generic version" {
            $result = Test-BackupSignature -Signature "PowerShellSecurityBackup"
            $result.Valid | Should -Be $true
        }
        
        It "Should reject version numbers not in whitelist" {
            $invalidVersions = @(
                "PSSecurityBackup_v1.9",
                "PSSecurityBackup_v2.2",
                "PSSecurityBackup_v3.0",
                "PSSecurityBackup_v10.0"
            )
            
            foreach ($version in $invalidVersions) {
                $result = Test-BackupSignature -Signature $version
                $result.Valid | Should -Be $false
                $result.SecurityRisk | Should -Be $true
            }
        }
        
        It "Should reject signatures with similar but incorrect naming" {
            $similarSignatures = @(
                "PSSecurityBackups_v2.1",  # Plural
                "PSSecurityBackup v2.1",   # Space instead of underscore
                "PS-SecurityBackup_v2.1",  # Hyphen
                "PSSecurityBackup_2.1"     # Missing 'v'
                # Note: PSSecurityBackup_V2.1 is valid due to case-insensitive matching
            )
            
            foreach ($signature in $similarSignatures) {
                $result = Test-BackupSignature -Signature $signature
                $result.Valid | Should -Be $false
                $result.SecurityRisk | Should -Be $true
            }
        }
    }
    
    AfterAll {
        # Clean up any test artifacts
        if (Test-Path "TestDrive:\") {
            Remove-Item "TestDrive:\*" -Recurse -Force -ErrorAction SilentlyContinue
        }
        
        # Remove any temporary variables
        Remove-Variable -Name "TestCorrelationId", "ValidSignatures", "InvalidSignatures" -Scope Script -ErrorAction SilentlyContinue
    }
}
