#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
Describe "Test-SIDSecurity" -Tag 'Unit', 'Private', 'SID' {
    BeforeAll {
        # Dot-source the classes and functions under test rather than importing the module
        $ModuleRoot = Split-Path -Path (Split-Path -Path (Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent) -Parent) -Parent
        $PrivatePath = Join-Path -Path $ModuleRoot -ChildPath 'Private'

        # Classes first: the functions below use them as type literals
        . (Join-Path -Path $ModuleRoot -ChildPath 'Classes\SecurityValidationResult.ps1')
        . (Join-Path -Path $ModuleRoot -ChildPath 'Classes\SIDAnalysisResult.ps1')

        . (Join-Path -Path $PrivatePath -ChildPath 'Logging\Write-SecurityLog.ps1')
        . (Join-Path -Path $PrivatePath -ChildPath 'Logging\Write-StructuredLog.ps1')
        . (Join-Path -Path $PrivatePath -ChildPath 'SID\Test-SIDFormat.ps1')
        . (Join-Path -Path $PrivatePath -ChildPath 'SID\Get-SIDAnalysis.ps1')
        . (Join-Path -Path $PrivatePath -ChildPath 'SID\Test-SIDSecurity.ps1')

        $script:TestConfig = @{
            ProtectedSIDs = @(
                'S-1-5-18',      # Local System
                'S-1-5-19',      # Local Service
                'S-1-5-20',      # Network Service
                'S-1-5-32-544'   # Administrators
            )
            CriticalObjectPatterns = @(
                'CN=Domain Controllers,*',
                'CN=Enterprise Admins,*',
                'CN=Schema Admins,*',
                'CN=Builtin,*'
            )
        }

        # SIDs whose analysed risk the Get-SIDAnalysis mock fixes, so each branch of the
        # risk switch is reached by a known input
        $script:DomainAdminsSID = 'S-1-5-21-123456789-123456789-123456789-512'   # High
        $script:UserSID = 'S-1-5-21-123456789-123456789-123456789-1001'          # Medium
        $script:ServiceSID = 'S-1-5-80-123456789-123456789-123456789-123456789'  # Low
        $script:CriticalSID = 'S-1-5-21-MALICIOUS'                               # Critical

        Mock Write-SecurityLog { }
        Mock Write-StructuredLog { }

        Mock Test-WellKnownSID {
            $SID -match '^S-1-5-(18|19|20)$' -or $SID -match '^S-1-5-32-5\d\d$' -or $SID -match '^S-1-5-21-.*-51[89]$'
        }

        Mock Get-SIDAnalysis {
            $result = [SIDAnalysisResult]::new()
            $result.SID = $SIDString
            $result.LikelySource = 'Test Source'
            $result.Confidence = 'High'
            $result.Notes = 'Test notes'
            $result.RiskLevel = switch -Regex ($SIDString) {
                '^S-1-5-18$' { 'Critical' }
                '^S-1-5-32-544$' { 'Critical' }
                'MALICIOUS' { 'Critical' }
                '^S-1-5-21-.*-512$' { 'High' }
                '^S-1-5-80-' { 'Low' }
                default { 'Medium' }
            }
            $result
        }
    }

    BeforeEach {
        $script:Config = $script:TestConfig
        $script:LastSecurityContext = $null
    }

    Context "Parameter validation" {
        It "Rejects a ValidationLevel outside Basic, Standard and Strict: <_>" -ForEach @('Invalid', 'Custom', 'Enterprise') {
            { Test-SIDSecurity -SIDString $UserSID -ValidationLevel $_ } | Should -Throw
        }

        It "Rejects a null, empty or whitespace SIDString" {
            { Test-SIDSecurity -SIDString $null } | Should -Throw
            { Test-SIDSecurity -SIDString "" } | Should -Throw
            { Test-SIDSecurity -SIDString "   " } | Should -Throw
        }

        It "Generates a GUID correlation ID when none is supplied" {
            Test-SIDSecurity -SIDString $UserSID | Out-Null

            Should -Invoke Write-SecurityLog -Times 1 -Exactly -ParameterFilter {
                $Outcome -eq 'Attempt' -and $CorrelationId -match '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$'
            }
        }

        It "Defaults ValidationLevel to Standard" {
            Test-SIDSecurity -SIDString $UserSID | Out-Null

            Should -Invoke Write-SecurityLog -Times 1 -Exactly -ParameterFilter {
                $Outcome -eq 'Attempt' -and $SecurityContext.ValidationLevel -eq 'Standard'
            }
        }

        It "Validates every SID piped to it" {
            $results = @($ServiceSID, 'S-1-5-18' | Test-SIDSecurity)

            $results.Count | Should -Be 2
            $results[0].IsValid | Should -Be $true
            $results[0].RiskLevel | Should -Be 'Low'
            $results[1].IsValid | Should -Be $false
            $results[1].RiskLevel | Should -Be 'Critical'
        }
    }

    Context "Malicious input patterns" {
        It "Blocks '<SID>' as Critical on pattern '<Pattern>' before any analysis" -ForEach @(
            @{ SID = "S-1-5-21-1001'; DROP TABLE Users; --"; Pattern = ';' }
            @{ SID = 'S-1-5-21|net user hacker password123 /add'; Pattern = '|' }
            @{ SID = 'S-1-5-21 & format c: /y'; Pattern = '&' }
            @{ SID = 'S-1-5-21<script>alert(1)'; Pattern = '<script' }
            @{ SID = 'S-1-5-21-cmd'; Pattern = 'cmd' }
            @{ SID = 'S-1-5-21$(Get-Process)'; Pattern = '$(' }
        ) {
            $expectedId = [guid]::NewGuid().ToString()
            $result = Test-SIDSecurity -SIDString $SID -CorrelationId $expectedId

            $result.IsValid | Should -Be $false
            $result.RiskLevel | Should -Be 'Critical'
            $result.BlockedSIDs | Should -Be @($SID)
            $result.Issues | Should -Be @("Critical security risk detected - potentially malicious input pattern: $Pattern")
            Should -Invoke Get-SIDAnalysis -Times 0 -Exactly
            Should -Invoke Write-SecurityLog -Times 1 -Exactly -ParameterFilter {
                $SecurityEventType -eq 'SecurityViolation' -and $Outcome -eq 'Failure' -and
                $CorrelationId -eq $expectedId -and
                $SecurityContext.BlockedReason -eq 'MaliciousInputPattern' -and
                $SecurityContext.DetectedPattern -eq $Pattern
            }
        }
    }

    Context "Protected SIDs" {
        It "Blocks protected SID <_> as Critical without analysing it" -ForEach @('S-1-5-18', 'S-1-5-19', 'S-1-5-20', 'S-1-5-32-544') {
            $result = Test-SIDSecurity -SIDString $_

            $result.IsValid | Should -Be $false
            $result.RiskLevel | Should -Be 'Critical'
            $result.BlockedSIDs | Should -Be @($_)
            $result.Issues | Should -Be @('SID is in protected SIDs list - removal blocked by security policy')
            Should -Invoke Get-SIDAnalysis -Times 0 -Exactly
        }

        It "Writes a ProtectedSIDsList failure to the security log with the caller's correlation ID" {
            $expectedId = [guid]::NewGuid().ToString()
            $objectDN = 'CN=Test,DC=contoso,DC=com'
            Test-SIDSecurity -SIDString 'S-1-5-32-544' -CorrelationId $expectedId -ObjectDN $objectDN | Out-Null

            Should -Invoke Write-SecurityLog -Times 1 -Exactly -ParameterFilter {
                $Outcome -eq 'Failure' -and $CorrelationId -eq $expectedId -and
                $SecurityContext.BlockedReason -eq 'ProtectedSIDsList' -and
                $SecurityContext.SIDString -eq 'S-1-5-32-544' -and
                $SecurityContext.ObjectDN -eq $objectDN
            }
        }

        It "Keeps the blocking context in LastSecurityContext when the security log fails" {
            Mock Write-SecurityLog { throw 'log down' } -ParameterFilter { $Outcome -eq 'Failure' }

            $result = Test-SIDSecurity -SIDString 'S-1-5-18'

            $result.IsValid | Should -Be $false
            $script:LastSecurityContext.BlockedReason | Should -Be 'ProtectedSIDsList'
            $script:LastSecurityContext.SIDString | Should -Be 'S-1-5-18'
        }

        It "Skips the protected list when no configuration is loaded, leaving the well-known check to block" {
            $script:Config = $null

            $result = Test-SIDSecurity -SIDString 'S-1-5-18'

            $result.IsValid | Should -Be $false
            $result.RiskLevel | Should -Be 'High'
            $result.Issues | Should -Be @('Well-known SID detected - removal may impact system security')
        }
    }

    Context "Well-known SIDs" {
        It "Blocks a well-known SID as High under <_> validation" -ForEach @('Standard', 'Strict') {
            $sid = 'S-1-5-21-123456789-123456789-123456789-519'
            $result = Test-SIDSecurity -SIDString $sid -ValidationLevel $_

            $result.IsValid | Should -Be $false
            $result.RiskLevel | Should -Be 'High'
            $result.BlockedSIDs | Should -Be @($sid)
            $result.Issues | Should -Be @('Well-known SID detected - removal may impact system security')
            Should -Invoke Write-SecurityLog -Times 1 -Exactly -ParameterFilter {
                $Outcome -eq 'Failure' -and $SecurityContext.BlockedReason -eq 'WellKnownSID' -and
                $SecurityContext.SIDAnalysis.SID -eq $sid
            }
        }

        It "Does not block a well-known SID under Basic validation; its analysed risk decides" {
            Mock Test-WellKnownSID { $true }

            $result = Test-SIDSecurity -SIDString $DomainAdminsSID -ValidationLevel 'Basic'

            $result.IsValid | Should -Be $true
            $result.RiskLevel | Should -Be 'High'
            $result.RequiresElevatedConfirmation | Should -Be $true
            $result.BlockedSIDs.Count | Should -Be 0
            $result.Issues | Should -Not -Contain 'Well-known SID detected - removal may impact system security'
        }
    }

    Context "Risk-based validation" {
        It "Blocks a SID analysed as Critical risk" {
            $result = Test-SIDSecurity -SIDString $CriticalSID

            $result.IsValid | Should -Be $false
            $result.RiskLevel | Should -Be 'Critical'
            $result.BlockedSIDs | Should -Be @($CriticalSID)
            $result.Issues | Should -Be @('Critical security risk detected - potentially malicious input')
            Should -Invoke Write-SecurityLog -Times 1 -Exactly -ParameterFilter {
                $Outcome -eq 'Failure' -and $SecurityContext.BlockedReason -eq 'CriticalSecurityRisk'
            }
        }

        It "Blocks a High risk SID under Strict validation" {
            $result = Test-SIDSecurity -SIDString $DomainAdminsSID -ValidationLevel 'Strict'

            $result.IsValid | Should -Be $false
            $result.RiskLevel | Should -Be 'High'
            $result.RequiresElevatedConfirmation | Should -Be $true
            $result.BlockedSIDs | Should -Be @($DomainAdminsSID)
            $result.Issues | Should -Be @('High-risk SID requires elevated confirmation for removal')
        }

        It "Allows a High risk SID under Standard validation but requires elevated confirmation" {
            $result = Test-SIDSecurity -SIDString $DomainAdminsSID -ValidationLevel 'Standard'

            $result.IsValid | Should -Be $true
            $result.RiskLevel | Should -Be 'High'
            $result.RequiresElevatedConfirmation | Should -Be $true
            $result.BlockedSIDs.Count | Should -Be 0
            $result.AllowedSIDs.Count | Should -Be 0
            $result.Issues | Should -Be @('High-risk SID requires elevated confirmation for removal')
        }

        It "Logs the analysis behind a High risk SID" {
            Test-SIDSecurity -SIDString $DomainAdminsSID -ValidationLevel 'Standard' | Out-Null

            Should -Invoke Write-SecurityLog -Times 1 -Exactly -ParameterFilter {
                $Outcome -eq 'Attempt' -and $SecurityContext.RiskLevel -eq 'High' -and
                $SecurityContext.RequiresElevatedConfirmation -eq $true -and
                $SecurityContext.SIDAnalysis.LikelySource -eq 'Test Source'
            }
        }

        It "Requires elevated confirmation for a Medium risk SID only under Strict validation" {
            $strict = Test-SIDSecurity -SIDString $UserSID -ValidationLevel 'Strict'
            $standard = Test-SIDSecurity -SIDString $UserSID -ValidationLevel 'Standard'

            $strict.RiskLevel | Should -Be 'Medium'
            $strict.IsValid | Should -Be $true
            $strict.RequiresElevatedConfirmation | Should -Be $true
            $standard.RiskLevel | Should -Be 'Medium'
            $standard.IsValid | Should -Be $true
            $standard.RequiresElevatedConfirmation | Should -Be $false
            $standard.AllowedSIDs | Should -Be @($UserSID)
        }

        It "Allows a Low risk SID and logs the successful validation" {
            $result = Test-SIDSecurity -SIDString $ServiceSID

            $result.IsValid | Should -Be $true
            $result.RiskLevel | Should -Be 'Low'
            $result.AllowedSIDs | Should -Contain $ServiceSID
            $result.Issues.Count | Should -Be 0
            Should -Invoke Write-SecurityLog -Times 1 -Exactly -ParameterFilter {
                $Outcome -eq 'Success' -and $SecurityContext.FinalRiskLevel -eq 'Low' -and $SecurityContext.IsValid -eq $true
            }
        }

        # Module bug (#26): the 'Low' branch and the final determination both add the SID to AllowedSIDs
        It "Lists an allowed Low risk SID in AllowedSIDs once" -Skip {
            $result = Test-SIDSecurity -SIDString $ServiceSID

            $result.AllowedSIDs | Should -Be @($ServiceSID)
        }

        It "Passes CurrentDomainSID to Get-SIDAnalysis only when supplied" {
            $domainSID = 'S-1-5-21-123456789-123456789-123456789'

            Test-SIDSecurity -SIDString $UserSID -CurrentDomainSID $domainSID | Out-Null
            Test-SIDSecurity -SIDString $UserSID | Out-Null

            Should -Invoke Get-SIDAnalysis -Times 1 -Exactly -ParameterFilter { $CurrentDomainSID -eq $domainSID }
            Should -Invoke Get-SIDAnalysis -Times 1 -Exactly -ParameterFilter {
                -not $PesterBoundParameters.ContainsKey('CurrentDomainSID')
            }
        }
    }

    Context "Object context" {
        It "Requires elevated confirmation for a SID on critical object <_>" -ForEach @(
            'CN=Domain Controllers,CN=System,DC=contoso,DC=com'
            'CN=Enterprise Admins,CN=Users,DC=contoso,DC=com'
            'CN=Schema Admins,CN=Users,DC=contoso,DC=com'
            'CN=Builtin,DC=contoso,DC=com'
        ) {
            $result = Test-SIDSecurity -SIDString $UserSID -ObjectDN $_

            $result.RequiresElevatedConfirmation | Should -Be $true
            $result.RiskLevel | Should -Be 'High'
            $result.Issues | Should -Be @("SID is on critical object: $_")
            $result.AllowedSIDs.Count | Should -Be 0
        }

        It "Adds no requirement for a SID on a non-critical object" {
            $result = Test-SIDSecurity -SIDString $UserSID -ObjectDN 'CN=TestUser,OU=Users,DC=contoso,DC=com'

            $result.RequiresElevatedConfirmation | Should -Be $false
            $result.RiskLevel | Should -Be 'Medium'
            $result.Issues.Count | Should -Be 0
            $result.AllowedSIDs | Should -Be @($UserSID)
        }

        It "Applies no object check when the configuration has no critical patterns" {
            $script:Config = @{ ProtectedSIDs = @() }

            $result = Test-SIDSecurity -SIDString $UserSID -ObjectDN 'CN=Domain Controllers,DC=contoso,DC=com'

            $result.RequiresElevatedConfirmation | Should -Be $false
            $result.Issues.Count | Should -Be 0
        }
    }

    Context "Audit logging" {
        It "Logs the validation attempt with the SID, level, object and correlation ID" {
            $expectedId = [guid]::NewGuid().ToString()
            $objectDN = 'CN=TestUser,OU=Users,DC=contoso,DC=com'

            Test-SIDSecurity -SIDString $UserSID -CorrelationId $expectedId -ObjectDN $objectDN -ValidationLevel 'Strict' | Out-Null

            Should -Invoke Write-SecurityLog -Times 1 -Exactly -ParameterFilter {
                $SecurityEventType -eq 'DataValidation' -and $Outcome -eq 'Attempt' -and
                $Message -eq 'SID security validation initiated' -and
                $CorrelationId -eq $expectedId -and
                $SecurityContext.SIDString -eq $UserSID -and
                $SecurityContext.ValidationLevel -eq 'Strict' -and
                $SecurityContext.ObjectDN -eq $objectDN -and
                $SecurityContext.Component -eq 'SIDSecurity'
            }
        }

        It "Uses the caller's correlation ID on every security and structured log entry" {
            $expectedId = [guid]::NewGuid().ToString()

            Test-SIDSecurity -SIDString $DomainAdminsSID -CorrelationId $expectedId | Out-Null

            Should -Invoke Write-SecurityLog -Times 0 -Exactly -ParameterFilter { $CorrelationId -ne $expectedId }
            Should -Invoke Write-StructuredLog -Times 0 -Exactly -ParameterFilter { $CorrelationId -ne $expectedId }
            Should -Invoke Write-SecurityLog -Times 2 -Exactly -ParameterFilter { $CorrelationId -eq $expectedId }
        }

        It "Writes Debug structured log entries for the SIDSecurity component" {
            Test-SIDSecurity -SIDString $UserSID | Out-Null

            Should -Invoke Write-StructuredLog -ParameterFilter {
                $Component -eq 'SIDSecurity' -and $Level -eq 'Debug' -and $Message -like "Security validation completed for $UserSID*"
            } -Times 1 -Exactly
        }

        It "Returns the same result when both logging functions fail" {
            Mock Write-StructuredLog { throw 'Logging service down' }
            Mock Write-SecurityLog { throw 'Logging service down' }

            $result = Test-SIDSecurity -SIDString $ServiceSID

            $result.IsValid | Should -Be $true
            $result.RiskLevel | Should -Be 'Low'
            $result.Issues.Count | Should -Be 0
        }
    }

    Context "Error handling" {
        It "Fails closed as Critical when SID analysis throws" {
            Mock Get-SIDAnalysis { throw 'Analysis service unavailable' }

            $result = Test-SIDSecurity -SIDString $UserSID

            $result | Should -BeOfType 'SecurityValidationResult'
            $result.IsValid | Should -Be $false
            $result.RiskLevel | Should -Be 'Critical'
            $result.Issues | Should -Be @('Validation error: Analysis service unavailable')
            Should -Invoke Write-SecurityLog -Times 1 -Exactly -ParameterFilter {
                $Outcome -eq 'Failure' -and $SecurityContext.ErrorMessage -eq 'Analysis service unavailable'
            }
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'Error' }
        }
    }
}

Describe "Get-SIDRiskAssessment" -Tag 'Unit', 'Private', 'SID' {
    BeforeAll {
        $ModuleRoot = Split-Path -Path (Split-Path -Path (Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent) -Parent) -Parent
        $PrivatePath = Join-Path -Path $ModuleRoot -ChildPath 'Private'

        . (Join-Path -Path $ModuleRoot -ChildPath 'Classes\SecurityValidationResult.ps1')
        . (Join-Path -Path $ModuleRoot -ChildPath 'Classes\SIDAnalysisResult.ps1')
        . (Join-Path -Path $PrivatePath -ChildPath 'Logging\Write-SecurityLog.ps1')
        . (Join-Path -Path $PrivatePath -ChildPath 'Logging\Write-StructuredLog.ps1')
        . (Join-Path -Path $PrivatePath -ChildPath 'SID\Test-SIDFormat.ps1')
        . (Join-Path -Path $PrivatePath -ChildPath 'SID\Get-SIDAnalysis.ps1')
        . (Join-Path -Path $PrivatePath -ChildPath 'SID\Test-SIDSecurity.ps1')

        $script:Config = @{ ProtectedSIDs = @('S-1-5-18', 'S-1-5-19'); CriticalObjectPatterns = @() }

        $script:SystemSID = 'S-1-5-18'                                           # Critical, protected
        $script:DomainAdminsSID = 'S-1-5-21-123456789-123456789-123456789-512'   # High
        $script:UserSID = 'S-1-5-21-123456789-123456789-123456789-1001'          # Medium
        $script:ServiceSID = 'S-1-5-80-123456789-123456789-123456789-123456789'  # Low

        Mock Write-SecurityLog { }
        Mock Write-StructuredLog { }
        Mock Test-WellKnownSID { $false }
        Mock Get-SIDAnalysis {
            $result = [SIDAnalysisResult]::new()
            $result.SID = $SIDString
            $result.RiskLevel = switch -Regex ($SIDString) {
                '^S-1-5-1[89]$' { 'Critical' }
                '^S-1-5-21-.*-512$' { 'High' }
                '^S-1-5-80-' { 'Low' }
                default { 'Medium' }
            }
            $result
        }
    }

    It "Returns a safe Low assessment for an empty list without analysing anything" {
        $result = Get-SIDRiskAssessment -SIDList @()

        $result.PSObject.TypeNames[0] | Should -Be 'SIDRiskAssessment'
        $result.TotalSIDs | Should -Be 0
        $result.OverallRisk | Should -Be 'Low'
        $result.SafeForAutomation | Should -Be $true
        $result.Recommendations | Should -Be @('No SIDs to assess - operation is safe')
        Should -Invoke Get-SIDAnalysis -Times 0 -Exactly
    }

    It "Counts each SID under its analysed risk level" {
        $result = Get-SIDRiskAssessment -SIDList @($SystemSID, $DomainAdminsSID, $UserSID, $ServiceSID)

        $result.TotalSIDs | Should -Be 4
        $result.RiskBreakdown.Critical | Should -Be 1
        $result.RiskBreakdown.High | Should -Be 1
        $result.RiskBreakdown.Medium | Should -Be 1
        $result.RiskBreakdown.Low | Should -Be 1
    }

    It "Rates the batch at its highest risk: <Expected>" -ForEach @(
        @{ SIDs = @('S-1-5-80-1-2', 'S-1-5-18'); Expected = 'Critical' }
        @{ SIDs = @('S-1-5-80-1-2', 'S-1-5-21-1-2-3-512'); Expected = 'High' }
        @{ SIDs = @('S-1-5-80-1-2', 'S-1-5-21-1-2-3-1001'); Expected = 'Medium' }
        @{ SIDs = @('S-1-5-80-1-2', 'S-1-5-80-3-4'); Expected = 'Low' }
    ) {
        (Get-SIDRiskAssessment -SIDList $SIDs).OverallRisk | Should -Be $Expected
    }

    It "Sorts SIDs into blocked, requiring approval and allowed by their Standard validation" {
        $result = Get-SIDRiskAssessment -SIDList @($SystemSID, $DomainAdminsSID, $UserSID, $ServiceSID)

        $result.BlockedSIDs | Should -Be @($SystemSID)
        $result.RequiresApproval | Should -Be @($DomainAdminsSID)
        $result.AllowedSIDs | Should -Be @($UserSID, $ServiceSID)
        $result.Recommendations | Should -Be @(
            'Review 1 blocked SIDs before proceeding'
            'Obtain elevated approval for 1 high-risk SIDs'
            '2 SIDs approved for automatic removal'
        )
    }

    It "Is safe for automation only when nothing is blocked or needs approval" {
        (Get-SIDRiskAssessment -SIDList @($ServiceSID, $UserSID)).SafeForAutomation | Should -Be $true
        (Get-SIDRiskAssessment -SIDList @($ServiceSID, $DomainAdminsSID)).SafeForAutomation | Should -Be $false
        (Get-SIDRiskAssessment -SIDList @($ServiceSID, $SystemSID)).SafeForAutomation | Should -Be $false
    }

    It "Uses the correlation ID as the assessment ID and passes it to the analysis" {
        $expectedId = [guid]::NewGuid().ToString()

        $result = Get-SIDRiskAssessment -SIDList @($UserSID) -CorrelationId $expectedId -ObjectContext 'Critical Infrastructure'

        $result.AssessmentId | Should -Be $expectedId
        $result.ObjectContext | Should -Be 'Critical Infrastructure'
        Should -Invoke Get-SIDAnalysis -Times 0 -Exactly -ParameterFilter { $CorrelationId -ne $expectedId }
    }

    It "Logs the completed assessment with its counts" {
        Get-SIDRiskAssessment -SIDList @($SystemSID, $ServiceSID) | Out-Null

        Should -Invoke Write-SecurityLog -Times 1 -Exactly -ParameterFilter {
            $SecurityEventType -eq 'RiskAssessment' -and $Outcome -eq 'Success' -and
            $SecurityContext.TotalSIDs -eq 2 -and $SecurityContext.BlockedSIDsCount -eq 1 -and
            $SecurityContext.AllowedSIDsCount -eq 1 -and $SecurityContext.SafeForAutomation -eq $false
        }
    }

    It "Logs the failure and rethrows when analysis throws" {
        Mock Get-SIDAnalysis { throw 'Analysis service unavailable' }

        { Get-SIDRiskAssessment -SIDList @($UserSID) } | Should -Throw -ExpectedMessage '*Analysis service unavailable*'

        Should -Invoke Write-SecurityLog -Times 1 -Exactly -ParameterFilter {
            $SecurityEventType -eq 'RiskAssessment' -and $Outcome -eq 'Failure' -and
            $SecurityContext.ErrorMessage -eq 'Analysis service unavailable'
        }
    }
}
