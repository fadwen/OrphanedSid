#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
# Unit tests for Write-ProcessingSummary.ps1: parameters, the opening log line, and result shapes
# that carry only some of the optional keys. Write-ProcessingSummary.Scenarios.Tests.ps1 covers what
# is logged for each kind of full result.
BeforeAll {
    . "$PSScriptRoot\..\..\..\..\Private\Reporting\Write-ProcessingSummary.ps1"

    # Placeholder for the logging function defined in another file: Pester can only mock a command
    # that exists
    function Write-StructuredLog { param($Message, $Level, $Component, $CorrelationId, $LogPath, $Data) }
}

Describe "Write-ProcessingSummary" -Tag "Unit", "Private", "Reporting" {

    BeforeEach {
        Mock Write-StructuredLog { }

        # Only the two keys every result carries
        $script:MinimalResults = [PSCustomObject]@{
            TotalObjectsProcessed = 150
            ProcessingDuration = [TimeSpan]::FromMinutes(15)
        }
    }

    Context "Parameter Validation" {
        It "Should reject a null ProcessingResults" {
            { Write-ProcessingSummary -ProcessingResults $null } | Should -Throw
            Should -Invoke Write-StructuredLog -Times 0 -Exactly
        }
    }

    Context "Opening and closing log lines" {
        It "Should log the start and the end of the summary under the given correlation ID" {
            Write-ProcessingSummary -ProcessingResults $script:MinimalResults -CorrelationId "test-123"

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Message -eq 'Generating processing summary' -and $CorrelationId -eq 'test-123' -and $Component -eq 'Summary'
            }
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Message -eq 'Processing summary completed' -and $CorrelationId -eq 'test-123'
            }
        }

        It "Should generate a correlation ID when none is given" {
            Write-ProcessingSummary -ProcessingResults $script:MinimalResults

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Message -eq 'Generating processing summary' -and
                $CorrelationId -match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
            }
        }
    }

    Context "Results with only the required keys" {
        It "Should log the totals and leave out the optional lines" {
            Write-ProcessingSummary -ProcessingResults $script:MinimalResults

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter { $Message -eq 'Total objects processed: 150' }
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter { $Message -eq 'Processing duration: 00:15:00.000' }
            Should -Invoke Write-StructuredLog -Times 0 -Exactly -ParameterFilter {
                $Message -like 'Processing rate:*' -or $Message -like 'Peak memory usage:*' -or
                $Message -like 'Processing errors:*' -or $Message -like 'Orphaned SIDs found:*'
            }
        }

        It "Should report a clean directory and not export when nothing was streamed" {
            Write-ProcessingSummary -ProcessingResults $script:MinimalResults -OutputPath (Join-Path $TestDrive 'none.csv')

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter { $Message -like 'No orphaned SIDs found.*' }
            Test-Path (Join-Path $TestDrive 'none.csv') | Should -BeFalse
        }

    }

    Context "Removal results" {
        It "Should count a single removal" {
            $results = [PSCustomObject]@{
                TotalObjectsProcessed = 1
                ProcessingDuration = [TimeSpan]::FromSeconds(1)
                RemovalResults = @([PSCustomObject]@{ ObjectDN = 'CN=A,DC=contoso,DC=com'; Success = $true })
            }

            Write-ProcessingSummary -ProcessingResults $results

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter { $Message -eq 'Removal operations attempted: 1' }
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter { $Message -eq 'Successful removals: 1' }
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter { $Message -eq 'Failed removals: 0' }
        }

        It "Should log no removal summary when there were no removals" {
            Write-ProcessingSummary -ProcessingResults $script:MinimalResults

            Should -Invoke Write-StructuredLog -Times 0 -Exactly -ParameterFilter { $Message -eq '=== REMOVAL SUMMARY ===' }
        }
    }
}
