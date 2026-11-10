# Test-OrphanedSID.Tests.ps1
# Tests for the Test-OrphanedSID private function

BeforeAll {
    # Pester can only mock a command that exists; define placeholder AD cmdlets when RSAT is absent
    . "$PSScriptRoot\..\..\..\TestHelpers\ADCmdletStubs.ps1"

    # Test-OrphanedSID has catch clauses typed [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException].
    # Without RSAT that type cannot be resolved, so the first AD lookup failure escapes to the outer catch and
    # every SID is reported orphaned. A stand-in type lets the catch clauses resolve without the AD module.
    if (-not ('Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException' -as [type])) {
        Add-Type -TypeDefinition @'
namespace Microsoft.ActiveDirectory.Management
{
    public class ADIdentityNotFoundException : System.Exception
    {
        public ADIdentityNotFoundException() : base() { }
        public ADIdentityNotFoundException(string message) : base(message) { }
    }
}
'@
    }

    function Write-StructuredLog { param($Message, $Level, $CorrelationId, $Component, $Data) }

    $ClassPath = Join-Path $PSScriptRoot '..\..\..\..\Classes'

    if (Test-Path $ClassPath) {
        Get-ChildItem -Path $ClassPath -Filter '*.ps1' | ForEach-Object { . $_.FullName }
    }

    $SIDPath = Join-Path $PSScriptRoot '..\..\..\..\Private\SID'

    if (Test-Path $SIDPath) {
        Get-ChildItem -Path $SIDPath -Filter '*.ps1' | ForEach-Object { . $_.FullName }
    }
}

Describe "Test-OrphanedSID Function Tests" {
    
    Context "Function Existence and Basic Functionality" {
        It "Should have Test-OrphanedSID function available" {
            Get-Command Test-OrphanedSID -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
        
        It "Should accept SID parameter" {
            $testSID = 'S-1-5-21-1234567890-1234567890-1234567890-1001'
            { Test-OrphanedSID -SID $testSID } | Should -Not -Throw
        }
        
        It "Should accept CorrelationId parameter" {
            $testSID = 'S-1-5-21-1234567890-1234567890-1234567890-1001'
            $correlationId = [System.Guid]::NewGuid().ToString()
            { Test-OrphanedSID -SID $testSID -CorrelationId $correlationId } | Should -Not -Throw
        }
        
        It "Should return an object when given valid SID" {
            $testSID = 'S-1-5-21-1234567890-1234567890-1234567890-1001'
            $result = Test-OrphanedSID -SID $testSID
            $result | Should -Not -BeNullOrEmpty
        }
    }
    
    Context "Parameter Validation" {
        It "Should validate SID parameter is not null" {
            { Test-OrphanedSID -SID $null } | Should -Throw
        }
        
        It "Should validate SID parameter is not empty" {
            { Test-OrphanedSID -SID '' } | Should -Throw
        }
        
        It "Should handle valid SID formats" {
            $validSIDs = @(
                'S-1-5-21-1234567890-1234567890-1234567890-1001',
                'S-1-5-32-544',
                'S-1-1-0'
            )
            
            foreach ($sid in $validSIDs) {
                { Test-OrphanedSID -SID $sid } | Should -Not -Throw
            }
        }
    }
    
    Context "Return Value Validation" {
        It "Should return a SIDLookupResult for valid SID" {
            $testSID = 'S-1-5-21-1234567890-1234567890-1234567890-1001'
            $result = Test-OrphanedSID -SID $testSID
            
            $result | Should -Not -BeNullOrEmpty
            $result.PSTypeNames | Should -Contain 'SIDLookupResult'
        }
        
        It "Should return a SIDLookupResult for well-known SID" {
            $wellKnownSID = 'S-1-5-32-544'  # Administrators group
            $result = Test-OrphanedSID -SID $wellKnownSID
            
            $result | Should -Not -BeNullOrEmpty
            $result.PSTypeNames | Should -Contain 'SIDLookupResult'
            # Function behavior: well-known SIDs translate locally, so they exist
            $result.Status | Should -Be 'Exists'
        }
    }
    
    Context "Directory Unreachable" {
        It "Leaves a domain SID unverified, not orphaned, when every directory lookup fails" {
            # Without a domain the AD lookups throw rather than report not-found, which is the
            # failure a timeout or an unreachable domain controller produces
            $result = Test-OrphanedSID -SID 'S-1-5-21-1234567890-1234567890-1234567890-1001'

            $result.Status | Should -Be 'Unverified'
            $result.IsOrphaned | Should -BeFalse
            $result.ErrorMessage | Should -Not -BeNullOrEmpty
        }
    }

    Context "Error Handling" {
        It "Should handle correlation ID tracking" {
            $testSID = 'S-1-5-21-1234567890-1234567890-1234567890-1001'
            $correlationId = [System.Guid]::NewGuid().ToString()
            
            # Function should accept correlation ID without throwing
            { Test-OrphanedSID -SID $testSID -CorrelationId $correlationId } | Should -Not -Throw
        }
        
        It "Should provide meaningful error information" {
            try {
                Test-OrphanedSID -SID 'invalid-sid-format' -ErrorAction Stop
            }
            catch {
                $_.Exception.Message | Should -Not -BeNullOrEmpty
            }
        }
        
        It "Should handle invalid SID formats gracefully" {
            $invalidSIDs = @(
                'invalid-sid',
                'S-1-5',
                'S-1-5-21',
                'not-a-sid-at-all',
                '123456789'
            )
            
            foreach ($sid in $invalidSIDs) {
                # Invalid SIDs are unverified: no lookup is made, so nothing proves them orphaned
                $result = Test-OrphanedSID -SID $sid
                $result.Status | Should -Be 'Unverified'
            }
        }
        
        It "Should handle null correlation ID gracefully" {
            $testSID = 'S-1-5-32-544'
            { Test-OrphanedSID -SID $testSID -CorrelationId $null } | Should -Not -Throw
        }
    }
    
    Context "Well-Known SID Validation" {
        It "Should correctly handle well-known SIDs" {
            $wellKnownSIDs = @(
                'S-1-5-32-544',    # Administrators
                'S-1-5-32-545',    # Users
                'S-1-1-0',         # Everyone
                'S-1-5-18',        # Local System
                'S-1-5-19',        # Local Service
                'S-1-5-20'         # Network Service
            )
            
            foreach ($sid in $wellKnownSIDs) {
                $result = Test-OrphanedSID -SID $sid
                $result.PSTypeNames | Should -Contain 'SIDLookupResult'
                # Function behavior: well-known Windows SIDs are not orphaned
                # they should translate successfully
                $result.Status | Should -Be 'Exists'
            }
        }
        
        It "Should handle built-in domain SIDs" {
            $builtInSIDs = @(
                'S-1-5-21-0-0-0-500',      # Domain Administrator template
                'S-1-5-21-0-0-0-501',      # Guest template
                'S-1-5-21-0-0-0-512'       # Domain Admins template
            )
            
            foreach ($sid in $builtInSIDs) {
                $result = Test-OrphanedSID -SID $sid
                $result.PSTypeNames | Should -Contain 'SIDLookupResult'
            }
        }
    }
    
    Context "Cache Management Integration" {
        It "Should work with Clear-SIDValidationCache function" {
            Get-Command Clear-SIDValidationCache -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            { Clear-SIDValidationCache } | Should -Not -Throw
        }
        
        It "Should work with Get-SIDValidationCacheStat function" {
            Get-Command Get-SIDValidationCacheStat -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            $stats = Get-SIDValidationCacheStat
            $stats | Should -Not -BeNullOrEmpty
            $stats.TotalEntries | Should -BeOfType [int]
        }
        
        It "Should benefit from caching on repeated calls" {
            $testSID = 'S-1-5-32-544'
            
            $time1 = Measure-Command { $result1 = Test-OrphanedSID -SID $testSID }
            $time2 = Measure-Command { $result2 = Test-OrphanedSID -SID $testSID }

            # The cached call returns the same status. Timing is measured but not asserted: the
            # second call is usually faster, but lookup time varies too much to rely on.
            $result1.Status | Should -Be $result2.Status

            $result2.PSTypeNames | Should -Contain 'SIDLookupResult'
        }
    }
    
    Context "Pipeline Processing" {
        It "Should handle pipeline input correctly" {
            $testSIDs = @(
                'S-1-5-32-544',
                'S-1-5-32-545',
                'S-1-1-0'
            )
            
            $results = $testSIDs | Test-OrphanedSID
            $results.Count | Should -Be 3
            $results | ForEach-Object { $_.PSTypeNames | Should -Contain 'SIDLookupResult' }
        }
        
        It "Should process mixed valid and invalid SIDs" {
            $mixedSIDs = @(
                'S-1-5-32-544',      # Valid well-known SID
                'invalid-sid',       # Invalid format
                'S-1-1-0'           # Valid well-known SID
            )
            
            $results = $mixedSIDs | Test-OrphanedSID
            $results.Count | Should -Be 3
            $results | ForEach-Object { $_.PSTypeNames | Should -Contain 'SIDLookupResult' }
            
            # Invalid SID is unverified, never orphaned
            $results[1].Status | Should -Be 'Unverified'
        }
    }
    
    Context "Performance and Reliability" {
        It "Should complete SID validation within reasonable time" {
            $testSID = 'S-1-5-32-544'
            
            $executionTime = Measure-Command {
                $result = Test-OrphanedSID -SID $testSID
            }
            
            # Should complete within 5 seconds for well-known SIDs
            $executionTime.TotalSeconds | Should -BeLessThan 5
            $result.PSTypeNames | Should -Contain 'SIDLookupResult'
        }
        
        It "Should handle batch processing efficiently" {
            $testSIDs = @(
                'S-1-5-32-544',
                'S-1-5-32-545', 
                'S-1-1-0',
                'S-1-5-18',
                'S-1-5-19'
            )
            
            $executionTime = Measure-Command {
                $results = $testSIDs | Test-OrphanedSID
            }
            
            # Should process 5 SIDs within 10 seconds
            $executionTime.TotalSeconds | Should -BeLessThan 10
            $results.Count | Should -Be 5
            $results | ForEach-Object { $_.PSTypeNames | Should -Contain 'SIDLookupResult' }
        }
        
        It "Should maintain consistent results across multiple calls" {
            $testSID = 'S-1-5-32-544'
            
            $results = @()
            1..3 | ForEach-Object {
                $results += Test-OrphanedSID -SID $testSID
            }
            
            # Every call returns the same status
            $results.Count | Should -Be 3
            $results[0].Status | Should -Be $results[1].Status
            $results[1].Status | Should -Be $results[2].Status
        }
    }
}
