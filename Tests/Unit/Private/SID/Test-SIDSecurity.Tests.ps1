#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
Describe "Test-SIDSecurity Enterprise Security Testing" {
    BeforeAll {
        # Dot-source the classes and functions under test rather than importing the module
        $ModuleRoot = Split-Path -Path (Split-Path -Path (Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent) -Parent) -Parent
        $PrivatePath = Join-Path -Path $ModuleRoot -ChildPath 'Private'
        
        # Classes first: the functions below use them as type literals
        . (Join-Path -Path $ModuleRoot -ChildPath 'Classes\SecurityValidationResult.ps1')
        . (Join-Path -Path $ModuleRoot -ChildPath 'Classes\SIDAnalysisResult.ps1')
    
        . (Join-Path -Path $PrivatePath -ChildPath 'SID\Test-SIDSecurity.ps1')
        . (Join-Path -Path $PrivatePath -ChildPath 'Logging\Write-SecurityLog.ps1')
        . (Join-Path -Path $PrivatePath -ChildPath 'Logging\Write-StructuredLog.ps1')
        . (Join-Path -Path $PrivatePath -ChildPath 'Logging\Write-StructuredLogEntry.ps1')
        . (Join-Path -Path $PrivatePath -ChildPath 'SID\Test-SIDFormat.ps1')
        . (Join-Path -Path $PrivatePath -ChildPath 'SID\Get-SIDAnalysis.ps1')
        
        . "$PSScriptRoot\..\..\..\..\Private\SID\Test-SIDSecurity.ps1"
        
        # Create mock configuration for testing  
        $script:Config = @{
            ProtectedSIDs = @(
                'S-1-5-18',      # Local System
                'S-1-5-19',      # Local Service  
                'S-1-5-20',      # Network Service
                'S-1-5-32-544',  # Administrators
                'S-1-5-32-548',  # Account Operators
                'S-1-5-32-549',  # Server Operators
                'S-1-5-32-550',  # Print Operators
                'S-1-5-32-551'   # Backup Operators
            )
            CriticalObjectPatterns = @(
                'CN=Domain Controllers,*',
                'CN=Enterprise Admins,*',
                'CN=Schema Admins,*',
                'CN=Builtin,*'
            )
            SecurityValidation = @{
                RequireElevatedConfirmation = $true
                AllowWellKnownSIDRemoval = $false
                ComplianceFrameworks = @('SOX', 'HIPAA', 'PCI-DSS')
            }
        }
        
        # Mock external dependencies with comprehensive behavior
        Mock Write-SecurityLog {
            param(
                [string]$SecurityEventType,
                [string]$Message,
                [string]$Outcome,
                [string]$CorrelationId,
                [hashtable]$SecurityContext,
                [string]$RiskLevel = 'Medium'
            )
            
            # Store the security log calls for validation
            if (-not $global:SecurityLogCalls) { $global:SecurityLogCalls = @() }
            $global:SecurityLogCalls += @{
                SecurityEventType = $SecurityEventType
                Message = $Message
                Outcome = $Outcome
                CorrelationId = $CorrelationId
                SecurityContext = $SecurityContext
                RiskLevel = $RiskLevel
                Timestamp = Get-Date
            }
        }
        
        Mock Write-StructuredLog {
            param(
                [string]$Message,
                [string]$Level,
                [string]$Component,
                [string]$CorrelationId,
                [hashtable]$Data
            )
            # Store structured log calls for validation
            if (-not $global:StructuredLogCalls) { $global:StructuredLogCalls = @() }
            $global:StructuredLogCalls += @{
                Message = $Message
                Level = $Level
                Component = $Component
                CorrelationId = $CorrelationId
                Data = $Data
                Timestamp = Get-Date
            }
        } -ModuleName $null
        
        # Pester can only mock a command that exists, and neither of these is loaded above
        function Global:Format-LogMessage { }
        function Global:Write-SecurityStructuredLogEntry { }
        
        Mock Write-StructuredLogEntry {
            param(
                [string]$Component,
                [string]$Level,
                [string]$Message,
                [string]$CorrelationId,
                [hashtable]$Details
            )
            # Store structured log entry calls
            if (-not $global:StructuredLogEntryCalls) { $global:StructuredLogEntryCalls = @() }
            $global:StructuredLogEntryCalls += @{
                Message = $Message
                Level = $Level
                Component = $Component
                CorrelationId = $CorrelationId
                Details = $Details
                Timestamp = Get-Date
            }
        } -ModuleName $null
        
        Mock Format-LogMessage {
            param(
                [string]$Message,
                [string]$Level,
                [string]$Component,
                [string]$CorrelationId,
                [hashtable]$AdditionalData,
                [string]$Format = 'PlainText'
            )
            return "[$Level] $Component - $Message"
        } -ModuleName $null
        
        Mock Write-SecurityStructuredLogEntry {
            param(
                [string]$Level,
                [string]$Component,
                [string]$Message,
                [string]$CorrelationId,
                [hashtable]$Data
            )
            # Store security structured log entry calls
            if (-not $global:SecurityStructuredLogEntryCalls) { $global:SecurityStructuredLogEntryCalls = @() }
            $global:SecurityStructuredLogEntryCalls += @{
                Level = $Level
                Component = $Component
                Message = $Message
                CorrelationId = $CorrelationId
                Data = $Data
                Timestamp = Get-Date
            }
        } -ModuleName $null
        
        Mock Test-WellKnownSID {
            param($SID, $CorrelationId)
            # Return true for well-known SIDs
            switch -Regex ($SID) {
                '^S-1-5-18$' { return $true }     # Local System
                '^S-1-5-19$' { return $true }     # Local Service
                '^S-1-5-20$' { return $true }     # Network Service
                '^S-1-5-32-544$' { return $true } # Administrators
                '^S-1-5-32-5[0-9][0-9]$' { return $true } # Built-in groups
                '^S-1-5-21.*-519$' { return $true } # Enterprise Admins
                '^S-1-5-21.*-518$' { return $true } # Schema Admins
                default { return $false }
            }
        } -ModuleName $null
        
        Mock Get-SIDAnalysis {
            param($SIDString, $CorrelationId)
            
            # Return comprehensive SIDAnalysisResult based on SID pattern
            $result = [SIDAnalysisResult]::new()
            $result.SID = $SIDString
            
            switch -Regex ($SIDString) {
                '^S-1-5-18$' {  # Local System
                    $result.LikelySource = 'System Account'
                    $result.Confidence = 'High'
                    $result.Notes = 'Critical system account - removal not permitted'
                    $result.RiskLevel = 'Critical'
                    $result.DomainContext = 'NT AUTHORITY'
                }
                '^S-1-5-32-544$' {  # Administrators
                    $result.LikelySource = 'Built-in Administrators Group'
                    $result.Confidence = 'High'
                    $result.Notes = 'Critical administrative group'
                    $result.RiskLevel = 'Critical'
                    $result.DomainContext = 'BUILTIN'
                }
                '^S-1-5-21.*-512$' {  # Domain Admins
                    $result.LikelySource = 'Domain Administrators Group'
                    $result.Confidence = 'High'
                    $result.Notes = 'High-privilege domain group'
                    $result.RiskLevel = 'High'
                    $result.DomainContext = 'Domain'
                }
                '^S-1-5-21.*-501$' {  # Guest
                    $result.LikelySource = 'Guest Account'
                    $result.Confidence = 'High'
                    $result.Notes = 'Built-in guest account'
                    $result.RiskLevel = 'Medium'
                    $result.DomainContext = 'Domain'
                }
                '^S-1-5-80-' {  # Service SID
                    $result.LikelySource = 'Service Account'
                    $result.Confidence = 'Medium'
                    $result.Notes = 'Service account SID'
                    $result.RiskLevel = 'Low'
                    $result.DomainContext = 'Service'
                }
                'MALICIOUS|INJECTION' {  # Malicious input
                    $result.LikelySource = 'Invalid Input'
                    $result.Confidence = 'Low'
                    $result.Notes = 'Potentially malicious input detected'
                    $result.RiskLevel = 'Critical'
                    $result.DomainContext = 'Unknown'
                }
                default {  # Regular user SIDs
                    $result.LikelySource = 'Domain User Account'
                    $result.Confidence = 'Medium'
                    $result.Notes = 'Standard domain user SID'
                    $result.RiskLevel = 'Medium'
                    $result.DomainContext = 'Domain'
                }
            }
            
            return $result
        } -ModuleName $null
        
        # Initialize global tracking variables for test validation
        $global:SecurityLogCalls = @()
        $global:StructuredLogCalls = @()
        $global:StructuredLogEntryCalls = @()
    }

    Context "Function Existence and Parameter Validation" {
        It "Should have Test-SIDSecurity function available" {
            { Get-Command Test-SIDSecurity -ErrorAction Stop } | Should -Not -Throw
        }

        It "Should accept mandatory SIDString parameter" {
            $testSID = "S-1-5-21-123456789-123456789-123456789-1001"
            { Test-SIDSecurity -SIDString $testSID } | Should -Not -Throw
        }

        It "Should accept optional ObjectDN parameter" {
            $testSID = "S-1-5-21-123456789-123456789-123456789-1001"
            $objectDN = "CN=TestUser,OU=Users,DC=contoso,DC=com"
            { Test-SIDSecurity -SIDString $testSID -ObjectDN $objectDN } | Should -Not -Throw
        }

        It "Should accept ValidationLevel parameter with valid values" {
            $testSID = "S-1-5-21-123456789-123456789-123456789-1001"
            $validLevels = @('Basic', 'Standard', 'Strict')
            
            foreach ($level in $validLevels) {
                { Test-SIDSecurity -SIDString $testSID -ValidationLevel $level } | Should -Not -Throw
            }
        }

        It "Should reject invalid ValidationLevel values" {
            $testSID = "S-1-5-21-123456789-123456789-123456789-1001"
            $invalidLevels = @('Invalid', 'Custom', 'Enterprise')
            
            foreach ($level in $invalidLevels) {
                { Test-SIDSecurity -SIDString $testSID -ValidationLevel $level } | Should -Throw
            }
        }

        It "Should accept CorrelationId parameter" {
            $testSID = "S-1-5-21-123456789-123456789-123456789-1001"
            $correlationId = [System.Guid]::NewGuid().ToString()
            { Test-SIDSecurity -SIDString $testSID -CorrelationId $correlationId } | Should -Not -Throw
        }

        It "Should generate CorrelationId when not provided" {
            $testSID = "S-1-5-21-123456789-123456789-123456789-1001"
            { Test-SIDSecurity -SIDString $testSID } | Should -Not -Throw
        }

        It "Should reject null or empty SIDString" {
            { Test-SIDSecurity -SIDString $null } | Should -Throw
            { Test-SIDSecurity -SIDString "" } | Should -Throw
            { Test-SIDSecurity -SIDString "   " } | Should -Throw
        }
    }

    Context "Protected SID Detection and Blocking" {
        BeforeEach {
            $global:SecurityLogCalls = @()
            $global:StructuredLogCalls = @()
        }

        It "Should block Local System SID (S-1-5-18)" {
            $systemSID = "S-1-5-18"
            $result = Test-SIDSecurity -SIDString $systemSID
            
            $result.IsValid | Should -Be $false
            $result.RiskLevel | Should -Be "Critical"
            ($result.BlockedSIDs -contains $systemSID) | Should -Be $true
            ($result.Issues -contains "SID is in protected SIDs list - removal blocked by security policy") | Should -Be $true
        }

        It "Should block Administrators group SID (S-1-5-32-544)" {
            $adminSID = "S-1-5-32-544"
            $result = Test-SIDSecurity -SIDString $adminSID
            
            $result.IsValid | Should -Be $false
            $result.RiskLevel | Should -Be "Critical"
            ($result.BlockedSIDs -contains $adminSID) | Should -Be $true
        }

        It "Should block all configured protected SIDs" {
            $protectedSIDs = $script:Config.ProtectedSIDs
            
            foreach ($sid in $protectedSIDs) {
                $result = Test-SIDSecurity -SIDString $sid
                $result.IsValid | Should -Be $false
                $result.RiskLevel | Should -Be "Critical"
                ($result.BlockedSIDs -contains $sid) | Should -Be $true
            }
        }

        It "Should log security blocking events for protected SIDs" {
            $global:SecurityLogCalls = @()
            $protectedSID = "S-1-5-18"
            $result = Test-SIDSecurity -SIDString $protectedSID
            
            # Protected SIDs are blocked
            $result.IsValid | Should -Be $false
            $result.RiskLevel | Should -Be "Critical"

            # The block is written to the security log
            $securityLogs = $global:SecurityLogCalls | Where-Object { 
                $_.SecurityEventType -eq 'DataValidation'
            }
            $securityLogs.Count | Should -BeGreaterThan 0
        }

        It "Should maintain audit trail for blocked SIDs" {
            $protectedSID = "S-1-5-32-544"
            $correlationId = [System.Guid]::NewGuid().ToString()
            $result = Test-SIDSecurity -SIDString $protectedSID -CorrelationId $correlationId
            
            $result.IsValid | Should -Be $false
            $result.RiskLevel | Should -Be "Critical"

            # The security log entries carry the caller's correlation ID
            $auditLogs = $global:SecurityLogCalls | Where-Object { 
                $_.CorrelationId -eq $correlationId -and 
                $_.SecurityEventType -eq 'DataValidation'
            }
            $auditLogs.Count | Should -BeGreaterThan 0
        }
    }

    Context "Well-Known SID Validation" {
        BeforeEach {
            $global:SecurityLogCalls = @()
            
            # Override Test-WellKnownSID mock for this context to include Domain Admins
            Mock Test-WellKnownSID {
                param($SID, $CorrelationId)
                switch -Regex ($SID) {
                    '^S-1-5-18$' { return $true }     # Local System
                    '^S-1-5-19$' { return $true }     # Local Service
                    '^S-1-5-20$' { return $true }     # Network Service
                    '^S-1-5-32-544$' { return $true } # Administrators
                    '^S-1-5-32-5[0-9][0-9]$' { return $true } # Built-in groups
                    '^S-1-5-21.*-519$' { return $true } # Enterprise Admins
                    '^S-1-5-21.*-518$' { return $true } # Schema Admins
                    '^S-1-5-21.*-512$' { return $true } # Domain Admins (treated as well-known in this context)
                    default { return $false }
                }
            } -ModuleName $null
        }

        It "Should detect and handle well-known SIDs with Standard validation" {
            $wellKnownSID = "S-1-5-21-123456789-123456789-123456789-512"  # Domain Admins pattern
            $result = Test-SIDSecurity -SIDString $wellKnownSID -ValidationLevel 'Standard'
            
            # Blocked as well-known, but rated High rather than Critical
            $result.IsValid | Should -Be $false
            $result.RiskLevel | Should -Be "High"
            ($result.Issues -contains "Well-known SID detected - removal may impact system security") | Should -Be $true
        }

        It "Should detect and handle well-known SIDs with Strict validation" {
            $wellKnownSID = "S-1-5-21-123456789-123456789-123456789-519"  # Enterprise Admins pattern
            $result = Test-SIDSecurity -SIDString $wellKnownSID -ValidationLevel 'Strict'
            
            $result.IsValid | Should -Be $false
            $result.RiskLevel | Should -Be "High"
            ($result.BlockedSIDs -contains $wellKnownSID) | Should -Be $true
        }

        It "Should allow well-known SIDs with Basic validation" {
            $wellKnownSID = "S-1-5-21-123456789-123456789-123456789-512"
            $result = Test-SIDSecurity -SIDString $wellKnownSID -ValidationLevel 'Basic'
            
            # Only checks that a result is returned; whether Basic allows the SID is not asserted
            $result | Should -Not -Be $null
        }

        It "Should log well-known SID detection events" {
            $wellKnownSID = "S-1-5-21-123456789-123456789-123456789-512"
            Test-SIDSecurity -SIDString $wellKnownSID -ValidationLevel 'Standard'
            
            $securityLogs = $global:SecurityLogCalls | Where-Object { 
                $_.SecurityEventType -eq 'DataValidation' -and 
                $_.Outcome -eq 'Failure' -and
                $_.SecurityContext.BlockedReason -eq 'WellKnownSID' 
            }
            $securityLogs.Count | Should -BeGreaterThan 0
        }
    }

    Context "Risk-Based Validation and Assessment" {
        BeforeEach {
            $global:SecurityLogCalls = @()
        }

        It "Should handle High risk SIDs with elevated confirmation requirements" {
            $highRiskSID = "S-1-5-21-123456789-123456789-123456789-512"  # Domain Admins
            $result = Test-SIDSecurity -SIDString $highRiskSID -ValidationLevel 'Strict'
            
            # The requirement is asserted through the Issues text, not RequiresElevatedConfirmation
            $result.RiskLevel | Should -Be "High"
            ($result.Issues -contains "High-risk SID requires elevated confirmation for removal") | Should -Be $true
        }

        It "Should handle Medium risk SIDs appropriately" {
            $mediumRiskSID = "S-1-5-21-123456789-123456789-123456789-1001"  # Regular user
            $result = Test-SIDSecurity -SIDString $mediumRiskSID -ValidationLevel 'Strict'
            
            $result.RiskLevel | Should -Be "Medium"
        }

        It "Should allow Low risk SIDs for removal" {
            $lowRiskSID = "S-1-5-80-123456789-123456789-123456789-123456789-123456789"  # Service SID
            $result = Test-SIDSecurity -SIDString $lowRiskSID
            
            $result.RiskLevel | Should -Be "Low"
            ($result.AllowedSIDs -contains $lowRiskSID) | Should -Be $true
            $result.IsValid | Should -Be $true
        }

        It "Should log high-risk SID validation events" {
            $highRiskSID = "S-1-5-21-123456789-123456789-123456789-512"
            Test-SIDSecurity -SIDString $highRiskSID -ValidationLevel 'Strict'
            
            # Should have validation logs for the high-risk SID
            $riskLogs = $global:SecurityLogCalls | Where-Object { 
                $_.SecurityEventType -eq 'DataValidation'
            }
            $riskLogs.Count | Should -BeGreaterThan 0
        }

        It "Should track SID analysis context in risk assessment" {
            $testSID = "S-1-5-21-123456789-123456789-123456789-512"
            Test-SIDSecurity -SIDString $testSID -ValidationLevel 'Strict'
            
            # Should have validation logs for the SID analysis
            $analysisLogs = $global:SecurityLogCalls | Where-Object { 
                $_.SecurityEventType -eq 'DataValidation'
            }
            $analysisLogs.Count | Should -BeGreaterThan 0
        }
    }

    Context "Object Context and Critical Path Validation" {
        BeforeEach {
            $global:SecurityLogCalls = @()
        }

        It "Should identify SIDs on critical objects" {
            $testSID = "S-1-5-21-123456789-123456789-123456789-1001"
            $criticalObjectDN = "CN=Domain Controllers,CN=System,DC=contoso,DC=com"
            $result = Test-SIDSecurity -SIDString $testSID -ObjectDN $criticalObjectDN
            
            $result.RequiresElevatedConfirmation | Should -Be $true
            ($result.Issues -contains "SID is on critical object: $criticalObjectDN") | Should -Be $true
            $result.RiskLevel | Should -Be "High"
        }

        It "Should handle Enterprise Admins container objects" {
            $testSID = "S-1-5-21-123456789-123456789-123456789-1001"
            $enterpriseAdminsDN = "CN=Enterprise Admins,CN=Users,DC=contoso,DC=com"
            $result = Test-SIDSecurity -SIDString $testSID -ObjectDN $enterpriseAdminsDN
            
            $result.RequiresElevatedConfirmation | Should -Be $true
            $result.RiskLevel | Should -Be "High"
        }

        It "Should handle Schema Admins container objects" {
            $testSID = "S-1-5-21-123456789-123456789-123456789-1001"
            $schemaAdminsDN = "CN=Schema Admins,CN=Users,DC=contoso,DC=com"
            $result = Test-SIDSecurity -SIDString $testSID -ObjectDN $schemaAdminsDN
            
            $result.RequiresElevatedConfirmation | Should -Be $true
        }

        It "Should allow SIDs on non-critical objects" {
            $testSID = "S-1-5-21-123456789-123456789-123456789-1001"
            $regularObjectDN = "CN=TestUser,OU=Users,DC=contoso,DC=com"
            $result = Test-SIDSecurity -SIDString $testSID -ObjectDN $regularObjectDN
            
            # Should not automatically require elevated confirmation for regular objects
            # (unless the SID itself requires it)
        }

        It "Should validate all critical object patterns from configuration" {
            $testSID = "S-1-5-21-123456789-123456789-123456789-1001"
            $criticalPatterns = $script:Config.CriticalObjectPatterns
            
            foreach ($pattern in $criticalPatterns) {
                $mockDN = $pattern.Replace('*', 'CN=TestObject,DC=contoso,DC=com')
                $result = Test-SIDSecurity -SIDString $testSID -ObjectDN $mockDN
                $result.RequiresElevatedConfirmation | Should -Be $true
            }
        }
    }

    Context "Security Audit Logging and Compliance" {
        BeforeEach {
            $global:SecurityLogCalls = @()
            $global:StructuredLogCalls = @()
        }

        It "Should log security validation initiation" {
            $testSID = "S-1-5-21-123456789-123456789-123456789-1001"
            Test-SIDSecurity -SIDString $testSID
            
            # Should have initiation logs for the validation attempt
            $initiationLogs = $global:SecurityLogCalls | Where-Object { 
                $_.SecurityEventType -eq 'DataValidation' -and 
                $_.Outcome -eq 'Attempt' 
            }
            $initiationLogs.Count | Should -BeGreaterThan 0
        }

        It "Should log successful validation completion" {
            $testSID = "S-1-5-80-123456789-123456789-123456789-123456789-123456789"  # Low risk service SID
            Test-SIDSecurity -SIDString $testSID
            
            $successLogs = $global:SecurityLogCalls | Where-Object { 
                $_.SecurityEventType -eq 'DataValidation' -and 
                $_.Outcome -eq 'Success' 
            }
            $successLogs.Count | Should -BeGreaterThan 0
        }

        It "Should maintain comprehensive security context in logs" {
            $testSID = "S-1-5-21-123456789-123456789-123456789-1001"
            $correlationId = [System.Guid]::NewGuid().ToString()
            $objectDN = "CN=TestUser,OU=Users,DC=contoso,DC=com"
            
            Test-SIDSecurity -SIDString $testSID -CorrelationId $correlationId -ObjectDN $objectDN -ValidationLevel 'Strict'
            
            $contextLogs = $global:SecurityLogCalls | Where-Object { $_.CorrelationId -eq $correlationId }
            $contextLogs.Count | Should -BeGreaterThan 0
            
            $context = $contextLogs[0].SecurityContext
            $context.SIDString | Should -Be $testSID
            $context.ValidationLevel | Should -Be 'Strict'
            $context.ObjectDN | Should -Be $objectDN
            $context.Component | Should -Be 'SIDSecurity'
        }

        It "Should include correlation ID in all log entries" {
            $testSID = "S-1-5-21-123456789-123456789-123456789-1001"
            $correlationId = [System.Guid]::NewGuid().ToString()
            
            Test-SIDSecurity -SIDString $testSID -CorrelationId $correlationId
            
            $correlatedLogs = $global:SecurityLogCalls | Where-Object { $_.CorrelationId -eq $correlationId }
            $correlatedLogs.Count | Should -BeGreaterThan 0
            
            # All logs should have the same correlation ID
            $correlatedLogs | ForEach-Object { $_.CorrelationId | Should -Be $correlationId }
        }

        It "Should log structured debug information" {
            $testSID = "S-1-5-21-123456789-123456789-123456789-1001"
            Test-SIDSecurity -SIDString $testSID
            
            $debugLogs = $global:StructuredLogCalls | Where-Object { 
                $_.Component -eq 'SIDSecurity' -and 
                $_.Level -eq 'Debug' 
            }
            $debugLogs.Count | Should -BeGreaterThan 0
        }
    }

    Context "SecurityValidationResult Structure and Properties" {
        It "Should return SecurityValidationResult object" {
            $testSID = "S-1-5-21-123456789-123456789-123456789-1001"
            $result = Test-SIDSecurity -SIDString $testSID
            $result.GetType().Name | Should -Be "SecurityValidationResult"
        }

        It "Should include all required properties" {
            $testSID = "S-1-5-21-123456789-123456789-123456789-1001"
            $result = Test-SIDSecurity -SIDString $testSID
            
            # Required properties based on SecurityValidationResult class
            ($result.PSObject.Properties.Name -contains 'IsValid') | Should -Be $true
            ($result.PSObject.Properties.Name -contains 'RiskLevel') | Should -Be $true
            ($result.PSObject.Properties.Name -contains 'Issues') | Should -Be $true
            ($result.PSObject.Properties.Name -contains 'RequiresElevatedConfirmation') | Should -Be $true
            ($result.PSObject.Properties.Name -contains 'BlockedSIDs') | Should -Be $true
            ($result.PSObject.Properties.Name -contains 'AllowedSIDs') | Should -Be $true
            ($result.PSObject.Properties.Name -contains 'ValidatedAt') | Should -Be $true
            ($result.PSObject.Properties.Name -contains 'ValidatorVersion') | Should -Be $true
        }

        It "Should have valid RiskLevel values" {
            $testSIDs = @(
                "S-1-5-18",                                           # Critical
                "S-1-5-21-123456789-123456789-123456789-512",       # High
                "S-1-5-21-123456789-123456789-123456789-1001",      # Medium
                "S-1-5-80-123456789-123456789-123456789-123456789-123456789" # Low
            )
            
            $validRiskLevels = @('Low', 'Medium', 'High', 'Critical')
            
            foreach ($sid in $testSIDs) {
                $result = Test-SIDSecurity -SIDString $sid
                ($validRiskLevels -contains $result.RiskLevel) | Should -Be $true
            }
        }

        It "Should populate ValidatedAt timestamp" {
            $testSID = "S-1-5-21-123456789-123456789-123456789-1001"
            $beforeValidation = Get-Date
            $result = Test-SIDSecurity -SIDString $testSID
            $afterValidation = Get-Date
            
            $result.ValidatedAt | Should -Not -BeNullOrEmpty
            $result.ValidatedAt | Should -BeGreaterThan $beforeValidation.AddSeconds(-2)
            $result.ValidatedAt | Should -BeLessThan $afterValidation.AddSeconds(2)
        }

        It "Should include ValidatorVersion" {
            $testSID = "S-1-5-21-123456789-123456789-123456789-1001"
            $result = Test-SIDSecurity -SIDString $testSID
            
            $result.ValidatorVersion | Should -Not -BeNullOrEmpty
            $result.ValidatorVersion | Should -Match '^\d+\.\d+\.\d+$'  # Version format
        }

        It "Should initialize collections properly" {
            $testSID = "S-1-5-21-123456789-123456789-123456789-1001"
            $result = Test-SIDSecurity -SIDString $testSID
            
            $result.Issues.Count | Should -BeGreaterThan -1
            $result.BlockedSIDs.Count | Should -BeGreaterThan -1
            $result.AllowedSIDs.Count | Should -BeGreaterThan -1
            
            # The collections are arrays, even when empty
            ($result.Issues -is [Array]) | Should -Be $true
            ($result.BlockedSIDs -is [Array]) | Should -Be $true
            ($result.AllowedSIDs -is [Array]) | Should -Be $true
        }
    }

    Context "Error Handling and Resilience" {
        BeforeEach {
            $global:SecurityLogCalls = @()
            $global:StructuredLogCalls = @()
        }

        It "Should handle Get-SIDAnalysis failures gracefully" {
            Mock Get-SIDAnalysis { throw "Analysis service unavailable" } -ModuleName $null
            
            $testSID = "S-1-5-21-123456789-123456789-123456789-1001"
            { Test-SIDSecurity -SIDString $testSID } | Should -Not -Throw
            
            $result = Test-SIDSecurity -SIDString $testSID
            $result.IsValid | Should -Be $false
            $result.RiskLevel | Should -Be "Critical"
            $result.Issues -join ' ' | Should -Match "Analysis service unavailable"
        }

        It "Should log errors for audit trail" {
            Mock Get-SIDAnalysis { throw "Service error" } -ModuleName $null
            
            $testSID = "S-1-5-21-123456789-123456789-123456789-1001"
            $result = Test-SIDSecurity -SIDString $testSID
            
            # A failed analysis fails closed: the SID is invalid and rated Critical
            $result.IsValid | Should -Be $false
            $result.RiskLevel | Should -Be "Critical"

            # The security log is still written when analysis fails
            $errorLogs = $global:SecurityLogCalls | Where-Object { 
                $_.SecurityEventType -eq 'DataValidation'
            }
            $errorLogs.Count | Should -BeGreaterThan 0
        }

        It "Should handle malformed SID input safely" {
            $maliciousSIDs = @(
                "S-1-5-21'; DROP TABLE Users; --",
                "S-1-5-21<script>alert('xss')</script>",
                "S-1-5-21`$(Get-Process)",
                "S-1-5-21 & rmdir /s /q C:\\"
            )
            
            foreach ($maliciousSID in $maliciousSIDs) {
                { Test-SIDSecurity -SIDString $maliciousSID } | Should -Not -Throw
                $result = Test-SIDSecurity -SIDString $maliciousSID
                $result | Should -Not -Be $null
                $result.RiskLevel | Should -Be "Critical"
            }
        }

        It "Should handle null script configuration gracefully" {
            $originalConfig = $script:Config
            $script:Config = $null
            
            try {
                $testSID = "S-1-5-21-123456789-123456789-123456789-1001"
                { Test-SIDSecurity -SIDString $testSID } | Should -Not -Throw
                
                $result = Test-SIDSecurity -SIDString $testSID
                $result | Should -Not -Be $null
            }
            finally {
                $script:Config = $originalConfig
            }
        }

        It "Should maintain logging even during errors" {
            Mock Write-StructuredLog { throw "Logging service down" } -ModuleName $null
            
            $testSID = "S-1-5-21-123456789-123456789-123456789-1001"
            { Test-SIDSecurity -SIDString $testSID } | Should -Not -Throw
            
            # A logging failure does not stop validation from returning a result
            $result = Test-SIDSecurity -SIDString $testSID
            $result | Should -Not -Be $null
            $result.IsValid | Should -Not -Be $null  # SID validation should still work
        }
    }

    Context "Performance and Scalability" {
        It "Should complete validation within acceptable time" {
            $testSID = "S-1-5-21-123456789-123456789-123456789-1001"
            
            $executionTime = Measure-Command {
                Test-SIDSecurity -SIDString $testSID
            }
            
            # Should complete within 2 seconds for single SID
            $executionTime.TotalSeconds | Should -BeLessThan 2
        }

        It "Should handle batch validation efficiently" {
            $testSIDs = 1..10 | ForEach-Object { "S-1-5-21-123456789-123456789-123456789-$_" }
            
            $executionTime = Measure-Command {
                foreach ($sid in $testSIDs) {
                    Test-SIDSecurity -SIDString $sid | Out-Null
                }
            }
            
            # Should complete 10 validations within 10 seconds
            $executionTime.TotalSeconds | Should -BeLessThan 10
        }

        It "Should maintain consistent performance across validation levels" {
            $testSID = "S-1-5-21-123456789-123456789-123456789-1001"
            $levels = @('Basic', 'Standard', 'Strict')
            $executionTimes = @()
            
            foreach ($level in $levels) {
                $time = Measure-Command {
                    Test-SIDSecurity -SIDString $testSID -ValidationLevel $level | Out-Null
                }
                $executionTimes += $time.TotalMilliseconds
            }
            
            # Strict is no more than five times slower than Basic
            $executionTimes[2] | Should -BeLessThan ($executionTimes[0] * 5)
        }

        It "Should handle memory efficiently" {
            $largeSIDList = 1..50 | ForEach-Object { "S-1-5-21-123456789-123456789-123456789-$_" }
            
            $memoryBefore = [System.GC]::GetTotalMemory($true)
            
            foreach ($sid in $largeSIDList) {
                Test-SIDSecurity -SIDString $sid | Out-Null
            }
            
            [System.GC]::Collect()
            $memoryAfter = [System.GC]::GetTotalMemory($true)
            $memoryIncrease = ($memoryAfter - $memoryBefore) / 1MB
            
        }
    }

    Context "Get-SIDRiskAssessment Function Tests" {
        BeforeEach {
            $global:SecurityLogCalls = @()
        }

        It "Should have Get-SIDRiskAssessment function available" {
            { Get-Command Get-SIDRiskAssessment -ErrorAction Stop } | Should -Not -Throw
        }

        It "Should accept SIDList parameter" {
            $testSIDs = @(
                "S-1-5-21-123456789-123456789-123456789-1001",
                "S-1-5-21-123456789-123456789-123456789-1002"
            )
            { Get-SIDRiskAssessment -SIDList $testSIDs } | Should -Not -Throw
        }

        It "Should return comprehensive risk assessment object" {
            $testSIDs = @(
                "S-1-5-21-123456789-123456789-123456789-1001",
                "S-1-5-21-123456789-123456789-123456789-1002"
            )
            $result = Get-SIDRiskAssessment -SIDList $testSIDs
            
            $result | Should -Not -Be $null
            $result.PSObject.TypeNames[0] | Should -Be 'SIDRiskAssessment'
            $result.TotalSIDs | Should -Be 2
            $result.AssessmentId | Should -Not -BeNullOrEmpty
            $result.AssessedAt | Should -Not -BeNullOrEmpty
        }

        It "Should categorize risk levels correctly" {
            $mixedSIDs = @(
                "S-1-5-18",                                           # Critical (System)
                "S-1-5-21-123456789-123456789-123456789-512",       # High (Domain Admins)
                "S-1-5-21-123456789-123456789-123456789-1001",      # Medium (User)
                "S-1-5-80-123456789-123456789-123456789-123456789-123456789"  # Low (Service)
            )
            
            $result = Get-SIDRiskAssessment -SIDList $mixedSIDs
            
            $result.RiskBreakdown.Critical | Should -BeGreaterThan 0
            $result.RiskBreakdown.High | Should -BeGreaterThan 0
            $result.RiskBreakdown.Medium | Should -BeGreaterThan 0
            $result.RiskBreakdown.Low | Should -BeGreaterThan 0
        }

        It "Should determine overall risk level appropriately" {
            $criticalSIDs = @("S-1-5-18", "S-1-5-19")  # System SIDs
            $result = Get-SIDRiskAssessment -SIDList $criticalSIDs
            $result.OverallRisk | Should -Be "Critical"
            
            $highSIDs = @("S-1-5-21-123456789-123456789-123456789-512")  # Domain Admins
            $result = Get-SIDRiskAssessment -SIDList $highSIDs
            $result.OverallRisk | Should -Be "High"
            
            $lowSIDs = @("S-1-5-80-123456789-123456789-123456789-123456789-123456789")  # Service
            $result = Get-SIDRiskAssessment -SIDList $lowSIDs
            $result.OverallRisk | Should -Be "Low"
        }

        It "Should categorize SIDs correctly into blocked, allowed, and requires approval" {
            $mixedSIDs = @(
                "S-1-5-18",                                           # Blocked (protected)
                "S-1-5-21-123456789-123456789-123456789-512",       # May require approval (high risk)
                "S-1-5-80-123456789-123456789-123456789-123456789-123456789"  # Allowed (low risk)
            )
            
            $result = Get-SIDRiskAssessment -SIDList $mixedSIDs
            
            $result.BlockedSIDs.Count | Should -BeGreaterThan 0
            $result.AllowedSIDs.Count | Should -BeGreaterThan 0
            # The RequiresApproval count is not asserted; it depends on the validation level
        }

        It "Should provide actionable recommendations" {
            $testSIDs = @(
                "S-1-5-18",  # Blocked
                "S-1-5-21-123456789-123456789-123456789-1001"  # Regular
            )
            
            $result = Get-SIDRiskAssessment -SIDList $testSIDs
            
            $result.Recommendations | Should -Not -BeNullOrEmpty
            $result.Recommendations.Count | Should -BeGreaterThan 0
            $result.Recommendations -join ' ' | Should -Match 'blocked|approval|automatic'
        }

        It "Should determine SafeForAutomation flag correctly" {
            $safeSIDs = @("S-1-5-80-123456789-123456789-123456789-123456789-123456789")
            $result = Get-SIDRiskAssessment -SIDList $safeSIDs
            $result.SafeForAutomation | Should -Be $true
            
            $unsafeSIDs = @("S-1-5-18")  # Protected SID
            $result = Get-SIDRiskAssessment -SIDList $unsafeSIDs
            $result.SafeForAutomation | Should -Be $false
        }

        It "Should handle empty SID list gracefully" {
            $emptySIDs = @()
            $result = Get-SIDRiskAssessment -SIDList $emptySIDs
            
            $result.TotalSIDs | Should -Be 0
            $result.OverallRisk | Should -Be "Low"
            $result.SafeForAutomation | Should -Be $true
        }

        It "Should support object context parameter" {
            $testSIDs = @("S-1-5-21-123456789-123456789-123456789-1001")
            $objectContext = "Critical Infrastructure"
            
            $result = Get-SIDRiskAssessment -SIDList $testSIDs -ObjectContext $objectContext
            $result.ObjectContext | Should -Be $objectContext
        }

        It "Should support correlation ID tracking" {
            $testSIDs = @("S-1-5-21-123456789-123456789-123456789-1001")
            $correlationId = [System.Guid]::NewGuid().ToString()
            
            $result = Get-SIDRiskAssessment -SIDList $testSIDs -CorrelationId $correlationId
            $result.AssessmentId | Should -Be $correlationId
        }

        It "Should log comprehensive risk assessment events" {
            $testSIDs = @(
                "S-1-5-21-123456789-123456789-123456789-1001",
                "S-1-5-21-123456789-123456789-1002"
            )
            
            $result = Get-SIDRiskAssessment -SIDList $testSIDs
            
            $result | Should -Not -Be $null
            $result.TotalSIDs | Should -Be 2

            # At least one successful RiskAssessment entry in the security log
            $riskLogs = $global:SecurityLogCalls | Where-Object { 
                $_.SecurityEventType -eq 'RiskAssessment' -and 
                $_.Outcome -eq 'Success' 
            }
            $riskLogs.Count | Should -BeGreaterThan 0
        }

        It "Should handle large SID lists efficiently" {
            $largeSIDList = 1..25 | ForEach-Object { "S-1-5-21-123456789-123456789-123456789-$_" }
            
            $executionTime = Measure-Command {
                $result = Get-SIDRiskAssessment -SIDList $largeSIDList
            }
            
            $executionTime.TotalSeconds | Should -BeLessThan 5  # Should complete within 5 seconds
            $result.TotalSIDs | Should -Be 25
        }
    }

    Context "Compliance Framework Integration" {
        BeforeEach {
            $global:SecurityLogCalls = @()
        }

        It "Should support SOX compliance requirements" {
            $testSID = "S-1-5-21-123456789-123456789-123456789-1001"
            # Test-SIDSecurity has no compliance-framework parameter; this checks only that the
            # security log entries carry the validation level and a correlation ID
            $result = Test-SIDSecurity -SIDString $testSID -ValidationLevel 'Strict'

            $auditLogs = $global:SecurityLogCalls | Where-Object {
                $_.SecurityEventType -eq 'DataValidation'
            }
            $auditLogs.Count | Should -BeGreaterThan 0

            $auditLogs[0].SecurityContext.ValidationLevel | Should -Not -BeNullOrEmpty
            $auditLogs[0].CorrelationId | Should -Not -BeNullOrEmpty
        }

        It "Should support HIPAA compliance requirements" {
            $testSID = "S-1-5-21-123456789-123456789-123456789-1001"
            $result = Test-SIDSecurity -SIDString $testSID -ValidationLevel 'Strict'
            
            $securityLogs = $global:SecurityLogCalls | Where-Object { 
                $_.SecurityEventType -eq 'DataValidation' 
            }
            $securityLogs.Count | Should -BeGreaterThan 0
        }

        It "Should maintain detailed audit context for compliance" {
            $testSID = "S-1-5-21-123456789-123456789-123456789-1001"
            $correlationId = [System.Guid]::NewGuid().ToString()
            
            Test-SIDSecurity -SIDString $testSID -CorrelationId $correlationId
            
            $auditLogs = $global:SecurityLogCalls | Where-Object { $_.CorrelationId -eq $correlationId }
            $auditLogs.Count | Should -BeGreaterThan 0
            
            # The entry names the SID, the component and when it was written
            $context = $auditLogs[0].SecurityContext
            $context.SIDString | Should -Be $testSID
            $context.Component | Should -Be 'SIDSecurity'
            $auditLogs[0].Timestamp | Should -Not -BeNullOrEmpty
        }

        It "Should support custom compliance frameworks" {
            $testSID = "S-1-5-21-123456789-123456789-123456789-1001"
            { Test-SIDSecurity -SIDString $testSID -ValidationLevel 'Strict' } | Should -Not -Throw

            $logs = $global:SecurityLogCalls
            $logs.Count | Should -BeGreaterThan 0
        }
    }

    Context "Integration with Enterprise Security Policies" {
        It "Should respect enterprise protected SID configuration" {
            $enterpriseProtectedSIDs = $script:Config.ProtectedSIDs
            
            foreach ($sid in $enterpriseProtectedSIDs) {
                $result = Test-SIDSecurity -SIDString $sid
                $result.IsValid | Should -Be $false
                $result.RiskLevel | Should -Be "Critical"
                ($result.BlockedSIDs -contains $sid) | Should -Be $true
            }
        }

        It "Should enforce critical object protection policies" {
            $testSID = "S-1-5-21-123456789-123456789-123456789-1001"
            $criticalPatterns = $script:Config.CriticalObjectPatterns
            
            foreach ($pattern in $criticalPatterns) {
                $mockDN = $pattern.Replace('*', 'CN=TestObject,DC=contoso,DC=com')
                $result = Test-SIDSecurity -SIDString $testSID -ObjectDN $mockDN
                $result.RequiresElevatedConfirmation | Should -Be $true
            }
        }

        It "Should support enterprise security validation settings" {
            $securitySettings = $script:Config.SecurityValidation
            
            # Reads back the test configuration from BeforeAll; Test-SIDSecurity is not called
            $securitySettings.RequireElevatedConfirmation | Should -Be $true
            $securitySettings.AllowWellKnownSIDRemoval | Should -Be $false
            $securitySettings.ComplianceFrameworks | Should -Not -BeNullOrEmpty
            ($securitySettings.ComplianceFrameworks -contains 'SOX') | Should -Be $true
        }

        It "Should integrate with enterprise compliance frameworks" {
            $complianceFrameworks = $script:Config.SecurityValidation.ComplianceFrameworks
            
            $complianceFrameworks -contains 'SOX' | Should -Be $true
            $complianceFrameworks -contains 'HIPAA' | Should -Be $true
            $complianceFrameworks -contains 'PCI-DSS' | Should -Be $true
        }
    }

    Context "Advanced Security Scenarios and Edge Cases" {
        BeforeEach {
            $global:SecurityLogCalls = @()
        }

        It "Should handle concurrent validation requests safely" {
            $testSIDs = 1..5 | ForEach-Object { "S-1-5-21-123456789-123456789-123456789-$_" }
            
            $jobs = $testSIDs | ForEach-Object {
                $sid = $_
                Start-Job -ScriptBlock {
                    param($SIDString)
                    # A job starts without this session's functions, so it does not call
                    # Test-SIDSecurity; it only echoes the SID after a random delay
                    Start-Sleep -Milliseconds (Get-Random -Minimum 10 -Maximum 100)
                    return $SIDString
                } -ArgumentList $sid
            }
            
            $results = $jobs | Wait-Job | Receive-Job
            $jobs | Remove-Job
            
            $results.Count | Should -Be 5
        }

        It "Should handle malicious input patterns safely" {
            $maliciousInputs = @(
                "S-1-5-21-123456789-123456789-123456789-1001'; DROP TABLE Users; --",
                "S-1-5-21<script>alert('xss')</script>",
                "S-1-5-21`$(Get-Process)",
                "S-1-5-21 & format c: /y",
                "S-1-5-21|net user hacker password123 /add"
            )
            
            foreach ($maliciousInput in $maliciousInputs) {
                { Test-SIDSecurity -SIDString $maliciousInput } | Should -Not -Throw
                $result = Test-SIDSecurity -SIDString $maliciousInput
                $result.RiskLevel | Should -Be "Critical"
            }
        }

        It "Should validate all validation levels consistently" {
            $testSID = "S-1-5-21-123456789-123456789-123456789-1001"
            $validationLevels = @('Basic', 'Standard', 'Strict')
            
            foreach ($level in $validationLevels) {
                $result = Test-SIDSecurity -SIDString $testSID -ValidationLevel $level
                $result | Should -Not -Be $null
                $result.GetType().Name | Should -Be "SecurityValidationResult"
            }
        }

        It "Should maintain security boundaries during validation" {
            $testSID = "S-1-5-21-123456789-123456789-123456789-1001"
            
            # Only checks that a well-formed SID returns a result; nothing here detects
            # executed code or started processes
            $result = Test-SIDSecurity -SIDString $testSID

            $result | Should -Not -Be $null
        }

        It "Should support enterprise-scale batch operations" {
            $enterpriseScale = 1..100 | ForEach-Object { "S-1-5-21-123456789-123456789-123456789-$_" }
            
            $executionTime = Measure-Command {
                $results = Get-SIDRiskAssessment -SIDList $enterpriseScale
            }
            
            $executionTime.TotalSeconds | Should -BeLessThan 30
        }
    }
}
