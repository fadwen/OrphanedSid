#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
# Unit tests for Write-ProcessingSummary.ps1: parameters, logging and CSV export.
# Write-ProcessingSummary.Scenarios.Tests.ps1 covers what is logged for each kind of result.
BeforeAll {
    . "$PSScriptRoot\..\..\..\..\Private\Reporting\Write-ProcessingSummary.ps1"
}

Describe "Write-ProcessingSummary" -Tag "Unit", "Private", "Reporting" {
    BeforeAll {
        # Placeholders for logging functions defined in other files: Pester can only mock a command
        # that exists
        function Write-StructuredLog {
            param($Message, $Level, $Component, $CorrelationId)
            Write-Host "Mock Write-StructuredLog: [$Level] $Message" -ForegroundColor Yellow
        }
        
        function Write-StructuredLogEntry {
            param($Message, $Level, $Component, $CorrelationId, $Details)
            Write-Host "Mock Write-StructuredLogEntry: [$Level] $Message" -ForegroundColor Yellow
        }
        
        function Format-LogMessage {
            param($Message, $Level, $Component, $CorrelationId)
            return "[$Level] $Message"
        }
        
        function Get-LoggingSystemState {
            return @{ LogPath = "" }
        }
    }
    
    BeforeEach {
        # Mock console and file operations
        Mock Add-Content { }
        Mock Write-Warning { }
        Mock Write-Error { }
        Mock Write-Information { }
        Mock Write-Debug { }
        Mock Write-Verbose { }
        Mock Write-Host { }
        Mock Write-Output { }
        
        Mock Write-StructuredLog { Write-Host "Mock Write-StructuredLog called" } -Verifiable

        Mock Export-Csv { }

        Mock Write-Host { }
        Mock Write-Output { }
        
        # Sample processing statistics with TimeSpan objects
        $script:TestStatistics = [PSCustomObject]@{
            TotalObjectsProcessed = 150
            OrphanedSIDsFound = 12
            OrphanedSIDsRemoved = 8
            ErrorCount = 2
            ProcessingDuration = [TimeSpan]::FromMinutes(15)
            StartTime = Get-Date
            EndTime = (Get-Date).AddMinutes(15)
        }
        
        # Test data with StreamingManager for CSV export tests
        $script:TestStatisticsWithStreaming = [PSCustomObject]@{
            TotalObjectsProcessed = 150
            OrphanedSIDsFound = 12
            OrphanedSIDsRemoved = 8
            ErrorCount = 2
            ProcessingDuration = [TimeSpan]::FromMinutes(15)
            StartTime = Get-Date
            EndTime = (Get-Date).AddMinutes(15)
            StreamingManager = [PSCustomObject]@{
                Summary = [PSCustomObject]@{
                    TotalResults = 12
                }
            }
        }
        
        # Stand-in for the streaming manager's ExportToCsv method
        Add-Member -InputObject $script:TestStatisticsWithStreaming.StreamingManager -MemberType ScriptMethod -Name ExportToCsv -Value { 
            param($path) 
            # Reaches the Export-Csv mock, so the export can be asserted
            Export-Csv -Path $path -InputObject @() -NoTypeInformation
        }
        
        # Sample orphaned SIDs
        $script:TestOrphanedSIDs = @(
            [PSCustomObject]@{
                SID = 'S-1-5-21-1234567890-987654321-1122334455-1001'
                ObjectPath = 'OU=TestOU,DC=domain,DC=com'
                ObjectType = 'organizationalUnit'
                Removed = $true
            },
            [PSCustomObject]@{
                SID = 'S-1-5-21-1234567890-987654321-1122334455-1002'
                ObjectPath = 'CN=TestUser,OU=Users,DC=domain,DC=com'
                ObjectType = 'user'
                Removed = $false
            }
        )
        
        # Sample errors
        $script:TestErrors = @(
            [PSCustomObject]@{
                Timestamp = Get-Date
                Level = 'Error'
                Message = 'Failed to process object: Access denied'
                Exception = 'System.UnauthorizedAccessException'
            }
        )
    }
    
    Context "Parameter Validation" {
        It "Should accept valid ProcessingResults parameter" {
            { Write-ProcessingSummary -ProcessingResults $script:TestStatistics } | Should -Not -Throw
        }

        It "Should accept valid OutputPath parameter" {
            { Write-ProcessingSummary -ProcessingResults $script:TestStatistics -OutputPath "C:\temp\test.csv" } | Should -Not -Throw
        }

        It "Should accept AutomationMode switch" {
            { Write-ProcessingSummary -ProcessingResults $script:TestStatistics -AutomationMode } | Should -Not -Throw
        }

        It "Should accept CorrelationId parameter" {
            { Write-ProcessingSummary -ProcessingResults $script:TestStatistics -CorrelationId "test-123" } | Should -Not -Throw
        }
    }
    
    Context "Console Output" {
        It "Should display processing summary to console" {
            Write-ProcessingSummary -ProcessingResults $script:TestStatistics
            
            Should -Invoke Write-StructuredLog -Scope It
        }
        
        It "Should display orphaned SIDs summary when provided" {
            Write-ProcessingSummary -ProcessingResults $script:TestStatistics
            
            Should -Invoke Write-StructuredLog -Scope It
        }
        
        It "Should display error summary when errors provided" {
            Write-ProcessingSummary -ProcessingResults $script:TestStatistics
            
            Should -Invoke Write-StructuredLog -Scope It
        }
    }
    
    Context "CSV Export" {
        It "Should export to CSV when OutputPath specified" {
            Write-ProcessingSummary -ProcessingResults $script:TestStatisticsWithStreaming -OutputPath "C:\temp\test.csv"
            
            Should -Invoke Export-Csv -Times 1 -Exactly -Scope It
        }
        
        It "Should not export to CSV when OutputPath not specified" {
            Write-ProcessingSummary -ProcessingResults $script:TestStatistics
            
            Should -Invoke Export-Csv -Times 0 -Exactly -Scope It
        }
    }
    
    Context "Automation Mode" {
        It "Should output structured data in automation mode" {
            Mock Write-Information { }
            
            Write-ProcessingSummary -ProcessingResults $script:TestStatistics -AutomationMode
            
            Should -Invoke Write-Information -Times 1
        }
        
        It "Should not display console output in automation mode" {
            Write-ProcessingSummary -ProcessingResults $script:TestStatistics -AutomationMode
            
            Should -Invoke Write-StructuredLog -Scope It
        }
    }
    
    Context "Structured Logging" {
        It "Should log processing summary" {
            Write-ProcessingSummary -ProcessingResults $script:TestStatistics
            
            Should -Invoke Write-StructuredLog -Scope It
        }
        
        It "Should log with correct parameters" {
            Write-ProcessingSummary -ProcessingResults $script:TestStatistics
            
            Should -Invoke Write-StructuredLog -Scope It
        }
    }
    
    Context "Error Handling" {
        It "Should handle missing ProcessingResults gracefully" {
            { Write-ProcessingSummary -ProcessingResults $null } | Should -Throw
        }
        
        It "Should handle invalid OutputPath gracefully" {
            # Use streaming data and mock the ExportToCsv method to throw
            $TestDataWithError = $script:TestStatisticsWithStreaming.PSObject.Copy()
            Add-Member -InputObject $TestDataWithError.StreamingManager -MemberType ScriptMethod -Name ExportToCsv -Value { 
                param($path) 
                throw "Access denied"
            } -Force
            
            { Write-ProcessingSummary -ProcessingResults $TestDataWithError -OutputPath "Z:\invalid\path.csv" } | Should -Not -Throw
        }
        
        It "Should log errors during CSV export" {
            # Use streaming data and mock the ExportToCsv method to throw
            $TestDataWithError = $script:TestStatisticsWithStreaming.PSObject.Copy()
            Add-Member -InputObject $TestDataWithError.StreamingManager -MemberType ScriptMethod -Name ExportToCsv -Value { 
                param($path) 
                throw "Access denied"
            } -Force
            
            Write-ProcessingSummary -ProcessingResults $TestDataWithError -OutputPath "Z:\invalid\path.csv"
            
            Should -Invoke Write-StructuredLog -ParameterFilter {
                $Level -eq 'Error'
            } -Scope It
        }
    }
}
