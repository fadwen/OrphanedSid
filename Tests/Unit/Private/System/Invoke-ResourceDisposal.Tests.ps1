#Requires -Version 5.1

<#
.SYNOPSIS
    Pester tests for Invoke-ResourceCleanup, in Private/System/Invoke-ResourceDisposal.ps1

.DESCRIPTION
    Invoke-ResourceCleanup releases resources at the end of a run: it disposes the MemoryManager
    and any additional IDisposable resources, then collects.

    Disposal must run even under -WhatIf; only the logging around it honours ShouldProcess.
    These tests use a small IDisposable test double so no real resources are touched.

.NOTES
    PowerShell Version: 5.1+

    Author: Jeffrey Stuhr
    Blog: https://www.techbyjeff.net
    LinkedIn: https://www.linkedin.com/in/jeffrey-stuhr-034214aa/
#>

BeforeAll {
    $projectRoot = Join-Path $PSScriptRoot '..\..\..\..'

    # The MemoryManager class is a typed parameter of Invoke-ResourceCleanup, so it must be defined
    # before that file is parsed.
    . (Join-Path $projectRoot 'Classes\MemoryManager.ps1')

    # The constants Invoke-ResourceCleanup reads are defined once, in Initialize-MemoryManager.ps1
    . (Join-Path $projectRoot 'Private\System\Initialize-MemoryManager.ps1')
    . (Join-Path $projectRoot 'Private\System\Invoke-ResourceDisposal.ps1')

    # Stub so Write-StructuredLog can be mocked. The parameter names are what the
    # -ParameterFilter blocks below bind to, so they are declared even though unused here.
    # Defined unconditionally: another test file may leave a global Write-StructuredLog with different
    # parameter names, and a mock built on that one binds the filter variables to the wrong arguments.
    function Write-StructuredLog {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
        param($Message, $Level, $Component, $CorrelationId, $Data)
    }

    # IDisposable test double. Records whether Dispose ran and can be told to fail.
    class DisposableProbe : System.IDisposable {
        [bool]$Disposed = $false
        [bool]$ThrowOnDispose = $false

        [void] Dispose() {
            if ($this.ThrowOnDispose) {
                throw 'Dispose failed on purpose'
            }
            $this.Disposed = $true
        }
    }
}

Describe 'Invoke-ResourceCleanup' -Tag 'Unit', 'System' {

    BeforeEach {
        Mock Write-StructuredLog { }
        $script:probe = [DisposableProbe]::new()
    }

    Context 'Additional resources' {
        It 'Disposes every IDisposable passed in AdditionalResources' {
            $second = [DisposableProbe]::new()

            Invoke-ResourceCleanup -AdditionalResources @($script:probe, $second) -CorrelationId 'test-cleanup-1'

            $script:probe.Disposed | Should -Be $true
            $second.Disposed | Should -Be $true
        }

        It 'Continues disposing when one resource throws' {
            $failing = [DisposableProbe]::new()
            $failing.ThrowOnDispose = $true

            { Invoke-ResourceCleanup -AdditionalResources @($failing, $script:probe) } | Should -Not -Throw

            $script:probe.Disposed | Should -Be $true
        }

        It 'Logs a warning for the resource that failed to dispose' {
            $failing = [DisposableProbe]::new()
            $failing.ThrowOnDispose = $true

            Invoke-ResourceCleanup -AdditionalResources @($failing)

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -Scope It -ParameterFilter {
                $Level -eq 'Warning' -and $Message -like 'Failed to dispose additional resource:*'
            }
        }

        It 'Accepts a null AdditionalResources value and still completes' {
            Invoke-ResourceCleanup -AdditionalResources $null -CorrelationId 'null-res'

            Should -Invoke Write-StructuredLog -Times 0 -Exactly -Scope It -ParameterFilter { $Level -eq 'Warning' }
            Should -Invoke Write-StructuredLog -Times 0 -Exactly -Scope It -ParameterFilter { $Message -eq 'Additional resource disposed successfully' }
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -Scope It -ParameterFilter {
                $Message -eq 'Resource cleanup completed' -and $CorrelationId -eq 'null-res'
            }
        }

        It 'Logs each successful disposal at Debug level' {
            Invoke-ResourceCleanup -AdditionalResources @($script:probe, [DisposableProbe]::new())

            Should -Invoke Write-StructuredLog -Times 2 -Exactly -Scope It -ParameterFilter {
                $Message -eq 'Additional resource disposed successfully' -and $Level -eq 'Debug'
            }
        }
    }

    Context 'Memory manager' {
        It 'Disposes a MemoryManager that has not been disposed' {
            $manager = [MemoryManager]::new(512, 25)

            Invoke-ResourceCleanup -MemoryManager $manager

            $manager.Disposed | Should -Be $true
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -Scope It -ParameterFilter {
                $Message -eq 'Memory manager disposed successfully' -and $Level -eq 'Information'
            }
        }

        It 'Does not dispose a MemoryManager twice' {
            $manager = [MemoryManager]::new(512, 25)
            $manager.Dispose()

            { Invoke-ResourceCleanup -MemoryManager $manager } | Should -Not -Throw

            Should -Invoke Write-StructuredLog -Times 0 -Exactly -Scope It -ParameterFilter {
                $Message -eq 'Memory manager disposed successfully'
            }
        }

        It 'Accepts a null MemoryManager and still runs the final collection' {
            Invoke-ResourceCleanup -MemoryManager $null

            Should -Invoke Write-StructuredLog -Times 0 -Exactly -Scope It -ParameterFilter { $Message -eq 'Memory manager disposed successfully' }
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -Scope It -ParameterFilter { $Message -eq 'Final garbage collection completed' }
        }
    }

    Context 'WhatIf behaviour' {
        It 'Still disposes resources under -WhatIf' {
            Invoke-ResourceCleanup -AdditionalResources @($script:probe) -WhatIf

            $script:probe.Disposed | Should -Be $true
        }

        It 'Logs the WhatIf simulation message instead of the start message under -WhatIf' {
            Invoke-ResourceCleanup -AdditionalResources @($script:probe) -WhatIf

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -Scope It -ParameterFilter {
                $Message -like 'WhatIf simulation:*'
            }
            Should -Invoke Write-StructuredLog -Times 0 -Exactly -Scope It -ParameterFilter {
                $Message -eq 'Starting resource cleanup and disposal...'
            }
        }
    }

    Context 'Correlation tracking' {
        It 'Passes the supplied CorrelationId to every log entry' {
            Invoke-ResourceCleanup -AdditionalResources @($script:probe) -CorrelationId 'corr-123'

            # Start, resource disposed, final collection, completion
            Should -Invoke Write-StructuredLog -Times 4 -Exactly -Scope It -ParameterFilter { $CorrelationId -eq 'corr-123' }
            Should -Invoke Write-StructuredLog -Times 0 -Exactly -Scope It -ParameterFilter {
                $CorrelationId -ne 'corr-123'
            }
        }

        It 'Generates a CorrelationId when given whitespace' {
            Invoke-ResourceCleanup -AdditionalResources @($script:probe) -CorrelationId '   '

            Should -Invoke Write-StructuredLog -Times 4 -Exactly -Scope It -ParameterFilter {
                $CorrelationId -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
            }
        }
    }
}
